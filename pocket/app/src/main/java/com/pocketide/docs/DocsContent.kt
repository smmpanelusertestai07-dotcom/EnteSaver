package com.pocketide.docs

import android.content.Context
import java.util.Locale

/** Screens a Help link or a search result opens, by the id after `app:` in a link. */
enum class AppPlace(val id: String, val title: String, val about: String) {
    SETTINGS("settings", "Settings", "Theme, dark, light, wallpaper colours, app lock"),
    DATA("data", "Data (bottom bar)", "Where your data is, the old phone computer, save a zip, delete"),
    COMPUTER(
        "computer",
        "Computer",
        "Google Cloud Shell: account, start, set up again, free limits, hours, files, download, reset, delete",
    ),
    ;

    companion object {
        fun of(id: String): AppPlace? = entries.firstOrNull { it.id == id }
    }
}

/**
 * All in-app docs, versioned with the app. Facts that change carry the day they were checked;
 * live values (sizes, versions) are shown by the screens, not written here.
 */
object DocsContent {
    const val TAGLINE = "Agentic development on your phone"

    /** Raised when the terms or the privacy policy change in a way the owner should see again. */
    const val TERMS_VERSION = 9

    // Page ids other screens open directly.
    const val TERMS_ID = "terms"
    const val PRIVACY_ID = "privacy"
    const val NOTICES_ID = "notices"
    const val YOUR_DATA_ID = "your-data"
    const val COMPUTER_ID = "computer"
    const val IDE_ID = "vs-code"
    const val TROUBLE_ID = "trouble"
    const val CONNECTION_ID = "connection"

    /** The day the facts, prices and links were checked. */
    const val CHECKED_ON: String = DocLinks.CHECKED_ON

    const val NOTICES_ASSET: String = Legal.NOTICES_ASSET

    /** The guide, in reading order. */
    val guide: List<DocSection> = Guide.all

    /** Terms of use, privacy policy and open-source licences. */
    val legal: List<DocSection> = Legal.all

    /** Every Help page. */
    val sections: List<DocSection> = Guide.all + Legal.all

    val faq: List<FaqEntry> = Faq.all

    val glossary: List<GlossaryEntry> = Glossary.all.sortedBy { it.term.lowercase(Locale.ROOT) }

    private val byId: Map<String, DocSection> = sections.associateBy { it.id }

    /** The page with this id, or null (for example a stale link). */
    fun section(id: String): DocSection? = byId[id]

    /** The questions that belong to this page. */
    fun faqFor(sectionId: String): List<FaqEntry> = faq.filter { it.sectionId == sectionId }

    /** A link to a place in the app, such as `app:data`, opens that screen. */
    const val APP_SCHEME = "app:"

    /** A link to another Help page, such as `help:your-data`. */
    const val HELP_SCHEME = "help:"

    /** Pages whose title, summary or text contains every word of [query]. */
    fun search(query: String): List<DocSection> {
        val words = words(query)
        if (words.isEmpty()) return emptyList()
        return sections.filter { section ->
            val text = (listOf(section.title, section.summary) + section.blocks.map(::textOf)).joinToString(" ").lowercase(Locale.ROOT)
            words.all { it in text }
        }
    }

    /** Questions whose question or answer contains every word of [query]. */
    fun searchQuestions(query: String): List<FaqEntry> {
        val words = words(query)
        if (words.isEmpty()) return emptyList()
        return faq.filter { entry ->
            val text = (listOf(entry.question) + entry.answer.map(::textOf)).joinToString(" ").lowercase(Locale.ROOT)
            words.all { it in text }
        }
    }

    /** Screens of the app whose name or subject matches [query]: search finds settings too. */
    fun searchPlaces(query: String): List<AppPlace> {
        val words = words(query)
        if (words.isEmpty()) return emptyList()
        return AppPlace.entries.filter { place -> words.all { it in (place.title + " " + place.about).lowercase(Locale.ROOT) } }
    }

    private fun words(query: String): List<String> = query.lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotBlank() }

    /** The full open-source notices from the APK's assets. */
    fun notices(context: Context): String =
        runCatching { context.assets.open(NOTICES_ASSET).bufferedReader().use { it.readText() } }
            .getOrDefault("The notices file is missing from this build.")

    private fun textOf(block: DocBlock): String = when (block) {
        is DocBlock.Paragraph -> block.text
        is DocBlock.Bullets -> block.items.joinToString(" ")
        is DocBlock.Steps -> block.items.joinToString(" ")
        is DocBlock.Table -> (block.header + block.rows.flatten()).joinToString(" ")
        is DocBlock.Note -> block.text
        is DocBlock.Link -> block.label
    }
}
