package app.entesaver.util

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * The system pages the app sends the person to: app info, notifications,
 * usage access, Battery Saver and Android's battery-optimisation list, each
 * with the page that holds the same switch as its fallback. The phone
 * makers' own pages are in [PowerPages].
 */
object OemPages {

    /**
     * Starts one outside page as a trip the app sent the person on, and takes
     * the trip back if the page refuses to open.
     */
    private fun go(context: Context, intent: Intent): Boolean {
        Errand.begin()
        return try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            Errand.cancel()
            false
        }
    }

    /**
     * Android's list of apps whose battery use is optimised, where the switch
     * for this app sits. Android 10 and 11 have no per-app battery page, so
     * this is where the switch is there. The one-tap question
     * (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) is not used: it needs a
     * permission of its own and, without it, closes without asking anything.
     */
    fun openBatteryOptimization(context: Context): Boolean =
        go(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            openAppInfo(context)

    fun openAppInfo(context: Context): Boolean = openAppInfoOf(context, context.packageName)

    /** Another app's App info page: its Uninstall button is there. */
    fun openAppInfoOf(context: Context, pkg: String): Boolean = go(
        context,
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
    )

    /** The system page that holds this app's notification switch. */
    fun openNotificationSettings(context: Context): Boolean = go(
        context,
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    ) || openAppInfo(context)

    /**
     * The switch that lets Android take this app's permissions away for not
     * being opened (Android 11: "Remove permissions if app isn't used";
     * 12 and later: "Pause app activity if unused"). Android has a page for
     * exactly this one, and app info as the fallback.
     */
    fun openAutoRevokeSettings(context: Context): Boolean =
        // Some skins do not carry the page; app info holds the same switch.
        (
            Build.VERSION.SDK_INT >= 30 &&
                go(
                    context,
                    Intent(Intent.ACTION_AUTO_REVOKE_PERMISSIONS, Uri.parse("package:${context.packageName}"))
                )
            ) ||
            openAppInfo(context)

    /** The phone-wide Battery Saver page. */
    fun openBatterySaverSettings(context: Context): Boolean =
        go(context, Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)) ||
            go(context, Intent(Settings.ACTION_SETTINGS))

    /** The system page for one notification category - the Alerts one. */
    fun openAlertsChannelSettings(context: Context): Boolean = go(
        context,
        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, Notifications.CH_ALERTS)
    ) || openNotificationSettings(context)

    /** Where every official build is published, and where problems are reported. */
    const val RELEASES_URL = "https://github.com/smmpanelusertestai07-dotcom/EnteSaver/releases"
    const val ISSUES_URL = "https://github.com/smmpanelusertestai07-dotcom/EnteSaver/issues"

    /** A web page, in the phone's browser; the app itself never goes online. */
    fun openWebPage(context: Context, url: String): Boolean =
        go(context, Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    /** This app's own Usage access switch, or the list that holds it. */
    fun openUsageAccess(context: Context): Boolean =
        go(context, Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, Uri.parse("package:${context.packageName}"))) ||
            go(context, Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))

    /**
     * The page with Ente Saver's own All files access switch (Android 11
     * and later), which Replace on this phone needs; the list of every app's
     * switch where a phone has no page for one app.
     */
    fun openFileAccess(context: Context): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && (
        go(context, Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${context.packageName}"))) ||
            go(context, Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        )
}
