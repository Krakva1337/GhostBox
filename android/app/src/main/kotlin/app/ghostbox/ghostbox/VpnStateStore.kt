package app.ghostbox.ghostbox

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Small cross-process state bridge for the isolated native core services. */
internal object VpnStateStore {
    private const val FILE_NAME = "ghostbox-vpn-state.json"
    private const val MAX_LOG_LINES = 1000

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)

    private fun read(context: Context): JSONObject = runCatching {
        JSONObject(file(context).takeIf { it.isFile }?.readText() ?: "{}")
    }.getOrElse { JSONObject() }

    @Synchronized
    fun update(context: Context, block: (JSONObject) -> Unit) {
        val target = file(context)
        val temporary = File(context.filesDir, "$FILE_NAME.tmp")
        val value = read(context)
        block(value)
        temporary.writeText(value.toString())
        if (!temporary.renameTo(target)) {
            target.writeText(value.toString())
            temporary.delete()
        }
    }

    fun updateForCore(context: Context, core: String, block: (JSONObject) -> Unit) {
        update(context) { value ->
            if (value.optString("activeCore", "sing-box") == core) block(value)
        }
    }

    fun state(context: Context): String = read(context).optString("state", "disconnected")
    fun error(context: Context): String? = read(context).optString("error", null)
    fun activeCore(context: Context): String = read(context).optString("activeCore", "sing-box")
    fun xrayProxyState(context: Context): String =
        read(context).optString("xrayProxyState", "disconnected")
    fun xrayProxyError(context: Context): String? =
        read(context).optString("xrayProxyError", null)
    fun logs(context: Context): List<String> {
        val values = read(context).optJSONArray("logs") ?: JSONArray()
        return (0 until values.length()).map { values.optString(it) }
    }

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
