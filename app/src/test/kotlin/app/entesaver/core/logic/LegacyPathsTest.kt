package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android 9 gives a file's full path where Android 10 gives its folder. The
 * folder rules only work if both come out as the same string.
 */
class LegacyPathsTest {

    @Test
    fun `a file on the phone's own storage gets Android 10's relative path`() {
        assertEquals("Pictures/EnteSaver/", LegacyPaths.relativePathOf("/storage/emulated/0/Pictures/EnteSaver/a__0123456789abcdef.jpg"))
        assertEquals("DCIM/Camera/", LegacyPaths.relativePathOf("/storage/emulated/0/DCIM/Camera/IMG_1.jpg"))
        assertEquals("Documents/Ente Saver/", LegacyPaths.relativePathOf("/storage/emulated/0/Documents/Ente Saver/history.json"))
    }

    @Test
    fun `a file on an SD card is relative to the card`() {
        assertEquals("DCIM/Camera/", LegacyPaths.relativePathOf("/storage/1234-ABCD/DCIM/Camera/IMG_1.jpg"))
    }

    @Test
    fun `a file at the root is the root, and a path outside shared storage is unknown`() {
        assertEquals("/", LegacyPaths.relativePathOf("/storage/emulated/0/IMG_1.jpg"))
        assertNull(LegacyPaths.relativePathOf("/data/data/app.entesaver/files/a.jpg"))
        assertNull(LegacyPaths.relativePathOf(null))
        assertNull(LegacyPaths.relativePathOf(""))
    }

    @Test
    fun `the phone's own root is tried first, wherever it is mounted`() {
        assertEquals("Pictures/EnteSaver/", LegacyPaths.relativePathOf("/mnt/sdcard/Pictures/EnteSaver/a.jpg", "/mnt/sdcard"))
        assertEquals("Pictures/EnteSaver/", LegacyPaths.relativePathOf("/storage/emulated/0/Pictures/EnteSaver/a.jpg", "/storage/emulated/0/"))
    }

    @Test
    fun `the derived path is what the folder rules already compare`() {
        val rel = LegacyPaths.relativePathOf("/storage/emulated/0/Pictures/EnteSaver/Photos/a.jpg")
        assertTrue(OutputRoots.isUnder(rel, Defaults.OUTPUT_DIR))
        assertTrue(ReleaseVerdict.samePath(rel, Defaults.OUTPUT_DIR_PHOTOS + "/"))
        assertFalse(OutputRoots.isUnder(LegacyPaths.relativePathOf("/storage/emulated/0/Pictures/EnteSaverOld/a.jpg"), Defaults.OUTPUT_DIR))
    }

    @Test
    fun `the DATA pattern escapes LIKE's own wildcards`() {
        assertEquals("%/Pictures/EnteSaver/%", LegacyPaths.dataLike("Pictures/EnteSaver/"))
        assertEquals("%/Pictures/my\\_photos/%", LegacyPaths.dataLike("Pictures/my_photos"))
    }
}
