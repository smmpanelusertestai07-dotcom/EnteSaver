package app.entesaver.media

import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import app.entesaver.core.logic.LegacyPaths

/**
 * Where a gallery file sits, asked the way this Android can answer it.
 *
 * From Android 10 MediaStore says it outright, in RELATIVE_PATH. Android 9
 * has no such column - a projection that names it throws - and says only
 * the file's full path, in DATA, from which [relativePath] makes the string
 * Android 10 would have given. A query asks for [FOLDER_COLUMN] and reads
 * the answer through [relativePath], and the rest of the app compares the
 * same strings on every version.
 */
object MediaPaths {

    /** The column that says where a file sits on this Android. */
    @Suppress("DEPRECATION")
    val FOLDER_COLUMN: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.MediaColumns.RELATIVE_PATH else MediaStore.MediaColumns.DATA

    /** A value read from [FOLDER_COLUMN], as a relative path: "Pictures/EnteSaver/". */
    fun relativePath(value: String?): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) value else LegacyPaths.relativePathOf(value, primaryRoot())

    /** The relative path of the file at [path], the way Android 10 would give it. */
    fun relativePathOfFile(path: String?): String? = LegacyPaths.relativePathOf(path, primaryRoot())

    @Suppress("DEPRECATION")
    private fun primaryRoot(): String? = runCatching { Environment.getExternalStorageDirectory().absolutePath }.getOrNull()

    /**
     * [uri], asking for the file's bytes as stored, the place it was taken
     * included. From Android 10 a photo another app made is handed over with
     * its location blanked unless this is asked for; Android 9 blanks
     * nothing, and has no such request to make.
     */
    fun original(uri: Uri): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.setRequireOriginal(uri) else uri
}
