package com.pocketide.docs

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class NoticesTest {
    private val raw: String by lazy {
        // Unit tests run with the module directory as the working directory.
        val file = listOf(File("src/main/assets"), File("app/src/main/assets"))
            .map { File(it, DocsContent.NOTICES_ASSET) }
            .firstOrNull { it.isFile }
        checkNotNull(file) { "notices asset not found" }.readText()
    }

    /** Lines are wrapped for reading; compare phrases across line breaks. */
    private val notices: String by lazy { raw.replace(Regex("\\s+"), " ") }

    /** PocketIDE's own words, before the licence texts it reproduces exactly. */
    private val ownText: String by lazy { notices.substringBefore(LICENCE_TEXTS) }

    @Test
    fun `notices name every part inside the APK and its licence`() {
        val missing = REQUIRED.filterNot { (part, licence) -> notices.contains(part) && notices.contains(licence) }
        assertTrue("missing from the notices: $missing", missing.isEmpty())
    }

    @Test
    fun `licences that must travel with the APK are there in full`() {
        assertTrue(notices.contains(LICENCE_TEXTS))
        val missing = FULL_TEXTS.filterNot { notices.contains(it) }
        assertTrue("licence texts missing: $missing", missing.isEmpty())
    }

    @Test
    fun `the Help page's licence table agrees with the notices`() {
        val table = checkNotNull(DocsContent.section(DocsContent.NOTICES_ID)).blocks.filterIsInstance<DocBlock.Table>().single()
        val disagree = table.rows.filterNot { (part, licence) ->
            notices.contains(part.substringBefore(" (").substringBefore(",").substringBefore(" and ")) && notices.contains(licence, ignoreCase = true)
        }
        assertTrue("rows the notices do not back: $disagree", disagree.isEmpty())
    }

    @Test
    fun `nothing of an earlier version is still listed`() {
        val gone = listOf("JGit", "Bouncy Castle", "xterm", "Codespaces", "Octicons", "Codicons", "desktop-lite", "npm")
        assertTrue(gone.filter { ownText.contains(it) }.toString(), gone.none { ownText.contains(it) })
    }

    @Test
    fun `PocketIDE's own text uses only https links and no placeholders`() {
        assertTrue(!ownText.contains("http://"))
        assertTrue(listOf("TODO", "FIXME", "lorem").none { notices.contains(it, ignoreCase = true) })
    }

    private companion object {
        const val LICENCE_TEXTS = "FULL LICENCE TEXTS"

        val REQUIRED = listOf(
            "PocketIDE" to "Apache License 2.0",
            "AndroidX" to "Apache License 2.0",
            "Kotlin" to "Apache License 2.0",
            "OkHttp" to "Apache License 2.0",
            "Haze" to "Apache License 2.0",
            "code-server" to "MIT License",
            "PRoot" to "GNU General Public License, version 2",
            "talloc" to "GNU Lesser General Public License, version 3 or later",
            "libandroid-shmem" to "BSD 3-Clause",
            "Google Cloud CLI" to "Apache License 2.0",
        )

        val FULL_TEXTS = listOf(
            "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
            "END OF TERMS AND CONDITIONS",
            // PRoot's GPL-2.0, and talloc's LGPL-3.0 with the GPL-3.0 it builds on.
            "GNU GENERAL PUBLIC LICENSE Version 2, June 1991",
            "GNU LESSER GENERAL PUBLIC LICENSE Version 3, 29 June 2007",
            "GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007",
        )
    }
}
