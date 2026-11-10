package app.ghostbox.ghostbox

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import org.json.JSONObject
import java.io.File

/** Persists the OS installer result even when Android recreates the app process. */
class UpdateInstallStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MainActivity.UPDATE_INSTALL_ACTION) return
        val transactionId = intent.getStringExtra("transactionId") ?: return
        val pending = goAsync()
        Thread({
            try {
                val transactionPath = intent.getStringExtra("transactionPath") ?: return@Thread
                val file = File(transactionPath).canonicalFile
                val updates = File(context.filesDir, "updates").canonicalFile
                if (!file.path.startsWith(updates.path + File.separator) ||
                    file.name != "update_transaction.json") return@Thread
                if (!file.isFile) return@Thread
                val transaction = JSONObject(file.readText())
                if (transaction.optString("id") != transactionId) return@Thread
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
                when (status) {
                    PackageInstaller.STATUS_SUCCESS -> transaction.put("status", "INSTALLATION_SUCCEEDED_PENDING_HEALTH")
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(Intent.EXTRA_INTENT)
                        }
                        if (confirm != null) {
                            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(confirm)
                        }
                        return@Thread
                    }
                    else -> transaction.put("status", "FAILED").put("error", message.ifBlank { "PackageInstaller status $status" })
                }
                transaction.put("installerStatus", status)
                    .put("updatedAt", System.currentTimeMillis())
                file.writeText(transaction.toString())
                if (status == PackageInstaller.STATUS_SUCCESS) {
                    val packagePath = transaction.optString("packagePath")
                    if (packagePath.isNotBlank()) {
                        val apk = File(packagePath).canonicalFile
                        val cache = File(context.cacheDir, "updates").canonicalFile
                        if (apk.path.startsWith(cache.path + File.separator) && apk.isFile) {
                            val parent = apk.parentFile
                            apk.delete()
                            if (parent?.name?.startsWith("ghostbox-update-") == true) {
                                parent.deleteRecursively()
                            }
                        }
                    }
                }
                if (status != PackageInstaller.STATUS_SUCCESS) {
                    MainActivity.updateInProgress = false
                    context.getSharedPreferences("update", Context.MODE_PRIVATE)
                        .edit().putBoolean("install_failed", true).apply()
                } else {
                    MainActivity.updateInProgress = false
                }
            } catch (_: Exception) {
                // Keep the app's startup path independent of diagnostics I/O.
            } finally {
                pending.finish()
            }
        }, "ghostbox-install-result").start()
    }
}
