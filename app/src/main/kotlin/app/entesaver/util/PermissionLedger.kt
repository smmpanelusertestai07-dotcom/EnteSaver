package app.entesaver.util

import android.Manifest
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import app.entesaver.R
import app.entesaver.engine.UsageVerifier

/**
 * Every permission this app can hold, what each is for, and whether it is
 * held right now - read from the manifest that actually shipped, not from a
 * list written by hand that could drift from it. A permission a library
 * merges in appears here on its own, which is the point: an unexplained
 * permission the person can see is safer than one they cannot.
 *
 * Nothing here changes anything. The only place a permission is granted or
 * taken back is the phone's own settings page.
 */
object PermissionLedger {

    /** One line of the ledger. */
    data class Entry(
        val permission: String,
        val name: String,
        val purpose: String,
        /** Held right now, by the phone's own account. */
        val held: Boolean,
        /** Android puts a prompt or a settings switch in front of it: the person's to take back. */
        val runtime: Boolean,
        /** Declared for an Android this phone is not running, so it does not apply here. */
        val notOnThisAndroid: Boolean = false
    )

    /** Something the app deliberately never asks for, named so its absence is checkable. */
    data class NeverAsked(val name: String, val why: String)

    /** Name and purpose, by permission. Anything not named is shown by its Android name. */
    val KNOWN: Map<String, Pair<Int, Int>> = mapOf(
        Manifest.permission.READ_MEDIA_IMAGES to (R.string.perm_name_media_images to R.string.perm_purpose_media),
        Manifest.permission.READ_MEDIA_VIDEO to (R.string.perm_name_media_video to R.string.perm_purpose_media),
        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED to (R.string.perm_name_media_selected to R.string.perm_purpose_media_selected),
        Manifest.permission.READ_EXTERNAL_STORAGE to (R.string.perm_name_read_storage to R.string.perm_purpose_read_storage),
        Manifest.permission.ACCESS_MEDIA_LOCATION to (R.string.perm_name_media_location to R.string.perm_purpose_media_location),
        Manifest.permission.POST_NOTIFICATIONS to (R.string.perm_name_notifications to R.string.perm_purpose_notifications),
        Manifest.permission.FOREGROUND_SERVICE to (R.string.perm_name_foreground to R.string.perm_purpose_foreground),
        "android.permission.FOREGROUND_SERVICE_DATA_SYNC" to (R.string.perm_name_foreground_type to R.string.perm_purpose_foreground_type),
        "android.permission.FOREGROUND_SERVICE_MEDIA_PROCESSING" to (R.string.perm_name_foreground_type to R.string.perm_purpose_foreground_type),
        Manifest.permission.PACKAGE_USAGE_STATS to (R.string.perm_name_usage to R.string.perm_purpose_usage),
        Manifest.permission.USE_BIOMETRIC to (R.string.perm_name_biometric to R.string.perm_purpose_biometric),
        Manifest.permission.MANAGE_EXTERNAL_STORAGE to (R.string.perm_name_all_files to R.string.perm_purpose_all_files),
        Manifest.permission.WRITE_EXTERNAL_STORAGE to (R.string.perm_name_write_storage to R.string.perm_purpose_all_files),
        Manifest.permission.WAKE_LOCK to (R.string.perm_name_wake to R.string.perm_purpose_wake),
        Manifest.permission.RECEIVE_BOOT_COMPLETED to (R.string.perm_name_boot to R.string.perm_purpose_boot)
    )

    /**
     * The ones Android puts a prompt or a settings page in front of. The rest
     * are granted at install and can only be inspected - which is exactly why
     * they are listed too.
     */
    val RUNTIME: Set<String> = setOf(
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VIDEO,
        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        Manifest.permission.READ_EXTERNAL_STORAGE,
        Manifest.permission.ACCESS_MEDIA_LOCATION,
        Manifest.permission.POST_NOTIFICATIONS,
        Manifest.permission.PACKAGE_USAGE_STATS,
        Manifest.permission.MANAGE_EXTERNAL_STORAGE,
        Manifest.permission.WRITE_EXTERNAL_STORAGE
    )

    /** Declared with a ceiling or a floor, so on the wrong Android they do not apply at all. */
    private fun appliesHere(permission: String): Boolean = when (permission) {
        Manifest.permission.READ_EXTERNAL_STORAGE -> Build.VERSION.SDK_INT <= 32
        Manifest.permission.WRITE_EXTERNAL_STORAGE -> Build.VERSION.SDK_INT <= 29
        Manifest.permission.MANAGE_EXTERNAL_STORAGE -> Build.VERSION.SDK_INT >= 30
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VIDEO,
        Manifest.permission.POST_NOTIFICATIONS -> Build.VERSION.SDK_INT >= 33
        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED -> Build.VERSION.SDK_INT >= 34
        "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
        "android.permission.FOREGROUND_SERVICE_MEDIA_PROCESSING" -> Build.VERSION.SDK_INT >= 34
        else -> true
    }

    /** What is deliberately absent. Internet first, because it is the one that matters most. */
    fun neverAsked(context: Context): List<NeverAsked> = listOf(
        NeverAsked(context.getString(R.string.never_internet), context.getString(R.string.never_internet_why)),
        NeverAsked(context.getString(R.string.never_camera), context.getString(R.string.never_camera_why)),
        NeverAsked(context.getString(R.string.never_location), context.getString(R.string.never_location_why)),
        NeverAsked(context.getString(R.string.never_microphone), context.getString(R.string.never_microphone_why)),
        NeverAsked(context.getString(R.string.never_contacts), context.getString(R.string.never_contacts_why)),
        NeverAsked(context.getString(R.string.never_other_apps), context.getString(R.string.never_other_apps_why))
    )

    /** Every permission in the shipped manifest, with its live state. */
    fun read(context: Context): List<Entry> {
        val info: PackageInfo = try {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        } catch (e: Exception) {
            return emptyList()
        }
        val declared = info.requestedPermissions ?: return emptyList()
        val flags = info.requestedPermissionsFlags
        return declared.mapIndexed { i, permission ->
            val known = KNOWN[permission]
            val held = when (permission) {
                // An app-op, not a grant: the flag is false even while it is on.
                Manifest.permission.PACKAGE_USAGE_STATS -> UsageVerifier.hasUsageAccess(context)
                // A special access, not a grant: the flag stays false while it is on.
                Manifest.permission.MANAGE_EXTERNAL_STORAGE ->
                    Build.VERSION.SDK_INT >= 30 && android.os.Environment.isExternalStorageManager()
                else -> flags != null && i < flags.size &&
                    flags[i] and PackageInfo.REQUESTED_PERMISSION_GRANTED != 0
            }
            Entry(
                permission = permission,
                name = known?.let { context.getString(it.first) } ?: permission.substringAfterLast('.'),
                purpose = known?.let { context.getString(it.second) } ?: permission,
                held = held,
                runtime = permission in RUNTIME,
                notOnThisAndroid = !appliesHere(permission)
            )
        }
    }
}
