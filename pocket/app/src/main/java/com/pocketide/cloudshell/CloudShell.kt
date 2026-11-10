package com.pocketide.cloudshell

import com.pocketide.BuildConfig
import com.pocketide.agents.Agent
import com.pocketide.core.Settings
import java.net.URLEncoder

/**
 * Google Cloud Shell, PocketIDE's computer: Google's own Linux computer, free with a Google account.
 * The set-up is one command, from a script pinned by its SHA-256, that gives each agent its own
 * VS Code, which Cloud Shell then starts by itself whenever it starts. PocketIDE runs it through
 * its own connection (Google's gcloud on the phone).
 */
object CloudShell {
    /** The commit that holds the setup script this app version gives out. */
    const val SCRIPT_COMMIT = "24e963a8be7714927adc767a1cd9dea84155493f"
    const val SCRIPT_PATH = "pocket/cloudshell/pocketide-cloudshell.sh"

    /** The script's SHA-256: the command runs it only when the download matches. */
    const val SCRIPT_SHA256 = "f963f18130390cc70da4ea965b89234299b4908c2de0ee990fbdb2f2778e8870"
    val SCRIPT_URL = "https://raw.githubusercontent.com/${BuildConfig.RELEASES_REPO}/$SCRIPT_COMMIT/$SCRIPT_PATH"

    /** Google deletes Cloud Shell's home folder after this many days without use. */
    const val DELETED_AFTER_DAYS = 120

    /** PocketIDE asks for the set-up again this many days after it last opened Cloud Shell. */
    const val ASK_AGAIN_AFTER_DAYS = 110
    private const val DAY_MS = 24 * 60 * 60 * 1000L

    const val NEW_ACCOUNT = "https://accounts.google.com/signup"
    const val LIMITS = "https://docs.cloud.google.com/shell/docs/limitations"
    const val RESET = "https://docs.cloud.google.com/shell/docs/resetting-cloud-shell"
    const val TERMS = "https://cloud.google.com/terms"
    const val PRIVACY = "https://cloud.google.com/terms/cloud-privacy-notice"

    /** The one command PocketIDE runs in Cloud Shell: download the script, check it, run it. */
    val setupCommand: String =
        "curl -fsSL -o ~/pocketide-cloudshell.sh $SCRIPT_URL && " +
            "echo \"$SCRIPT_SHA256  \$HOME/pocketide-cloudshell.sh\" | sha256sum -c - && " +
            "bash ~/pocketide-cloudshell.sh"

    /** The first agent's port; each next agent takes the next one, as the script sets them up. */
    private const val FIRST_PORT = 8080

    /** Each agent's port in Cloud Shell: Claude Code 8080, Codex 8081, Antigravity 8082. */
    fun port(agent: Agent): Int = FIRST_PORT + agent.ordinal

    /** The set-up's name for [agent]: its VS Code's folder, and what `pocketide start` and info.py take. */
    fun key(agent: Agent): String = when (agent) {
        Agent.CLAUDE -> "claude-code"
        Agent.CODEX -> "codex"
        Agent.ANTIGRAVITY -> "antigravity"
    }

    /** Where PocketIDE's browser view (relay.py) listens in Cloud Shell; Chrome's DevTools are on [BROWSER_DEVTOOLS_PORT]. */
    const val BROWSER_PORT = 6080
    const val BROWSER_DEVTOOLS_PORT = 9222

    fun projects(agent: Agent): String = when (agent) {
        Agent.CLAUDE -> "~/projects/claude-code"
        Agent.CODEX -> "~/projects/codex"
        Agent.ANTIGRAVITY -> "~/projects/antigravity"
    }

    /**
     * Google's own Cloud Shell page, with [account], in the browser: only for what that page alone
     * settles, once (accepting Google Cloud's terms, verifying the account). The agents never open there.
     */
    fun googlePage(account: String): String = "https://shell.cloud.google.com/?show=terminal" + authUser(account)

    /**
     * True until the owner has picked an account and finished the set-up, and again when PocketIDE
     * has not opened Cloud Shell for [ASK_AGAIN_AFTER_DAYS]: by then Google may have deleted the
     * home folder, and the set-up only adds what is missing.
     */
    fun needsSetUp(settings: Settings, now: Long): Boolean =
        settings.cloudAccount.isBlank() || settings.cloudSetUpAt == 0L || daysUnused(settings, now) >= ASK_AGAIN_AFTER_DAYS

    /** True when the owner's Cloud Shell was set up with another script than the one this app version gives out. */
    fun newerSetUp(settings: Settings): Boolean = settings.cloudScript != SCRIPT_COMMIT

    /** Whole days since PocketIDE last opened Cloud Shell (or finished its set-up). */
    fun daysUnused(settings: Settings, now: Long): Long {
        val last = maxOf(settings.cloudOpenedAt, settings.cloudSetUpAt)
        return if (last == 0L) 0 else ((now - last) / DAY_MS).coerceAtLeast(0)
    }

    private fun authUser(account: String): String = if (account.isBlank()) "" else "&authuser=" + encode(account)

    private fun encode(text: String): String = URLEncoder.encode(text, "UTF-8")
}
