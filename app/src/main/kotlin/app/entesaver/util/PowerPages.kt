package app.entesaver.util

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * The background-work settings this phone actually has, and where they live.
 *
 * Every OEM breaks background work in its own way and hides the switch in its
 * own place, so "open app info and look around" is not an instruction anyone
 * can follow. Where the state can be read, it is read; where it cannot, the
 * app says so plainly rather than guessing, and still offers the one tap that
 * gets there.
 */
object PowerPages {

    enum class Vendor { COLOR_OS, MIUI, ONE_UI, VIVO, HUAWEI, PIXEL, OTHER }

    /**
     * One thing the user may need to allow.
     *
     * [readable] is false when no public API reports the state; those are
     * shown as "check this" rather than as a problem, because claiming a
     * setting is off when it might be on trains people to ignore the app.
     */
    data class Requirement(
        val id: String,
        val readable: Boolean,
        val satisfied: Boolean
    )

    const val ID_BATTERY_UNRESTRICTED = "battery_unrestricted"
    /** App info › Battery › Restricted - Android's own per-app ban, readable. */
    const val ID_BACKGROUND_RESTRICTION = "background_restriction"
    /** "Remove permissions / pause app if unused" - readable from Android 11. */
    const val ID_KEEP_PERMISSIONS = "keep_permissions"
    const val ID_AUTO_LAUNCH = "auto_launch"
    const val ID_BACKGROUND_ACTIVITY = "background_activity"

    fun vendor(
        manufacturer: String = Build.MANUFACTURER,
        brand: String = Build.BRAND
    ): Vendor {
        val name = "${manufacturer.lowercase()} ${brand.lowercase()}"
        return when {
            listOf("oppo", "realme", "oneplus").any { it in name } -> Vendor.COLOR_OS
            listOf("xiaomi", "redmi", "poco").any { it in name } -> Vendor.MIUI
            "samsung" in name -> Vendor.ONE_UI
            listOf("vivo", "iqoo").any { it in name } -> Vendor.VIVO
            listOf("huawei", "honor").any { it in name } -> Vendor.HUAWEI
            listOf("google", "pixel").any { it in name } -> Vendor.PIXEL
            else -> Vendor.OTHER
        }
    }

    /**
     * What to ask for on this phone. Battery optimisation is readable
     * everywhere; auto-launch and background activity are not readable on any
     * of these skins, so they are listed as unverifiable checks.
     */
    fun requirementsFor(
        vendor: Vendor,
        ignoringBatteryOptimizations: Boolean,
        backgroundRestricted: Boolean = false,
        /** Null where Android has no such switch (Android 10). */
        permissionsAutoReset: Boolean? = null
    ): List<Requirement> {
        val battery = Requirement(
            ID_BATTERY_UNRESTRICTED, readable = true, satisfied = ignoringBatteryOptimizations
        )
        // Two more Android reports itself. Restricted is the per-app ban that
        // stops every background run outright; the permission reset is the
        // one that takes the photos permission away from an app nobody opens
        // for a few months - which is what this app is meant to be.
        val readable = listOfNotNull(
            battery,
            Requirement(ID_BACKGROUND_RESTRICTION, readable = true, satisfied = !backgroundRestricted),
            permissionsAutoReset?.let {
                Requirement(ID_KEEP_PERMISSIONS, readable = true, satisfied = !it)
            }
        )
        val unverifiable = when (vendor) {
            Vendor.COLOR_OS -> listOf(ID_BACKGROUND_ACTIVITY, ID_AUTO_LAUNCH)
            Vendor.MIUI, Vendor.VIVO -> listOf(ID_AUTO_LAUNCH)
            Vendor.ONE_UI -> listOf(ID_BACKGROUND_ACTIVITY)
            Vendor.HUAWEI -> listOf(ID_AUTO_LAUNCH)
            Vendor.PIXEL, Vendor.OTHER -> emptyList()
        }
        return readable + unverifiable.map {
            Requirement(it, readable = false, satisfied = false)
        }
    }

    /**
     * Where the switch is, in the words the phone itself uses.
     *
     * Android cannot read the maker's own switches, so the row cannot say
     * On or Off - but it can say exactly where to look, which "please check
     * it yourself" never did. The labels are the skins' own English ones;
     * a phone set to another language shows its translation of the same
     * item in the same place.
     */
    fun pathHint(vendor: Vendor, requirementId: String): String? = when (requirementId) {
        ID_AUTO_LAUNCH -> when (vendor) {
            Vendor.COLOR_OS ->
                "Settings › Battery › App battery management › Ente Saver › Allow auto-launch " +
                    "(some phones: Settings › App management › App list › Ente Saver › " +
                    "Allow auto-launch, or Settings › Privacy › Startup manager)"
            Vendor.MIUI -> "Settings › Apps › Manage apps › Ente Saver › Autostart"
            Vendor.VIVO -> "i Manager › App manager › Autostart manager › Ente Saver"
            Vendor.HUAWEI ->
                "Settings › Apps › App launch › Ente Saver › Manage manually: " +
                    "Auto-launch, Secondary launch, Run in background"
            else -> null
        }
        ID_BACKGROUND_ACTIVITY -> when (vendor) {
            Vendor.COLOR_OS ->
                "Settings › Battery › App battery management › Ente Saver › " +
                    "Allow background activity, and Don't optimise " +
                    "(some phones: App info › Battery usage)"
            Vendor.ONE_UI -> "Settings › Apps › Ente Saver › Battery › Unrestricted"
            else -> null
        }
        ID_BATTERY_UNRESTRICTED -> when (vendor) {
            Vendor.COLOR_OS ->
                "Settings › Battery › App battery management › Ente Saver › Don't optimise"
            Vendor.MIUI -> "Settings › Apps › Manage apps › Ente Saver › Battery saver › No restrictions"
            Vendor.ONE_UI -> "Settings › Apps › Ente Saver › Battery › Unrestricted"
            else -> "Settings › Apps › Ente Saver › Battery › Unrestricted (or Don't optimise)"
        }
        // The same page on every skin: the "Restricted" choice under the
        // app's battery entry, which must not be the one selected.
        ID_BACKGROUND_RESTRICTION -> when (vendor) {
            Vendor.COLOR_OS ->
                "Settings › Battery › App battery management › Ente Saver — not \"Restricted\" " +
                    "(some phones: App info › Battery usage)"
            else -> "Settings › Apps › Ente Saver › Battery (App battery usage) — Unrestricted or Optimised, not Restricted"
        }
        // Android's own words for the switch changed with each version.
        ID_KEEP_PERMISSIONS -> when {
            Build.VERSION.SDK_INT >= 33 ->
                "Settings › Apps › Ente Saver › Pause app activity if unused — off " +
                    "(Android 13 and later: under \"Unused app settings\")"
            Build.VERSION.SDK_INT >= 31 ->
                "Settings › Apps › Ente Saver › Pause app activity if unused — off"
            else ->
                "Settings › Apps › Ente Saver › Permissions › Remove permissions if app isn't used — off"
        }
        else -> null
    }

    /** Auto-launch / auto-start list, by skin. */
    private val AUTO_LAUNCH: Map<Vendor, List<ComponentName>> = mapOf(
        // Newest naming first: realme UI 3 and later moved the security centre
        // to "oplus"; an Android 11 realme still carries "coloros", under one
        // of three class names depending on the build.
        Vendor.COLOR_OS to listOf(
            ComponentName(
                "com.oplus.safecenter",
                "com.oplus.safecenter.permission.startup.StartupAppListActivity"
            ),
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity"
            ),
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startupapp.StartupAppListActivity"
            ),
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.startupapp.StartupAppListActivity"
            ),
            ComponentName(
                "com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"
            ),
            ComponentName(
                "com.oneplus.security",
                "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
            )
        ),
        Vendor.MIUI to listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            )
        ),
        Vendor.VIVO to listOf(
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
            ),
            ComponentName(
                "com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"
            )
        ),
        Vendor.ONE_UI to listOf(
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.battery.ui.BatteryActivity"
            ),
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.ui.battery.BatteryActivity"
            )
        ),
        Vendor.HUAWEI to listOf(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
            )
        )
    )

    /**
     * Background-activity page. On ColorOS this is the app's own battery
     * screen, which is where "Allow background activity" lives.
     */
    fun openBackgroundActivity(context: Context): Boolean {
        // The per-app battery page moved packages when ColorOS became
        // "oplus" (realme UI 3 and later); the older name is what an
        // Android 11 realme still has. Both carry the package as an extra,
        // under both spellings the skins have used, so the page opens on
        // this app rather than on the list.
        val direct = when (vendor()) {
            Vendor.COLOR_OS -> listOf(
                ComponentName(
                    "com.oplus.battery",
                    "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity"
                ),
                ComponentName(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"
                ),
                ComponentName(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerConsumptionActivity"
                )
            )
            Vendor.ONE_UI -> listOf(
                ComponentName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.battery.ui.BatteryActivity"
                ),
                ComponentName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.ui.battery.BatteryActivity"
                )
            )
            else -> emptyList()
        }
        if (start(context, direct, withPackageExtras = true)) return true
        // Every skin puts a per-app battery entry inside app info, so that is
        // one tap away from the right switch rather than a dead end.
        return OemPages.openAppInfo(context)
    }

    /**
     * Only this maker's own pages, then app info. Every other maker's list was
     * tried after this one as well, so a Realme also knocked on Xiaomi's and
     * Samsung's doors - and ColorOS's own twice - before landing anywhere.
     */
    fun openAutoLaunch(context: Context): Boolean =
        start(context, AUTO_LAUNCH[vendor()].orEmpty()) || OemPages.openAppInfo(context)

    fun open(context: Context, requirementId: String): Boolean = when (requirementId) {
        // From Android 12 the switch is on the app's own battery page
        // (Unrestricted), which is the maker's per-app page or app info. On
        // 10 and 11 it is Android's optimisation list. Already exempt, the
        // tap goes to the page that holds the maker's other switches.
        ID_BATTERY_UNRESTRICTED ->
            if (Build.VERSION.SDK_INT >= 31 || Permissions.isIgnoringBatteryOptimizations(context)) {
                openBackgroundActivity(context)
            } else {
                OemPages.openBatteryOptimization(context)
            }
        ID_AUTO_LAUNCH -> openAutoLaunch(context)
        ID_BACKGROUND_ACTIVITY -> openBackgroundActivity(context)
        // The Restricted choice lives on the app's battery page; the maker's
        // per-app page is that page where there is one, app info otherwise.
        ID_BACKGROUND_RESTRICTION -> openBackgroundActivity(context)
        ID_KEEP_PERMISSIONS -> OemPages.openAutoRevokeSettings(context)
        else -> OemPages.openAppInfo(context)
    }

    /**
     * Tries each component in turn, without asking whether it resolves first.
     *
     * Package visibility hides these skin packages from `resolveActivity` on
     * Android 11 and up, so the check said "no such page" on every phone that
     * actually had one and the user was always dropped in app info. A start
     * that cannot happen throws, and the throw is the answer.
     */
    private fun start(
        context: Context,
        components: List<ComponentName>,
        withPackageExtras: Boolean = false
    ): Boolean {
        for (component in components) {
            try {
                val intent = Intent().setComponent(component)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (withPackageExtras) {
                    intent.putExtra("package_name", context.packageName)
                    intent.putExtra("packageName", context.packageName)
                }
                Errand.begin()
                context.startActivity(intent)
                return true
            } catch (e: Exception) {
                // Try the next component; skins rename these between versions.
                Errand.cancel()
            }
        }
        return false
    }
}
