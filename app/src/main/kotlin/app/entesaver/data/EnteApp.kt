package app.entesaver.data

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable
import android.net.Uri
import app.entesaver.BuildConfig
import app.entesaver.core.logic.KnownClouds
import app.entesaver.util.Errand

/**
 * Ente Photos, the one app this app works with.
 *
 * Ente keeps every file end-to-end encrypted and stores originals exactly as
 * it receives them, so a light copy made here is what ends up in the
 * account. It removes its own uploads from the phone when asked to free up
 * space, and it checks for duplicates by content - the two things that let
 * this app prove a copy arrived instead of guessing. This app never talks to
 * Ente's servers: it only finds, opens and (with Usage Access) measures the
 * Ente app on this phone.
 */
object EnteApp {

    const val ID = "ente"
    const val LABEL = "Ente Photos"

    /** Play Store, the website's own APK, and F-Droid: three builds, one app. */
    val PACKAGES: List<String> = KnownClouds.ENTE

    /** Ente's free plan, for the calculator's starting value - editable, never a fact. */
    const val FREE_PLAN_GB = 10

    /** Where Ente can be installed from, each opened in the phone's own app for it. */
    enum class Source(val uri: String) {
        PLAY("https://play.google.com/store/apps/details?id=io.ente.photos"),
        FDROID("https://f-droid.org/packages/io.ente.photos.fdroid/"),
        WEBSITE("https://ente.com/download/")
    }

    /**
     * Debug builds only: lets the instrumented suite act as if Ente were
     * installed. No emulator has Ente on it, and every path that needs it -
     * Free up space above all - would otherwise be untestable. A release
     * build ignores it entirely.
     */
    @Volatile
    var assumeInstalledForTest: Boolean = false

    fun installedPackage(context: Context): String? =
        PACKAGES.firstOrNull { isPackageInstalled(context, it) }

    fun isInstalled(context: Context): Boolean =
        (BuildConfig.DEBUG && assumeInstalledForTest) || installedPackage(context) != null

    /**
     * Ente's own launcher icon, read from the phone rather than shipped: it is
     * always the current one, and null simply means Ente is not installed.
     */
    fun icon(context: Context): Drawable? {
        val pkg = installedPackage(context) ?: return null
        return runCatching { context.packageManager.getApplicationIcon(pkg) }.getOrNull()
    }

    /** The installed Ente's user id, which Usage Access counts traffic by. */
    fun uid(context: Context): Int? = installedPackage(context)?.let { uidOf(context, it) }

    fun uidOf(context: Context, pkg: String): Int? = try {
        context.packageManager.getApplicationInfo(pkg, 0).uid
    } catch (e: Exception) {
        null
    }

    /** True for a package name that belongs to Ente. */
    fun isEnte(pkg: String?): Boolean = pkg != null && pkg in PACKAGES

    /**
     * Opens Ente (its own Free up space screen has no public link).
     *
     * [errand] is the app lock's grace for a trip out and back. It is right
     * when a person taps a button inside Ente Saver, and wrong for the
     * "Photos" shortcut: that one can be started by anything on the phone,
     * and would otherwise leave an unlocked Ente Saver open to whoever picks
     * the phone up in the next two minutes.
     */
    fun launch(context: Context, errand: Boolean = true): Boolean {
        val pkg = installedPackage(context) ?: return false
        val intent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return start(context, intent, errand)
    }

    /** Ente's own help pages, for the tools Ente Saver points to rather than copies. */
    object Help {
        private const val BASE = "https://ente.com/help/photos"
        const val STORAGE = "$BASE/features/albums-and-organization/storage-optimization"
        const val FREE_UP_DEVICE = "$STORAGE#free-up-device-space"
        const val DEVICE_CACHE = "$STORAGE#manage-device-cache"
        const val DUPLICATES = "$STORAGE#remove-exact-duplicates"
        const val SIMILAR = "$STORAGE#remove-similar-images"
        const val LARGE_FILES = "$STORAGE#view-large-files"
        const val SUGGESTIONS = "$STORAGE#delete-suggestions"
        const val TRASH = "$BASE/features/albums-and-organization/deleting"
        const val BACKUP = "$BASE/faq/backup-and-sync"
        const val BACKUP_FOLDERS = "$BASE/features/backup-and-sync/"
        const val MOBILE_DATA = "$BACKUP#mobile-data"
        const val COMPRESS = "$BACKUP#does-ente-compress"
        const val FREE_UP_FOLDER = "$BASE/faq/storage-and-plans#free-up-space-slow"
        const val FREE_PLAN = "$BASE/faq/storage-and-plans#free-plan"
        const val ML = "$BASE/features/search-and-discovery/machine-learning"
        const val MAP = "$BASE/features/search-and-discovery/map-and-location"
        const val STREAMING = "$BASE/features/utilities/video-streaming"
        const val GALLERY = "$BASE/features/utilities/android-gallery"
        const val APP_LOCK = "$BASE/features/account/app-lock"
    }

    /** Opens one of Ente's help pages in the phone's browser. */
    fun openHelp(context: Context, url: String, errand: Boolean = true): Boolean =
        start(context, Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), errand)

    /** Opens the page Ente is installed from; the phone picks the store or browser. */
    fun openInstallPage(context: Context, source: Source, errand: Boolean = true): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(source.uri))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return start(context, intent, errand)
    }

    private fun start(context: Context, intent: Intent, errand: Boolean): Boolean = try {
        if (errand) Errand.begin()
        context.startActivity(intent)
        true
    } catch (e: Exception) {
        if (errand) Errand.cancel()
        false
    }

    private fun isPackageInstalled(context: Context, pkg: String): Boolean = try {
        context.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    } catch (e: Exception) {
        false
    }
}
