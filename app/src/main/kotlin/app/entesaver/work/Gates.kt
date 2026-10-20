package app.entesaver.work

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.RunDecider
import app.entesaver.data.EarlierInstall
import app.entesaver.data.prefs.Options
import app.entesaver.util.Storage
import app.entesaver.util.Volumes

/**
 * Reads the live device state for [RunDecider] and checks the resource gates
 * (storage volume, free space, app budget) that are independent of power.
 */
object Gates {

    /**
     * Snapshot of battery/screen/thermal. [lastInteractiveAt] is the last time
     * the app observed the screen ON (activity lifecycle or a worker tick); it
     * is the best estimate available without an implicit broadcast receiver.
     */
    fun readPower(context: Context, lastInteractiveAt: Long, now: Long): RunDecider.Power {
        var plugged = false
        var pct = 100
        var temp = 0
        try {
            val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (intent != null) {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                if (level >= 0 && scale > 0) pct = level * 100 / scale
                // AC, USB, wireless and dock all count as charging.
                plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
                temp = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0)
            }
        } catch (e: Exception) {
            // Treat an unreadable battery as "on battery, full" - the other
            // gates still apply and nothing dangerous happens.
        }

        var interactive = false
        var thermal = false
        var saver = false
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            interactive = pm.isInteractive
            saver = pm.isPowerSaveMode
            // Android 9 reports no thermal status at all. There the battery's
            // own temperature, read above, is the gate that decides.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                thermal = pm.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE
            }
        } catch (e: Exception) {
            // Some OEMs throw on thermal queries; keep the safe defaults.
        }

        val screenOffMs = if (interactive) 0L else (now - lastInteractiveAt).coerceAtLeast(0L)
        return RunDecider.Power(
            plugged = plugged,
            batteryPct = pct,
            batteryTempTenthsC = temp,
            saverOn = saver,
            screenInteractive = interactive,
            screenOffMs = screenOffMs,
            thermalThrottled = thermal
        )
    }

    /** Storage-side stop reasons; null means there is room to work. */
    fun resourceGate(
        context: Context,
        o: Options,
        stageBytes: Long,
        releasedBytes: Long
    ): String? {
        // Two Ente Savers would each make a copy of every new photo; this one
        // waits while the earlier one is installed, and Home says why.
        if (EarlierInstall.isInstalled(context)) return "earlier_app"
        if (o.storageVolume.isNotEmpty() && Volumes.byName(context, o.storageVolume) == null) {
            return "volume_missing"
        }
        if (Storage.freeBytes(context, o.storageVolume) < o.minFreeBytes) return "low_space"
        val extra = stageBytes + releasedBytes
        if (o.maxExtraBytes >= 0 && extra >= o.maxExtraBytes) return "extra_full"
        if (o.dailyCapBytes >= 0 && stageBytes >= Defaults.STAGE_CAP_FACTOR * o.dailyCapBytes) {
            return "stage_full"
        }
        return null
    }
}
