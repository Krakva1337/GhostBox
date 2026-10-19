package app.ghostbox.ghostbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.net.InetAddress

class GhostBoxVpnService : VpnService(), CommandServerHandler {
    companion object {
        const val EXTRA_CONFIG = "ghostbox.config"
        const val EXTRA_PROFILE = "ghostbox.profile"
        const val EXTRA_MEMORY = "ghostbox.memory"
        private const val CHANNEL_ID = "ghostbox_vpn"
        private const val NOTIFICATION_ID = 731
        private const val TAG = "GhostBoxVpn"
        @Volatile private var libboxInitialized = false
    }

    private var commandServer: CommandServer? = null
    @Volatile private var currentProfileName = "GhostBox"
    @Volatile private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "app.ghostbox.STOP_VPN") {
            stopVpn()
            return START_NOT_STICKY
        }
        stopping = false
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val name = intent.getStringExtra(EXTRA_PROFILE) ?: "GhostBox"
        currentProfileName = name
        val memoryMb = intent.getIntExtra(EXTRA_MEMORY, 128).coerceIn(64, 256)
        startForeground(NOTIFICATION_ID, createNotification(name, connected = false))
        Thread({ startCore(config, memoryMb) }, "GhostBox-sing-box-start").start()
        return START_NOT_STICKY
    }

    private fun startCore(config: String, memoryMb: Int) {
        try {
            val setup = SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = filesDir.absolutePath
                tempPath = cacheDir.absolutePath
                logMaxLines = 1000
                appVersion = BuildConfig.VERSION_NAME
                appMarketingVersion = BuildConfig.VERSION_NAME
                platformMetadata = "Android ${Build.VERSION.RELEASE} (${Build.MODEL})"
                oomKillerEnabled = true
                oomMemoryLimit = memoryMb.toLong() * 1024L * 1024L
            }
            if (!libboxInitialized) {
                synchronized(GhostBoxVpnService::class.java) {
                    if (!libboxInitialized) {
                        Libbox.setup(setup)
                        libboxInitialized = true
                    }
                }
            }
            if (stopping) return
            val platform = createPlatform()
            val server = CommandServer(this, platform)
            server.start()
            commandServer = server
            if (stopping) {
                server.close()
                commandServer = null
                return
            }
            server.startOrReloadService(config, OverrideOptions())
            getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
                .putString("state", "connected").remove("error").apply()
            updateNotification(connected = true)
            Log.i(TAG, "sing-box VPN service started")
        } catch (error: Exception) {
            Log.e(TAG, "sing-box failed to start", error)
            getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
                .putString("state", "error")
                .putString("error", error.message ?: error.toString()).apply()
            stopVpn()
        }
    }

    private fun createPlatform(): PlatformInterface {
        val handler = InvocationHandler { _, method, args ->
            when (method.name) {
                "usePlatformAutoDetectInterfaceControl" -> true
                "autoDetectInterfaceControl" -> {
                    protect((args?.firstOrNull() as? Number)?.toInt() ?: -1)
                    null
                }
                "usePlatformInterface" -> true
                "useProcFS" -> false
                "openTun" -> openTun(args?.firstOrNull() ?: error("Missing TUN options"))
                "underNetworkExtension", "includeAllNetworks", "usePlatformBridge",
                "usePlatformAutoRedirect", "usePlatformShell" -> false
                "startDefaultInterfaceMonitor", "closeDefaultInterfaceMonitor",
                "clearDNSCache", "startNeighborMonitor", "closeNeighborMonitor",
                "registerMyInterface" -> null
                "getInterfaces" -> emptyIteratorProxy(method.returnType)
                "findConnectionOwner" -> null
                "readWIFIState", "localDNSTransport", "createBridge",
                "createAutoRedirect", "openShellSession" -> null
                "lookupUser" -> null
                "tailscaleHostname" -> "GhostBox Android"
                "lookupSFTPServer", "readSystemSSHHostKey" -> ""
                "toString" -> "GhostBoxAndroidPlatform"
                "hashCode" -> System.identityHashCode(this)
                "equals" -> this === args?.firstOrNull()
                else -> defaultValue(method.returnType)
            }
        }
        return Proxy.newProxyInstance(
            PlatformInterface::class.java.classLoader,
            arrayOf(PlatformInterface::class.java),
            handler,
        ) as PlatformInterface
    }

    private fun openTun(options: Any): Int {
        if (VpnService.prepare(this) != null) error("Android VPN permission is missing")
        val builder = Builder().setSession("GhostBox").setMtu(readNumber(options, "mtu", 1500))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        readIterator(options, "inet4Address").forEach { addAddress(builder, it) }
        readIterator(options, "inet6Address").forEach { addAddress(builder, it) }
        if (readBoolean(options, "autoRoute")) {
            readIterator(options, "dnsServerAddress").forEach { builder.addDnsServer(it) }
            val ipv4Routes = readIterator(options, "inet4RouteAddress")
                .ifEmpty { readIterator(options, "inet4RouteRange") }
            val ipv6Routes = readIterator(options, "inet6RouteAddress")
                .ifEmpty { readIterator(options, "inet6RouteRange") }
            if (ipv4Routes.isEmpty() && ipv6Routes.isEmpty()) {
                builder.addRoute("0.0.0.0", 0)
                builder.addRoute("::", 0)
            } else {
                (ipv4Routes + ipv6Routes).forEach { addRoute(builder, it) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                (readIterator(options, "inet4RouteExcludeAddress") +
                    readIterator(options, "inet6RouteExcludeAddress")).forEach { value ->
                    val (address, prefix) = splitPrefix(value)
                    builder.excludeRoute(IpPrefix(InetAddress.getByName(address), prefix))
                }
            }
        }
        val descriptor = builder.establish() ?: error("Could not establish Android VPN interface")
        return descriptor.detachFd()
    }

    private fun addAddress(builder: Builder, value: String) {
        val (address, prefix) = splitPrefix(value)
        builder.addAddress(InetAddress.getByName(address), prefix)
    }

    private fun addRoute(builder: Builder, value: String) {
        val (address, prefix) = splitPrefix(value)
        builder.addRoute(InetAddress.getByName(address), prefix)
    }

    private fun splitPrefix(value: String): Pair<String, Int> {
        val pieces = value.split('/')
        val address = InetAddress.getByName(pieces[0])
        val max = if (address.address.size == 4) 32 else 128
        return pieces[0] to (pieces.getOrNull(1)?.toIntOrNull() ?: max).coerceIn(0, max)
    }

    private fun readIterator(target: Any, property: String): List<String> {
        val iterator = readProperty(target, property) ?: return emptyList()
        val hasNext = iterator.javaClass.methods.firstOrNull { it.name == "hasNext" } ?: return emptyList()
        val next = iterator.javaClass.methods.firstOrNull { it.name == "next" } ?: return emptyList()
        val output = mutableListOf<String>()
        while ((hasNext.invoke(iterator) as? Boolean) == true) {
            output += (next.invoke(iterator)?.toString() ?: continue)
        }
        return output
    }

    private fun readNumber(target: Any, property: String, fallback: Int): Int =
        (readProperty(target, property) as? Number)?.toInt() ?: fallback

    private fun readBoolean(target: Any, property: String): Boolean =
        readProperty(target, property) as? Boolean ?: false

    private fun readProperty(target: Any, property: String): Any? {
        val capitalized = property.replaceFirstChar { it.uppercase() }
        val getter = target.javaClass.methods.firstOrNull {
            it.name == "get$capitalized" || it.name == "is$capitalized" || it.name == property
        } ?: return null
        return getter.invoke(target)
    }

    private fun emptyIteratorProxy(type: Class<*>): Any = Proxy.newProxyInstance(
        type.classLoader,
        arrayOf(type),
    ) { _, method, _ ->
        when (method.name) {
            "hasNext" -> false
            "len" -> 0
            else -> defaultValue(method.returnType)
        }
    }

    private fun defaultValue(type: Class<*>): Any? = when (type) {
        java.lang.Boolean.TYPE -> false
        java.lang.Integer.TYPE -> 0
        java.lang.Long.TYPE -> 0L
        java.lang.Short.TYPE -> 0.toShort()
        java.lang.Byte.TYPE -> 0.toByte()
        java.lang.Float.TYPE -> 0f
        java.lang.Double.TYPE -> 0.0
        else -> null
    }

    private fun updateNotification(connected: Boolean) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, createNotification(currentProfileName, connected))
    }

    private fun createNotification(profileName: String, connected: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.vpn_notification_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ghostbox_status)
                .setContentTitle(profileName)
                .setContentText(
                    getString(
                        if (connected) R.string.vpn_notification_connected
                        else R.string.vpn_notification_connecting,
                    ),
                )
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ghostbox_status)
                .setContentTitle(profileName)
                .setContentText(
                    getString(
                        if (connected) R.string.vpn_notification_connected
                        else R.string.vpn_notification_connecting,
                    ),
                )
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        }
    }

    private fun stopVpn() {
        stopping = true
        try {
            commandServer?.closeService()
            commandServer?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Error while stopping sing-box", error)
        } finally {
            commandServer = null
            if (getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).getString("state", "") != "error") {
                getSharedPreferences("ghostbox_vpn", MODE_PRIVATE).edit()
                    .putString("state", "disconnected").apply()
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        if (!stopping) stopVpn()
        super.onDestroy()
    }

    override fun serviceStop() = stopVpn()
    override fun serviceReload() = Unit
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        available = false
        enabled = false
    }
    override fun setSystemProxyEnabled(enabled: Boolean) = Unit
    override fun triggerNativeCrash() = error("Not supported")
    override fun writeDebugMessage(message: String?) {
        val line = message.orEmpty()
        Log.d(TAG, line)
        val preferences = getSharedPreferences("ghostbox_vpn", MODE_PRIVATE)
        val logs = runCatching {
            org.json.JSONArray(preferences.getString("logs", "[]") ?: "[]")
        }.getOrElse { org.json.JSONArray() }
        logs.put(line)
        while (logs.length() > 1000) logs.remove(0)
        preferences.edit().putString("logs", logs.toString()).apply()
    }
    override fun connectSSHAgent(): Int = -1
}
