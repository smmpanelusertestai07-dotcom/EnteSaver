package app.entesaver.core.logic

/**
 * Turns what the app records into what a person reads.
 *
 * The Activity screen used to print the stored constant straight out, so a
 * quality change appeared as "STORAGE_SAVER". Nothing in this app should ever
 * show a person the name of one of its own enum values. Settings changes are
 * stored as a `SETTING:VALUE` token and rendered from that, so the record
 * stays machine-readable and the screen stays readable.
 */
object ActivityWording {

    /**
     * The settings worth naming in the history. QUALITY and CODEC are the
     * single preset and codec before 11, kept so older entries still read;
     * PHOTOS and VIDEOS replaced them.
     */
    enum class Setting { QUALITY, CLOUD_APP, SPEED, LAYOUT, CODEC, THEME, SCOPE, SPACE, PHOTOS, VIDEOS, FOLDER, SAVE_MODE }

    data class Change(val setting: Setting, val value: String)

    fun encode(setting: Setting, value: String): String = "${setting.name}:$value"

    /** Null for a detail this build does not recognise, so it is simply not shown. */
    fun decode(detail: String?): Change? {
        val raw = detail?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val at = raw.indexOf(':')
        if (at <= 0 || at == raw.length - 1) return null
        val setting = Setting.entries.firstOrNull { it.name == raw.substring(0, at) }
            ?: return null
        return Change(setting, raw.substring(at + 1))
    }

    /**
     * Repeats of the same setting inside this window collapse to the newest.
     *
     * Dragging a slider or tapping through three quality presets is one
     * decision, not three events, and a history that records every keystroke
     * buries the events that matter.
     */
    const val COALESCE_MS = 5 * 60_000L

    /**
     * Drops entries superseded by a newer change to the same setting.
     *
     * [rows] must be newest first, which is the order the screen shows. Only
     * settings changes coalesce; every other kind is kept exactly as recorded.
     */
    fun <T> coalesce(
        rows: List<T>,
        isSettingChange: (T) -> Boolean,
        detailOf: (T) -> String?,
        atMsOf: (T) -> Long
    ): List<T> {
        val kept = mutableListOf<T>()
        val lastSeen = mutableMapOf<Setting, Long>()
        for (row in rows) {
            if (!isSettingChange(row)) {
                kept += row
                continue
            }
            val setting = decode(detailOf(row))?.setting
            if (setting == null) {
                kept += row
                continue
            }
            val newer = lastSeen[setting]
            if (newer != null && newer - atMsOf(row) <= COALESCE_MS) continue
            lastSeen[setting] = atMsOf(row)
            kept += row
        }
        return kept
    }
}
