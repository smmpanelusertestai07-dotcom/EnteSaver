package app.entesaver

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.OutputRoots
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.ReattachEngine
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Rows restored from a history file, matched to the copies still in the
 * folder on a real Android: a copy that was waiting for Ente goes back under
 * watch with what its history recorded about it, a different file under the
 * same fingerprint earns nothing, and a row whose copy has gone keeps its
 * evidence as DONE only if it had any.
 */
@RunWith(AndroidJUnit4::class)
class ReattachE2eTest {

    /** Android 9 writes the copies as files, which takes storage access. */
    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forSharedFiles())

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val repo: OptionsRepo get() = OptionsRepo.get(context)
    private val db get() = AppDb.get(context)
    private val made = mutableListOf<Uri>()
    private var onboardingWas = false

    @Before
    fun setUp(): Unit = runBlocking {
        TestPipeline.stopAndWait(context)
        db.clearAllTables()
        onboardingWas = repo.current().onboardingDone
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
        repo.useDefaultFolders()
    }

    @After
    fun tearDown(): Unit = runBlocking {
        for (uri in made) runCatching { context.contentResolver.delete(uri, null, null) }
        db.clearAllTables()
        repo.setBool(OptionsRepo.K.COPIES_REATTACHED, false)
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, onboardingWas)
    }

    /** A copy in the output folder, the way an earlier install left it; returns its size. */
    private suspend fun leaveCopy(name: String, seed: Int): Long {
        val root = OutputRoots.normalize(repo.current().layout.current.first())
        val bitmap = MediaFixtures.makeBitmap(64, 64, seed)
        val bytes = ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)
        }.toByteArray()
        bitmap.recycle()
        val uri = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            MediaFixtures.publishFile(context, "$root/", name, "image/jpeg") { it.write(bytes) }.also { made += it }
        } else {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$root/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val pending = requireNotNull(context.contentResolver.insert(collection, values))
            made += pending
            context.contentResolver.openOutputStream(pending)!!.use { it.write(bytes) }
            context.contentResolver.update(
                pending, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null
            )
            pending
        }
        MediaFixtures.awaitIndexed(context, uri, name)
        return context.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null
        )!!.use { c -> c.moveToFirst(); c.getLong(0) }
    }

    private fun restored(original: String, evidence: Evidence, outputName: String?, outputBytes: Long?) =
        ItemRow(
            fingerprint = Fingerprint.fp16(original, 1_000_000L, 1_600_000_000L),
            displayName = original,
            sizeBytes = 1_000_000L,
            dateModified = 1_600_000_000L,
            captureAt = 1_600_000_000_000L,
            mimeType = "image/jpeg",
            isVideo = false,
            state = ItemState.UNKNOWN.name,
            evidence = evidence.name,
            outputName = outputName,
            outputBytes = outputBytes,
            outputSha256 = "sha-of-$original",
            releasedAt = 1_600_000_000_000L,
            confirmedAt = if (evidence == Evidence.NONE) null else 1_600_000_000_000L,
            fromImport = true
        )

    @Test
    fun restoredRowsAreMatchedToTheCopiesStillWaiting(): Unit = runBlocking {
        val start = System.currentTimeMillis()

        // Waited 10 days for Ente, copy still there: back under watch, AGED kept.
        val waiting = restored("waiting.jpg", Evidence.AGED, null, null)
        val waitingName = Fingerprint.outputName("waiting.jpg", waiting.fingerprint, "jpg")
        val waitingBytes = leaveCopy(waitingName, seed = 1)
        db.items().insert(waiting.copy(outputName = waitingName, outputBytes = waitingBytes))

        // A different file under the same fingerprint: the record was about another copy.
        val other = restored("other.jpg", Evidence.CONFIRMED_PACED, "other__old.jpg", 1L)
        leaveCopy(Fingerprint.outputName("other.jpg", other.fingerprint, "jpg"), seed = 2)
        db.items().insert(other)

        // Copies gone: done with evidence, still not matched without.
        db.items().insert(restored("taken.jpg", Evidence.CONFIRMED_EXACT, "taken__x.jpg", 10L))
        db.items().insert(restored("unproven.jpg", Evidence.NONE, "unproven__x.jpg", 10L))

        repo.setBool(OptionsRepo.K.COPIES_REATTACHED, false)
        // A restore no longer watched: the pass settles what it did not find.
        repo.setLong(OptionsRepo.K.RESTORED_AT, 1L)
        ReattachEngine(context).run()
        assertTrue("the run must finish", repo.current().copiesReattached)

        val w = db.items().byFingerprint(waiting.fingerprint)!!
        assertEquals(ItemState.RELEASED.name, w.state)
        assertEquals(Evidence.AGED.name, w.evidence)
        assertEquals("sha-of-waiting.jpg", w.outputSha256)
        assertTrue("watched from now, not from the old install", w.releasedAt!! >= start)

        val o = db.items().byFingerprint(other.fingerprint)!!
        assertEquals(ItemState.RELEASED.name, o.state)
        assertEquals(Evidence.NONE.name, o.evidence)
        assertNull(o.outputSha256)
        assertNull(o.confirmedAt)

        val taken = db.items().byFingerprint(restored("taken.jpg", Evidence.NONE, null, null).fingerprint)!!
        assertEquals(ItemState.DONE.name, taken.state)
        assertEquals(Evidence.CONFIRMED_EXACT.name, taken.evidence)

        val unproven = db.items().byFingerprint(restored("unproven.jpg", Evidence.NONE, null, null).fingerprint)!!
        assertEquals(ItemState.UNKNOWN.name, unproven.state)
    }
}
