package app.entesaver

import android.Manifest
import android.os.Build

/**
 * The gallery permissions this Android actually has.
 *
 * READ_MEDIA_IMAGES and READ_MEDIA_VIDEO were introduced in API 33; below
 * that the manifest asks for READ_EXTERNAL_STORAGE instead, capped at 32.
 * GrantPermissionRule cannot grant a permission the platform has never heard
 * of, so a suite that names the API-33 pair unconditionally cannot even start
 * on the oldest Android the app installs on - which is exactly the phone its
 * results would matter most for. Android 9 is that phone now: it has no
 * ACCESS_MEDIA_LOCATION, since it hides no photo's location, and it writes
 * every copy as a file, which takes WRITE_EXTERNAL_STORAGE as well.
 */
object TestPermissions {

    /** Everything the suites need, named as this API level knows it. */
    fun forThisDevice(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= 33) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
            add(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            add(Manifest.permission.ACCESS_MEDIA_LOCATION)
        } else {
            add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
    }.toTypedArray()

    /**
     * What a suite that only writes into shared folders needs. From Android
     * 10 an app adds its own files there without asking; Android 9 wants
     * storage access to write them and to read them back.
     */
    fun forSharedFiles(): Array<String> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        emptyArray()
    } else {
        arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE)
    }
}
