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
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.Executors
import java.util.zip.ZipFile

/** Xray owns its Go runtime in :xraycore2, separate from sing-box's :singboxcore2 process. */
class XrayVpnService : VpnService() {
    companion object {
        const val EXTRA_CONFIG = "ghostbox.xray.config"
        const val EXTRA_PROFILE = "ghostbox.xray.profile"
        const val EXTRA_PROXY_ONLY = "ghostbox.xray.proxy_only"
        const val EXTRA_MEMORY = "ghostbox.xray.memory_mb"
        const val ACTION_RELOAD_PROXY = "app.ghostbox.RELOAD_XRAY_PROXY"
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
    @Volatile private var explicitStopRequested = false
    private val coreLifecycleLock = Any()
    private val coreWorker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "GhostBox-xray-core").apply { isDaemon = true }
    }
    @Volatile private var proxyReloadQueued = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        recordAndroidVpnPolicy()
        if (intent?.action == "app.ghostbox.STOP_VPN") {
            explicitStopRequested = true
            stopXray()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_RELOAD_PROXY) {
            val config = intent.getStringExtra(EXTRA_CONFIG)
            val profileName = intent.getStringExtra(EXTRA_PROFILE)
            val memoryMb = intent.getIntExtra(EXTRA_MEMORY, 128).coerceIn(64, 256)
            if (config.isNullOrBlank() || profileName.isNullOrBlank()) {
                VpnStateStore.update(this) {
                    it.put("xrayProxyState", "error")
                        .put("xrayProxyError", "Xray reload config or profile name is empty")
                }
                return START_NOT_STICKY
            }
            synchronized(coreLifecycleLock) {
                if (proxyReloadQueued) {
                    // MainActivity already marks the first request as
                    // connecting. Ignore duplicate intents rather than
                    // running overlapping stop/run calls against libXray.
                    return START_NOT_STICKY
                }
                proxyReloadQueued = true
            }
            coreWorker.execute {
                try {
                    synchronized(coreLifecycleLock) {
                        if (explicitStopRequested) return@synchronized
                        if (!proxyOnlyMode || tun != null) {
                            error("The running Xray instance cannot be reloaded as a proxy")
                        }
                        VpnStateStore.update(this) {
                            it.put("xrayProxyState", "connecting")
                                .put("xrayMemoryMb", memoryMb)
                                .remove("xrayProxyError")
                        }
                        replaceProxyCore(config, profileName)
                    }
                } catch (error: Throwable) {
                    Log.e(TAG, "Xray proxy reload failed", error)
                    VpnStateStore.update(this) {
                        it.put("xrayProxyState", "error")
                            .put("xrayProxyError", shortFailure("reloading the Xray proxy", error))
                    }
                    VpnStateStore.appendLog(
                        this,
                        "Xray proxy reload failed: ${shortFailure("reloading the Xray proxy", error)}",
                    )
                    VpnStateStore.appendLog(this, Log.getStackTraceString(error))
                } finally {
                    proxyReloadQueued = false
                }
            }
            return START_NOT_STICKY
        }
        stopping = false
        explicitStopRequested = false
        proxyOnlyMode = intent?.getBooleanExtra(EXTRA_PROXY_ONLY, false) ?: false
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val profileName = intent.getStringExtra(EXTRA_PROFILE) ?: "GhostBox"
        startForeground(notificationId(), createNotification(profileName, false))
        coreWorker.execute {
            synchronized(coreLifecycleLock) {
                if (!explicitStopRequested) startCore(config, profileName)
            }
        }
        return START_NOT_STICKY
    }

    /** Replace only the managed Xray instance; the VPN service and its TUN stay alive. */
    private fun replaceProxyCore(rawConfig: String, profileName: String) {
        stopping = true
        try {
            val response = invoke("stopXray", JSONObject())
            if (!response.optBoolean("success")) {
                error(response.optString("error", "Xray did not stop for proxy reload"))
            }
            runCatching { loadXrayApi().getMethod("resetDNS").invoke(null) }
            stopping = false
            startCore(rawConfig, profileName, keepServiceOnFailure = true)
        } finally {
            stopping = false
        }
    }

    private fun recordAndroidVpnPolicy() {
        val known = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val lockdown = if (known) isLockdownEnabled() else false
        val alwaysOn = if (known) isAlwaysOn() else false
        VpnStateStore.update(this) {
            it.put("androidLockdownStatusKnown", known)
                .put("androidLockdownEnabled", lockdown)
                .put("androidAlwaysOn", alwaysOn)
        }
    }

    private fun startCore(
        rawConfig: String,
        profileName: String,
        keepServiceOnFailure: Boolean = false,
    ) {
        var phase = "checking Android VPN permission"
        try {
            if (!proxyOnlyMode && VpnService.prepare(this) != null) {
                error("Android VPN permission is missing")
            }
            phase = "loading the embedded libXray runtime"
            val api = loadXrayApi()
            val controller = requireNotNull(dialerController)
            phase = "registering Android socket protection callbacks"
            api.getMethod("registerDialerController", loadXrayApi("libXray.DialerController"))
                .invoke(null, controller)
            api.getMethod("registerListenerController", loadXrayApi("libXray.DialerController"))
                .invoke(null, controller)
            api.getMethod("setDNS", loadXrayApi("libXray.DialerController"), String::class.java)
                .invoke(null, controller, "1.1.1.1:53")

            phase = "preparing the Xray configuration"
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
            phase = "starting Xray core"
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
                        it.put("state", "connected")
                            .put("connectedAtMs", System.currentTimeMillis())
                            .remove("error")
                        it.remove("startedAtMs")
                    }
                }
            } else {
                VpnStateStore.updateForCore(this, "xray") {
                    it.put("state", "connected")
                        .put("connectedAtMs", System.currentTimeMillis())
                        .remove("error")
                    it.remove("startedAtMs")
                }
            }
            VpnStateStore.appendLog(this, "Xray Android VPN started ($profileName)")
            getSystemService(NotificationManager::class.java)
                .notify(notificationId(), createNotification(profileName, true))
            Log.i(TAG, "Xray VPN service started")
        } catch (error: Throwable) {
            val detail = describeFailure(phase, error)
            Log.e(TAG, detail, error)
            if (proxyOnlyMode) {
                VpnStateStore.update(this) {
                    val message = shortFailure(phase, error)
                    it.put("xrayProxyState", "error").put("xrayProxyError", message)
                    if (it.optString("activeCore") == "xray") {
                        it.put("state", "error").put("error", message).remove("connectedAtMs")
                        it.remove("startedAtMs")
                    }
                }
            } else {
                VpnStateStore.updateForCore(this, "xray") {
                    it.put("state", "error").put("error", shortFailure(phase, error))
                        .remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
            }
            VpnStateStore.appendLog(this, detail)
            VpnStateStore.appendLog(this, Log.getStackTraceString(error))
            if (keepServiceOnFailure) {
                stopping = true
                runCatching { invoke("stopXray", JSONObject()) }
                    .onFailure { Log.w(TAG, "Could not clean failed reloaded Xray instance", it) }
                runCatching { loadXrayApi().getMethod("resetDNS").invoke(null) }
                stopping = false
            } else {
                stopXray()
            }
        }
    }

    private fun unwrapped(error: Throwable): Throwable {
        var current = error
        val seen = HashSet<Throwable>()
        while (seen.add(current)) {
            val next = when (current) {
                is InvocationTargetException -> current.targetException
                is ExceptionInInitializerError -> current.exception
                else -> current.cause
            } ?: break
            if (next === current) break
            current = next
        }
        return current
    }

    private fun shortFailure(phase: String, error: Throwable): String {
        val cause = unwrapped(error)
        val message = cause.message?.takeIf(String::isNotBlank)
        return "Xray failed while $phase (${cause.javaClass.simpleName})" +
            if (message == null) ". Check the connection log for the full cause." else ": $message"
    }

    private fun describeFailure(phase: String, error: Throwable): String =
        "Xray failed while $phase: ${shortFailure(phase, error)}"

    private fun invoke(method: String, payload: JSONObject): JSONObject {
        val request = JSONObject()
            .put("apiVersion", 3)
            .put("method", method)
            .put("payload", payload)
        val result = try {
            loadXrayApi().getMethod("invoke", String::class.java)
                .invoke(null, request.toString()) as String
        } catch (error: InvocationTargetException) {
            throw (error.targetException ?: error)
        }
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
                    val dexClasses = File(runtimeDir, "xray-runtime-dex.jar")
                    val nativeDir = File(runtimeDir, "jni").apply { mkdirs() }
                    val nativeLibrary = File(nativeDir, "libgojni.so")
                    // Android 14+ rejects DEX archives that still have a
                    // writable bit. Replace old writable caches through a
                    // temporary file, mark it read-only, then atomically move
                    // it into place before DexClassLoader sees the path.
                    val stagedDex = File(
                        runtimeDir,
                        "xray-runtime-dex.jar.tmp-${android.os.Process.myPid()}",
                    )
                    stagedDex.delete()
                    assets.open("xray-runtime-dex.jar").use { input ->
                        stagedDex.outputStream().use(input::copyTo)
                    }
                    if (!stagedDex.setReadOnly() || stagedDex.canWrite()) {
                        stagedDex.delete()
                        error("Could not make the embedded Xray DEX archive read-only")
                    }
                    if (dexClasses.exists() && !dexClasses.delete()) {
                        stagedDex.delete()
                        error("Could not replace the previous Xray DEX cache")
                    }
                    if (!stagedDex.renameTo(dexClasses)) {
                        stagedDex.delete()
                        error("Could not install the Xray DEX archive")
                    }
                    if (!nativeLibrary.isFile) {
                        nativeLibrary.setWritable(true, false)
                        ZipFile(aarFile).use { archive ->
                            val abi = Build.SUPPORTED_ABIS.firstNotNullOfOrNull { candidate ->
                                archive.getEntry("jni/$candidate/libgojni.so")?.let { candidate to it }
                            } ?: error("libXray AAR has no native library for ${Build.SUPPORTED_ABIS.joinToString()}")
                            archive.getInputStream(abi.second).use { input ->
                                nativeLibrary.outputStream().use(input::copyTo)
                            }
                        }
                    }
                    val hasDex = ZipFile(dexClasses).use { archive ->
                        archive.getEntry("classes.dex")?.size?.let { it > 0 } ?: false
                    }
                    if (!hasDex) {
                        dexClasses.delete()
                        error("The embedded Xray bindings are not DEX-compiled")
                    }
                    dexClasses.setReadable(true, false)
                    nativeLibrary.setReadable(true, false)
                    loader = ChildFirstGoClassLoader(
                        dexClasses.absolutePath,
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
        synchronized(coreLifecycleLock) {
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
                    if (it.optString("xrayProxyState") != "error" || explicitStopRequested) {
                        it.put("xrayProxyState", "disconnected")
                    }
                    if (it.optString("state") == "stopping") {
                        it.put("state", "disconnected").remove("connectedAtMs")
                        it.remove("startedAtMs")
                    }
                    if (explicitStopRequested) it.put("xrayStopComplete", true)
                }
            } else if (VpnStateStore.state(this) != "error" || explicitStopRequested) {
                VpnStateStore.updateForCore(this, "xray") {
                    it.put("state", "disconnected").remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
                if (explicitStopRequested) {
                    VpnStateStore.update(this) {
                        it.put("xrayProxyState", "disconnected")
                        it.put("xrayStopComplete", true)
                        if (it.optString("state") == "stopping") {
                            it.put("state", "disconnected").remove("connectedAtMs")
                            it.remove("startedAtMs")
                        }
                    }
                }
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        if (!stopping) stopXray()
        super.onDestroy()
    }

    override fun onRevoke() {
        Log.w(TAG, "Android revoked the VPN interface")
        VpnStateStore.appendLog(this, "Android revoked the Xray VPN interface")
        if (proxyOnlyMode) {
            VpnStateStore.update(this) {
                if (it.optString("activeCore") == "xray" && it.optString("state") != "error") {
                    it.put("state", "disconnected").remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
            }
        } else {
            VpnStateStore.updateForCore(this, "xray") {
                if (it.optString("state") != "error") {
                    it.put("state", "disconnected").remove("connectedAtMs")
                    it.remove("startedAtMs")
                }
            }
        }
        stopXray()
    }
}
