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
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.math.BigInteger
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
        recordAndroidVpnPolicy()
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
                // Go's Android stack workaround prevents native stack faults on
                // devices with stricter ART/NDK behavior.
                fixAndroidStack = true
                // Do not let libbox terminate the isolated VPN process at its
                // conservative default heap cap. Android's LMK manages this
                // service process; a Go-side kill leaves ActivityManager with
                // a dead VPN service and reports "process is bad" on restart.
                oomKillerEnabled = false
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
            VpnStateStore.updateForCore(this, "sing-box") {
                it.put("state", "connected").remove("error")
            }
            updateNotification(connected = true)
            Log.i(TAG, "sing-box VPN service started")
        } catch (error: Throwable) {
            Log.e(TAG, "sing-box failed to start", error)
            VpnStateStore.updateForCore(this, "sing-box") {
                it.put("state", "error").put("error", error.message ?: error.toString())
            }
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

    private fun openTun(value: Any): Int {
        if (VpnService.prepare(this) != null) error("Android VPN permission is missing")
        val options = value as? TunOptions ?: error("Unexpected sing-box TUN options: ${value.javaClass.name}")
        val builder = Builder().setSession("GhostBox").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        options.inet4Address.forEach { builder.addAddress(it.address(), it.prefix()) }
        options.inet6Address.forEach { builder.addAddress(it.address(), it.prefix()) }
        if (options.autoRoute) {
            if (!options.dnsMode.value.equals("disabled", ignoreCase = true)) {
                options.dnsServerAddress.forEach { builder.addDnsServer(it) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val ipv4Routes = options.inet4RouteAddress
                val ipv6Routes = options.inet6RouteAddress
                if (!ipv4Routes.hasNext() && !ipv6Routes.hasNext()) {
                    // Some configs request auto-route without explicit routes.
                    // Add only families that have a TUN address.
                    if (options.inet4Address.hasNext()) builder.addRoute("0.0.0.0", 0)
                    if (options.inet6Address.hasNext()) builder.addRoute("::", 0)
                } else {
                    ipv4Routes.forEach { builder.addRoute(it.address(), it.prefix()) }
                    ipv6Routes.forEach { builder.addRoute(it.address(), it.prefix()) }
                }
                options.inet4RouteExcludeAddress.forEach { builder.excludeRoute(it.toIpPrefix()) }
                options.inet6RouteExcludeAddress.forEach { builder.excludeRoute(it.toIpPrefix()) }
            } else {
                val ipv4Routes = options.inet4RouteRange
                val ipv6Routes = options.inet6RouteRange
                if (!ipv4Routes.hasNext() && !ipv6Routes.hasNext()) {
                    if (options.inet4Address.hasNext()) {
                        addRoutesExcluding(
                            builder,
                            listOf(NetPrefix("0.0.0.0", 0)),
                            collectPrefixes(options.inet4RouteExcludeAddress),
                            32,
                        )
                    }
                    if (options.inet6Address.hasNext()) {
                        addRoutesExcluding(
                            builder,
                            listOf(NetPrefix("::", 0)),
                            collectPrefixes(options.inet6RouteExcludeAddress),
                            128,
                        )
                    }
                } else {
                    addRoutesExcluding(
                        builder,
                        collectPrefixes(ipv4Routes),
                        collectPrefixes(options.inet4RouteExcludeAddress),
                        32,
                    )
                    addRoutesExcluding(
                        builder,
                        collectPrefixes(ipv6Routes),
                        collectPrefixes(options.inet6RouteExcludeAddress),
                        128,
                    )
                }
            }
        }
        val descriptor = builder.establish() ?: error("Could not establish Android VPN interface")
        return descriptor.detachFd()
    }

    private inline fun <T> RoutePrefixIterator.forEach(action: (RoutePrefix) -> T) {
        while (hasNext()) action(next())
    }

    /** Android API 21–32 has no Builder.excludeRoute; carve exclusions out of
     * included routes as CIDR blocks instead of silently routing them into TUN.
     */
    private data class NetPrefix(val address: String, val prefix: Int)

    private fun collectPrefixes(iterator: RoutePrefixIterator): List<NetPrefix> =
        buildList {
            while (iterator.hasNext()) {
                val item = iterator.next()
                add(NetPrefix(item.address(), item.prefix()))
            }
        }

    private data class AddressRange(val start: BigInteger, val end: BigInteger)

    private fun addRoutesExcluding(
        builder: Builder,
        routes: List<NetPrefix>,
        exclusions: List<NetPrefix>,
        bits: Int,
    ) {
        val familyExclusions = exclusions.mapNotNull { prefix ->
            val bytes = InetAddress.getByName(prefix.address).address
            if (bytes.size * 8 != bits) return@mapNotNull null
            prefix.toRange(bits)
        }
        routes.forEach { route ->
            val routeBytes = InetAddress.getByName(route.address).address
            if (routeBytes.size * 8 != bits) return@forEach
            var remaining = mutableListOf(route.toRange(bits))
            familyExclusions.forEach { excluded ->
                remaining = remaining.flatMap { current ->
                    when {
                        excluded.end < current.start || excluded.start > current.end ->
                            listOf(current)
                        else -> buildList {
                            if (excluded.start > current.start) {
                                add(AddressRange(current.start, excluded.start - BigInteger.ONE))
                            }
                            if (excluded.end < current.end) {
                                add(AddressRange(excluded.end + BigInteger.ONE, current.end))
                            }
                        }
                    }
                }.toMutableList()
            }
            remaining.forEach { range -> addRange(builder, range, bits) }
        }
    }

    private fun NetPrefix.toRange(bits: Int): AddressRange {
        val address = BigInteger(1, InetAddress.getByName(address).address)
        val hostBits = (bits - prefix).coerceIn(0, bits)
        val size = BigInteger.ONE.shiftLeft(hostBits)
        val start = address.divide(size).multiply(size)
        return AddressRange(start, start + size - BigInteger.ONE)
    }

    private fun addRange(builder: Builder, range: AddressRange, bits: Int) {
        val addressLimit = BigInteger.ONE.shiftLeft(bits)
        var cursor = range.start
        while (cursor <= range.end) {
            val alignmentBits = if (cursor == BigInteger.ZERO) bits else cursor.lowestSetBit
            val remainingBits = (range.end - cursor + BigInteger.ONE).bitLength() - 1
            val hostBits = minOf(alignmentBits, remainingBits, bits)
            val bytes = cursor.toByteArray().let { encoded ->
                val result = ByteArray(bits / 8)
                val sourceOffset = (encoded.size - result.size).coerceAtLeast(0)
                val copyLength = minOf(encoded.size, result.size)
                System.arraycopy(encoded, sourceOffset, result, result.size - copyLength, copyLength)
                result
            }
            builder.addRoute(InetAddress.getByAddress(bytes), bits - hostBits)
            cursor += BigInteger.ONE.shiftLeft(hostBits)
            if (cursor >= addressLimit) break
        }
    }

    private inline fun StringIterator.forEach(action: (String) -> Unit) {
        while (hasNext()) action(next())
    }

    private fun RoutePrefix.toIpPrefix(): IpPrefix =
        IpPrefix(InetAddress.getByName(address()), prefix())

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
            if (VpnStateStore.state(this) != "error") {
                VpnStateStore.updateForCore(this, "sing-box") { it.put("state", "disconnected") }
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
        VpnStateStore.appendLog(this, line)
    }
    override fun connectSSHAgent(): Int = -1
}
