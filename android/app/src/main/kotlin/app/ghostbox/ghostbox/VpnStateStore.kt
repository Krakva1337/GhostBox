package app.ghostbox.ghostbox

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel

/** Small cross-process state bridge for the isolated native core services. */
internal object VpnStateStore {
    private const val FILE_NAME = "ghostbox-vpn-state.json"
    private const val LOCK_FILE_NAME = "ghostbox-vpn-state.lock"
    private const val MAX_LOG_LINES = 1000

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)
    private fun lockFile(context: Context) = File(context.filesDir, LOCK_FILE_NAME)

    private fun readUnlocked(context: Context): JSONObject = runCatching {
        JSONObject(file(context).takeIf { it.isFile }?.readText() ?: "{}")
    }.getOrElse { JSONObject() }

    @Synchronized
    fun read(context: Context): JSONObject = withLock(context) {
        readUnlocked(context)
    }

    @Synchronized
    fun update(context: Context, block: (JSONObject) -> Unit) {
        withLock(context) {
            val target = file(context)
            val temporary = File(context.filesDir, "$FILE_NAME.tmp")
            val value = readUnlocked(context)
            block(value)
            temporary.writeText(value.toString())
            if (!temporary.renameTo(target)) {
                target.writeText(value.toString())
                temporary.delete()
            }
        }
    }

    private inline fun <T> withLock(context: Context, action: () -> T): T =
        RandomAccessFile(lockFile(context), "rw").use { lockHandle ->
            val channel: FileChannel = lockHandle.channel
            channel.lock().use { action() }
        }

    fun updateForCore(context: Context, core: String, block: (JSONObject) -> Unit) {
        update(context) { value ->
            if (value.optString("activeCore", "sing-box") == core) block(value)
        }
    }

    fun state(context: Context): String = read(context).optString("state", "disconnected")
    fun error(context: Context): String? = read(context).optString("error", null)
    fun activeCore(context: Context): String = read(context).optString("activeCore", "sing-box")
    fun androidLockdownStatus(context: Context): Boolean? {
        val value = read(context)
        if (!value.optBoolean("androidLockdownStatusKnown", false)) return null
        return value.optBoolean("androidLockdownEnabled", false)
    }
    fun xrayProxyState(context: Context): String =
        read(context).optString("xrayProxyState", "disconnected")
    fun xrayProxyError(context: Context): String? =
        read(context).optString("xrayProxyError", null)
    fun connectedAtMs(context: Context): Long? = read(context)
        .takeIf { it.optString("state") == "connected" }
        ?.optLong("connectedAtMs")
        ?.takeIf { it > 0L }

    fun logs(context: Context): List<String> {
        val values = read(context).optJSONArray("logs") ?: JSONArray()
        val result = (0 until values.length()).map { values.optString(it) }.toMutableList()
        latestSingBoxCrashReport(context)?.let { (path, content) ->
            result.add("[sing-box crash report: ${path.name}]")
            result.addAll(content.lineSequence().toList())
        }
        return result
    }

    /**
     * sing-box-lx redirects Go's crash output to filesDir/CrashReport-*.log,
     * then archives it under filesDir/crash_reports on its next setup. Surface
     * either form through the existing connection log so Android crashes can
     * be diagnosed without adb.
     */
    private fun latestSingBoxCrashReport(context: Context): Pair<File, String>? {
        val workingDir = context.filesDir
        val liveReport = File(workingDir, "CrashReport-ghostbox-sing-box.log")
        val liveContent = readReport(liveReport)
        if (liveContent != null) return liveReport to liveContent

        val reportsDir = File(workingDir, "crash_reports")
        val archived = reportsDir.listFiles()
            ?.asSequence()
            ?.filter(File::isDirectory)
            ?.map { directory -> File(directory, "go.log") }
            ?.filter(File::isFile)
            ?.sortedByDescending(File::lastModified)
            ?.firstOrNull()
            ?: return null
        return readReport(archived)?.let { archived to it }
    }

    private fun readReport(file: File): String? = runCatching {
        if (!file.isFile || file.length() <= 0L) return null
        val content = file.readText()
        content.takeLast(64 * 1024).takeIf(String::isNotBlank)
    }.getOrNull()

    fun appendLog(context: Context, line: String) = update(context) { value ->
        val old = value.optJSONArray("logs") ?: JSONArray()
        val logs = JSONArray()
        for (index in (old.length() - MAX_LOG_LINES + 1).coerceAtLeast(0) until old.length()) {
            logs.put(old.optString(index))
        }
        logs.put(line)
        value.put("logs", logs)
    }
}
