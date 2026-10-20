package app.entesaver.media

import java.io.File
import org.junit.Assert.assertEquals
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
}
