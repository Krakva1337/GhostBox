package app.ghostbox.ghostbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
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
import java.net.InetSocketAddress

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
    @Volatile private var tunDescriptor: ParcelFileDescriptor? = null
    @Volatile private var currentProfileName = "GhostBox"
    @Volatile private var stopping = false
    @Volatile private var tunEstablished = false
    @Volatile private var explicitStopRequested = false
    private val lifecycleLock = Any()
    private var startWorkerRunning = false
    private var pendingStart: StartRequest? = null
    private var stopCleanupPending = false
    private var stopCleanupRunning = false
    private var latestStartId = 0

    private data class StartRequest(val config: String, val profileName: String, val memoryMb: Int)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        recordAndroidVpnPolicy()
        if (intent?.action == "app.ghostbox.STOP_VPN") {
            explicitStopRequested = true
            synchronized(lifecycleLock) { latestStartId = startId }
            stopVpn()
            return START_NOT_STICKY
        }
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            synchronized(lifecycleLock) { latestStartId = startId }
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val name = intent.getStringExtra(EXTRA_PROFILE) ?: "GhostBox"
        currentProfileName = name
        val memoryMb = intent.getIntExtra(EXTRA_MEMORY, 128).coerceIn(64, 256)
        val launchWorker = enqueueStart(StartRequest(config, name, memoryMb), startId)
        startForeground(NOTIFICATION_ID, createNotification(name, connected = false))
        if (launchWorker) launchStartWorker()
        return START_NOT_STICKY
    }

    /** Serialize libbox start/reload calls. Starting a second CommandServer
     * from a duplicate service intent can race Go's process-global runtime.
     */
    private fun enqueueStart(request: StartRequest, startId: Int): Boolean = synchronized(lifecycleLock) {
        latestStartId = startId
        explicitStopRequested = false
        pendingStart = request // Keep the newest intent while a start is in flight.
        if (startWorkerRunning || stopCleanupRunning) false else {
            stopping = false
            stopCleanupPending = false
            startWorkerRunning = true
            true
        }
    }

    private fun launchStartWorker() {
        Thread({ drainStarts() }, "GhostBox-sing-box-start").start()
    }

    private fun drainStarts() {
        while (true) {
            val request = synchronized(lifecycleLock) {
                if (stopping) pendingStart = null
                val next = pendingStart
                pendingStart = null
                if (next == null) startWorkerRunning = false
                next
            }
            if (request == null) {
                runPendingStopCleanup()
                return
            }
            startCore(request.config, request.memoryMb)
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

    private fun startCore(config: String, memoryMb: Int) {
        var phase = "initializing libbox"
        try {
            val setup = SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = filesDir.absolutePath
                tempPath = cacheDir.absolutePath
                logMaxLines = 1000
                appVersion = BuildConfig.VERSION_NAME
                appMarketingVersion = BuildConfig.VERSION_NAME
                crashReportSource = "ghostbox-sing-box"
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
            phase = "starting the sing-box command server"
            var server = commandServer
            val createdServer = server == null
            if (server == null) {
                val platform = createPlatform()
                server = CommandServer(this, platform)
                server.start()
                commandServer = server
            }
            if (stopping) {
                if (createdServer) {
                    server.close()
                    if (commandServer === server) commandServer = null
                }
                return
            }
            tunEstablished = false
            phase = "installing the Android TUN interface"
            server.startOrReloadService(config, OverrideOptions())
            if (stopping) return
            if (!tunEstablished) {
                error("sing-box returned without asking Android to establish a TUN interface")
            }
            VpnStateStore.updateForCore(this, "sing-box") {
                it.put("state", "connected")
                    .put("connectedAtMs", System.currentTimeMillis())
                    .remove("error")
                it.remove("startedAtMs")
            }
            updateNotification(connected = true)
            Log.i(TAG, "sing-box VPN service started")
        } catch (error: Throwable) {
            val detail = "sing-box failed while $phase: ${error.message ?: error.javaClass.name}"
            Log.e(TAG, detail, error)
            VpnStateStore.updateForCore(this, "sing-box") {
                it.put("state", "error").put("error", detail).remove("connectedAtMs")
                it.remove("startedAtMs")
            }
            VpnStateStore.appendLog(this, detail)
            VpnStateStore.appendLog(this, Log.getStackTraceString(error))
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
                "useProcFS" -> Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
                "openTun" -> openTun(args?.firstOrNull() ?: error("Missing TUN options"))
                "underNetworkExtension", "includeAllNetworks", "usePlatformBridge",
                "usePlatformAutoRedirect", "usePlatformShell" -> false
                "startDefaultInterfaceMonitor", "closeDefaultInterfaceMonitor",
                "clearDNSCache", "startNeighborMonitor", "closeNeighborMonitor",
                "registerMyInterface" -> null
                "getInterfaces" -> emptyIteratorProxy(method.returnType)
                "findConnectionOwner" -> findConnectionOwner(args)
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

    /** libbox dereferences ConnectionOwner without a nil check. Returning null
     * here crashed the Go runtime on the first routed packet. */
    private fun findConnectionOwner(args: Array<out Any?>?): ConnectionOwner {
        val owner = ConnectionOwner()
        val emptyPackages = stringIteratorProxy(emptyList())
        owner.userId = -1
        owner.userName = ""
        owner.setAndroidPackageNames(emptyPackages)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return owner
        }
        return try {
            val protocol = (args?.getOrNull(0) as? Number)?.toInt() ?: -1
            val sourceAddress = args?.getOrNull(1)?.toString() ?: return owner
            val sourcePort = (args.getOrNull(2) as? Number)?.toInt() ?: return owner
            val destinationAddress = args.getOrNull(3)?.toString() ?: return owner
            val destinationPort = (args.getOrNull(4) as? Number)?.toInt() ?: return owner
            val uid = getSystemService(android.net.ConnectivityManager::class.java)
                .getConnectionOwnerUid(
                    protocol,
                    InetSocketAddress(sourceAddress, sourcePort),
                    InetSocketAddress(destinationAddress, destinationPort),
                )
            val packages = if (uid >= 0) {
                packageManager.getPackagesForUid(uid)?.toList().orEmpty()
            } else {
                emptyList()
            }
            owner.userId = uid
            owner.userName = packages.firstOrNull().orEmpty()
            owner.setAndroidPackageNames(stringIteratorProxy(packages))
            owner
        } catch (error: Exception) {
            Log.w(TAG, "Could not resolve Android connection owner", error)
            owner.userId = -1
            owner.userName = ""
            owner.setAndroidPackageNames(emptyPackages)
            owner
        }
    }

    private fun stringIteratorProxy(values: List<String>): StringIterator {
        var index = 0
        return Proxy.newProxyInstance(
            StringIterator::class.java.classLoader,
            arrayOf(StringIterator::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "hasNext" -> index < values.size
                "len" -> values.size
                "next" -> values.getOrNull(index++) ?: ""
                "toString" -> values.toString()
                "hashCode" -> System.identityHashCode(values)
                "equals" -> false
                else -> defaultValue(method.returnType)
            }
        } as StringIterator
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
        // Keep the ParcelFileDescriptor, like the upstream sing-box Android
        // service. Closing it on stop is what releases Android's VPN route
        // and status icon; detaching here left the service without a handle.
        tunDescriptor?.let { runCatching { it.close() } }
        tunDescriptor = descriptor
        val fd = descriptor.fd
        tunEstablished = true
        Log.i(TAG, "Android TUN established (fd=$fd, mtu=${options.mtu})")
        VpnStateStore.appendLog(this, "Android sing-box TUN established (MTU ${options.mtu})")
        return fd
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
        val cleanupNow = synchronized(lifecycleLock) {
            stopping = true
            pendingStart = null
            stopCleanupPending = true
            if (startWorkerRunning || stopCleanupRunning) false else {
                stopCleanupRunning = true
                true
            }
        }
        if (!cleanupNow) return
        cleanupVpn()
    }

    private fun runPendingStopCleanup() {
        val cleanupNow = synchronized(lifecycleLock) {
            if (!stopCleanupPending || stopCleanupRunning || startWorkerRunning) false else {
                stopCleanupRunning = true
                true
            }
        }
        if (cleanupNow) cleanupVpn()
    }

    /** Called only after any in-flight libbox operation has returned. */
    private fun cleanupVpn() {
        val descriptor = tunDescriptor
        tunDescriptor = null
        runCatching { descriptor?.close() }
        try {
            commandServer?.closeService()
            commandServer?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Error while stopping sing-box", error)
        }

        commandServer = null
        val queuedStart = synchronized(lifecycleLock) {
            val queued = pendingStart
            if (queued != null) {
                stopping = false
                stopCleanupPending = false
                startWorkerRunning = true
            } else {
                if (VpnStateStore.state(this) != "error" || explicitStopRequested) {
                    VpnStateStore.updateForCore(this, "sing-box") {
                        it.put("state", "disconnected").remove("connectedAtMs")
                        it.remove("startedAtMs")
                    }
                    VpnStateStore.update(this) {
                        if (it.optString("state") == "stopping") {
                            it.put("state", "disconnected").remove("connectedAtMs")
                            it.remove("startedAtMs")
                        }
                        if (explicitStopRequested) it.put("xrayProxyState", "disconnected")
                        if (explicitStopRequested) it.put("singBoxStopComplete", true)
                    }
                }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelfResult(latestStartId)
                stopCleanupPending = false
                stopCleanupRunning = false
            }
            queued
        }
        if (queuedStart != null) {
            currentProfileName = queuedStart.profileName
            startForeground(
                NOTIFICATION_ID,
                createNotification(queuedStart.profileName, connected = false),
            )
            synchronized(lifecycleLock) { stopCleanupRunning = false }
            launchStartWorker()
        }
    }

    override fun onDestroy() {
        if (!stopping) stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        Log.w(TAG, "Android revoked the VPN interface")
        VpnStateStore.appendLog(this, "Android revoked the sing-box VPN interface")
        VpnStateStore.updateForCore(this, "sing-box") {
            if (it.optString("state") != "error") {
                it.put("state", "disconnected").remove("connectedAtMs")
                it.remove("startedAtMs")
            }
        }
        stopVpn()
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
