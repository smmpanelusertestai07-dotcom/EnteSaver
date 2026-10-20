package app.entesaver.core.logic

/**
 * The one list of setup steps.
 *
 * The header used to count from the loop index while each card carried its
 * number in the copy, so "Step 6 of 7" sat above a card headed "5.". Both now
 * come from here, and nothing in the copy states a position.
 */
object OnboardingSteps {

    enum class Step {
        WELCOME,

        /** Read access to photos and videos. Nothing works without it. */
        MEDIA,

        /**
         * Which albums are in scope. Not skippable: the alternative is an app
         * that silently decides to copy someone's screenshots and WhatsApp
         * folder, and the first they learn of it is the cloud bill.
         */
        ALBUMS,

        /**
         * Replace on this phone, or copies for Ente: what happens to the
         * person's own files, chosen before anything happens to them.
         */
        SAVE_MODE,
        NOTIFICATIONS,
        BATTERY,
        USAGE,
        CLOUD,

        /**
         * The summary. Shows the exact folder that will be written to, offers
         * a three-file trial, and holds the tap that starts anything at all.
         */
        READY
    }

    val ALL: List<Step> = Step.entries.toList()

    /**
     * The steps shown for [mode]. Usage access confirms that Ente collected
     * a copy from Ente Saver's folder; replacing in place puts nothing in a
     * folder, so the step would ask for something that is never used.
     */
    fun visible(mode: SaveMode): List<Step> = if (mode == SaveMode.IN_PLACE) ALL - Step.USAGE else ALL

    val TOTAL: Int = ALL.size

    /** The position a person would read out loud: one-based. */
    fun humanNumber(step: Step): Int = ALL.indexOf(step) + 1

    fun at(index: Int): Step = ALL[index.coerceIn(0, TOTAL - 1)]

    fun indexOf(step: Step): Int = ALL.indexOf(step)

    fun next(step: Step): Step = at(indexOf(step) + 1)

    fun previous(step: Step): Step = at(indexOf(step) - 1)

    val isLast: (Step) -> Boolean = { it == ALL.last() }

    /**
     * Steps that cannot be walked past without doing the thing. Everything
     * else is a permission the app can live without, so those carry Skip.
     */
    val REQUIRED: Set<Step> = setOf(Step.MEDIA, Step.ALBUMS)

    fun isRequired(step: Step): Boolean = step in REQUIRED
}
