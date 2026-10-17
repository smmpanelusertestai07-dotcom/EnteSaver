package app.entesaver

import android.content.Context
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.UiDevice
import app.entesaver.core.logic.SpeedMode
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.BatchRow
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.SnapshotStore
import app.entesaver.ui.Lock
import app.entesaver.util.BoundedRead
import java.io.File
import java.io.RandomAccessFile
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The lock, and the one file the user can carry their settings away in.
 *
 * Both are places where being almost right is worse than not existing: a lock
 * that shows the content behind it protects nothing, and a restore that
 * half-applies a file leaves someone's history in a state they cannot reason
 * about.
 */
@RunWith(AndroidJUnit4::class)
class LockBackupE2eTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    @get:Rule
    val compose = createEmptyComposeRule()

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target: Context get() = instrumentation.targetContext
    private fun s(id: Int): String = target.getString(id)

    private val repo get() = OptionsRepo.get(target)
    private fun backupFile() = File(target.cacheDir, "e2e-backup.csb")

    @Before
    fun setUp(): Unit = runBlocking {
        AppDb.get(target).clearAllTables()
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
        repo.useDefaultFolders()
        repo.setBool(OptionsRepo.K.APP_LOCK, false)
        backupFile().delete()
    }

    @After
    fun tearDown(): Unit = runBlocking {
        repo.setBool(OptionsRepo.K.APP_LOCK, false)
        backupFile().delete()
        AppDb.get(target).clearAllTables()
        // A restore is watched for a week; the tests after this one are not
        // about that (an old date, not none: an unset one is a restore made
        // by an earlier version, watched from its first pass).
        repo.setLong(OptionsRepo.K.RESTORED_AT, 1L)
    }

    // ---- the lock ------------------------------------------------------------

    /**
     * The bug this pins: the lock used to cover only the current tab, so
     * tapping a different one in the bar underneath showed that screen in
     * full. Nothing of the app may be on screen while it is locked - and the
     * bar itself is part of the app.
     */
    @Test
    fun nothingOfTheAppIsReachableWhileItIsLocked(): Unit = runBlocking {
        // Decided by the phone, not by whichever frame the test samples. A
        // phone with no screen lock gives the app nothing to verify against,
        // so the lock screen asks once and the app turns its own lock off
        // rather than trapping the user; sampling the lock title in the
        // moment before that happens and then waiting for the tabs to vanish
        // was a race the test could lose. That path has its own test below.
        val canLock = Lock.canEnable(target)
        repo.setBool(OptionsRepo.K.APP_LOCK, true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.waitForIdle()
            if (!canLock) {
                compose.waitUntil(timeoutMillis = 20_000) { !runBlocking { repo.current().appLock } }
                assertFalse(
                    "with no screen lock the app must turn its own lock off",
                    repo.current().appLock
                )
                return@runBlocking
            }
            // The options flow starts on defaults and the stored value lands a
            // frame or two later, so the bar is briefly on screen before the
            // lock is even known about. Waiting for the lock screen is the
            // difference between testing the lock and testing that first frame.
            compose.waitUntil(timeoutMillis = 20_000) {
                compose.onAllNodes(hasText(s(R.string.lock_title), substring = true))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            // The bar leaves through a transition, and Compose transitions do
            // not honour the system's animations-off switch - so for a few
            // frames after the lock title appears, the outgoing bar is still
            // in the tree. A frame of exit animation is not reachability;
            // what must be true is that the bar is gone once the lock has
            // settled.
            val tabs = listOf(
                R.string.nav_home, R.string.nav_files, R.string.nav_storage, R.string.nav_options
            )
            compose.waitUntil(timeoutMillis = 20_000) {
                tabs.all {
                    compose.onAllNodes(hasText(s(it))).fetchSemanticsNodes().isEmpty()
                }
            }
            for (tab in tabs) {
                assertEquals(
                    "the ${s(tab)} tab must not be on screen while locked",
                    0,
                    compose.onAllNodes(hasText(s(tab))).fetchSemanticsNodes().size
                )
            }
            compose.onNodeWithText(s(R.string.lock_unlock)).assertIsDisplayed()
        }
    }

    /**
     * A lock whose key has been thrown away is a door nobody can open. When
     * the phone has no screen lock at all the app must say so and let the
     * user back in, not sit on a screen with a button that cannot work.
     */
    @Test
    fun aLockNeverLeavesTheUserWithNoWayIn(): Unit = runBlocking {
        repo.setBool(OptionsRepo.K.APP_LOCK, true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.waitForIdle()
            // One of two things must be true within a few seconds: the lock
            // screen is up with something to unlock it, or the app has turned
            // its own lock off because this phone has no screen lock to verify
            // against. A locked screen with a dead button is the failure.
            compose.waitUntil(timeoutMillis = 20_000) {
                val locked = compose
                    .onAllNodes(hasText(s(R.string.lock_unlock), substring = true))
                    .fetchSemanticsNodes().isNotEmpty()
                locked || !runBlocking { repo.current().appLock }
            }
            val locked = compose
                .onAllNodes(hasText(s(R.string.lock_unlock), substring = true))
                .fetchSemanticsNodes().isNotEmpty()
            assertTrue(
                "with the lock on, the app must either ask to unlock or turn " +
                    "the lock off; it did neither",
                locked || !repo.current().appLock
            )
        }
    }

    // ---- the backup file -----------------------------------------------------

    private fun exportTo(file: File, password: String?): Boolean = runBlocking {
        file.parentFile?.mkdirs()
        file.delete()
        file.createNewFile()
        SnapshotStore(target, AppDb.get(target), repo).exportTo(Uri.fromFile(file), password)
    }

    private fun importFrom(file: File, password: String?) = runBlocking {
        SnapshotStore(target, AppDb.get(target), repo).importFrom(Uri.fromFile(file), password)
    }

    @Test
    fun aBackupRoundTripsThroughARealFileWithItsPassword(): Unit = runBlocking {
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.CHARGING_ONLY.name)
        val before = repo.current().speed
        assertTrue("export must succeed", exportTo(backupFile(), "correct horse battery"))
        assertTrue("the file must have content", backupFile().length() > 0)

        // Change the thing that was saved, then put the file back.
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.FAST.name)
        assertNotEquals(before, repo.current().speed)

        val result = importFrom(backupFile(), "correct horse battery")
        assertTrue(
            "a correct password must restore, got $result",
            result is SnapshotStore.ImportResult.Success
        )
        assertEquals("the saved setting must come back", before, repo.current().speed)
    }

    @Test
    fun aRestoreKeepsTheKeptCopyAndTheExclusion(): Unit = runBlocking {
        // A scan can rebuild every other column. These two it cannot: a
        // kept light copy sits under the original's own name, and only its
        // row's URI says it is not a new photo; "never optimise" is a choice
        // made once. A restore used to drop both, and the first scan after
        // it queued every kept copy as an original and sent it up again.
        val db = AppDb.get(target)
        val keptUri = "content://media/external/images/media/424242"
        db.items().insert(
            row("kept.jpg").copy(
                state = "FREED_KEPT", evidence = "CONFIRMED_EXACT",
                outputSha256 = "feed", outputBytes = 500, keptUri = keptUri
            )
        )
        db.items().insert(
            row("leave-alone.jpg").copy(
                state = "SKIP", skipReason = "user_excluded", neverOptimise = true
            )
        )
        assertTrue("export must succeed", exportTo(backupFile(), null))
        db.clearAllTables()
        assertEquals(0, db.items().count())

        val result = importFrom(backupFile(), null)
        assertTrue("restore must succeed, got $result", result is SnapshotStore.ImportResult.Success)
        val kept = db.items().byFingerprint("fp-kept.jpg")
        assertEquals("the kept copy's address must come back", keptUri, kept?.keptUri)
        assertEquals("FREED_KEPT", kept?.state)
        val excluded = db.items().byFingerprint("fp-leave-alone.jpg")
        assertEquals("the exclusion must come back", true, excluded?.neverOptimise)
    }

    @Test
    fun aRestoreAfterTheFirstScanEndsWhereARestoreIntoAnEmptyTableWould(): Unit = runBlocking {
        // After a reinstall the scan runs before the person finds Restore in
        // Settings, so every photo is already a NEW row. Giving that row the
        // history's evidence and nothing else left it queued: it was encoded
        // again and a second copy went up. And a "never optimise" set only
        // the flag, so the excluded photo was optimised all the same.
        val db = AppDb.get(target)
        db.items().insert(
            row("sent.jpg").copy(
                state = "DONE", evidence = "CONFIRMED_EXACT", outputSha256 = "5e47",
                outputName = "sent__fp.jpg", outputBytes = 500, releasedAt = 1L, confirmedAt = 2L
            )
        )
        db.items().insert(
            row("private.jpg").copy(state = "SKIP", skipReason = "user_excluded", neverOptimise = true)
        )
        db.items().insert(row("waiting.jpg"))
        db.batches().insert(BatchRow(releasedAt = 1L, totalBytes = 500, folder = "SINGLE"))
        assertTrue("export must succeed", exportTo(backupFile(), null))
        db.clearAllTables()

        // The new install's scan.
        db.items().insert(row("sent.jpg").copy(contentUri = "content://media/external/images/media/1"))
        db.items().insert(row("private.jpg").copy(contentUri = "content://media/external/images/media/2"))
        assertTrue(importFrom(backupFile(), null) is SnapshotStore.ImportResult.Success)
        // A second restore of the same file changes nothing more.
        assertTrue(importFrom(backupFile(), null) is SnapshotStore.ImportResult.Success)

        val sent = db.items().byFingerprint("fp-sent.jpg")!!
        assertEquals("DONE", sent.state)
        assertEquals("5e47", sent.outputSha256)
        assertEquals("the scan's location stays", "content://media/external/images/media/1", sent.contentUri)
        val excluded = db.items().byFingerprint("fp-private.jpg")!!
        assertEquals("SKIP", excluded.state)
        assertEquals("user_excluded", excluded.skipReason)
        val queue = db.items().nextByPriority(
            photos = true, videos = true, excludedBuckets = listOf("-"), freshAfter = 0L,
            limit = 10, videoMaxMs = -1L, skipIds = listOf(-1L), holdOverrun = false
        )
        assertTrue("nothing the history settled is queued: $queue", queue.isEmpty())
        assertEquals(
            "a queued row with no file here is left to the scan, not restored as a ghost",
            null, db.items().byFingerprint("fp-waiting.jpg")
        )
        assertTrue("batches link to no restored row and are not imported", db.batches().all().isEmpty())
    }

    @Test
    fun aFileFarBiggerThanAnyBackupIsTurnedAwayWithoutReadingItAll(): Unit = runBlocking {
        val huge = File(target.cacheDir, "not-a-backup.mp4")
        RandomAccessFile(huge, "rw").use { it.setLength(BoundedRead.MAX_BACKUP_BYTES + 1) }
        try {
            assertEquals(SnapshotStore.ImportResult.TooLarge, importFrom(huge, null))
        } finally {
            huge.delete()
        }
    }

    private fun row(name: String) = ItemRow(
        fingerprint = "fp-$name",
        displayName = name,
        sizeBytes = 1_000,
        dateModified = 1_700_000_000,
        captureAt = 1_700_000_000_000,
        mimeType = "image/jpeg",
        isVideo = false,
        state = "NEW"
    )

    @Test
    fun theWrongPasswordRestoresNothingAtAll(): Unit = runBlocking {
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.CHARGING_ONLY.name)
        assertTrue(exportTo(backupFile(), "the real password"))
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.FAST.name)

        val result = importFrom(backupFile(), "not the real password")
        assertEquals(
            "a wrong password must be reported as such",
            SnapshotStore.ImportResult.WrongPassword,
            result
        )
        assertEquals(
            "and must leave every setting exactly as it was",
            SpeedMode.FAST.name,
            repo.current().speed.name
        )
    }

    @Test
    fun aBackupFromBeforeFourteenRestoresWithoutItsQualitySettings(): Unit = runBlocking {
        // Files written before 14 carry quality presets, and 10.x one preset
        // and one codec. There is nothing left to restore them into: they
        // are read past, and everything else in the file still comes back.
        repo.importMap(
            mapOf(
                "preset" to "MAX_SAVER", "codec" to "HEVC", "photoPreset" to "CUSTOM", "photoMaxMp" to "7",
                "videoPreset" to "SMALLEST", "speed" to SpeedMode.CHARGING_ONLY.name
            )
        )
        assertEquals(SpeedMode.CHARGING_ONLY, repo.current().speed)
    }

    @Test
    fun anEncryptedFileWithNoPasswordAsksForOneInsteadOfFailing(): Unit = runBlocking {
        assertTrue(exportTo(backupFile(), "a password"))
        assertEquals(
            SnapshotStore.ImportResult.NeedsPassword,
            importFrom(backupFile(), null)
        )
    }

    @Test
    fun aFileThatIsNotABackupIsRefusedAndChangesNothing(): Unit = runBlocking {
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.CHARGING_ONLY.name)
        val junk = File(target.cacheDir, "not-a-backup.csb")
        junk.writeBytes(ByteArray(4096) { (it % 251).toByte() })
        val result = importFrom(junk, null)
        assertEquals(
            "unreadable input must be refused, not half-applied",
            SnapshotStore.ImportResult.Unreadable,
            result
        )
        assertEquals(SpeedMode.CHARGING_ONLY.name, repo.current().speed.name)
        junk.delete()
    }

    @Test
    fun anUnencryptedBackupStillRoundTrips(): Unit = runBlocking {
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.CHARGING_ONLY.name)
        val before = repo.current().speed
        assertTrue(exportTo(backupFile(), null))
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.FAST.name)
        assertTrue(importFrom(backupFile(), null) is SnapshotStore.ImportResult.Success)
        assertEquals(before, repo.current().speed)
    }

    @Test
    fun aBackupFromBeforeAutomaticLimitsKeepsItsOwnLimits(): Unit = runBlocking {
        // 11.1 stores Automatic once Settings has been opened; a backup made
        // by 11.0 carries the person's own figures and no choice at all.
        repo.setBool(OptionsRepo.K.SPACE_AUTO, true)
        repo.importMap(mapOf("dailyCapMb" to "2000", "minFreeMb" to "5000"))
        val o = repo.current()
        assertFalse("the restored limits would be replaced on the next run", o.spaceAuto)
        assertEquals(2000, o.dailyCapMb)
        assertEquals(5000, o.minFreeMb)
        repo.setBool(OptionsRepo.K.SPACE_AUTO, true)
    }

    // ---- the dialog that asks for the password -------------------------------

    @Test
    fun theSaveBackupRowOpensThePasswordDialogAndCancellingChangesNothing(): Unit = runBlocking {
        val speedBefore = repo.current().speed
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            // Backups sit under Advanced, folded away by default.
            compose.onNodeWithText(s(R.string.opt_advanced_show)).performScrollTo().performClick()
            compose.waitForIdle()
            compose.onNode(hasText(s(R.string.transfer_export), substring = true))
                .performScrollTo().performClick()
            compose.waitForIdle()
            compose.onNode(hasText(s(R.string.backup_password_label), substring = true))
                .assertIsDisplayed()
            // The save dialog offers Skip - save without a password - rather
            // than Cancel, and skipping would write a file, which is not what
            // abandoning means. Backing out is how a person abandons it.
            UiDevice
                .getInstance(InstrumentationRegistry.getInstrumentation())
                .pressBack()
            compose.waitForIdle()
            compose.onNodeWithText(s(R.string.backup_password_label)).assertDoesNotExist()
            compose.onNode(hasText(s(R.string.transfer_export), substring = true))
                .assertIsDisplayed()
        }
        assertEquals(speedBefore, repo.current().speed)
    }
}
