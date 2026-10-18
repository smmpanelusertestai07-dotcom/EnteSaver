package app.entesaver.media

import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.KeptCopies
import app.entesaver.core.logic.RowActions
import app.entesaver.data.db.ItemRow
import app.entesaver.ui.screens.toActionRow
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a row says about a file replaced on this phone, and about one whose
 * original was put back - the two moments the file at the item's address
 * changes under it. Both must leave the scanner knowing that file as the
 * row's own, or it is read as a new photo, optimised again and uploaded as
 * a second one.
 */
class InPlaceRowsTest {

    private val photo = ItemRow(
        id = 3,
        fingerprint = "fp-IMG_1234.jpg",
        contentUri = "content://media/external/images/media/42",
        displayName = "IMG_1234.jpg",
        sizeBytes = 4_000_000,
        dateModified = 1,
        captureAt = 1_000,
        mimeType = "image/jpeg",
        isVideo = false,
        state = ItemState.STAGED.name
    )

    @Test
    fun `a replaced file is the row's own by its address, and keeps the original's size`() {
        val row = Stager.replaced(photo, "content://media/external/images/media/77", 900_000, "abc", "orig", now = 5)
        assertEquals(ItemState.FREED_KEPT.name, row.state)
        assertEquals(photo.contentUri, row.keptUri)
        assertEquals("content://media/external/images/media/77", row.backupUri)
        assertEquals("the saving counts from the original's size", 4_000_000L, row.sizeBytes)
        assertEquals(900_000L, row.outputBytes)
        assertEquals("the same name, not a copy's", photo.displayName, row.outputName)
        assertEquals("the kept original's hash, which Put back checks", "orig", row.originalSha256)
        assertNull(row.stagePath)
        assertTrue(RowActions.Action.PUT_BACK in RowActions.forItem(row.toActionRow()))
    }

    @Test
    fun `a put-back original is left alone and is still known by its address`() {
        val replaced = Stager.replaced(photo, "content://media/external/images/media/77", 900_000, "abc", "orig", now = 5)
        val back = Stager.putBack(replaced, now = 9)
        assertEquals(ItemState.SKIP.name, back.state)
        assertEquals(Stager.PUT_BACK, back.skipReason)
        assertTrue("never queued again on its own", back.neverOptimise)
        assertEquals("the scanner keeps reading it as this row's", photo.contentUri, back.keptUri)
        assertEquals("no original kept apart any more", "", back.backupUri)
        assertNull("nothing of the copy stays on the row", back.outputBytes)
        assertNull(back.outputSha256)
        assertNull(back.outputName)
        // The way back is the ordinary one, and there is nothing left to put back.
        val actions = RowActions.forItem(back.toActionRow())
        assertTrue(RowActions.Action.ALLOW_AGAIN in actions)
        assertFalse(RowActions.Action.PUT_BACK in actions)
        // Whatever size the original has, the scanner matches it by name at
        // the row's address, so the rewritten file is never a new photo.
        assertTrue(KeptCopies.isRowsCopy("IMG_1234.jpg", 4_000_000, back.displayName, back.fingerprint, back.outputBytes))
    }

    @Test
    fun `a put back restored without its address keeps the scanner's link to the file`() {
        // A row restored from the daily snapshot has no content address,
        // only the kept one; putting the original back must not lose that.
        val restored = Stager.replaced(photo, "content://media/external/images/media/77", 900_000, "abc", "orig", now = 5)
            .copy(contentUri = null)
        assertEquals(photo.contentUri, Stager.putBack(restored, now = 9).keptUri)
    }

    @Test
    fun `a replace recovery gave up on keeps its original on record, and only Put back is offered`() {
        val stuck = Stager.stuck(photo, "content://media/external/images/media/77", "orig", "restore_failed", now = 7)
        assertEquals(ItemState.SKIP.name, stuck.state)
        assertEquals(Stager.IN_PLACE_FAILED, stuck.skipReason)
        assertEquals("restore_failed", stuck.lastError)
        assertEquals("content://media/external/images/media/77", stuck.backupUri)
        assertEquals("orig", stuck.originalSha256)
        assertEquals("still the row's own file to the scanner", photo.contentUri, stuck.keptUri)
        assertEquals(
            listOf(RowActions.Action.OPEN, RowActions.Action.PUT_BACK),
            RowActions.forItem(stuck.toActionRow())
        )
    }

    @Test
    fun `a dropped copy leaves the row waiting with nothing of the copy`() {
        val staged = photo.copy(
            stagePath = "/data/stage/x.jpg", outputBytes = 1, outputSha256 = "s", outputName = "x.jpg",
            srcPixels = 4, outPixels = 2, presetUsed = "p", codecUsed = "c", predictedBytes = 3, lastError = "e"
        )
        val back = Stager.unstaged(staged, now = 11)
        assertEquals(ItemState.NEW.name, back.state)
        assertNull(back.stagePath)
        assertNull(back.outputBytes)
        assertNull(back.outputSha256)
        assertNull(back.outputName)
        assertEquals(0L, back.srcPixels)
        assertEquals(0L, back.predictedBytes)
        assertNull(back.lastError)
    }

    @Test
    fun `a file changed in the last hour waits before it is replaced`() {
        val now = 1_700_000_000_000L
        assertTrue(Stager.tooFresh(now / 1000 - 60, now))
        assertFalse(Stager.tooFresh(now / 1000 - 2 * 3600, now))
        assertFalse("a date ahead of now is a wrong clock, not a fresh file", Stager.tooFresh(now / 1000 + 3600, now))
        assertFalse("no date at all is not fresh", Stager.tooFresh(0, now))
    }

    @Test
    fun `a file replaced on this phone is never offered as a light copy to remove`() {
        // Remove deletes the file at the row's address. For a light copy that
        // is a spare; for a file replaced on this phone it is the only one.
        val dao = File("src/main/kotlin/app/entesaver/data/db/Db.kt").readText()
        assertTrue(dao.contains("WHERE keptUri IS NOT NULL AND backupUri IS NULL ORDER BY captureAt DESC"))
        assertTrue(dao.contains("FROM items WHERE keptUri IS NOT NULL AND backupUri IS NULL\")\n    fun keptBytesFlow()"))
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        assertTrue(vm.contains("keptCopies.value = db.items().keptLightCopies()"))
        assertFalse(vm.contains("keptCopies.value = db.items().keptCopies()"))
    }

    @Test
    fun `a modified build replaces nothing and deletes no kept original`() {
        val worker = File("src/main/kotlin/app/entesaver/work/CompressWorker.kt").readText()
        assertTrue(worker.contains("TamperCheck.isModified(app) -> RunDecider.Wait.MODIFIED_BUILD"))
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        val delete = vm.substringAfter("fun deleteKeptOriginals(").substringBefore("viewModelScope.launch")
        assertTrue(delete.contains("TamperCheck.isModified(ctx)"))
    }
}
