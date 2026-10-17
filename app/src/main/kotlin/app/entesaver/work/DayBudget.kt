package app.entesaver.work

import android.content.Context
import app.entesaver.core.logic.RunDecider
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.DayBudgetRow
import app.entesaver.util.Formats

/**
 * Reads and updates today's on-battery budget row. The key is the local date,
 * so the budget resets by itself at local midnight.
 */
class DayBudget(context: Context) {

    private val db = AppDb.get(context)

    suspend fun read(now: Long): RunDecider.Budget {
        val day = Formats.dayKey(now)
        val row = db.dayBudget().byDay(day)
        return RunDecider.Budget(
            videoEncodeMs = row?.videoEncodeMs ?: 0L,
            photosOnBattery = row?.photosOnBattery ?: 0
        )
    }

    suspend fun addVideoEncode(now: Long, ms: Long) {
        if (ms <= 0) return
        val day = ensureRow(now)
        db.dayBudget().addEncodeMs(day, ms)
    }

    suspend fun addPhotos(now: Long, count: Int) {
        if (count <= 0) return
        val day = ensureRow(now)
        db.dayBudget().addPhotos(day, count)
    }

    /** Bytes Replace on this phone wrote today. */
    suspend fun replacedToday(now: Long): Long = db.dayBudget().byDay(Formats.dayKey(now))?.replacedBytes ?: 0L

    suspend fun addReplaced(now: Long, bytes: Long) {
        if (bytes <= 0) return
        val day = ensureRow(now)
        db.dayBudget().addReplaced(day, bytes)
    }

    private suspend fun ensureRow(now: Long): String {
        val day = Formats.dayKey(now)
        db.dayBudget().insert(DayBudgetRow(day))
        db.dayBudget().pruneOlderThan(day)
        return day
    }
}
