package com.pocketide.docs

import com.pocketide.BuildConfig

/** Every outside page the docs point to, in one place so each can be checked before a release. */
internal object DocLinks {
    /** The day every fact and link below was last checked. */
    const val CHECKED_ON = "1 Oct 2026"

    /** The repository that builds and publishes PocketIDE; questions go to its issues. */
    val REPOSITORY = "https://github.com/${BuildConfig.RELEASES_REPO}"
    val ISSUES = "$REPOSITORY/issues"
    val RELEASES = "$REPOSITORY/releases"

    /** Each AI company's own page of the plan's limits, signed in there: the 5-hour and weekly use. */
    const val CLAUDE_USAGE = "https://claude.ai/settings/usage"
    const val CODEX_USAGE = "https://chatgpt.com/codex/cloud/settings/analytics#usage"
    const val ANTIGRAVITY_PLANS = "https://antigravity.google/docs/plans"

    /** Google's 50 hours a week, the 12-hour session, and where Cloud Shell's own page shows the hours left. */
    const val CLOUD_SHELL_QUOTA = "https://docs.cloud.google.com/shell/docs/quotas-limits"
}
