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
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
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
                        result.success(null)
                    }
                    "vpnState" -> result.success(getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).getString("state", "disconnected"))
                    "vpnError" -> result.success(getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).getString("error", null))
                    "vpnMemoryMb" -> result.success(android.os.Debug.getPss() / 1024)
                    "vpnLogs" -> {
                        val raw = getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).getString("logs", "[]") ?: "[]"
                        result.success(org.json.JSONArray(raw).let { array ->
                            (0 until array.length()).map { array.optString(it) }
                        })
                    }
                    "clearVpnLogs" -> {
                        getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit().putString("logs", "[]").apply()
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
                        "IconClassic", "IconMidnight", "IconGraphite", "IconOcean",
                        "IconEmerald", "IconAmethyst", "IconSapphire", "IconRuby",
                        "IconLavender", "IconForest", "IconSand", "IconDaylight",
                        "IconPaper", "IconMist", "IconAurora", "IconObsidian",
                        "IconSunset", "IconArctic",
                    )
                    aliases.forEach { alias ->
                        packageManager.setComponentEnabledSetting(
                            android.content.ComponentName(this, "$packageName.$alias"),
                            if (alias == component) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
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
        "classic" -> "IconClassic"
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
            getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
                .putString("state", "disconnected")
                .putString("error", "VPN permission was denied")
                .apply()
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
        getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
            .putString("state", "error")
            .putString("error", message)
            .apply()
    }

    private fun startPreparedVpn() {
        val config = pendingConfig ?: error("Missing sing-box configuration")
        val intent = Intent(this, GhostBoxVpnService::class.java)
            .putExtra(GhostBoxVpnService.EXTRA_CONFIG, config)
            .putExtra(GhostBoxVpnService.EXTRA_PROFILE, pendingProfileName ?: "GhostBox")
            .putExtra(GhostBoxVpnService.EXTRA_MEMORY, pendingMemoryMb)
        getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
            .putString("state", "connecting").remove("error").apply()
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        pendingConfig = null
        pendingProfileName = null
    }
}
