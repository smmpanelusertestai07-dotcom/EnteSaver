package com.pocketide.ui.web

import java.net.URI
import java.util.Locale

/**
 * Which addresses PocketIDE hands to Chrome. Pure Kotlin (java.net.URI), so the rule is tested on
 * the JVM. Only https leaves the app: Cloud Shell, the agents' VS Code, sign-in pages and the docs'
 * links are all https, and anything else (http, intent:, file:, javascript:) goes nowhere.
 */
object WebPolicy {
    /** An address Chrome may be given: https, to a named host. */
    fun isWebLink(url: String): Boolean {
        val uri = parse(url) ?: return false
        return uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank()
    }

    /** The host an "open in Chrome" note names, so the owner sees where it goes. */
    fun hostOf(url: String): String? = parse(url)?.host?.lowercase(Locale.ROOT)

    private fun parse(url: String): URI? = try {
        URI(url.trim())
    } catch (_: Exception) {
        null
    }
}
