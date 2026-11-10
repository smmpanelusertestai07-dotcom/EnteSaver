package com.pocketide.ui.workspace

import com.pocketide.cloudshell.SignInReturn
import java.net.URI
import java.util.Locale

/**
 * Where an address a page opens goes. Pure Kotlin (java.net.URI), so the rule is tested on the JVM.
 *
 * The agents and their VS Code run in Cloud Shell, so "localhost" in anything they show means
 * Cloud Shell's own address: a dev server an agent started, its preview, its docs. Those open in
 * PocketIDE's page viewer, through PocketIDE's private door. A sign-in page that returns to
 * localhost opens in Chrome, with its return passed on to Cloud Shell. Any other web page opens in
 * Chrome, and nothing else (file:, intent:, javascript:) opens at all.
 */
internal sealed interface Opening {
    /** [path] on Cloud Shell's [port]: PocketIDE's page viewer. */
    data class CloudShellPage(val port: Int, val path: String) : Opening

    /** A sign-in page whose return goes to Cloud Shell's localhost:[port]: Chrome, with the return relayed. */
    data class SignIn(val url: String, val port: Int) : Opening

    /** Any other web page: Chrome. */
    data class Web(val url: String) : Opening

    data object Nowhere : Opening

    companion object {
        private val LOOPBACK = setOf("localhost", "127.0.0.1", "[::1]", "::1")
        private const val LOWEST_PORT = 1024
        private const val HIGHEST_PORT = 65535

        /** [doorPort] says which Cloud Shell port an address of PocketIDE's door leads to (null: not the door). */
        @Suppress("ReturnCount") // The door first, then an address that cannot be read, then the rest.
        fun of(url: String, doorPort: (String) -> Int?): Opening {
            val trimmed = url.trim()
            doorPort(trimmed)?.let { port -> return CloudShellPage(port, pathOf(trimmed)) }
            val uri = runCatching { URI(trimmed) }.getOrNull() ?: return Nowhere
            val scheme = uri.scheme?.lowercase(Locale.ROOT)
            val host = uri.host?.lowercase(Locale.ROOT)
            return when {
                scheme == "http" && host in LOOPBACK && uri.port in LOWEST_PORT..HIGHEST_PORT ->
                    CloudShellPage(uri.port, pathOf(trimmed))
                scheme == "https" && !host.isNullOrBlank() ->
                    SignInReturn.pagePort(trimmed)?.let { SignIn(trimmed, it) } ?: Web(trimmed)
                else -> Nowhere
            }
        }

        /** The path, query and fragment of [url], "/" when it has none. */
        fun pathOf(url: String): String {
            val uri = runCatching { URI(url) }.getOrNull() ?: return "/"
            val path = uri.rawPath?.takeIf { it.startsWith("/") } ?: "/"
            return path + (uri.rawQuery?.let { "?$it" } ?: "") + (uri.rawFragment?.let { "#$it" } ?: "")
        }
    }
}
