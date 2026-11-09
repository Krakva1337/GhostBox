package app.ghostbox.ghostbox

import android.app.Activity
import android.app.DownloadManager
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.VpnService
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.ZipFile
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "app.ghostbox.ghostbox/vpn"
        private const val ICON_CHANNEL = "app.ghostbox.ghostbox/app_icon"
        private const val UPDATE_CHANNEL = "app.ghostbox.ghostbox/app_update"
        private const val VPN_PERMISSION_REQUEST = 4137
        private const val NOTIFICATION_PERMISSION_REQUEST = 4138
        private const val LOG_EXPORT_REQUEST = 4139
        private const val DOWNLOADS_PERMISSION_REQUEST = 4140
        private const val APPEARANCE_FILE_REQUEST = 4141
    }

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var pendingProfileName: String? = null
    private var pendingMemoryMb = 128
    private var pendingCore = "sing-box"
    private var pendingProxyOnly = false
    private var pendingKeepXray = false
    private var pendingLogExportResult: MethodChannel.Result? = null
    private var pendingLogExportContent: ByteArray? = null
    private var pendingDownloadsResult: MethodChannel.Result? = null
    private var pendingDownloadsSource: String? = null
    private var pendingDownloadsName: String? = null
    private var pendingAppearanceResult: MethodChannel.Result? = null
    private var pendingAppearanceMaxBytes = 0
    @Volatile private var updateInProgress = false
    @Volatile private var staleVpnCleanupScheduled = false

    private val xrayProcessName get() = "$packageName:xraycore2"
    private val singBoxProcessName get() = "$packageName:singboxcore2"
    private val legacyVpnProcessNames get() =
        setOf("$packageName:xray", "$packageName:singboxcore")
    private val allVpnProcessNames get() =
        legacyVpnProcessNames + setOf(xrayProcessName, singBoxProcessName)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInstallationId" -> {
                        try {
                            result.success(DeviceIdentityStore.installationId(this))
                        } catch (_: Exception) {
                            // Do not include the identifier or storage contents
                            // in platform errors or diagnostic logs.
                            result.error("identity_unavailable", "Unable to load the saved device identity", null)
                        }
                    }
                    "startVpn" -> {
                        if (pendingVpnResult != null) {
                            result.error("busy", "VPN permission request is already open", null)
                            return@setMethodCallHandler
                        }
                        pendingConfig = call.argument<String>("config")
                        pendingProfileName = call.argument<String>("profileName") ?: "GhostBox"
                        pendingMemoryMb = (call.argument<Int>("memoryMb") ?: 128).coerceIn(64, 256)
                        pendingCore = call.argument<String>("core")?.lowercase()?.takeIf {
                            it == "xray" || it == "sing-box"
                        } ?: "sing-box"
                        pendingProxyOnly = call.argument<Boolean>("proxyOnly") ?: false
                        pendingKeepXray = call.argument<Boolean>("keepXray") ?: false
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
                            call.argument<Boolean>("keepXray") != true &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            pendingVpnResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                NOTIFICATION_PERMISSION_REQUEST,
                            )
                        } else {
                            requestVpnPermission(result)
                        }
                    }
                    "reloadXrayProxy" -> reloadXrayProxy(call, result)
                    "stopVpn" -> {
                        try {
                            // Ask both native services to close their VPN file
                            // descriptors before stopping. stopService() can
                            // destroy the service before asynchronous libbox
                            // cleanup releases Android's TUN route.
                            VpnStateStore.update(this) {
                                it.put("state", "stopping")
                                    .put("xrayProxyState", "stopping")
                                    .put("singBoxStopComplete", false)
                                    .put("xrayStopComplete", false)
                                    .remove("connectedAtMs")
                            }
                            val stopIntent = Intent("app.ghostbox.STOP_VPN")
                            startService(Intent(stopIntent).setClass(this, GhostBoxVpnService::class.java))
                            startService(Intent(stopIntent).setClass(this, XrayVpnService::class.java))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("stop_failed", error.message ?: error.toString(), null)
                        }
                    }
                    "cleanupVpnBeforeConnect" -> cleanupVpnBeforeConnect(result)
                    "forceCleanupVpn" -> forceCleanupVpn(result)
                    "resetVpnConfiguration" -> {
                        // VPN JSON is handed to the native services in memory;
                        // GhostBox does not persist user configurations on Android.
                        // Reuse the owned-process cleanup path, which clears all
                        // persisted runtime/error state after both services stop.
                        pendingConfig = null
                        pendingProfileName = null
                        pendingCore = "sing-box"
                        pendingProxyOnly = false
                        pendingKeepXray = false
                        forceCleanupVpn(result)
                    }
                    "appearanceStorageDirectory" -> {
                        val directory = File(filesDir, "appearance")
                        directory.mkdirs()
                        result.success(directory.absolutePath)
                    }
                    "pickAppearanceFile" -> {
                        if (pendingAppearanceResult != null) {
                            result.error("busy", "A file picker is already open", null)
                        } else {
                            val kind = call.argument<String>("kind")
                            val mime = when (kind) {
                                "font" -> arrayOf("font/ttf", "font/otf", "application/font-sfnt", "application/octet-stream")
                                "background" -> arrayOf("image/*")
                                else -> null
                            }
                            if (mime == null) {
                                result.error("invalid_kind", "Expected font or background", null)
                            } else {
                                pendingAppearanceResult = result
                                pendingAppearanceMaxBytes = if (kind == "font") 5 * 1024 * 1024 else 12 * 1024 * 1024
                                try { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = if (kind == "background") "image/*" else "*/*"
                                    putExtra(Intent.EXTRA_MIME_TYPES, mime)
                                }, APPEARANCE_FILE_REQUEST) } catch (error: Exception) {
                                    pendingAppearanceResult = null
                                    result.error("picker_unavailable", error.message, null)
                                }
                            }
                        }
                    }
                    "vpnState" -> result.success(currentVpnState())
                    "vpnStopComplete" -> {
                        val state = VpnStateStore.read(this)
                        result.success(
                            state.optBoolean("singBoxStopComplete") &&
                                state.optBoolean("xrayStopComplete"),
                        )
                    }
                    "vpnConnectedAt" -> result.success(VpnStateStore.connectedAtMs(this))
                    "androidTrafficCounters" -> {
                        val uid = applicationInfo.uid
                        val received = android.net.TrafficStats.getUidRxBytes(uid)
                        val sent = android.net.TrafficStats.getUidTxBytes(uid)
                        result.success(mapOf("received" to received, "sent" to sent))
                    }
                    "installedApps" -> result.success(installedApps())
                    "vpnError" -> result.success(VpnStateStore.error(this))
                    "androidCoreInventory" -> result.success(androidCoreInventory())
                    "androidKillSwitchStatus" -> result.success(androidKillSwitchStatus())
                    "openAndroidVpnSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                            result.success(false)
                        } else {
                            try {
                                startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS))
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "openExternalUrl" -> {
                        val value = call.arguments as? String
                        val uri = value?.let(Uri::parse)
                        if (uri == null || uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
                            result.error("invalid_url", "A valid HTTP(S) URL is required", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, uri))
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("open_url_failed", error.message, null)
                            }
                        }
                    }
                    "xrayProxyState" -> result.success(VpnStateStore.xrayProxyState(this))
                    "xrayProxyError" -> result.success(VpnStateStore.xrayProxyError(this))
                    "vpnMemoryMb" -> {
                        val processName = if (VpnStateStore.activeCore(this) == "xray") {
                            xrayProcessName
                        } else {
                            singBoxProcessName
                        }
                        val pid = getSystemService(android.app.ActivityManager::class.java)
                            .runningAppProcesses
                            ?.firstOrNull { it.processName == processName }
                            ?.pid
                        val pss: Long = if (pid == null) android.os.Debug.getPss() else
                            getSystemService(android.app.ActivityManager::class.java)
                                .getProcessMemoryInfo(intArrayOf(pid)).firstOrNull()?.totalPss?.toLong()
                                ?: android.os.Debug.getPss()
                        result.success(pss / 1024)
                    }
                    "vpnLogs" -> {
                        result.success(VpnStateStore.logs(this))
                    }
                    "clearVpnLogs" -> {
                        VpnStateStore.update(this) { it.put("logs", org.json.JSONArray()) }
                        result.success(null)
                    }
                    "exportLog" -> {
                        val content = call.argument<ByteArray>("content")
                        if (content == null) {
                            result.error("invalid_log", "Missing log content", null)
                        } else if (pendingLogExportResult != null) {
                            result.error("busy", "A log export is already open", null)
                        } else {
                            pendingLogExportResult = result
                            pendingLogExportContent = content
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "text/plain"
                                putExtra(
                                    Intent.EXTRA_TITLE,
                                    call.argument<String>("fileName")
                                        ?: "GhostBox-connection-log.txt",
                                )
                            }
                            try {
                                startActivityForResult(intent, LOG_EXPORT_REQUEST)
                            } catch (error: Exception) {
                                pendingLogExportResult = null
                                pendingLogExportContent = null
                                result.error("export_failed", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ICON_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "setAppIcon") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val variant = call.argument<String>("variant")
                val component = iconAlias(variant)
                if (component == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                try {
                    val aliases = listOf(
                        "IconMidnight", "IconGraphite", "IconOcean",
                        "IconEmerald", "IconAmethyst", "IconSapphire", "IconRuby",
                        "IconLavender", "IconForest", "IconSand", "IconDaylight",
                        "IconPaper", "IconMist", "IconAurora", "IconObsidian",
                        "IconSunset", "IconArctic",
                    )
                    val targetAlias = android.content.ComponentName(
                        this,
                        "$packageName.$component",
                    )
                    // Enable the requested launcher entry first. Disabling the
                    // previous alias before that can leave some launchers with
                    // no resolvable MAIN/LAUNCHER activity and a stale icon.
                    packageManager.setComponentEnabledSetting(
                        targetAlias,
                        PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                        PackageManager.DONT_KILL_APP,
                    )
                    aliases.filter { it != component }.forEach { alias ->
                        packageManager.setComponentEnabledSetting(
                            android.content.ComponentName(this, "$packageName.$alias"),
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                            PackageManager.DONT_KILL_APP,
                        )
                    }
                    result.success(true)
                } catch (error: Exception) {
                    result.error("icon_change_failed", error.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getUpdateCacheDirectory") {
                    try {
                        val directory = File(cacheDir, "updates")
                        check(directory.isDirectory || directory.mkdirs()) { "Could not create update cache" }
                        result.success(directory.absolutePath)
                    } catch (error: Exception) {
                        result.error("update_cache_failed", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "sha256File") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "File path was not provided", null)
                        return@setMethodCallHandler
                    }
                    Thread({
                        try {
                            val digest = MessageDigest.getInstance("SHA-256")
                            File(path).inputStream().use { input ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    digest.update(buffer, 0, count)
                                }
                            }
                            val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                            runOnUiThread { result.success(hash) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("checksum_failed", error.message, null) }
                        }
                    }, "ghostbox-update-checksum").start()
                    return@setMethodCallHandler
                }
                if (call.method != "saveApkToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (updateInProgress) {
                    result.error("update_busy", "Another APK is already being saved", null)
                    return@setMethodCallHandler
                }
                val sourcePath = call.argument<String>("path")
                if (sourcePath.isNullOrBlank()) {
                    result.error("missing_apk", "APK path was not provided", null)
                    return@setMethodCallHandler
                }
                val fileName = call.argument<String>("fileName")
                    ?.substringAfterLast('/')
                    ?.takeIf { it.endsWith(".apk", ignoreCase = true) }
                    ?: "GhostBox-update.apk"
                updateInProgress = true
                try {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingDownloadsResult = result
                        pendingDownloadsSource = sourcePath
                        pendingDownloadsName = fileName
                        requestPermissions(
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            DOWNLOADS_PERMISSION_REQUEST,
                        )
                        return@setMethodCallHandler
                    }
                    saveApkAsync(sourcePath, fileName, result)
                } catch (error: Exception) {
                    updateInProgress = false
                    result.error("downloads_failed", error.message, null)
                }
            }
    }

    /**
     * Lists launchable, non-system apps for per-app split routing. The manifest
     * declares only launcher intent visibility, so this does not request broad
     * QUERY_ALL_PACKAGES access.
     */
    private fun installedApps(): List<Map<String, String>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(launcherIntent, 0)
            .asSequence()
            .mapNotNull { resolveInfo ->
                val activityInfo = resolveInfo.activityInfo ?: return@mapNotNull null
                val appInfo = activityInfo.applicationInfo ?: return@mapNotNull null
                val packageName = activityInfo.packageName ?: return@mapNotNull null
                if (packageName == this.packageName) return@mapNotNull null
                if (!appInfo.enabled || appInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0) {
                    return@mapNotNull null
                }
                val label = resolveInfo.loadLabel(packageManager)?.toString()?.trim()
                    ?.takeIf { it.isNotEmpty() } ?: packageName
                packageName to label
            }
            .distinctBy { it.first }
            .sortedWith(Comparator<Pair<String, String>> { left, right ->
                val labelOrder = String.CASE_INSENSITIVE_ORDER.compare(left.second, right.second)
                if (labelOrder != 0) labelOrder else left.first.compareTo(right.first)
            })
            .map { (packageName, label) ->
                mapOf("packageName" to packageName, "label" to label)
            }
            .toList()
    }

    /**
     * Mobile builds embed native cores instead of shipping desktop CLI binaries
     * under vendor/bin. Inspect this installed APK so diagnostics don't report
     * the Android cores as missing just because Process.run() cannot find them.
     */
    private fun androidCoreInventory(): Map<String, Any> {
        val installedAbis = Build.SUPPORTED_ABIS.toList()
        return try {
            ZipFile(applicationInfo.sourceDir).use { apk ->
                val xrayAsset = apk.getEntry("assets/libXray.aar")
                // libXray is packaged as an AAR asset and extracted by
                // XrayVpnService's child class loader when Xray is selected.
                // The service validates classes.jar and selected libgojni.so
                // without copying/examining the 50+ MB AAR just to open About.
                val singBoxAbis = installedAbis.filter { abi ->
                    val entry = apk.getEntry("lib/$abi/libbox.so")
                    entry != null && entry.size > 0
                }
                mapOf(
                    "xray" to mapOf(
                        "available" to (xrayAsset != null && xrayAsset.size > 0),
                        "kind" to "embedded AAR",
                        "assetBytes" to (xrayAsset?.size ?: 0L),
                    ),
                    "sing-box" to mapOf(
                        "available" to singBoxAbis.isNotEmpty(),
                        "kind" to "embedded JNI library",
                        "abis" to singBoxAbis,
                    ),
                    "deviceAbis" to installedAbis,
                )
            }
        } catch (error: Exception) {
            mapOf(
                "xray" to mapOf("available" to false, "kind" to "embedded AAR", "error" to error.message),
                "sing-box" to mapOf("available" to false, "kind" to "embedded JNI library", "error" to error.message),
                "deviceAbis" to installedAbis,
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun validateUpdateApk(apk: File) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IllegalArgumentException(
                "APK повреждён или загружен не полностью. Проверь размер файла и checksum релиза.",
            )
        if (candidate.packageName != packageName) {
            throw IllegalArgumentException(
                "Этот APK предназначен для другого приложения: ${candidate.packageName}.",
            )
        }

        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidateVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            candidate.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            candidate.versionCode.toLong()
        }
        val installedVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            installed.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            installed.versionCode.toLong()
        }
        if (candidateVersion < installedVersion) {
            throw IllegalArgumentException(
                "Версия APK старее уже установленной. Проверь ветку обновлений GitHub.",
            )
        }
        val candidateSignatures = certificateHistory(candidate)
        val installedSignatures = certificateHistory(installed)
        val hasMultipleSigners = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            (candidate.signingInfo?.hasMultipleSigners() == true ||
                installed.signingInfo?.hasMultipleSigners() == true)
        val signerMatches = if (hasMultipleSigners) {
            candidate.signingInfo?.apkContentsSigners?.toSet() ==
                installed.signingInfo?.apkContentsSigners?.toSet()
        } else {
            candidateSignatures.any { candidateSignature ->
                installedSignatures.any { installedSignature ->
                    candidateSignature.toByteArray()
                        .contentEquals(installedSignature.toByteArray())
                }
            }
        }
        if (candidateSignatures.isEmpty()) {
            throw SecurityException(
                "APK не подписан. Unsigned-сборку из GitHub Actions нужно сначала подписать тем же Android keystore, что и установленное приложение.",
            )
        }
        if (!signerMatches) {
            throw SecurityException(
                "Подпись APK не совпадает с установленной версией. Android запрещает обновление. Используй в GitHub Actions тот же постоянный Android keystore, которым подписана установленная сборка.",
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun certificateHistory(info: android.content.pm.PackageInfo): List<android.content.pm.Signature> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.let { signing ->
                if (signing.hasMultipleSigners()) signing.apkContentsSigners.toList()
                else signing.signingCertificateHistory?.toList().orEmpty()
            }.orEmpty()
        } else {
            info.signatures?.toList().orEmpty()
        }
    }

    private fun iconAlias(variant: String?): String? = when (variant) {
        "midnight" -> "IconMidnight"
        "graphite" -> "IconGraphite"
        "ocean" -> "IconOcean"
        "emerald" -> "IconEmerald"
        "amethyst" -> "IconAmethyst"
        "sapphire" -> "IconSapphire"
        "ruby" -> "IconRuby"
        "lavender" -> "IconLavender"
        "forest" -> "IconForest"
        "sand" -> "IconSand"
        "daylight" -> "IconDaylight"
        "paper" -> "IconPaper"
        "mist" -> "IconMist"
        "aurora" -> "IconAurora"
        "obsidian" -> "IconObsidian"
        "sunset" -> "IconSunset"
        "arctic" -> "IconArctic"
        else -> null
    }

    @Deprecated("FlutterActivity permission result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == APPEARANCE_FILE_REQUEST) {
            val pickerResult = pendingAppearanceResult ?: return
            pendingAppearanceResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                pickerResult.success(null)
                return
            }
            try {
                val uri = data.data!!
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= pendingAppearanceMaxBytes) { "Selected file exceeds size limit" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: error("Unable to read selected file")
                val name = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: "appearance-file"
                pickerResult.success(mapOf("name" to name, "bytes" to bytes))
            } catch (error: Exception) {
                pickerResult.error("appearance_file_failed", error.message ?: "Unable to read selected file", null)
            }
            return
        }
        if (requestCode == LOG_EXPORT_REQUEST) {
            val exportResult = pendingLogExportResult ?: return
            val content = pendingLogExportContent
            pendingLogExportResult = null
            pendingLogExportContent = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                exportResult.success(false)
                return
            }
            try {
                val uri: Uri = data.data!!
                val output = contentResolver.openOutputStream(uri, "wt")
                    ?: error("Android could not open the selected file")
                output.use { stream -> stream.write(content ?: ByteArray(0)) }
                exportResult.success(true)
            } catch (error: Exception) {
                exportResult.error("export_failed", error.message, null)
            }
            return
        }
        if (requestCode != VPN_PERMISSION_REQUEST) return
        val result = pendingVpnResult
        pendingVpnResult = null
        if (resultCode == Activity.RESULT_OK) {
            try {
                startPreparedVpn()
                result?.success(null)
            } catch (error: Exception) {
                saveVpnError(error.message ?: error.toString())
                result?.error("start_failed", error.message, null)
            }
        } else {
            pendingConfig = null
            pendingProfileName = null
            VpnStateStore.update(this) {
                it.put("state", "disconnected")
                    .put("error", "VPN permission was denied")
                it.remove("connectedAtMs")
                it.remove("startedAtMs")
            }
            result?.error("permission_denied", "VPN permission was denied", null)
        }
    }

    @Deprecated("Runtime permission result bridge")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == DOWNLOADS_PERMISSION_REQUEST) {
            val result = pendingDownloadsResult
            val sourcePath = pendingDownloadsSource
            val fileName = pendingDownloadsName
            pendingDownloadsResult = null
            pendingDownloadsSource = null
            pendingDownloadsName = null
            if (result == null) return
            if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                updateInProgress = false
                result.error(
                    "downloads_permission_denied",
                    "Разреши доступ к Загрузкам, чтобы сохранить APK.",
                    null,
                )
                return
            }
            if (sourcePath == null) {
                updateInProgress = false
                result.error("missing_apk", "Downloaded APK path was lost", null)
            } else {
                saveApkAsync(sourcePath, fileName ?: "GhostBox-update.apk", result)
            }
            return
        }
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val result = pendingVpnResult ?: return
        pendingVpnResult = null
        // Notifications are optional for connectivity. Continue to the VPN
        // consent screen even when the user declines this permission.
        requestVpnPermission(result)
    }

    private fun saveApkAsync(sourcePath: String, fileName: String, result: MethodChannel.Result) {
        Thread({
            try {
                val savedPath = saveApkToDownloads(sourcePath, fileName)
                runOnUiThread {
                    try {
                        val opened = !isFinishing && !isDestroyed && openDownloads()
                        val prefix = if (opened) "downloads_opened:" else "downloads_saved:"
                        result.success("$prefix$savedPath")
                    } finally {
                        updateInProgress = false
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    updateInProgress = false
                    result.error("downloads_failed", error.message, null)
                }
            }
        }, "ghostbox-save-update").start()
    }

    private fun saveApkToDownloads(sourcePath: String, fileName: String): String {
        val source = File(sourcePath)
        if (!source.isFile || source.length() <= 0L) {
            error(
                "Downloaded APK was not found or is empty: " +
                    "${source.absolutePath} (exists=${source.exists()}, size=${source.length()})",
            )
        }
        validateUpdateApk(source)
        val mimeType = "application/vnd.android.package-archive"
        val downloadsRelativePath = "${Environment.DIRECTORY_DOWNLOADS}/GhostBox"
        var savedFileName = fileName
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val relativePath = "$downloadsRelativePath/"
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Android could not create a file in Downloads")
            try {
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: error("Android could not open the Downloads file")
                val copied = output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
                check(copied == source.length()) { "Downloaded APK copy is incomplete" }
                val completed = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                if (contentResolver.update(uri, completed, null, null) <= 0) {
                    error("Android could not finish saving the APK")
                }
                runCatching {
                    contentResolver.query(
                        uri,
                        arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            savedFileName = cursor.getString(0) ?: fileName
                        }
                    }
                }
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        } else {
            @Suppress("DEPRECATION")
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            val directory = File(downloads, "GhostBox")
            check(directory.isDirectory || directory.mkdirs()) { "Could not create Downloads/GhostBox" }
            val destination = File(directory, fileName)
            val staging = File.createTempFile("ghostbox-", ".part", directory)
            try {
                source.copyTo(staging, overwrite = true)
                check(staging.length() == source.length()) { "Downloaded APK copy is incomplete" }
                check(staging.renameTo(destination)) { "Could not finish saving the APK" }
            } finally {
                staging.delete()
            }
            // Registration is optional: the fully saved file is still usable
            // if a vendor DownloadManager refuses external completed files.
            @Suppress("DEPRECATION")
            runCatching {
                getSystemService(DownloadManager::class.java).addCompletedDownload(
                    destination.name,
                    "GhostBox Android update",
                    true,
                    mimeType,
                    destination.absolutePath,
                    destination.length(),
                    true,
                )
            }
        }

        return "$downloadsRelativePath/$savedFileName"
    }

    private fun openDownloads(): Boolean {
        // Launch directly: resolveActivity can return null because of package
        // visibility even when a matching system file manager is installed.
        val intents = listOf(
            Intent(DownloadManager.ACTION_VIEW_DOWNLOADS),
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(
                    android.provider.DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents",
                        "primary:${Environment.DIRECTORY_DOWNLOADS}/GhostBox",
                    ),
                    android.provider.DocumentsContract.Document.MIME_TYPE_DIR,
                )
            },
        )
        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try opening the saved directory in a system file manager.
            } catch (_: SecurityException) {
                // Saving succeeded even if the system denies opening its UI.
            }
        }
        return false
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent == null) {
            try {
                startPreparedVpn()
                result.success(null)
            } catch (error: Exception) {
                saveVpnError(error.message ?: error.toString())
                result.error("start_failed", error.message, null)
            }
        } else {
            pendingVpnResult = result
            startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST)
        }
    }

    private fun saveVpnError(message: String) {
        VpnStateStore.update(this) {
            it.put("state", "error").put("error", message).remove("connectedAtMs")
            it.remove("startedAtMs")
        }
    }

    /** A native core can die after establish() succeeds, leaving the persisted
     * state at "connected" while Android has already removed the VPN icon.
     * Reconcile that stale state with the actual service process and surface
     * ActivityManager's exit reason instead of reporting a fake connection.
     */
    private fun currentVpnState(): String {
        val state = VpnStateStore.state(this)
        val core = VpnStateStore.activeCore(this)
        val processes = getSystemService(android.app.ActivityManager::class.java)
        fun serviceAlive(processName: String, serviceSuffix: String): Boolean =
            processes.runningAppProcesses?.any { it.processName == processName } == true ||
                processes.getRunningServices(1000).any { service ->
                    service.process == processName &&
                        service.service.className.endsWith(serviceSuffix)
                }

        val processName = if (core == "xray") xrayProcessName else singBoxProcessName
        val coreAlive = serviceAlive(
            processName,
            if (core == "xray") "XrayVpnService" else "GhostBoxVpnService",
        )
        val xrayAlive = serviceAlive(xrayProcessName, "XrayVpnService") ||
            serviceAlive("$packageName:xray", "XrayVpnService")

        // A launcher Activity can be recreated while either foreground VPN
        // service survives. If persisted state says disconnected, it is an
        // orphaned core: stop it before the next user connection can start a
        // second Xray runtime and report the stale state to Flutter.
        if (state == "stopping") return state
        val startedAt = VpnStateStore.read(this).optLong("startedAtMs")
        val staleConnecting = state == "connecting" && startedAt > 0L &&
            System.currentTimeMillis() - startedAt >= 60_000L && (coreAlive || xrayAlive)
        if ((state != "connecting" && state != "connected") || staleConnecting) {
            if (!coreAlive && !xrayAlive) return state
            val message = if (staleConnecting) {
                "VPN-процесс завис на подключении; выполняется очистка"
            } else {
                "При запуске обнаружен оставшийся VPN-процесс; выполняется очистка"
            }
            VpnStateStore.update(this) {
                it.put("state", "error").put("error", message)
                if (xrayAlive) it.put("xrayProxyState", "error").put("xrayProxyError", message)
                it.remove("connectedAtMs")
            }
            cleanupOrphanedVpnProcesses()
            VpnStateStore.appendLog(this, message)
            return "error"
        }

        // XHTTP/REALITY uses Xray as an upstream proxy process while
        // sing-box owns the system TUN. Checking only activeCore therefore
        // made a dead Xray process look like a healthy connection after the
        // Activity was recreated.
        val saved = VpnStateStore.read(this)
        val xrayState = saved.optString("xrayProxyState", "disconnected")
        val xrayStartedAt = saved.optLong("xrayProxyStartedAtMs")
        if (core == "sing-box" && xrayState in setOf("connecting", "connected") &&
            !xrayAlive && xrayStartedAt > 0L &&
            System.currentTimeMillis() - xrayStartedAt >= 5_000L
        ) {
            val message = "VPN-процесс Xray завершился; Android TUN больше не может передавать трафик"
            VpnStateStore.update(this) {
                it.put("state", "error")
                    .put("xrayProxyState", "error")
                    .put("xrayProxyError", message)
                    .put("error", message)
                it.remove("connectedAtMs")
                it.remove("startedAtMs")
            }
            VpnStateStore.appendLog(this, message)
            return "error"
        }
        if (coreAlive) return state

        val lastTransitionAt = VpnStateStore.read(this).let { value ->
            maxOf(value.optLong("startedAtMs"), value.optLong("connectedAtMs"))
        }
        if (lastTransitionAt <= 0L ||
            System.currentTimeMillis() - lastTransitionAt < 5_000L
        ) return state

        val exit = recentVpnServiceExit(core)
        val message = buildString {
            append("VPN-процесс ").append(core).append(" завершился во время подключения")
            if (exit != null) append(" (").append(exit).append(')')
        }
        VpnStateStore.update(this) {
            it.put("state", "error").put("error", message)
            it.remove("connectedAtMs")
            it.remove("startedAtMs")
        }
        VpnStateStore.appendLog(this, message)
        return "error"
    }

    /**
     * Drain a VPN session left behind by a killed/recreated Flutter Activity
     * before starting another libbox/Xray runtime. The isolated services get
     * a normal STOP command first; after a short grace period only this app's
     * two dedicated VPN child processes may be killed. The channel call is
     * completed only after Android no longer reports either child process.
     */
    private fun cleanupVpnBeforeConnect(result: MethodChannel.Result) {
        val childNames = allVpnProcessNames
        fun liveChildren(): List<android.app.ActivityManager.RunningAppProcessInfo> =
            getSystemService(android.app.ActivityManager::class.java)
                .runningAppProcesses
                ?.filter {
                    it.processName in childNames && it.pid != android.os.Process.myPid()
                }
                .orEmpty()

        try {
            VpnStateStore.update(this) {
                it.put("state", "stopping")
                    .put("xrayProxyState", "stopping")
                    .put("singBoxStopComplete", false)
                    .put("xrayStopComplete", false)
                    .remove("connectedAtMs")
            }
            val stopIntent = Intent("app.ghostbox.STOP_VPN")
            // Android can blacklist a recently-crashed service process and
            // reject even a stop intent with `process is bad`. Treat that as
            // a failed graceful-stop request, not as a failed cleanup: below
            // we wait for and, if needed, kill only our own isolated VPN
            // processes before allowing a new connection.
            val liveNames = liveChildren().mapTo(mutableSetOf()) { it.processName }
            listOf(
                GhostBoxVpnService::class.java to singBoxProcessName,
                XrayVpnService::class.java to xrayProcessName,
            ).forEach { (serviceClass, processName) ->
                if (processName !in liveNames) return@forEach
                try {
                    startService(Intent(stopIntent).setClass(this, serviceClass))
                } catch (error: Exception) {
                    val detail = error.message ?: error.toString()
                    VpnStateStore.appendLog(
                        this,
                        "Не удалось отправить STOP_VPN в ${serviceClass.simpleName}; " +
                            "перехожу к очистке процесса: $detail",
                    )
                }
            }
        } catch (error: Exception) {
            result.error("cleanup_failed", error.message ?: error.toString(), null)
            return
        }

        Thread({
            try {
                val gracefulDeadline = System.currentTimeMillis() + 2_500L
                while (
                    System.currentTimeMillis() < gracefulDeadline &&
                    liveChildren().isNotEmpty()
                ) {
                    Thread.sleep(100L)
                }

                val remaining = liveChildren()
                if (remaining.isNotEmpty()) {
                    remaining.forEach { process ->
                        VpnStateStore.appendLog(
                            this,
                            "Останавливаю оставшийся VPN-процесс " +
                                "${process.processName} (pid ${process.pid}) перед новым подключением",
                        )
                        android.os.Process.killProcess(process.pid)
                    }
                }

                val exitDeadline = System.currentTimeMillis() + 3_000L
                var stillRunning = liveChildren()
                while (System.currentTimeMillis() < exitDeadline && stillRunning.isNotEmpty()) {
                    Thread.sleep(100L)
                    stillRunning = liveChildren()
                }
                if (stillRunning.isNotEmpty()) {
                    throw IllegalStateException(
                        "VPN-процесс остался запущен (${stillRunning.joinToString { it.processName }}); новое подключение не запущено",
                    )
                }

                VpnStateStore.update(this) {
                    it.put("state", "disconnected")
                    it.put("xrayProxyState", "disconnected")
                    it.put("singBoxStopComplete", true)
                    it.put("xrayStopComplete", true)
                    it.remove("connectedAtMs")
                    it.remove("startedAtMs")
                    it.remove("xrayProxyStartedAtMs")
                    it.remove("error")
                    it.remove("xrayProxyError")
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                VpnStateStore.update(this) {
                    it.put("state", "error")
                    it.put("error", error.message ?: error.toString())
                    it.remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
                runOnUiThread {
                    result.error("cleanup_failed", error.message ?: error.toString(), null)
                }
            }
        }, "GhostBox-vpn-preconnect-cleanup").start()
    }

    /**
     * Hard recovery for a user-confirmed broken VPN session. Android has no
     * separately installable VpnService component: stop both app-owned VPN
     * services, terminate only their isolated core processes, then clear the
     * persisted runtime state so the next connection can start fresh.
     */
    private fun forceCleanupVpn(result: MethodChannel.Result) {
        val childNames = allVpnProcessNames
        fun liveChildren(): List<android.app.ActivityManager.RunningAppProcessInfo> =
            getSystemService(android.app.ActivityManager::class.java)
                .runningAppProcesses
                ?.filter {
                    it.processName in childNames && it.pid != android.os.Process.myPid()
                }
                .orEmpty()

        try {
            VpnStateStore.update(this) {
                it.put("state", "stopping")
                    .put("xrayProxyState", "stopping")
                    .put("singBoxStopComplete", false)
                    .put("xrayStopComplete", false)
                    .remove("connectedAtMs")
            }
        } catch (error: Exception) {
            result.error("force_cleanup_failed", error.message ?: error.toString(), null)
            return
        }

        Thread({
            try {
                val stopIntent = Intent("app.ghostbox.STOP_VPN")
                val liveNames = liveChildren().mapTo(mutableSetOf()) { it.processName }
                listOf(
                    GhostBoxVpnService::class.java to singBoxProcessName,
                    XrayVpnService::class.java to xrayProcessName,
                ).forEach { (serviceClass, processName) ->
                    if (processName !in liveNames) return@forEach
                    runCatching {
                        startService(Intent(stopIntent).setClass(this, serviceClass))
                    }.onFailure { error ->
                        VpnStateStore.appendLog(
                            this,
                            "Force cleanup: STOP для ${serviceClass.simpleName} не принят: " +
                                (error.message ?: error.toString()),
                        )
                    }
                }

                val gracefulDeadline = System.currentTimeMillis() + 1_000L
                while (
                    System.currentTimeMillis() < gracefulDeadline &&
                    liveChildren().isNotEmpty()
                ) {
                    Thread.sleep(100L)
                }

                liveChildren().forEach { process ->
                    VpnStateStore.appendLog(
                        this,
                        "Force cleanup: завершаю процесс ${process.processName} " +
                            "(pid ${process.pid})",
                    )
                    android.os.Process.killProcess(process.pid)
                }

                val exitDeadline = System.currentTimeMillis() + 4_000L
                var remaining = liveChildren()
                while (System.currentTimeMillis() < exitDeadline && remaining.isNotEmpty()) {
                    Thread.sleep(100L)
                    remaining = liveChildren()
                }
                if (remaining.isNotEmpty()) {
                    throw IllegalStateException(
                        "Не удалось остановить VPN-процессы: " +
                            remaining.joinToString { it.processName },
                    )
                }

                stopService(Intent(this, GhostBoxVpnService::class.java))
                stopService(Intent(this, XrayVpnService::class.java))
                VpnStateStore.update(this) {
                    it.put("state", "disconnected")
                        .put("xrayProxyState", "disconnected")
                        .put("singBoxStopComplete", true)
                        .put("xrayStopComplete", true)
                    it.remove("connectedAtMs")
                    it.remove("startedAtMs")
                    it.remove("xrayProxyStartedAtMs")
                    it.remove("error")
                    it.remove("xrayProxyError")
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                VpnStateStore.update(this) {
                    it.put("state", "error")
                        .put("error", error.message ?: error.toString())
                    it.remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
                runOnUiThread {
                    result.error("force_cleanup_failed", error.message ?: error.toString(), null)
                }
            }
        }, "GhostBox-vpn-force-cleanup").start()
    }

    /**
     * A crashed libXray runtime can leave its isolated :xray process registered
     * with Android. Signal graceful service shutdown first, then kill only the
     * app-owned VPN child processes if they are still present. This path is
     * reached only when the persisted session is not connecting or connected.
     */
    private fun cleanupOrphanedVpnProcesses() {
        if (staleVpnCleanupScheduled) return
        staleVpnCleanupScheduled = true
        val stopIntent = Intent("app.ghostbox.STOP_VPN")
        val runningNames = getSystemService(android.app.ActivityManager::class.java)
            .runningAppProcesses
            ?.mapTo(mutableSetOf()) { it.processName }
            .orEmpty()
        if (singBoxProcessName in runningNames) {
            runCatching {
                startService(Intent(stopIntent).setClass(this, GhostBoxVpnService::class.java))
            }
        }
        if (xrayProcessName in runningNames) {
            runCatching {
                startService(Intent(stopIntent).setClass(this, XrayVpnService::class.java))
            }
        }
        android.os.Handler(mainLooper).postDelayed({
            if (VpnStateStore.state(this) == "connecting" ||
                VpnStateStore.state(this) == "connected"
            ) {
                staleVpnCleanupScheduled = false
                return@postDelayed
            }
            val activityManager = getSystemService(android.app.ActivityManager::class.java)
            val staleNames = allVpnProcessNames
            activityManager.runningAppProcesses
                ?.filter { it.processName in staleNames && it.pid != android.os.Process.myPid() }
                ?.forEach { process ->
                    VpnStateStore.appendLog(
                        this,
                        "Останавливаю оставшийся VPN-процесс ${process.processName} (pid ${process.pid})",
                    )
                    android.os.Process.killProcess(process.pid)
                }
            staleVpnCleanupScheduled = false
        }, 700L)
    }

    /**
     * Android owns the lockdown switch. API 29+ lets a running VpnService
     * query the OS-enforced state; MainActivity reads the value that service
     * recorded. Before a VPN service has run (or below API 29), the state is
     * unknown and must not be inferred from a running tunnel.
     */
    private fun androidKillSwitchStatus(): Map<String, Any?> {
        val lockdownEnabled = VpnStateStore.androidLockdownStatus(this)
        return mapOf(
            "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N),
            "alwaysOnSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N),
            "lockdownEnabled" to lockdownEnabled,
            "lockdownStatusKnown" to (lockdownEnabled != null),
        )
    }

    private fun startPreparedVpn() {
        val config = pendingConfig ?: error("Missing VPN configuration")
        val core = pendingCore
        val intent = if (core == "xray") {
            Intent(this, XrayVpnService::class.java)
                .putExtra(XrayVpnService.EXTRA_CONFIG, config)
                .putExtra(XrayVpnService.EXTRA_PROFILE, pendingProfileName ?: "GhostBox")
                .putExtra(XrayVpnService.EXTRA_PROXY_ONLY, pendingProxyOnly)
        } else {
            Intent(this, GhostBoxVpnService::class.java)
                .putExtra(GhostBoxVpnService.EXTRA_CONFIG, config)
                .putExtra(GhostBoxVpnService.EXTRA_PROFILE, pendingProfileName ?: "GhostBox")
                .putExtra(GhostBoxVpnService.EXTRA_MEMORY, pendingMemoryMb)
        }
        val proxyOnly = pendingProxyOnly
        val keepXray = pendingKeepXray
        VpnStateStore.update(this) {
            it.put("activeCore", core).put("state", "connecting")
            it.remove("error")
            it.remove("connectedAtMs")
            it.put("startedAtMs", System.currentTimeMillis())
            if (proxyOnly) {
                it.put("xrayProxyState", "connecting")
                    .put("xrayProxyStartedAtMs", System.currentTimeMillis())
                    .remove("xrayProxyError")
            }
        }
        if (core == "xray") {
            stopService(Intent(this, GhostBoxVpnService::class.java))
        } else if (!keepXray) {
            stopService(Intent(this, XrayVpnService::class.java))
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            val previousExit = recentVpnServiceExit(core)
            val detail = buildString {
                append(error.message ?: error.toString())
                if (previousExit != null) append("; последнее завершение VPN-процесса: ").append(previousExit)
            }
            throw IllegalStateException(detail, error)
        }
        pendingConfig = null
        pendingProfileName = null
        pendingProxyOnly = false
        pendingKeepXray = false
    }

    /**
     * Reload only the existing Android Xray proxy. The sing-box service owns
     * the device TUN and stays active while Xray replaces its upstream.
     */
    private fun reloadXrayProxy(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val config = call.argument<String>("config")
            ?.takeIf(String::isNotBlank)
        val profileName = call.argument<String>("profileName")
            ?.takeIf(String::isNotBlank)
        val memoryMb = call.argument<Int>("memoryMb")
        if (config == null || profileName == null || memoryMb == null || memoryMb <= 0) {
            result.error("invalid_reload", "Xray config, profile name and memory are required", null)
            return
        }

        val proxyState = VpnStateStore.xrayProxyState(this)
        if (proxyState != "connected" && proxyState != "error") {
            result.error("xray_not_running", "The Android Xray proxy is not active", null)
            return
        }
        val processName = xrayProcessName
        val xrayProcessRunning = getSystemService(android.app.ActivityManager::class.java)
            .runningAppProcesses
            ?.any { it.processName == processName && it.pid != android.os.Process.myPid() }
            ?: false
        if (!xrayProcessRunning) {
            result.error("xray_not_running", "The Android Xray service process is not active", null)
            return
        }

        // Claim the state before enqueueing the service intent so a second
        // rapid profile tap cannot queue another reload over the first one.
        VpnStateStore.update(this) {
            it.put("xrayProxyState", "connecting")
                .put("xrayMemoryMb", memoryMb.coerceIn(64, 256))
                .remove("xrayProxyError")
        }
        val intent = Intent(this, XrayVpnService::class.java)
            .setAction(XrayVpnService.ACTION_RELOAD_PROXY)
            .putExtra(XrayVpnService.EXTRA_CONFIG, config)
            .putExtra(XrayVpnService.EXTRA_PROFILE, profileName)
            .putExtra(XrayVpnService.EXTRA_MEMORY, memoryMb.coerceIn(64, 256))
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            VpnStateStore.update(this) {
                it.put("xrayProxyState", "error")
                    .put("xrayProxyError", error.message ?: error.toString())
            }
            result.error("xray_reload_failed", error.message ?: error.toString(), null)
        }
    }

    private fun recentVpnServiceExit(core: String): String? {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return null
        return runCatching {
            val expectedProcesses = if (core == "xray") {
                setOf(xrayProcessName, "$packageName:xray")
            } else {
                setOf(singBoxProcessName, "$packageName:singboxcore")
            }
            val recentThreshold = System.currentTimeMillis() - 2 * 60 * 1000L
            getSystemService(android.app.ActivityManager::class.java)
                .getHistoricalProcessExitReasons(packageName, 0, 20)
                .asSequence()
                .filter { it.processName in expectedProcesses && it.timestamp >= recentThreshold }
                .sortedByDescending { it.timestamp }
                .firstOrNull()
                ?.let { exit ->
                    val description = exit.description?.takeIf(String::isNotBlank)
                    "$core: reason=${exit.reason}${description?.let { " ($it)" } ?: ""}, status=${exit.status}"
                }
        }.getOrNull()
    }
}
