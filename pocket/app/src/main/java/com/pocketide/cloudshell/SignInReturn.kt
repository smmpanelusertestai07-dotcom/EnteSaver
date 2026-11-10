package com.pocketide.cloudshell

import java.net.URI
import java.net.URLDecoder

/**
 * A sign-in page that returns to localhost. An agent that signs in with a browser waits in Cloud
 * Shell for the page to return to http://localhost:PORT/...; on a phone that return lands on the
 * phone itself, where PocketIDE passes it on to the agent in Cloud Shell ([SignInCatcher]).
 */
object SignInReturn {
    private const val LOWEST_PORT = 1024
    private const val HIGHEST_PORT = 65535
    private val LOOPBACK = setOf("localhost", "127.0.0.1")

    /**
     * The phone port a sign-in page returns to: [page] is an https sign-in page whose redirect_uri
     * is http://localhost:PORT/... (as Antigravity's is). Null for anything else.
     */
    fun pagePort(page: String): Int? {
        val uri = runCatching { URI(page.trim()) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.host.isNullOrBlank()) return null
        val redirect = uri.rawQuery.orEmpty().split('&')
            .firstOrNull { it.startsWith("redirect_uri=") }
            ?.let { runCatching { URLDecoder.decode(it.substringAfter('='), "UTF-8") }.getOrNull() }
        return redirect?.let { runCatching { URI(it) }.getOrNull() }?.let(::loopbackPort)
    }

    /** True for a port an agent's sign-in can wait on: not a system one. */
    fun isAgentPort(port: Int): Boolean = port in LOWEST_PORT..HIGHEST_PORT

    private fun loopbackPort(uri: URI): Int? =
        uri.port.takeIf { uri.scheme == "http" && uri.host in LOOPBACK && isAgentPort(it) }
}
