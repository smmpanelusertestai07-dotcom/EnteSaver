package com.pocketide.downloads

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.Base64

class HeldStreamTest {
    /** A page holding [pieces] (base64); it answers "" [reading] times first, as while it reads one. */
    private class Page(private val pieces: List<String>, private var reading: Int = 0) : HeldFile {
        override val name = "notes.txt"
        override val mime = "text/plain"
        override val size = 0L
        val asked = mutableListOf<Int>()

        override fun piece(index: Int, answer: (String?) -> Unit) {
            asked += index
            when {
                reading > 0 -> {
                    reading--
                    answer("")
                }
                index < pieces.size -> answer(pieces[index])
                else -> answer(null)
            }
        }

        override fun letGo() = Unit
    }

    private val now: (Runnable) -> Unit = { it.run() }

    private fun base64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)

    @Test
    fun `the page's pieces come whole and in order, waiting while it still reads one`() {
        val bytes = ByteArray(300_000) { (it * 31).toByte() }
        val page = Page(listOf(base64(bytes.copyOfRange(0, 200_000)), base64(bytes.copyOfRange(200_000, 300_000))), reading = 3)
        assertArrayEquals(bytes, HeldStream(page, now, { false }).readBytes())
        assertEquals("each piece once, after the waits", listOf(0, 0, 0, 0, 1, 2), page.asked)
    }

    @Test
    fun `an empty file is an empty file`() {
        assertEquals(0, HeldStream(Page(emptyList()), now, { false }).readBytes().size)
    }

    @Test
    fun `a page that never answers, or reads too long, ends the download instead of keeping it waiting`() {
        val closed = object : HeldFile {
            override val name = "a"
            override val mime = "text/plain"
            override val size = 1L
            override fun piece(index: Int, answer: (String?) -> Unit) = Unit
            override fun letGo() = Unit
        }
        assertThrows(PageGone::class.java) { HeldStream(closed, now, { false }, waitMs = 50).readBytes() }
        assertThrows(PageGone::class.java) { HeldStream(Page(listOf("AAAA"), reading = Int.MAX_VALUE), now, { false }, waitMs = 100).readBytes() }
    }

    @Test
    fun `a piece that is not base64 ends it, and so does Cancel`() {
        assertThrows(PageGone::class.java) { HeldStream(Page(listOf("not base64!")), now, { false }).readBytes() }
        val cancelled = assertThrows(IOException::class.java) { HeldStream(Page(listOf("AAAA")), now, { true }).readBytes() }
        assertTrue(cancelled !is PageGone)
    }
}
