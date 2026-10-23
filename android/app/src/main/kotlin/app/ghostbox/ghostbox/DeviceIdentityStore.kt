package app.ghostbox.ghostbox

import android.content.Context
import android.provider.Settings
import java.util.UUID

/** Keeps provider identity independent of Flutter plugin/Activity lifetime. */
internal object DeviceIdentityStore {
    private const val PREFERENCES = "ghostbox_device_identity"
    private const val ID = "installation_id"
    private const val LEGACY_PREFERENCES = "FlutterSharedPreferences"
    private const val LEGACY_ID = "flutter.device.installation_id"

    @Synchronized
    fun installationId(context: Context): String {
        val app = context.applicationContext
        val preferences = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val existing = preferences.getString(ID, null)?.trim()?.takeIf(String::isNotEmpty)
        if (existing != null) {
            mirrorLegacyId(app, existing)
            return existing
        }

        // Preserve the UUID already registered by this install's VPN provider.
        // This reads the legacy plugin store directly, even if its channel is
        // temporarily unavailable after an Activity/engine restart.
        val legacy = app.getSharedPreferences(LEGACY_PREFERENCES, Context.MODE_PRIVATE)
        val previous = legacy.getString(LEGACY_ID, null)?.trim()?.takeIf(String::isNotEmpty)
        val id = previous ?: createDeviceScopedId(app)
        check(preferences.edit().putString(ID, id).commit()) {
            "Unable to persist Android device identity"
        }
        mirrorLegacyId(app, id)
        return id
    }

    private fun mirrorLegacyId(context: Context, id: String) {
        // Older builds read only Flutter's preference. Keep that value aligned
        // so updating/downgrading the APK does not rotate the provider identity.
        // The dedicated native store remains authoritative if this optional
        // compatibility write fails.
        try {
            val legacy = context.getSharedPreferences(LEGACY_PREFERENCES, Context.MODE_PRIVATE)
            if (legacy.getString(LEGACY_ID, null) != id) {
                legacy.edit().putString(LEGACY_ID, id).commit()
            }
        } catch (_: Exception) {
            // Never replace the canonical ID because the legacy store failed.
        }
    }

    private fun createDeviceScopedId(context: Context): String {
        // ANDROID_ID is scoped to the signing key, user and device on Android
        // 8+. Namespace and hash it so the raw OS identifier is never sent to
        // providers. Build version and launcher icon deliberately do not enter
        // the identifier. A different signing key can still produce a new ID.
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID,
        )?.trim()?.lowercase()
        check(!androidId.isNullOrBlank() && androidId != "9774d56d682e549c" &&
            androidId.matches(Regex("[0-9a-f]{1,16}")) && androidId.any { it != '0' }) {
            "Android device identity is temporarily unavailable"
        }
        val input = "ghostbox-device-v1:${context.packageName}:${androidId.padStart(16, '0')}"
        return UUID.nameUUIDFromBytes(input.toByteArray(Charsets.UTF_8)).toString()
    }
}
