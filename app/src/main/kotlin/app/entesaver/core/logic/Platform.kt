package app.entesaver.core.logic

/**
 * What this Android version can and cannot do, stated in one place.
 *
 * The app runs on Android 9 through 16, but "runs on" is not the same as
 * "does everything on". Android 9 and 10 have no media trash, so a removed
 * original there is gone for good - and a button that says "Move to trash"
 * while permanently deleting would be the worst lie this app could tell.
 * Every screen that offers such an action asks here first, and the About
 * page states the same thing before anyone gets that far.
 */
object Platform {

    /** Oldest Android this app installs on. Matches minSdk. */
    const val MIN_SDK = 28

    /** The Android version this app is built and tested against. */
    const val TARGET_SDK = 36

    /** Below this there is no media trash, so removal cannot be undone. */
    const val TRASH_SDK = 30



    /** How completely the app works on a given version. */
    enum class Support {
        /** Every feature, including thirty-day recovery from the trash. */
        FULL,
        /** Everything works, but a removed original cannot be brought back. */
        NO_UNDO
    }

    fun supportFor(sdkInt: Int): Support =
        if (sdkInt >= TRASH_SDK) Support.FULL else Support.NO_UNDO

    /** True when removal can be undone from the system trash. */
    fun canTrash(sdkInt: Int): Boolean = sdkInt >= TRASH_SDK

    /** True when one dialog can cover a whole batch. */
    fun canBatchDelete(sdkInt: Int): Boolean = sdkInt >= TRASH_SDK

    /**
     * The Android release name for an API level, for the About page. A level
     * newer than this table answers with the phone's own [release] string,
     * or the number when there is none, rather than a guessed name.
     */
    fun releaseName(sdkInt: Int, release: String = ""): String = when (sdkInt) {
        28 -> "9"
        29 -> "10"
        30 -> "11"
        31 -> "12"
        32 -> "12L"
        33 -> "13"
        34 -> "14"
        35 -> "15"
        36 -> "16"
        37 -> "17"
        else -> release.trim().ifEmpty { "API $sdkInt" }
    }
}
