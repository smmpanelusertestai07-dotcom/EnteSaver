package com.pocketide

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.Instant

class StopNoteTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `the details name the app, when, the thread and the whole error`() {
        val failure = IllegalStateException("outer", IllegalArgumentException("inner"))

        val details = StopNote.details("main", failure, Instant.parse("2026-09-29T17:00:00Z"))

        assertTrue(details.startsWith("PocketIDE ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\n"))
        assertTrue(details.contains("\n2026-09-29T17:00:00Z, thread main\n"))
        assertTrue(details.contains("java.lang.IllegalStateException: outer"))
        assertTrue(details.contains("Caused by: java.lang.IllegalArgumentException: inner"))
    }

    @Test
    fun `a very long error is cut to what a clipboard and a chat take`() {
        val details = StopNote.details("main", IllegalStateException("x".repeat(100_000)))

        assertEquals(24_000, details.length)
    }

    @Test
    fun `a note is written whole and read back, and there is none before`() {
        val file = File(tmp.root, "no_backup/last-stop.txt")
        assertNull(StopNote.read(file))

        StopNote.save(file, "first")
        StopNote.save(file, "second")

        assertEquals("second", StopNote.read(file))
        assertFalse(File(file.path + ".tmp").exists())
    }
}
