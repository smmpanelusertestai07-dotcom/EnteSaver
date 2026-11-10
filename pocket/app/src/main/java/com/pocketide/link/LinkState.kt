package com.pocketide.link

/** Where PocketIDE's connection to Cloud Shell is, as the screens show it. */
sealed interface LinkState {
    /** Not connected, and nothing under way. */
    data object Off : LinkState

    /** Connecting: [step] says what is happening, [detail] the latest line from Cloud Shell. */
    data class Working(val step: String, val detail: String? = null) : LinkState

    /** Connected: the agents' VS Code opens inside PocketIDE. */
    data object On : LinkState

    data class Failed(val problem: Problem, val why: String) : LinkState
}

/** What the owner can do about a connection that failed. */
enum class Problem {
    /** PocketIDE's connection is not set up on this phone, or part of it broke: its set-up. */
    CONNECTOR,

    /** gcloud is not signed in, or Google ended its sign-in: sign in again. */
    SIGN_IN,

    /** Something only Google's own Cloud Shell page settles (its terms, a verification, the week's hours): open it once. */
    CLOUD_SHELL,

    /** Google could not be reached: try again. */
    NETWORK,

    /** This gcloud opens its tunnel in a way PocketIDE cannot yet keep private: update PocketIDE. */
    APP_UPDATE,

    /** Anything else: try again. */
    OTHER,
}

internal class LinkFailure(val problem: Problem, val why: String) : Exception(why)

/** What gcloud's last words mean, in the owner's words. Pure, so it is tested off the phone. */
internal object GcloudSays {
    /** What private_tunnel.py says when a gcloud update changed how the tunnel opens. */
    const val TUNNEL_CHANGED = "opens its Cloud Shell tunnel in a new way"

    private val SIGN_IN = Regex(
        "(?i)(reauthentication|invalid_grant|no credentialed accounts|do not currently have an active account|" +
            "gcloud auth login|refresh(ing)? (your )?(current )?auth tokens|expired or revoked|Please run:\\s+\\\$ gcloud auth)",
    )
    private val TERMS = Regex("(?i)(terms of service|accept the terms|\\bToS\\b)")
    private val QUOTA = Regex("(?i)(quota|RESOURCE_EXHAUSTED|usage limit)")
    private val NETWORK = Regex(
        "(?i)(Unable to find the server|Name or service not known|Temporary failure in name resolution|" +
            "Network is unreachable|Connection (refused|reset|aborted|timed out)|Max retries exceeded|" +
            "Failed to establish a new connection|ConnectionError|timed out|No route to host)",
    )
    private val ANSI = Regex("\u001B\\[[0-9;?]*[A-Za-z]")

    fun failure(lines: List<String>): LinkFailure {
        val text = lines.joinToString("\n")
        return when {
            text.contains(TUNNEL_CHANGED) -> LinkFailure(
                Problem.APP_UPDATE,
                "Google's gcloud changed how it connects to Cloud Shell. Get the newest PocketIDE; your projects and chats wait in Cloud Shell.",
            )
            SIGN_IN.containsMatchIn(text) -> LinkFailure(Problem.SIGN_IN, "Google asks you to sign in to gcloud again on this phone.")
            text.contains("unverified", ignoreCase = true) -> LinkFailure(
                Problem.CLOUD_SHELL,
                "Google asks you to verify your account for Cloud Shell: do it once on Google's Cloud Shell page, then try again.",
            )
            TERMS.containsMatchIn(text) -> LinkFailure(
                Problem.CLOUD_SHELL,
                "Accept Google Cloud's terms once on Google's Cloud Shell page, then try again.",
            )
            QUOTA.containsMatchIn(text) -> LinkFailure(
                Problem.CLOUD_SHELL,
                "Cloud Shell's free hours for this week are used up, or Google limits it for now. Cloud Shell's page says until when.",
            )
            NETWORK.containsMatchIn(text) -> LinkFailure(Problem.NETWORK, "PocketIDE could not reach Google. Check the phone's connection and try again.")
            text.contains("did not start", ignoreCase = true) -> LinkFailure(
                Problem.CLOUD_SHELL,
                "Cloud Shell did not start. Google's Cloud Shell page says why; then try again.",
            )
            else -> LinkFailure(Problem.OTHER, lastWords(lines)?.let { "gcloud stopped: $it" } ?: "gcloud stopped without saying why.")
        }
    }

    /** gcloud's error line without its "ERROR: (gcloud.cloud-shell.ssh)" prefix, or the last line it printed. */
    fun lastWords(lines: List<String>): String? {
        val clean = lines.map(::clean).filter { it.isNotEmpty() }
        val error = clean.lastOrNull { it.startsWith("ERROR:") }
        return (error?.substringAfter("ERROR:")?.trim()?.replace(Regex("^\\([^)]*\\)\\s*"), "") ?: clean.lastOrNull())
            ?.take(MAX_WORDS)
    }

    /** True when PocketIDE's check found that gcloud opens its Cloud Shell tunnel in a way it cannot keep private. */
    fun tunnelChanged(lines: List<String>): Boolean = lines.any { it.contains(TUNNEL_CHANGED) }

    /** A line without terminal colours. */
    fun clean(line: String): String = line.replace(ANSI, "").trim()

    /** The account in gcloud's "You are now logged in as [account]." */
    fun signedInAs(lines: List<String>): String? =
        lines.firstNotNullOfOrNull { Regex("""logged in as \[([^\]\s]+)]""").find(it)?.groupValues?.get(1) }

    /** What a line of gcloud's output says about its progress, in the owner's words; null for anything else. */
    fun progress(line: String): String? = when {
        line.contains("Starting your Cloud Shell machine") || line.contains("Waiting for your Cloud Shell machine") ->
            "Starting Cloud Shell (up to a minute after a break)…"
        line.contains("Pushing your public key") || line.contains("public key to propagate") -> "Preparing the connection…"
        line.contains("Listening on local port") -> "Connecting to Cloud Shell…"
        else -> null
    }

    private const val MAX_WORDS = 300
}
