package app.entesaver

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.GoneReason
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.KeptCopies
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.LedgerRow
import app.entesaver.data.db.ReclaimBatchRow
import app.entesaver.data.db.ReclaimItemRow
import app.entesaver.data.prefs.Options
import app.entesaver.engine.ReclaimEngine
import app.entesaver.media.MediaScanner
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The bookkeeping after Android has removed the originals, driven directly.
 *
 * Android's dialog is not part of this: finish() is told which originals went,
 * exactly as the dialog's answer tells it, and the files are real MediaStore
 * entries so the identities it reads back are the ones a phone would give.
 */
@RunWith(AndroidJUnit4::class)
class ReclaimFinishTest {

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    private val target: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val db get() = AppDb.get(target)

    /** What MediaStore says a file is, as the scanner would fingerprint it. */
    private data class Seen(val name: String, val size: Long, val modified: Long) {
        val fingerprint get() = Fingerprint.fp16(name, size, modified)
    }

    @Before
    fun setUp() {
        MediaFixtures.cleanUp(target)
        runBlocking { db.clearAllTables() }
    }

    @After
    fun tearDown() {
        MediaFixtures.cleanUp(target)
        runBlocking { db.clearAllTables() }
    }

    /**
     * The in-place copy lands beside its original under the same name, so the
     * provider calls it "name (1).jpg"; a scan in the window before finish()
     * made a NEW row for it under the very fingerprint finish() then gave the
     * original's row. The unique index refused, after the originals were
     * gone: a crash, no history, no undo, and the copy queued to be optimised
     * and uploaded again.
     */
    @Test
    fun anInPlaceCopyTheScannerMetFirstIsReKeyedWithoutACrash() = runBlocking {
        val original = photo("reclaim_inplace.jpg", seed = 1)
        val copy = photo("reclaim_inplace.jpg", seed = 2)
        val copySeen = seen(copy)
        assertTrue(
            "the copy must belong to the row under the provider's own name",
            KeptCopies.belongsTo(copySeen.name, "reclaim_inplace.jpg", "0000000000000000")
        )
        val rowId = db.items().insert(
            row("reclaim_inplace.jpg", original, "inplaceorig00001").copy(keptUri = copy.toString())
        )
        val strayId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(state = ItemState.NEW.name)
        )
        assertTrue(strayId > 0)

        val result = finish(rowId, original, copy, ReclaimRules.Mode.REPLACE_WITH_LIGHT)

        assertEquals(1, result.done.size)
        val freed = db.items().byId(rowId)!!
        assertEquals(ItemState.FREED_KEPT.name, freed.state)
        assertEquals(copySeen.fingerprint, freed.fingerprint)
        assertEquals(copy.toString(), freed.contentUri)
        assertNull("the scanner's stray row must be gone", db.items().byId(strayId))
        val history = db.reclaim().itemsOf(result.batchId)
        assertEquals("the batch must be in history, so it can be undone", 1, history.size)
        assertEquals(original.toString(), history.single().contentUri)
        assertEquals(freed.fingerprint, history.single().fingerprint)
    }

    /** A row that has been worked on keeps its history; this one keeps its key. */
    @Test
    fun aWorkedOnRowHoldingTheKeyIsLeftAlone() = runBlocking {
        val original = photo("reclaim_kept.jpg", seed = 3)
        val copy = photo("reclaim_kept.jpg", seed = 4)
        val copySeen = seen(copy)
        val rowId = db.items().insert(
            row("reclaim_kept.jpg", original, "keptorig00000001").copy(keptUri = copy.toString())
        )
        val otherId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(
                state = ItemState.RELEASED.name,
                releasedAt = 1L
            )
        )

        val result = finish(rowId, original, copy, ReclaimRules.Mode.REPLACE_WITH_LIGHT)

        assertEquals(1, result.done.size)
        assertNotNull(db.items().byId(otherId))
        val freed = db.items().byId(rowId)!!
        assertEquals(ItemState.FREED_KEPT.name, freed.state)
        assertEquals("keptorig00000001", freed.fingerprint)
        assertEquals(1, db.reclaim().itemsOf(result.batchId).size)
    }

    /**
     * Restoring an original freed in place must put its row back on the
     * original. Otherwise the history pointed at a fingerprint no row had,
     * nothing was updated, and the next scan queued the original as new.
     */
    @Test
    fun restoringAnInPlaceOriginalPointsItsRowBackAtIt() = runBlocking {
        val original = photo("reclaim_restore.jpg", seed = 5)
        val copy = photo("reclaim_restore.jpg", seed = 6)
        val rowId = db.items().insert(
            row("reclaim_restore.jpg", original, "restoreorig00001").copy(keptUri = copy.toString())
        )
        val result = finish(rowId, original, copy, ReclaimRules.Mode.REPLACE_WITH_LIGHT)
        val item = db.reclaim().itemsOf(result.batchId).single()

        ReclaimEngine(target).onRestored(item)

        val back = db.items().byId(rowId)!!
        assertEquals(ItemState.DONE.name, back.state)
        assertFalse(back.originalMissing)
        assertEquals(original.toString(), back.contentUri)
        assertEquals(seen(original).fingerprint, back.fingerprint)
        assertEquals(
            "the copy beside it must stay known to the scanner",
            copy.toString(), back.keptUri
        )
    }

    /**
     * "Remove the light copy" clears keptUri and leaves the row on the copy's
     * address. A restore read that as "never moved", marked the row DONE on a
     * deleted file, and the original came back as a new photo to upload.
     */
    @Test
    fun restoringAfterTheLightCopyWasRemovedStillFindsTheOriginal() = runBlocking {
        val original = photo("reclaim_removed.jpg", seed = 9)
        val copy = photo("reclaim_removed.jpg", seed = 10)
        val rowId = db.items().insert(
            row("reclaim_removed.jpg", original, "removedorig00001").copy(keptUri = copy.toString())
        )
        val result = finish(rowId, original, copy, ReclaimRules.Mode.REPLACE_WITH_LIGHT)
        val item = db.reclaim().itemsOf(result.batchId).single()
        // What "Remove the light copy" does.
        val freed = db.items().byId(rowId)!!
        assertTrue(target.contentResolver.delete(copy, null, null) > 0)
        db.items().update(
            freed.copy(
                keptUri = null,
                state = KeptCopies.stateAfterRemoval(freed.state),
                originalMissing = true
            )
        )

        ReclaimEngine(target).onRestored(item)

        val back = db.items().byId(rowId)!!
        assertEquals(ItemState.DONE.name, back.state)
        assertFalse(back.originalMissing)
        assertEquals(original.toString(), back.contentUri)
        assertEquals(seen(original).fingerprint, back.fingerprint)
    }

    /**
     * A restored row keeps its first light copy. Freeing it again wrote a
     * second one over keptUri, and the first became a photo nobody tracked:
     * optimised and uploaded again. It is used again instead, and a refusal
     * in the dialog leaves it where it was.
     */
    @Test
    fun freeingARestoredRowAgainReusesItsLightCopy() = runBlocking {
        val original = photo("reclaim_again.jpg", seed = 11)
        val copy = photo("reclaim_again.jpg", seed = 12)
        val sha = "ab".repeat(32)
        db.ledger().insert(
            LedgerRow(
                outputSha256 = sha,
                fingerprint = "againorig0000001",
                displayName = "reclaim_again.jpg",
                outputBytes = 1234L,
                evidence = Evidence.CONFIRMED_EXACT.name,
                confirmedAt = 1L
            )
        )
        val rowId = db.items().insert(
            row("reclaim_again.jpg", original, "againorig0000001").copy(
                keptUri = copy.toString(),
                outputSha256 = sha,
                evidence = Evidence.CONFIRMED_EXACT.name
            )
        )
        val result = finish(rowId, original, copy, ReclaimRules.Mode.REPLACE_WITH_LIGHT)
        ReclaimEngine(target).onRestored(db.reclaim().itemsOf(result.batchId).single())
        val restored = db.items().byId(rowId)!!
        assertEquals(copy.toString(), restored.keptUri)

        val engine = ReclaimEngine(target)
        val prepared = engine.prepare(
            listOf(restored), ReclaimRules.Mode.REPLACE_WITH_LIGHT,
            Options(keptInPlace = true), System.currentTimeMillis()
        )
        val pin = prepared.pinned[rowId]
        assertNotNull("the row must be offered: ${prepared.skipped}", pin)
        assertEquals("the first copy, not a second one", copy, pin!!.uri)
        assertTrue(pin.reused)
        assertTrue(pin.inPlace)

        engine.finish(
            prepared, emptySet(), ReclaimRules.Mode.REPLACE_WITH_LIGHT, trashed = true,
            now = System.currentTimeMillis()
        )
        assertTrue("a refusal must not delete the copy it did not make", exists(copy))
        assertEquals(copy.toString(), db.items().byId(rowId)!!.keptUri)
    }

    /**
     * 12.1 wrote in-place history under the original's fingerprint, before
     * the row moved to its copy. Restoring such a batch after the upgrade
     * found no row, and the original came back as a new photo to upload.
     */
    @Test
    fun aRestoreOfA121InPlaceBatchFindsItsRow() = runBlocking {
        val original = photo("reclaim_legacy.jpg", seed = 13)
        val copy = photo("reclaim_legacy.jpg", seed = 14)
        val copySeen = seen(copy)
        val rowId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(
                state = ItemState.FREED_KEPT.name,
                keptUri = copy.toString()
            )
        )
        val item = legacyHistory("reclaim_legacy.jpg", original)

        ReclaimEngine(target).onRestored(item)

        val back = db.items().byId(rowId)!!
        assertEquals(ItemState.DONE.name, back.state)
        assertEquals(original.toString(), back.contentUri)
        assertEquals(seen(original).fingerprint, back.fingerprint)
        assertEquals(copy.toString(), back.keptUri)
    }

    /** Two rows that could be it: neither is guessed at. */
    @Test
    fun aRestoreOfA121BatchThatMatchesTwoRowsTouchesNeither() = runBlocking {
        val original = photo("reclaim_twice.jpg", seed = 15)
        val ids = listOf(16, 17).map { seed ->
            val copy = photo("reclaim_twice.jpg", seed = seed)
            val s = seen(copy)
            db.items().insert(
                row(s.name, copy, s.fingerprint).copy(
                    state = ItemState.FREED_KEPT.name,
                    keptUri = copy.toString()
                )
            )
        }
        val before = ids.map { db.items().byId(it)!! }

        ReclaimEngine(target).onRestored(legacyHistory("reclaim_twice.jpg", original))

        assertEquals(before, ids.map { db.items().byId(it)!! })
    }

    /**
     * 12.1 kept the provider's DCIM count-up for an in-place copy, so the
     * row moved to "IMG_1235.jpg" while its history says "IMG_1234.jpg".
     * The copy carries the original's modified time, and that is what lets
     * the row be found; without it, the next number is the camera's next
     * photo, and nothing is touched.
     */
    @Test
    fun aRestoreOfA121CopyTheProviderNumberedFindsItsRowOnlyByItsTime() = runBlocking {
        val original = photo("IMG_1234.jpg", seed = 21)
        val modified = seen(original).modified
        val copy = photo("IMG_1235.jpg", seed = 22)
        val copySeen = seen(copy)
        val rowId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(
                state = ItemState.FREED_KEPT.name,
                keptUri = copy.toString(),
                dateModified = modified + 60
            )
        )
        val item = legacyHistory("IMG_1234.jpg", original)
        val before = db.items().byId(rowId)!!

        ReclaimEngine(target).onRestored(item)

        assertEquals(before, db.items().byId(rowId)!!)

        db.items().update(before.copy(dateModified = modified))
        ReclaimEngine(target).onRestored(item)

        val back = db.items().byId(rowId)!!
        assertEquals(ItemState.DONE.name, back.state)
        assertEquals(original.toString(), back.contentUri)
        assertEquals(seen(original).fingerprint, back.fingerprint)
        assertEquals(copy.toString(), back.keptUri)
    }

    /**
     * Once the restore points the row back at "IMG_1234.jpg", its copy
     * "IMG_1235.jpg" no longer carries the row's name. The scanner read it
     * as a stranger and queued an already light copy to be optimised and
     * uploaded again as a new photo.
     */
    @Test
    fun aRestored121RowStillKnowsItsNumberedCopyAtTheNextScan() = runBlocking {
        val original = photo("IMG_1234.jpg", seed = 26)
        val modified = seen(original).modified
        val copy = photo("IMG_1235.jpg", seed = 27)
        val copySeen = seen(copy)
        val rowId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(
                state = ItemState.FREED_KEPT.name,
                keptUri = copy.toString(),
                dateModified = modified,
                outputBytes = copySeen.size
            )
        )
        ReclaimEngine(target).onRestored(legacyHistory("IMG_1234.jpg", original, copySeen.size))
        assertEquals(original.toString(), db.items().byId(rowId)!!.contentUri)

        MediaScanner(target, db).scan()

        assertNull("the copy is not new work", db.items().byFingerprint(copySeen.fingerprint))
        assertEquals(rowId, db.items().byFingerprint(seen(original).fingerprint)?.id)
        assertEquals(copy.toString(), db.items().byId(rowId)!!.keptUri)
        assertEquals(ItemState.DONE.name, db.items().byId(rowId)!!.state)
    }

    /**
     * A copy remade from the original is not the size first staged, so the
     * restore's outputBytes no longer matched it, and the next scan sent
     * "IMG_1235.jpg" to Ente again as a new photo.
     */
    @Test
    fun aRestored121RowKnowsARemadeCopyByItsOwnSize() = runBlocking {
        val (original, copy) = numberedPair("IMG_1234.jpg", "IMG_1235.jpg")
        val copySeen = seen(copy)
        val staged = copySeen.size + 4096
        val rowId = db.items().insert(
            row(copySeen.name, copy, copySeen.fingerprint).copy(
                state = ItemState.FREED_KEPT.name,
                keptUri = copy.toString(),
                sizeBytes = copySeen.size,
                dateModified = copySeen.modified,
                outputBytes = staged
            )
        )
        ReclaimEngine(target).onRestored(legacyHistory("IMG_1234.jpg", original, staged))
        val back = db.items().byId(rowId)!!
        assertEquals(original.toString(), back.contentUri)
        assertEquals(copySeen.size, back.outputBytes)

        MediaScanner(target, db).scan()

        assertNull("the copy is not new work", db.items().byFingerprint(copySeen.fingerprint))
        assertEquals(copy.toString(), db.items().byId(rowId)!!.keptUri)
    }

    /** A file at the copy's address that does not count up is still a new photo. */
    @Test
    fun aRestoredRowDoesNotTakeAStrangersSizeAtItsCopysAddress() = runBlocking {
        val original = photo("IMG_1234.jpg", seed = 28)
        val other = photo("holiday.jpg", seed = 29)
        val otherSeen = seen(other)
        // Matched by the history's own fingerprint, so no count-up proof was needed.
        val rowId = db.items().insert(
            row(otherSeen.name, other, "legacyorig000001").copy(
                state = ItemState.FREED_KEPT.name,
                keptUri = other.toString(),
                dateModified = otherSeen.modified
            )
        )
        ReclaimEngine(target).onRestored(legacyHistory("IMG_1234.jpg", original))
        val back = db.items().byId(rowId)!!
        assertEquals(original.toString(), back.contentUri)
        assertEquals(1234L, back.outputBytes)

        MediaScanner(target, db).scan()

        assertNotNull("a stranger's file is queued", db.items().byFingerprint(otherSeen.fingerprint))
    }

    /** Two numbered copies with the original's time: neither is guessed at. */
    @Test
    fun aRestoreOfA121NumberedBatchThatMatchesTwoRowsTouchesNeither() = runBlocking {
        val original = photo("IMG_2000.jpg", seed = 23)
        val modified = seen(original).modified
        val ids = listOf("IMG_2001.jpg" to 24, "IMG_2002.jpg" to 25).map { (name, seed) ->
            val copy = photo(name, seed = seed)
            val s = seen(copy)
            db.items().insert(
                row(s.name, copy, s.fingerprint).copy(
                    state = ItemState.FREED_KEPT.name,
                    keptUri = copy.toString(),
                    dateModified = modified
                )
            )
        }
        val before = ids.map { db.items().byId(it)!! }

        ReclaimEngine(target).onRestored(legacyHistory("IMG_2000.jpg", original))

        assertEquals(before, ids.map { db.items().byId(it)!! })
    }

    /**
     * Under DCIM the provider renames a camera name the camera's way, not
     * with " (1)", and the copy was taken back as a stranger's file: Free up
     * in place freed nothing for most camera photos.
     */
    @Test
    fun anInPlaceCopyOfACameraPhotoKeepsANameThatBelongs() = runBlocking {
        for ((i, name) in listOf("IMG_20240101_123456.jpg", "IMG_1234.jpg").withIndex()) {
            val original = photo(name, seed = 18 + i)
            val fp = "cameraorig00000$i"
            val staged = File(target.cacheDir, "reclaim_staged_$i.jpg")
            staged.outputStream().use {
                MediaFixtures.makeBitmap(64, 64, seed = 30 + i)
                    .compress(Bitmap.CompressFormat.JPEG, 90, it)
            }
            val sha = staged.inputStream().use { Fingerprint.sha256(it) }
            val rowId = db.items().insert(
                row(name, original, fp).copy(
                    stagePath = staged.path,
                    outputSha256 = sha,
                    outputName = Fingerprint.outputName(name, fp, "jpg")
                )
            )

            val kept = ReclaimEngine(target).pinLightCopy(
                db.items().byId(rowId)!!, Options(keptInPlace = true), System.currentTimeMillis()
            )
            staged.delete()

            assertNotNull("$name: the copy must not be taken back", kept)
            assertTrue(kept!!.inPlace)
            val landed = seen(kept.uri).name
            assertTrue("$name landed as $landed", KeptCopies.belongsTo(landed, name, fp))
            assertEquals(kept.uri.toString(), db.items().byId(rowId)!!.keptUri)
        }
    }

    /**
     * Free up fully on a row whose copy is still in the upload folder: once
     * the row is FREED no folder pass reads it again, so the copy has to go
     * with the original, or it stays on the phone untracked forever.
     */
    @Test
    fun freeingAReleasedRowTakesItsUploadCopyWithIt() = runBlocking {
        val original = photo("reclaim_released.jpg", seed = 7)
        val uploadCopy = photo("reclaim_released__0123456789abcdef.jpg", seed = 8)
        val rowId = db.items().insert(
            row("reclaim_released.jpg", original, "releasedorig0001").copy(
                state = ItemState.RELEASED.name,
                outputUri = uploadCopy.toString(),
                outputBytes = 1234L,
                releasedAt = 1L
            )
        )

        val result = finish(rowId, original, null, ReclaimRules.Mode.FREE_UP_FULLY)

        assertEquals(1, result.done.size)
        val freed = db.items().byId(rowId)!!
        assertEquals(ItemState.FREED.name, freed.state)
        assertNull("the copy must not be left behind", freed.outputUri)
        assertEquals(GoneReason.APP_DELETED.name, freed.goneReason)
        assertFalse("the copy must be gone from the gallery", exists(uploadCopy))
        assertEquals(freed.sizeBytes + 1234L, result.freedBytes)
    }

    // ---- helpers ---------------------------------------------------------

    private fun photo(name: String, seed: Int): Uri =
        MediaFixtures.insertPhoto(target, name = name, width = 64, height = 64, seed = seed)

    /**
     * An original and its 12.1 numbered copy, which 12.1 stamped with the
     * original's modified time. MediaStore keeps it in seconds and takes it
     * from the file when it is published, so both files are written and
     * published back to back - a fixture that went through the full photo
     * helper (EXIF, then waiting for the scan) took seconds per file and
     * on Android 12 never landed in the same second. Written again, from
     * scratch, if a second boundary fell between the two.
     */
    private fun numberedPair(originalName: String, copyName: String): Pair<Uri, Uri> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return numberedPairOnDisk(originalName, copyName)
        val resolver = target.contentResolver
        val images = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        fun jpeg(seed: Int): ByteArray {
            val bitmap = MediaFixtures.makeBitmap(64, 64, seed)
            return ByteArrayOutputStream().also {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)
                bitmap.recycle()
            }.toByteArray()
        }
        fun pending(name: String): Uri = requireNotNull(
            resolver.insert(
                images,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "${MediaFixtures.TEST_ALBUM}/")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
            )
        ) { "MediaStore refused the fixture insert" }
        repeat(10) { i ->
            val originalBytes = jpeg(40 + i)
            val copyBytes = jpeg(60 + i)
            val original = pending(originalName)
            val copy = pending(copyName)
            resolver.openOutputStream(original)!!.use { it.write(originalBytes) }
            resolver.openOutputStream(copy)!!.use { it.write(copyBytes) }
            val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(original, publish, null, null)
            resolver.update(copy, publish, null, null)
            MediaFixtures.awaitIndexed(target, original, originalName)
            MediaFixtures.awaitIndexed(target, copy, copyName)
            val modified = seen(original).modified
            if (modified > 0L && modified == seen(copy).modified) return original to copy
            MediaFixtures.cleanUp(target)
        }
        throw AssertionError("$originalName and $copyName never shared a modified time")
    }

    /**
     * [numberedPair] on Android 9, where the media scanner takes a file's
     * modified time from the file itself: both are written into the album
     * with the same one before it reads them. Written again, from scratch, if
     * the phone would not take the time.
     */
    private fun numberedPairOnDisk(originalName: String, copyName: String): Pair<Uri, Uri> {
        @Suppress("DEPRECATION")
        val album = File(Environment.getExternalStorageDirectory(), MediaFixtures.TEST_ALBUM).apply { mkdirs() }
        repeat(10) { i ->
            val modified = System.currentTimeMillis()
            fun land(name: String, seed: Int): Uri {
                val file = File(album, name)
                val bitmap = MediaFixtures.makeBitmap(64, 64, seed)
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
                bitmap.recycle()
                file.setLastModified(modified)
                return MediaFixtures.scan(target, file, "image/jpeg")
                    ?: throw AssertionError("the media scanner never added $name")
            }
            val original = land(originalName, 40 + i)
            val copy = land(copyName, 60 + i)
            MediaFixtures.awaitIndexed(target, original, originalName)
            MediaFixtures.awaitIndexed(target, copy, copyName)
            val seenModified = seen(original).modified
            if (seenModified > 0L && seenModified == seen(copy).modified) return original to copy
            MediaFixtures.cleanUp(target)
        }
        throw AssertionError("$originalName and $copyName never shared a modified time")
    }

    private fun seen(uri: Uri): Seen =
        target.contentResolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED
            ),
            null, null, null
        )!!.use { c ->
            assertTrue("fixture $uri is not in MediaStore", c.moveToFirst())
            Seen(c.getString(0), c.getLong(1), c.getLong(2))
        }

    private fun exists(uri: Uri): Boolean =
        target.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null
        )?.use { it.count > 0 } ?: false

    private fun row(name: String, uri: Uri, fingerprint: String) = ItemRow(
        fingerprint = fingerprint,
        mediaStoreId = ContentUris.parseId(uri),
        contentUri = uri.toString(),
        displayName = name,
        sizeBytes = 3L * 1024 * 1024,
        dateModified = 1_600_000_000L,
        captureAt = 1_600_000_000_000L,
        mimeType = "image/jpeg",
        isVideo = false,
        bucket = "EnteSaverTest",
        state = ItemState.DONE.name,
        outputBytes = 1234L,
        updatedAt = 1L
    )

    /** A history entry as 12.1 wrote it: the original's own fingerprint, name and address. */
    private suspend fun legacyHistory(name: String, original: Uri, optimisedBytes: Long = 1234L): ReclaimItemRow {
        val batchId = db.reclaim().insertBatch(
            ReclaimBatchRow(
                atMs = System.currentTimeMillis(),
                mode = ReclaimRules.Mode.REPLACE_WITH_LIGHT.name,
                itemCount = 1,
                freedBytes = 1L,
                trashed = true
            )
        )
        db.reclaim().insertItems(
            listOf(
                ReclaimItemRow(
                    batchId = batchId,
                    fingerprint = "legacyorig000001",
                    displayName = name,
                    album = "EnteSaverTest",
                    originalBytes = 3L * 1024 * 1024,
                    optimisedBytes = optimisedBytes,
                    contentUri = original.toString(),
                    trashed = true
                )
            )
        )
        return db.reclaim().itemsOf(batchId).single()
    }

    /** finish() as the dialog's answer drives it: [original] went, [pinned] is the copy. */
    private suspend fun finish(
        rowId: Long,
        original: Uri,
        pinned: Uri?,
        mode: ReclaimRules.Mode
    ): ReclaimEngine.Result {
        val row = db.items().byId(rowId)!!
        val prepared = ReclaimEngine.Prepared(
            uris = listOf(original),
            rows = listOf(row),
            pinned = pinned?.let { mapOf(rowId to ReclaimEngine.Pinned(it, inPlace = true)) }
                ?: emptyMap(),
            skipped = emptyList()
        )
        return ReclaimEngine(target).finish(
            prepared, setOf(original.toString()), mode, trashed = true,
            now = System.currentTimeMillis()
        )
    }
}
