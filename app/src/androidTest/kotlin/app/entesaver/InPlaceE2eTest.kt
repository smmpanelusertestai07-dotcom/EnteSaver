package app.entesaver

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.OptimisedMark
import app.entesaver.media.InPlace
import app.entesaver.media.PhotoCompressor
import java.io.File
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
 * Replace on this phone, on a real MediaStore: the smaller version goes
 * into the original's own item - the same id, name, album and date, which is
 * what lets Ente swap its copy instead of uploading a second one - and the
 * original waits where it can be put back from.
 *
 * The fixture is the app's own MediaStore item, which it may write without
 * All files access; the steps are the ones a camera photo goes through.
 */
@RunWith(AndroidJUnit4::class)
class InPlaceE2eTest {

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        *(TestPermissions.forThisDevice() + if (Build.VERSION.SDK_INT <= 29) arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) else emptyArray())
    )

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private lateinit var tempDir: File
    private val backups = mutableListOf<String>()

    @Before
    fun setUp() {
        tempDir = File(context.cacheDir, "in_place_test").apply {
            deleteRecursively()
            mkdirs()
        }
    }

    @After
    fun tearDown() {
        backups.forEach { InPlace.deleteBackup(context, it) }
        MediaFixtures.cleanUp(context)
        tempDir.deleteRecursively()
    }

    private class Row(val id: Long, val name: String, val size: Long, val dateTaken: Long)

    private fun rowOf(uri: Uri): Row = context.contentResolver.query(
        uri,
        arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_TAKEN
        ),
        null, null, null
    )!!.use { c ->
        assertTrue("the item must still be there", c.moveToFirst())
        Row(c.getLong(0), c.getString(1), c.getLong(2), c.getLong(3))
    }

    private fun sha(uri: Uri) = context.contentResolver.openInputStream(uri)!!.use { Fingerprint.sha256(it) }

    private fun optimised(uri: Uri, name: String): File {
        val result = PhotoCompressor.compress(
            context, uri, name, rowOf(uri).size, MediaSettings.PHOTO, heicWorks = false, tempDir = tempDir
        )
        assertFalse("the fixture must compress, got ${result.reason}", result.asIs)
        return result.file
    }

    @Test
    fun aReplacedPhotoKeepsItsItemNameAndDateAndItsOriginalCanBePutBack() {
        val name = "in_place_photo.jpg"
        val uri = MediaFixtures.insertPhoto(context, name, captureMillis = 1_600_000_000_000L)
        val before = rowOf(uri)
        val originalSha = sha(uri)
        val copy = optimised(uri, name)

        val outcome = InPlace.replace(context, uri, isVideo = false, expectedBytes = before.size, copy = copy, rowId = 1L)
        assertTrue("the replace must happen, got $outcome", outcome is InPlace.Result.Replaced)
        outcome as InPlace.Result.Replaced
        backups += outcome.backup
        InPlace.settled(context)

        val after = rowOf(uri)
        assertEquals("the same MediaStore item, which is what Ente follows", before.id, after.id)
        assertEquals("the same name", before.name, after.name)
        assertEquals("the date it was taken stays", before.dateTaken, after.dateTaken)
        assertEquals("the item now holds the copy", outcome.sha256, sha(uri))
        assertTrue("and is smaller", outcome.bytes < before.size)
        assertNotEquals(originalSha, outcome.sha256)
        // The copy says it was made here, so it is never optimised again.
        val head = context.contentResolver.openInputStream(uri)!!.use { it.readNBytesCompat(OptimisedMark.HEAD_BYTES) }
        assertTrue(OptimisedMark.isMarked(head))

        // The original waits - in the trash from Android 11 - byte for byte.
        assertTrue("the original must be kept", InPlace.backupExists(context, outcome.backup))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val trashed = context.contentResolver.query(
                Uri.parse(outcome.backup),
                arrayOf(MediaStore.MediaColumns.IS_TRASHED),
                Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE) },
                null
            )!!.use { c -> c.moveToFirst() && c.getInt(0) == 1 }
            assertTrue("kept in the trash, so no gallery - Ente's included - shows it", trashed)
        }

        // And it goes back into the very same item.
        assertTrue(InPlace.putBack(context, outcome.backup, uri))
        assertEquals("the original is back", originalSha, sha(uri))
        assertEquals("in the same item", before.id, rowOf(uri).id)
        assertFalse("and is no longer kept twice", InPlace.backupExists(context, outcome.backup))
    }

    @Test
    fun anOriginalThatChangedSinceItWasEncodedIsLeftAlone() {
        val name = "in_place_changed.jpg"
        val uri = MediaFixtures.insertPhoto(context, name, seed = 7)
        val before = rowOf(uri)
        val copy = optimised(uri, name)
        val outcome = InPlace.replace(context, uri, isVideo = false, expectedBytes = before.size + 1, copy = copy, rowId = 2L)
        assertEquals(InPlace.Result.Failed("original_changed"), outcome)
        assertEquals("nothing was written", before.size, rowOf(uri).size)
    }

    @Test
    fun aCopyThatIsNotSmallerIsNeverWritten() {
        val name = "in_place_bigger.jpg"
        val uri = MediaFixtures.insertPhoto(context, name, seed = 9)
        val before = rowOf(uri)
        val bigger = File(tempDir, "bigger.jpg").apply { writeBytes(ByteArray((before.size + 10).toInt())) }
        val outcome = InPlace.replace(context, uri, isVideo = false, expectedBytes = before.size, copy = bigger, rowId = 3L)
        assertEquals(InPlace.Result.Failed("not_smaller"), outcome)
        assertEquals(before.size, rowOf(uri).size)
    }

    @Test
    fun withNothingCutShortThereIsNothingToRecover() {
        assertEquals(null, InPlace.recover(context))
    }

    private fun java.io.InputStream.readNBytesCompat(n: Int): ByteArray {
        val out = ByteArray(n)
        var read = 0
        while (read < n) {
            val r = read(out, read, n - read)
            if (r < 0) break
            read += r
        }
        return out.copyOf(read)
    }
}
