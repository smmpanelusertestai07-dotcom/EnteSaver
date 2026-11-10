package com.pocketide.docs

/** In-app documentation is structured data, not files: rendered natively and selectable. */
sealed interface DocBlock {
    data class Paragraph(val text: String) : DocBlock
    data class Bullets(val items: List<String>) : DocBlock
    data class Steps(val items: List<String>) : DocBlock
    data class Table(val header: List<String>, val rows: List<List<String>>) : DocBlock

    /** A highlighted note: [tone] is "info", "warn" or "tip". */
    data class Note(val tone: String, val text: String) : DocBlock

    /** A link the owner may open in Chrome. */
    data class Link(val label: String, val url: String) : DocBlock
}

data class DocSection(val id: String, val title: String, val summary: String, val blocks: List<DocBlock>)

data class FaqEntry(val id: String, val question: String, val answer: List<DocBlock>, val sectionId: String?)

data class GlossaryEntry(val term: String, val meaning: String)
