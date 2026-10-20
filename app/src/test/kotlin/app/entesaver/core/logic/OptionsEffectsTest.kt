package app.entesaver.core.logic

import app.entesaver.data.prefs.Options
import app.entesaver.util.Formats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Options defaults and derived values (section 6). */
class OptionsEffectsTest {

    @Test
    fun defaultsMatchSpec() {
        val o = Options()
        assertEquals(BackupScope.ALL, o.scope)
        assertEquals(OutputMode.SINGLE, o.outputMode)
        assertEquals(SpeedMode.SMART, o.speed)
        assertEquals(250, o.dailyCapMb)
        assertEquals(1500, o.minFreeMb)
        assertEquals(1500, o.maxExtraMb)
        assertEquals(ThemeMode.SYSTEM, o.theme)
        // A new install replaces in place; Options() is a new install.
        assertEquals(SaveMode.IN_PLACE, o.saveMode)
        // The brand palette is the default; wallpaper colours are opt-in, or
        // the app looks like a different product on every phone.
        assertFalse(o.dynamicColor)
        assertTrue(o.warningsNotif)
        assertEquals("ente", o.cloudSingle)
        assertEquals("", o.storageVolume)
        // Dangerous things default OFF.
        assertTrue(!o.freeUpAllowVerified30)
        assertTrue(!o.pauseAll)
        assertTrue(!o.appLock)
    }

    @Test
    fun byteConversions() {
        val o = Options(dailyCapMb = 250, minFreeMb = 1500, maxExtraMb = 3000)
        assertEquals(250L * Defaults.MB, o.dailyCapBytes)
        assertEquals(1500L * Defaults.MB, o.minFreeBytes)
        assertEquals(3000L * Defaults.MB, o.maxExtraBytes)
    }

    @Test
    fun `every limit reads back as the number the chip promised`() {
        // The bug: MB was binary while sizes were printed decimal, so picking
        // "500 MB" produced a limit the Storage screen called 524 MB.
        for (mb in listOf(250, 500, 1000, 2000, 1500, 3000, 5000)) {
            val bytes = Options(dailyCapMb = mb).dailyCapBytes
            assertEquals(Formats.mbLabel(mb), Formats.bytes(bytes))
        }
    }

    @Test
    fun `a limit stored by an older build still lands on a chip`() {
        // 1024, 1536, 2048, 3072 and 5120 were the binary-era choices.
        assertEquals(1000, Defaults.snapToChoice(1024, Defaults.DAILY_CAP_CHOICES_MB))
        assertEquals(2000, Defaults.snapToChoice(2048, Defaults.DAILY_CAP_CHOICES_MB))
        assertEquals(1500, Defaults.snapToChoice(1536, Defaults.MIN_FREE_CHOICES_MB))
        assertEquals(3000, Defaults.snapToChoice(3072, Defaults.MAX_EXTRA_CHOICES_MB))
        assertEquals(5000, Defaults.snapToChoice(5120, Defaults.MAX_EXTRA_CHOICES_MB))
        // Unlimited is a sentinel, not a size: it must survive untouched.
        assertEquals(-1, Defaults.snapToChoice(-1, Defaults.DAILY_CAP_CHOICES_MB))
        // A value that is already a chip is left exactly as it is.
        assertEquals(500, Defaults.snapToChoice(500, Defaults.DAILY_CAP_CHOICES_MB))
    }

    @Test
    fun unlimitedSentinels() {
        val o = Options(dailyCapMb = -1, maxExtraMb = -1)
        assertEquals(-1L, o.dailyCapBytes)
        assertEquals(-1L, o.maxExtraBytes)
    }

    @Test
    fun choiceListsMatchSpec() {
        assertEquals(listOf(250, 500, 1000, 2000, -1), Defaults.DAILY_CAP_CHOICES_MB)
        assertEquals(listOf(1500, 3000, 5000, -1), Defaults.MAX_EXTRA_CHOICES_MB)
        assertEquals(listOf(1500, 3000, 5000), Defaults.MIN_FREE_CHOICES_MB)
        assertEquals(5, Defaults.KEEP_MIN_DAYS)
        assertEquals(10, Defaults.AGED_DAYS)
        assertEquals(40, Defaults.MAX_RUN_MIN)
        assertEquals(19_800_000L, Defaults.FGS_BUDGET_MS) // 5.5 h
    }

    @Test
    fun outputFoldersAreUnderPicturesNeverDcim() {
        assertEquals("Pictures/CloudSaver", Defaults.legacyRelPath(OutFolder.SINGLE))
        assertEquals("Pictures/CloudSaver/Photos", Defaults.legacyRelPath(OutFolder.PHOTOS))
        assertEquals("Pictures/CloudSaver/Videos", Defaults.legacyRelPath(OutFolder.VIDEOS))
        val layout = OutputLayout(OutputMode.SINGLE)
        for (folder in OutFolder.entries) {
            assertTrue(layout.path(folder).startsWith("Pictures/"))
            assertTrue(Defaults.legacyRelPath(folder).startsWith("Pictures/"))
        }
    }

    @Test
    fun onlyTheRealOutputFolderCountsAsOurs() {
        val layout = OutputLayout(OutputMode.SINGLE)
        for (folder in OutFolder.entries) {
            for (path in listOf(layout.path(folder), Defaults.legacyRelPath(folder))) {
                assertTrue(Defaults.isOutputPath(path))
                assertTrue(Defaults.isOutputPath("$path/"))
            }
        }
        assertTrue(Defaults.isOutputPath("Pictures/CloudSaver/.cloudsaver/"))

        // A user folder that merely starts with the same letters is not ours.
        assertFalse(Defaults.isOutputPath("Pictures/CloudSaverBackup/"))
        assertFalse(Defaults.isOutputPath("Pictures/CloudSaver2/"))
        assertFalse(Defaults.isOutputPath("Pictures/CSTestShots/"))
        assertFalse(Defaults.isOutputPath("DCIM/Camera/"))
        assertFalse(Defaults.isOutputPath(null))
        assertFalse(Defaults.isOutputPath(""))

        // The SQL pattern must draw the same line.
        assertEquals("Pictures/CloudSaver/%", Defaults.LEGACY_OUTPUT_DIR_LIKE)
        assertTrue(sqlLike("Pictures/CloudSaver/", Defaults.LEGACY_OUTPUT_DIR_LIKE))
        assertTrue(sqlLike("Pictures/CloudSaver/Photos/", Defaults.LEGACY_OUTPUT_DIR_LIKE))
        assertFalse(sqlLike("Pictures/CloudSaverBackup/", Defaults.LEGACY_OUTPUT_DIR_LIKE))
    }

    /** Minimal stand-in for SQLite LIKE: only '%' is used in our patterns. */
    private fun sqlLike(value: String, pattern: String): Boolean =
        Regex(
            pattern.split("%").joinToString(".*") { Regex.escape(it) },
            RegexOption.IGNORE_CASE
        ).matches(value)
}
