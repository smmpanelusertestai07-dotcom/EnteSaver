package app.entesaver.media

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * On Android 9 a new copy is written with the file API rather than through
 * MediaStore, so nothing but the app chooses the name it lands under. The
 * name chosen must never be one a file already has: the rename that puts the
 * copy in place would replace that file without a word.
 */
class LegacyMediaTest {

    @get:Rule
    val dir = TemporaryFolder()

    @Test
    fun `a free name is claimed as it is, by an empty file`() {
        val claimed = LegacyMedia.claimName(dir.root, "IMG_1.jpg")
        assertEquals(File(dir.root, "IMG_1.jpg"), claimed)
        assertTrue(claimed!!.isFile)
        assertEquals(0L, claimed.length())
    }

    @Test
    fun `a taken name gets the number MediaProvider would add, and the files there are left alone`() {
        val first = File(dir.root, "IMG_1.jpg").apply { writeText("theirs") }
        val second = File(dir.root, "IMG_1 (1).jpg").apply { writeText("also theirs") }
        assertEquals(File(dir.root, "IMG_1 (2).jpg"), LegacyMedia.claimName(dir.root, "IMG_1.jpg"))
        assertEquals("theirs", first.readText())
        assertEquals("also theirs", second.readText())
    }

    @Test
    fun `a name without an extension is numbered at its end`() {
        File(dir.root, "notes").writeText("x")
        assertEquals(File(dir.root, "notes (1)"), LegacyMedia.claimName(dir.root, "notes"))
    }

    @Test
    fun `when every name up to 32 is taken, none is claimed and none is written over`() {
        File(dir.root, "a.json").writeText("0")
        for (n in 1..32) File(dir.root, "a ($n).json").writeText("$n")
        assertNull(LegacyMedia.claimName(dir.root, "a.json"))
        assertEquals("0", File(dir.root, "a.json").readText())
        assertEquals("32", File(dir.root, "a (32).json").readText())
    }

    /**
     * Android 9's scan of the whole of storage, at each start of the phone,
     * passes over hidden folders only: a hidden file beside the photos is
     * listed as one of them. Work in progress waits in a hidden folder.
     */
    @Test
    fun `work waits in a hidden folder, which goes once it is empty`() {
        val work = LegacyMedia.workFolder(dir.root)!!
        assertEquals(File(dir.root, ".entesaver"), work)
        assertTrue(work.isDirectory && work.name.startsWith("."))
        val kept = File(work, ".entesaver-original-1-IMG_1.jpg").apply { writeText("original") }
        LegacyMedia.tidyWorkFolder(dir.root)
        assertTrue("a folder with an original in it stays", work.isDirectory)
        kept.delete()
        LegacyMedia.tidyWorkFolder(dir.root)
        assertFalse(work.exists())
    }

    @Test
    fun `only half-written files a day old are swept, and kept originals never`() {
        val now = 10L * 24 * 60 * 60_000
        val work = LegacyMedia.workFolder(dir.root)!!
        val old = File(work, ".pending-${now - 25L * 60 * 60_000}-IMG_1.jpg").apply { writeText("x") }
        val fresh = File(work, ".pending-${now - 60_000}-IMG_2.jpg").apply { writeText("x") }
        val kept = File(work, ".entesaver-original-7-${now - 40L * 24 * 60 * 60_000}-IMG_3.jpg").apply { writeText("x") }
        val theirs = File(dir.root, ".pending-photo.jpg").apply { writeText("x") }
        assertEquals(1, LegacyMedia.sweep(work, now))
        assertFalse(old.exists())
        assertTrue(fresh.exists() && kept.exists())
        assertEquals(0, LegacyMedia.sweep(dir.root, now))
        assertTrue("a name this app does not make is not its to remove", theirs.exists())
    }

    @Test
    fun `a kept original is removed after 30 days with its hidden folder, an earlier one beside the photo too`() {
        val now = System.currentTimeMillis()
        val work = LegacyMedia.workFolder(dir.root)!!
        val expired = File(work, ".entesaver-original-1-1-IMG_1.jpg").apply {
            writeText("x")
            setLastModified(now - 31L * 24 * 60 * 60_000)
        }
        val beside = File(dir.root, ".entesaver-original-2-1-IMG_2.jpg").apply {
            writeText("x")
            setLastModified(now - 31L * 24 * 60 * 60_000)
        }
        val recent = File(dir.root, ".entesaver-original-3-1-IMG_3.jpg").apply { writeText("x") }
        assertEquals(2, InPlace.purgeExpired(listOf(expired.path, beside.path, recent.path), now))
        assertFalse(expired.exists() || beside.exists())
        assertFalse("the emptied hidden folder goes too", work.exists())
        assertTrue(recent.exists())
    }
}
