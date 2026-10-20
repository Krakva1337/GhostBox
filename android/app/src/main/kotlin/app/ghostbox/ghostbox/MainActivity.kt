package app.ghostbox.ghostbox

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.net.VpnService
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "app.ghostbox.ghostbox/vpn"
        private const val ICON_CHANNEL = "app.ghostbox.ghostbox/app_icon"
        private const val UPDATE_CHANNEL = "app.ghostbox.ghostbox/app_update"
        private const val VPN_PERMISSION_REQUEST = 4137
        private const val NOTIFICATION_PERMISSION_REQUEST = 4138
    }

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var pendingProfileName: String? = null
    private var pendingMemoryMb = 128
    private var pendingCore = "sing-box"
    private var pendingProxyOnly = false
    private var pendingKeepXray = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    "stopVpn" -> {
                        stopService(Intent(this, GhostBoxVpnService::class.java))
                        stopService(Intent(this, XrayVpnService::class.java))
                        result.success(null)
                    }
                    "vpnState" -> result.success(VpnStateStore.state(this))
                    "vpnError" -> result.success(VpnStateStore.error(this))
                    "xrayProxyState" -> result.success(VpnStateStore.xrayProxyState(this))
                    "xrayProxyError" -> result.success(VpnStateStore.xrayProxyError(this))
                    "vpnMemoryMb" -> {
                        val processName = "$packageName:${if (VpnStateStore.activeCore(this) == "xray") "xray" else "singboxcore"}"
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
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val sourcePath = call.argument<String>("path")
                if (sourcePath.isNullOrBlank()) {
                    result.error("missing_apk", "APK path was not provided", null)
                    return@setMethodCallHandler
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()
                    ) {
                        startActivity(
                            Intent(
                                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success("permission_required")
                        return@setMethodCallHandler
                    }
                    val source = File(sourcePath)
                    if (!source.isFile) {
                        result.error("missing_apk", "Downloaded APK was not found", null)
                        return@setMethodCallHandler
                    }
                    val updateDirectory = File(cacheDir, "updates").apply { mkdirs() }
                    val apk = File(updateDirectory, "GhostBox-update.apk")
                    source.copyTo(apk, overwrite = true)
                    val apkUri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        apk,
                    )
                    val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                        setDataAndType(apkUri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(installIntent)
                    result.success("installer_opened")
                } catch (error: Exception) {
                    result.error("install_failed", error.message, null)
                }
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
                it.put("state", "disconnected").put("error", "VPN permission was denied")
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
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val result = pendingVpnResult ?: return
        pendingVpnResult = null
        // Notifications are optional for connectivity. Continue to the VPN
        // consent screen even when the user declines this permission.
        requestVpnPermission(result)
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
        VpnStateStore.update(this) { it.put("state", "error").put("error", message) }
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
            it.put("activeCore", core).put("state", "connecting").remove("error")
            if (proxyOnly) {
                it.put("xrayProxyState", "connecting").remove("xrayProxyError")
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
                if (previousExit != null) append("; предыдущий вылет VPN-процесса: ").append(previousExit)
            }
            throw IllegalStateException(detail, error)
        }
        pendingConfig = null
        pendingProfileName = null
        pendingProxyOnly = false
        pendingKeepXray = false
    }

    private fun recentVpnServiceExit(core: String): String? {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return null
        return runCatching {
            getSystemService(android.app.ActivityManager::class.java)
                .getHistoricalProcessExitReasons(packageName, 0, 20)
                .asSequence()
                .filter { it.processName.startsWith("$packageName:") }
                .sortedByDescending { it.timestamp }
                .firstOrNull()
                ?.let { exit ->
                    val description = exit.description?.takeIf(String::isNotBlank)
                    "$core: reason=${exit.reason}${description?.let { " ($it)" } ?: ""}, status=${exit.status}"
                }
        }.getOrNull()
    }
}
