package app.entesaver.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How the Free-up screens are wired to their view model.
 *
 * Read from the source, because each of these failed on a phone with no
 * crash and no message: the screen simply did the wrong thing quietly.
 */
class FreeUpWiringTest {

    private val main = File("src/main/kotlin/app/entesaver")
    private val vm = File(main, "ui/ReclaimViewModel.kt").readText()
    private val reclaim = File(main, "ui/screens/ReclaimScreen.kt").readText()
    private val findSpace = File(main, "ui/screens/FindSpaceScreens.kt").readText()

    /** A function's body, roughly: from its signature to the next declaration. */
    private fun body(source: String, function: String): String {
        val start = source.indexOf("fun $function(")
        assertTrue("$function() is gone", start >= 0)
        val next = Regex("""\n    (private )?(fun|val|var) """).find(source, start + 1)
        return source.substring(start, next?.range?.first ?: source.length)
    }

    @Test
    fun `every screen sends a system dialog's answer to the view model's router`() {
        // History once answered every dialog with the restore handler, so a
        // Free-up batch it happened to open trashed originals and was never
        // recorded. Each screen now hands the answer back undecided.
        for ((name, source) in listOf("ReclaimScreen" to reclaim, "FindSpaceScreens" to findSpace)) {
            assertFalse("$name answers a dialog itself", source.contains("rvm.onDialogResult("))
            assertFalse("$name answers a dialog itself", source.contains("rvm.onRestoreResult("))
        }
        assertTrue(reclaim.contains("rvm.onSystemDialogResult("))
        assertTrue(
            "Duplicates and History must both use the router",
            Regex("""rvm\.onSystemDialogResult\(""").findAll(findSpace).count() >= 2
        )
        assertTrue(vm.contains("private fun onDialogResult("))
        assertTrue(vm.contains("private fun onRestoreResult("))
    }

    @Test
    fun `every request is tagged with the flow that made it`() {
        val bare = vm.lines()
            .filter { it.contains("pendingIntent.value = ") && !it.contains("pendingIntent.value = null") }
            .map { it.trim() }
        assertTrue(
            "a request set without its flow cannot be routed: $bare",
            bare == listOf("pendingIntent.value = sender")
        )
        assertTrue(body(vm, "ask").contains("pendingIntent.value = sender"))
    }

    @Test
    fun `a batch cannot be started twice`() {
        val start = body(vm, "start")
        val launch = start.indexOf("viewModelScope.launch")
        val guard = start.indexOf("if (flowOpen()) return")
        val busy = start.indexOf("busy.value = true")
        assertTrue("start() has no re-entry guard", guard in 0 until launch)
        assertTrue("busy must be set on the tap, before the coroutine", busy in guard until launch)
        for (other in listOf("removeDuplicateExtras", "restore")) {
            assertTrue("$other() can overwrite a running flow", body(vm, other).contains("if (flowOpen()) return"))
        }
    }

    @Test
    fun `the buttons that start a batch wait while one is running`() {
        assertTrue(reclaim.contains("val working by rvm.busy.collectAsStateWithLifecycle()"))
        assertTrue(reclaim.contains("if (loading || working)"))
        assertTrue(
            "Trash and Delete must be off while a batch runs",
            Regex("""enabled = actionable > 0 && understood && !working""").findAll(reclaim).count() == 2
        )
        assertTrue(
            "the confirm sheet's Continue must be off while a batch runs",
            reclaim.substringAfter("confirmButton = {").take(300).contains("enabled = !working")
        )
    }

    @Test
    fun `optimise first never rewrites the capture date`() {
        val optimise = body(vm, "optimiseFirst")
        assertFalse("captureAt is the camera's date, not a queue position", optimise.contains("captureAt ="))
        // The same jump as Files' "Optimise first" and "Try again".
        assertTrue(optimise.contains("Stager.askedFirst(row, now)"))
        val appVm = File(main, "ui/AppViewModel.kt").readText()
        assertTrue(
            appVm.substringAfter("fun optimiseNow(id: Long)").substringBefore("\n    fun ")
                .contains("Stager.askedFirst(row, now)")
        )
        // No other view model may fake the date either.
        val offenders = File(main, "ui").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { Regex("""captureAt = (now|System\.currentTimeMillis)""").containsMatchIn(it.readText()) }
            .map { it.name }
            .toList()
        assertTrue("these overwrite a capture date: $offenders", offenders.isEmpty())
    }

    @Test
    fun `a group's box can untick the group`() {
        assertTrue(reclaim.contains("onValueChange = { tick -> rvm.tickGroup(key, tick) }"))
        assertFalse(vm.contains("fun selectGroup("))
    }

    @Test
    fun `copies-only is worded as removing copies`() {
        assertTrue(reclaim.contains("FreeUpFlow.buttonWording(mode, rvm.canUndoRemoval)"))
        assertTrue(reclaim.contains("FreeUpFlow.sheetWording(mode, permanent)"))
        assertTrue(reclaim.contains("R.string.reclaim_remove_copies"))
        assertTrue(reclaim.contains("R.plurals.reclaim_confirm_copies_body"))
    }

    @Test
    fun `history never offers a restore after the trash has been emptied`() {
        assertTrue(body(vm, "restore").contains("FreeUpFlow.trashExpired(batch.atMs"))
        assertTrue(vm.contains("batches.filterNot { FreeUpFlow.trashExpired(it.atMs, now) }"))
        assertTrue(findSpace.contains("if (batch.trashed && !expired && shown.isNotEmpty())"))
    }
}
