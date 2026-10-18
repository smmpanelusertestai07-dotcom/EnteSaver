package app.entesaver.core.logic

/**
 * Scheduling brain (13.G). One pure function decides whether photo work, video
 * work, both or nothing may run right now, and why not. It is evaluated at
 * worker start AND between every item, so a phone that is picked up mid-run
 * stops encoding within one item.
 *
 * WorkManager itself only carries a batteryNotLow constraint; every other
 * condition lives here so it can be unit tested and explained to the user.
 */
object RunDecider {

    /** Everything the decision needs from the device, read once per check. */
    data class Power(
        val plugged: Boolean,
        val batteryPct: Int,
        /** Battery temperature in tenths of a degree Celsius. */
        val batteryTempTenthsC: Int,
        val saverOn: Boolean,
        val screenInteractive: Boolean,
        /** Best estimate of how long the screen has been off (0 while on). */
        val screenOffMs: Long,
        /** PowerManager thermal status >= MODERATE. */
        val thermalThrottled: Boolean
    )

    /** Today's on-battery usage, reset at local midnight. */
    data class Budget(val videoEncodeMs: Long, val photosOnBattery: Int)

    enum class Wait {
        NONE,
        PAUSED,
        BATTERY_SAVER,
        TOO_HOT,
        NOT_CHARGING,
        BATTERY_LOW,
        SCREEN_ON,
        BUDGET_USED,
        PHOTO_CAP,
        /** The copies folder has reached the space the user allowed. */
        SPACE_FULL,
        /** The phone is below the free space the user asked to keep. */
        LOW_SPACE,
        /** The chosen storage location (an SD card) is not mounted. */
        VOLUME_MISSING,
        /** Long videos need a run with a foreground service (app open, or battery Unrestricted). */
        LONG_VIDEOS,
        /** The next files would take the phone below the free space it keeps. */
        NEXT_TOO_BIG,
        /** On the smallest phones videos are made only while charging. */
        VIDEOS_CHARGING,
        /**
         * The earlier Ente Saver (until 12.2) is still installed: it would
         * make copies of the same photos, so this one waits until it is gone.
         */
        EARLIER_APP,

        /** Replace on this phone is on, and Android's file access for it is not. */
        NEEDS_FILE_ACCESS,

        /**
         * Replace on this phone is on, and media-location access is not:
         * without it every photo is handed over with its location blanked
         * out, and a replace would lose it.
         */
        NEEDS_MEDIA_LOCATION,

        /** Replace on this phone has written today's daily limit; Ente uploads no more than that a day. */
        DAILY_LIMIT,

        /**
         * Replace on this phone is on in a build not signed with Ente
         * Saver's key. A replaced original is deleted after 30 days, and a
         * modified build deletes nothing (TamperCheck).
         */
        MODIFIED_BUILD
    }

    /**
     * The storage-side stop reasons, as something Home can say.
     *
     * The worker's resource gate stopped a run with a word only it knew and
     * nothing on any screen: Help promises that a full copies folder "says so
     * on Home", and Home said "N files in the queue" instead, forever, to
     * exactly the person Help was written for - one with no cloud app to
     * empty the folder.
     */
    fun waitForResource(gate: String): Wait = when (gate) {
        "extra_full", "stage_full" -> Wait.SPACE_FULL
        "low_space" -> Wait.LOW_SPACE
        "volume_missing" -> Wait.VOLUME_MISSING
        "earlier_app" -> Wait.EARLIER_APP
        else -> Wait.NONE
    }

    /**
     * [photos] / [videos] say what may be processed right now. When both are
     * false, [wait] explains why in a form the Home screen can show verbatim.
     * [floorPct] is the battery floor that applied to this decision, so the
     * message can name the real number.
     */
    data class Plan(
        val photos: Boolean,
        val videos: Boolean,
        val wait: Wait,
        val floorPct: Int
    ) {
        val canRun: Boolean get() = photos || videos
    }

    /** Battery floor while running on battery. */
    fun batteryFloor(mode: SpeedMode): Int = when (mode) {
        SpeedMode.SMART -> Defaults.SMART_BATTERY_FLOOR
        SpeedMode.FAST -> Defaults.FAST_BATTERY_FLOOR
        SpeedMode.CHARGING_ONLY -> Defaults.CHARGING_BATTERY_FLOOR
    }

    /** Daily on-battery video-encode budget in ms (0 = no on-battery work). */
    fun videoBudgetMs(mode: SpeedMode): Long = when (mode) {
        SpeedMode.SMART -> Defaults.SMART_BUDGET_MS
        SpeedMode.FAST -> Defaults.FAST_BUDGET_MS
        SpeedMode.CHARGING_ONLY -> 0L
    }

    /** How long the screen must have been off before video encodes start. */
    fun screenOffWaitMs(mode: SpeedMode): Long = when (mode) {
        SpeedMode.SMART -> Defaults.SMART_SCREEN_OFF_WAIT_MS
        SpeedMode.FAST -> 0L
        SpeedMode.CHARGING_ONLY -> 0L
    }

    /**
     * [videosNeedCharger]: the smallest phones (2.5 GB of memory or less)
     * make videos only while charging; on battery they make photos.
     */
    fun decide(
        mode: SpeedMode,
        power: Power,
        budget: Budget,
        paused: Boolean = false,
        videosNeedCharger: Boolean = false
    ): Plan {
        val floor = batteryFloor(mode)
        if (paused) return Plan(false, false, Wait.PAUSED, floor)

        // Battery Saver pauses compression in every mode, charging included:
        // the user asked the system to stop background work.
        if (power.saverOn) return Plan(false, false, Wait.BATTERY_SAVER, floor)
        if (power.thermalThrottled ||
            power.batteryTempTenthsC > Defaults.BATTERY_MAX_TEMP_TENTHS_C
        ) {
            return Plan(false, false, Wait.TOO_HOT, floor)
        }

        if (power.plugged) {
            // Charging: photos always, videos need a small floor so a nearly
            // empty phone charges up first. No budget, screen may be on.
            val videos = power.batteryPct >= Defaults.CHARGING_BATTERY_FLOOR
            return Plan(photos = true, videos = videos, wait = Wait.NONE, floorPct = floor)
        }

        if (mode == SpeedMode.CHARGING_ONLY) {
            return Plan(false, false, Wait.NOT_CHARGING, floor)
        }

        // On battery.
        if (power.batteryPct < floor) return Plan(false, false, Wait.BATTERY_LOW, floor)

        // Photos are cheap: no screen-off wait, no time budget, only a daily cap.
        val photos = budget.photosOnBattery < Defaults.PHOTO_CAP_ON_BATTERY

        // Videos are expensive: screen must be off long enough and the daily
        // encode budget must be left. A mode with a zero wait (FAST) does not
        // care about the screen at all.
        val screenWait = screenOffWaitMs(mode)
        val screenBlocked = screenWait > 0 &&
            (power.screenInteractive || power.screenOffMs < screenWait)
        val budgetBlocked = budget.videoEncodeMs >= videoBudgetMs(mode)
        val videos = !screenBlocked && !budgetBlocked && !videosNeedCharger

        if (photos || videos) return Plan(photos, videos, Wait.NONE, floor)

        // Nothing may run: report the most useful blocker.
        val reason = when {
            budgetBlocked -> Wait.BUDGET_USED
            screenBlocked -> Wait.SCREEN_ON
            videosNeedCharger -> Wait.VIDEOS_CHARGING
            else -> Wait.PHOTO_CAP
        }
        return Plan(false, false, reason, floor)
    }

    /**
     * The longest video a run without a foreground service can take on with
     * [remainingMs] left, or 0 for none. Android stops such a run after about
     * ten minutes. Encoding on a budget phone runs at about real time, so a
     * clip needs its own length and a half plus a minute to read and write
     * it; and the encoder is never handed less than [minBudgetMs], so less
     * than that left means no video at all. A clip of unknown length waits
     * for a run that has the time.
     */
    fun plainRunVideoMaxMs(remainingMs: Long, minBudgetMs: Long): Long =
        if (remainingMs < minBudgetMs) 0L else ((remainingMs - 60_000L) * 2 / 3).coerceAtLeast(0L)

    fun fitsPlainRun(durationMs: Long, remainingMs: Long, minBudgetMs: Long): Boolean =
        durationMs in 1..plainRunVideoMaxMs(remainingMs, minBudgetMs)

    /**
     * Whether a video that ran out of [budgetMs] should wait for another run
     * rather than be copied across as it is.
     *
     * Only when the budget was less than [fullBudgetMs], the most any run
     * gives one clip: then a later run can give it more. A clip that ran out
     * of the whole budget would run out again, so it is copied as before.
     */
    fun outOfTimeWaits(budgetMs: Long, fullBudgetMs: Long): Boolean = budgetMs < fullBudgetMs

    /**
     * Whether a clip of [durationMs] is better left for a later run than
     * started with [budgetMs]: the same reading as [plainRunVideoMaxMs] - its
     * own length and a half plus a minute - and only while a later run could
     * give it more ([outOfTimeWaits]). A clip of unknown length is tried.
     */
    fun videoWaitsForLongerRun(durationMs: Long, budgetMs: Long, fullBudgetMs: Long): Boolean =
        durationMs > 0 && outOfTimeWaits(budgetMs, fullBudgetMs) &&
            durationMs * 3 / 2 + 60_000L > budgetMs

    /**
     * Whether a file can still be started with [remainingMs] of the run left,
     * asked once the encoder is free (Stager.stageInRun): the same tests the
     * run made before it waited, [fitsPlainRun] without a foreground service
     * and [videoWaitsForLongerRun] with one, against what the wait has left.
     * [budgetMs] is what the encoder would be given now. A run past its
     * deadline starts nothing.
     */
    fun canStart(
        isVideo: Boolean,
        durationMs: Long,
        remainingMs: Long,
        foreground: Boolean,
        budgetMs: Long,
        minBudgetMs: Long,
        fullBudgetMs: Long
    ): Boolean = when {
        remainingMs <= 0 -> false
        !isVideo -> true
        !foreground -> fitsPlainRun(durationMs, remainingMs, minBudgetMs)
        else -> !videoWaitsForLongerRun(durationMs, budgetMs, fullBudgetMs)
    }

    /**
     * What one file just cost the day's on-battery allowance. A video's
     * encoder time is spent whether or not a copy came of it, so a clip that
     * failed or ran out of time is charged as well: left uncharged, a clip
     * that never finishes could drain every run on battery and the daily
     * limit would never stop it. A photo counts only once it is made.
     * [tookMs] is the encode's own time, never a wait for the encoder.
     */
    fun batteryCost(plugged: Boolean, isVideo: Boolean, ok: Boolean, tookMs: Long): Budget = when {
        plugged -> Budget(0L, 0)
        isVideo -> Budget(tookMs.coerceAtLeast(0L), 0)
        ok -> Budget(0L, 1)
        else -> Budget(0L, 0)
    }

    /**
     * "Run now" is user-initiated, so only hard safety limits apply:
     * charging or at least 15%, and not too hot.
     */
    fun decideManual(power: Power): Plan {
        val floor = Defaults.CHARGING_BATTERY_FLOOR
        if (power.thermalThrottled ||
            power.batteryTempTenthsC > Defaults.BATTERY_MAX_TEMP_TENTHS_C
        ) {
            return Plan(false, false, Wait.TOO_HOT, floor)
        }
        if (!power.plugged && power.batteryPct < floor) {
            return Plan(false, false, Wait.BATTERY_LOW, floor)
        }
        return Plan(photos = true, videos = true, wait = Wait.NONE, floorPct = floor)
    }
}
