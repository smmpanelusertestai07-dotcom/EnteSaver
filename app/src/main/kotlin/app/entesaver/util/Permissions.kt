package app.entesaver.util

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

object Permissions {

    /**
     * How much of the gallery the app can actually see.
     *
     * The three are not interchangeable. Under PARTIAL - Android 14's "Select
     * photos" - MediaStore answers every query as if the handful the user
     * picked were the whole library, and the app used to believe it: counts,
     * the calculator and the queue all reported a gallery of nine photos as
     * fact. A grant for photos but not videos - which Android 13 and later
     * ask for separately - hides just as much and counts as PARTIAL too.
     * Anything that scans, counts or projects must ask for this level.
     */
    enum class MediaAccess { FULL, PARTIAL, NONE }

    fun mediaAccess(context: Context): MediaAccess = mediaAccessFor(
        sdk = Build.VERSION.SDK_INT,
        imagesGranted = granted(context, Manifest.permission.READ_MEDIA_IMAGES),
        videoGranted = granted(context, Manifest.permission.READ_MEDIA_VIDEO),
        userSelectedGranted = Build.VERSION.SDK_INT >= 34 &&
            granted(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED),
        legacyReadGranted = granted(context, Manifest.permission.READ_EXTERNAL_STORAGE),
        legacyWriteGranted = granted(context, Manifest.permission.WRITE_EXTERNAL_STORAGE)
    )

    /** The decision alone, so the API 28/29/33/34 mapping is testable on the JVM. */
    fun mediaAccessFor(
        sdk: Int,
        imagesGranted: Boolean,
        videoGranted: Boolean,
        userSelectedGranted: Boolean,
        legacyReadGranted: Boolean,
        legacyWriteGranted: Boolean = false
    ): MediaAccess = when {
        sdk >= 33 -> when {
            // Both halves of the gallery, or it is not a full view of it.
            // Android 13 split the old single read permission into photos and
            // videos, and the system asks for them one after the other, so
            // "photos yes, videos no" is one tap away - and a phone that had
            // only granted videos used to read as FULL. MediaStore then
            // answered every query as if the missing half were not there: the
            // photos the user can see in their own gallery were absent from
            // the count, from the calculator's total and from the queue, with
            // nothing on screen admitting it. That is exactly the lie this
            // three-way level exists to prevent, so half a grant is PARTIAL
            // and the screens say so instead of quietly showing half a phone.
            imagesGranted && videoGranted -> MediaAccess.FULL
            imagesGranted || videoGranted -> MediaAccess.PARTIAL
            sdk >= 34 && userSelectedGranted -> MediaAccess.PARTIAL
            else -> MediaAccess.NONE
        }
        // Android 9 has no scoped storage: every copy is written into its
        // folder as a file, which takes the write permission as well, and
        // the one storage prompt grants the two together. Reading without
        // writing would queue a gallery the app could put nothing beside.
        sdk < 29 -> if (legacyReadGranted && legacyWriteGranted) MediaAccess.FULL else MediaAccess.NONE
        legacyReadGranted -> MediaAccess.FULL
        else -> MediaAccess.NONE
    }

    fun mediaPermissionsToRequest(): Array<String> = if (Build.VERSION.SDK_INT >= 33) {
        arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            // Without this, every copy loses its GPS location - silently.
            //
            // ACCESS_MEDIA_LOCATION is a runtime permission from API 29, not a
            // manifest declaration that grants itself. It was declared and
            // never asked for, so MediaStore.setRequireOriginal threw, the
            // fallback opened the REDACTED stream, and the location was
            // stripped from every photo the app ever copied - while FAQ 5 said
            // "Every copy carries the original's ... GPS location". Refusing it
            // still works: the same fallback runs, and the FAQ now says so.
            Manifest.permission.ACCESS_MEDIA_LOCATION
        )
    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.ACCESS_MEDIA_LOCATION
        )
    } else {
        // Android 9 hides no photo's location, so there is no permission
        // for it to ask; what it needs is storage write access, for the
        // copies (see [mediaAccessFor]).
        arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE
        )
    }

    /**
     * Whether copies may keep where each photo was taken (see
     * [mediaPermissionsToRequest]). Always on Android 9, which hands every
     * app a photo's location with the photo.
     */
    fun hasMediaLocation(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_MEDIA_LOCATION)

    fun hasNotifications(context: Context): Boolean {
        // Android 13 added a runtime permission, but the switch in system settings is older
        // than that and exists on every version. Checking the permission alone said "Allowed"
        // on an Android 11 phone whose owner had switched this app's notifications off, and a
        // permissions screen has no business contradicting the system settings. The switch is
        // read here; the permission check stays because on 13 and up it is the thing the
        // one-tap prompt grants.
        val switchedOn = runCatching {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        }.getOrDefault(true)
        return switchedOn &&
            (Build.VERSION.SDK_INT < 33 || granted(context, Manifest.permission.POST_NOTIFICATIONS))
    }

    fun isIgnoringBatteryOptimizations(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(context.packageName)
    } catch (e: Exception) {
        false
    }

    /**
     * App info › Battery › "Restricted": Android's own per-app background
     * ban, distinct from battery optimisation. Restricted, the scheduler
     * never runs this app's jobs while it is in the background, so the
     * queue simply stops - and until this was read, the Permissions screen
     * said everything was allowed while it did.
     */
    fun isBackgroundRestricted(context: Context): Boolean = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        am.isBackgroundRestricted
    } catch (e: Exception) {
        false
    }

    /** The phone-wide Battery Saver. On, Ente Saver pauses until it is off or the phone charges. */
    fun batterySaverOn(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isPowerSaveMode
    } catch (e: Exception) {
        false
    }

    /**
     * Whether Android will take this app's permissions away for not being
     * opened.
     *
     * From Android 11 an app that is not opened for a few months has its
     * runtime permissions reset; from 12 it is also put to sleep. Ente Saver
     * is exactly the app nobody opens for months - it is meant to work
     * unattended - so without this switch off, one day the photos permission
     * is gone and everything stops without a word. True means the reset is
     * armed; null on Android 9 and 10, where there is no such thing.
     */
    fun permissionsAutoResetOn(context: Context): Boolean? {
        if (Build.VERSION.SDK_INT < 30) return null
        return try {
            !context.packageManager.isAutoRevokeWhitelisted
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Android's own rationing bucket for this app's background work, as the
     * platform's constant, or null where it cannot be read. RESTRICTED (the
     * strictest) allows roughly one run a day.
     */
    fun standbyBucket(context: Context): Int? = try {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        usm.appStandbyBucket
    } catch (e: Exception) {
        null
    }

    /**
     * Notifications on, but the Alerts category switched off on its own.
     * Android lets a person silence one category and keep the rest, and the
     * app-level switch says nothing about it - so "Allowed" could sit above a
     * category that would never show a warning.
     */
    fun alertsChannelOff(context: Context): Boolean = try {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.getNotificationChannel(Notifications.CH_ALERTS)?.importance ==
            NotificationManager.IMPORTANCE_NONE
    } catch (e: Exception) {
        false
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
