package app.ghostbox.ghostbox

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "app.ghostbox.ghostbox/vpn"
        private const val VPN_PERMISSION_REQUEST = 4137
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
                        val permissionIntent = VpnService.prepare(this)
                        if (permissionIntent == null) {
                            startPreparedVpn()
                            result.success(null)
                        } else {
                            pendingVpnResult = result
                            startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST)
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
                result?.error("start_failed", error.message, null)
            }
        } else {
            result?.error("permission_denied", "VPN permission was denied", null)
        }
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
