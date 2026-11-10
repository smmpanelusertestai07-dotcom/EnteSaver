package com.pocketide.docs

// Short builders so the content files read like the text they hold.

internal const val TONE_INFO = "info"
internal const val TONE_WARN = "warn"
internal const val TONE_TIP = "tip"

/** Marks what is still being checked on real phones, until it is. */
internal const val BEING_TESTED = "Being tested on phones like yours"

internal fun section(id: String, title: String, summary: String, vararg blocks: DocBlock) =
    DocSection(id, title, summary, blocks.toList())

internal fun p(text: String) = DocBlock.Paragraph(text)

internal fun bullets(vararg items: String) = DocBlock.Bullets(items.toList())

internal fun steps(vararg items: String) = DocBlock.Steps(items.toList())

internal fun table(header: List<String>, vararg rows: List<String>) = DocBlock.Table(header, rows.toList())

internal fun row(vararg cells: String) = cells.toList()

internal fun info(text: String) = DocBlock.Note(TONE_INFO, text)

internal fun warn(text: String) = DocBlock.Note(TONE_WARN, text)

internal fun tip(text: String) = DocBlock.Note(TONE_TIP, text)

internal fun link(label: String, url: String) = DocBlock.Link(label, url)

internal fun faq(id: String, sectionId: String?, question: String, vararg answer: String) =
    FaqEntry(id, question, answer.map(::p), sectionId)

internal fun term(term: String, meaning: String) = GlossaryEntry(term, meaning)
