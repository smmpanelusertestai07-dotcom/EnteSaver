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
        val row = Stager.replaced(photo, "content://media/external/images/media/77", 900_000, "abc", now = 5)
        assertEquals(ItemState.FREED_KEPT.name, row.state)
        assertEquals(photo.contentUri, row.keptUri)
        assertEquals("content://media/external/images/media/77", row.backupUri)
        assertEquals("the saving counts from the original's size", 4_000_000L, row.sizeBytes)
        assertEquals(900_000L, row.outputBytes)
        assertEquals("the same name, not a copy's", photo.displayName, row.outputName)
        assertNull(row.stagePath)
        assertTrue(RowActions.Action.PUT_BACK in RowActions.forItem(row.toActionRow()))
    }

    @Test
    fun `a put-back original is left alone and is still known by its address`() {
        val replaced = Stager.replaced(photo, "content://media/external/images/media/77", 900_000, "abc", now = 5)
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
