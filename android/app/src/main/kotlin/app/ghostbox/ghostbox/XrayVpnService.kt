package app.ghostbox.ghostbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.lang.reflect.Proxy
import java.util.zip.ZipFile

/** Xray owns its Go runtime in :xray, separate from sing-box's :singbox process. */
class XrayVpnService : VpnService() {
    companion object {
        const val EXTRA_CONFIG = "ghostbox.xray.config"
        const val EXTRA_PROFILE = "ghostbox.xray.profile"
        const val EXTRA_PROXY_ONLY = "ghostbox.xray.proxy_only"
        private const val TAG = "GhostBoxXray"
        private const val CHANNEL_ID = "ghostbox_vpn"
        private const val VPN_NOTIFICATION_ID = 731
        private const val UPSTREAM_NOTIFICATION_ID = 732
        @Volatile private var processXrayClassLoader: ClassLoader? = null
        @Volatile private var processXrayApiClass: Class<*>? = null
    }

    private var tun: ParcelFileDescriptor? = null
    private var xrayClassLoader: ClassLoader? = null
    private var xrayClass: Class<*>? = null
    private var dialerController: Any? = null
    @Volatile private var proxyOnlyMode = false
    @Volatile private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "app.ghostbox.STOP_VPN") {
            stopXray()
            return START_NOT_STICKY
        }
        stopping = false
        proxyOnlyMode = intent?.getBooleanExtra(EXTRA_PROXY_ONLY, false) ?: false
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val profileName = intent.getStringExtra(EXTRA_PROFILE) ?: "GhostBox"
        startForeground(notificationId(), createNotification(profileName, false))
        Thread({ startCore(config, profileName) }, "GhostBox-xray-start").start()
        return START_NOT_STICKY
    }

    private fun startCore(rawConfig: String, profileName: String) {
        try {
            if (!proxyOnlyMode && VpnService.prepare(this) != null) {
                error("Android VPN permission is missing")
            }
            val api = loadXrayApi()
            val controller = requireNotNull(dialerController)
            api.getMethod("registerDialerController", loadXrayApi("libXray.DialerController"))
                .invoke(null, controller)
            api.getMethod("registerListenerController", loadXrayApi("libXray.DialerController"))
                .invoke(null, controller)
            api.getMethod("setDNS", loadXrayApi("libXray.DialerController"), String::class.java)
                .invoke(null, controller, "1.1.1.1:53")

            val config = JSONObject(rawConfig)
            if (!proxyOnlyMode) {
                val builder = Builder()
                    .setSession(profileName)
                    .setMtu(1500)
                    .addAddress("172.19.0.1", 30)
                    .addAddress("fc00::1", 64)
                    .addRoute("0.0.0.0", 0)
                    .addRoute("::", 0)
                    .addDnsServer("1.1.1.1")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
                tun = builder.establish()
                    ?: error("Android did not establish the Xray VPN interface")
                val env = config.optJSONObject("env")
                    ?: JSONObject().also { config.put("env", it) }
                env.put("xray.tun.fd", tun!!.fd.toString())
            }
            val response = invoke("runXray", JSONObject().put("xrayJson", config.toString()))
            if (stopping) return
            if (!response.optBoolean("success")) {
                error(response.optString("error", "Xray failed to start"))
            }
            val state = invoke("getXrayState", JSONObject())
            val isRunning = state.optJSONObject("data")?.optBoolean("running", false) ?: false
            if (!state.optBoolean("success") || !isRunning) {
                error("Xray returned without starting its core")
            }

            if (proxyOnlyMode) {
                VpnStateStore.update(this) {
                    it.put("xrayProxyState", "connected").remove("xrayProxyError")
                    if (it.optString("activeCore") == "xray") {
                        it.put("state", "connected").remove("error")
                    }
                }
            } else {
                VpnStateStore.updateForCore(this, "xray") {
                    it.put("state", "connected").remove("error")
                }
            }
            VpnStateStore.appendLog(this, "Xray Android VPN started ($profileName)")
            getSystemService(NotificationManager::class.java)
                .notify(notificationId(), createNotification(profileName, true))
            Log.i(TAG, "Xray VPN service started")
        } catch (error: Throwable) {
            Log.e(TAG, "Xray failed to start", error)
            if (proxyOnlyMode) {
                VpnStateStore.update(this) {
                    val message = error.message ?: error.toString()
                    it.put("xrayProxyState", "error").put("xrayProxyError", message)
                    if (it.optString("activeCore") == "xray") {
                        it.put("state", "error").put("error", message)
                    }
                }
            } else {
                VpnStateStore.updateForCore(this, "xray") {
                    it.put("state", "error").put("error", error.message ?: error.toString())
                }
            }
            VpnStateStore.appendLog(this, "Xray startup failed: ${error.message ?: error}")
            stopXray()
        }
    }

    private fun invoke(method: String, payload: JSONObject): JSONObject {
        val request = JSONObject()
            .put("apiVersion", 3)
            .put("method", method)
            .put("payload", payload)
        val result = loadXrayApi().getMethod("invoke", String::class.java)
            .invoke(null, request.toString()) as String
        return JSONObject(result)
    }

    private fun loadXrayApi(className: String = "libXray.LibXray"): Class<*> {
        var loader = processXrayClassLoader
        if (loader == null) {
            synchronized(XrayVpnService::class.java) {
                loader = processXrayClassLoader
                if (loader == null) {
                    val runtimeDir = File(filesDir, "xray-runtime-${BuildConfig.VERSION_CODE}").apply { mkdirs() }
                    val aarFile = File(runtimeDir, "libXray.aar")
                    if (!aarFile.isFile) assets.open("libXray.aar").use { input ->
                        aarFile.outputStream().use(input::copyTo)
                    }
                    val classes = File(runtimeDir, "classes.jar")
                    val nativeDir = File(runtimeDir, "jni").apply { mkdirs() }
                    val nativeLibrary = File(nativeDir, "libgojni.so")
                    if (!classes.isFile || !nativeLibrary.isFile) {
                        classes.setWritable(true, false)
                        nativeLibrary.setWritable(true, false)
                        ZipFile(aarFile).use { archive ->
                            val classesEntry = archive.getEntry("classes.jar")
                                ?: error("libXray AAR has no Java bindings")
                            archive.getInputStream(classesEntry).use { input ->
                                classes.outputStream().use(input::copyTo)
                            }
                            val abi = Build.SUPPORTED_ABIS.firstNotNullOfOrNull { candidate ->
                                archive.getEntry("jni/$candidate/libgojni.so")?.let { candidate to it }
                            } ?: error("libXray AAR has no native library for ${Build.SUPPORTED_ABIS.joinToString()}")
                            archive.getInputStream(abi.second).use { input ->
                                nativeLibrary.outputStream().use(input::copyTo)
                            }
                        }
                    }
                    if (!classes.setReadable(true, false) || !classes.setWritable(false, false)) {
                        error("Could not mark the embedded Xray bindings read-only")
                    }
                    nativeLibrary.setReadable(true, false)
                    loader = ChildFirstGoClassLoader(
                        classes.absolutePath,
                        codeCacheDir.absolutePath,
                        nativeDir.absolutePath,
                        javaClass.classLoader,
                    )
                    processXrayApiClass = Class.forName("libXray.LibXray", true, loader)
                    processXrayClassLoader = loader
                }
            }
        }
        xrayClassLoader = loader
        xrayClass = processXrayApiClass
        if (dialerController == null) {
            val controllerClass = Class.forName(
                "libXray.DialerController", true, xrayClassLoader,
            )
            dialerController = Proxy.newProxyInstance(
                xrayClassLoader,
                arrayOf(controllerClass),
            ) { _, method, args ->
                when (method.name) {
                    "protectFd" -> protect((args?.firstOrNull() as Number).toInt())
                    "toString" -> "GhostBoxVpnSocketController"
                    "hashCode" -> System.identityHashCode(this)
                    "equals" -> this === args?.firstOrNull()
                    else -> null
                }
            }
        }
        return if (className == "libXray.LibXray") {
            requireNotNull(xrayClass)
        } else {
            Class.forName(className, true, xrayClassLoader)
        }
    }

    /**
     * Each gomobile AAR includes its own `go.Seq` Java runtime classes. Keep
     * libXray's copy child-loaded so it cannot collide with libbox's copy in
     * the app class loader. The VPN services themselves run in separate OS
     * processes, so each native Go runtime remains isolated too.
     */
    private class ChildFirstGoClassLoader(
        dexPath: String,
        optimizedDirectory: String,
        librarySearchPath: String,
        parent: ClassLoader?,
    ) : DexClassLoader(dexPath, optimizedDirectory, librarySearchPath, parent) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (name.startsWith("go.") || name.startsWith("libXray.")) {
                synchronized(name.intern()) {
                    findLoadedClass(name)?.let { return it }
                    try {
                        val loaded = findClass(name)
                        if (resolve) resolveClass(loaded)
                        return loaded
                    } catch (_: ClassNotFoundException) {
                        // Fall back to the parent for Java or shared API types.
                    }
                }
            }
            return super.loadClass(name, resolve)
        }
    }

    private fun createNotification(profile: String, connected: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.vpn_notification_channel), NotificationManager.IMPORTANCE_LOW),
            )
        }
        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = getString(
            if (connected) R.string.vpn_notification_connected else R.string.vpn_notification_connecting,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ghostbox_status)
                .setContentTitle(profile)
                .setContentText(text)
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ghostbox_status)
                .setContentTitle(profile)
                .setContentText(text)
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        }
    }

    private fun notificationId(): Int =
        if (proxyOnlyMode) UPSTREAM_NOTIFICATION_ID else VPN_NOTIFICATION_ID

    private fun stopXray() {
        stopping = true
        runCatching { invoke("stopXray", JSONObject()) }
            .onFailure { Log.w(TAG, "Error while stopping Xray", it) }
        runCatching {
            loadXrayApi().getMethod("resetDNS").invoke(null)
        }
        runCatching { tun?.close() }
        tun = null
        if (proxyOnlyMode) {
            VpnStateStore.update(this) {
                if (it.optString("xrayProxyState") != "error") {
                    it.put("xrayProxyState", "disconnected")
                }
            }
        } else if (VpnStateStore.state(this) != "error") {
            VpnStateStore.updateForCore(this, "xray") { it.put("state", "disconnected") }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (!stopping) stopXray()
        super.onDestroy()
    }
}
