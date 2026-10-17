package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeActionTest {

    private fun decide(
        queued: Int = 10,
        running: Boolean = false,
        paused: Boolean = false,
        thermalThrottled: Boolean = false,
        batteryPct: Int = 80,
        plugged: Boolean = false,
        freeBytes: Long = 20_000_000_000L,
        minFreeBytes: Long = 1_500_000_000L,
        waitReason: RunDecider.Wait = RunDecider.Wait.NONE,
        earlierApp: Boolean = false,
        needsFileAccess: Boolean = false,
        modifiedBuild: Boolean = false
    ) = HomeAction.decide(
        queued, running, paused, thermalThrottled, batteryPct, plugged,
        freeBytes, minFreeBytes, waitReason, earlierApp, needsFileAccess, modifiedBuild
    )

    @Test
    fun `replace on this phone blocks the button until it can run`() {
        // A run would stop at once; the button says why instead of starting it.
        val access = decide(needsFileAccess = true)
        assertFalse(access.enabled)
        assertEquals(HomeAction.Blocker.FILE_ACCESS, access.blocker)
        val modified = decide(needsFileAccess = true, modifiedBuild = true)
        assertFalse(modified.enabled)
        assertEquals("the reason no access can fix comes first", HomeAction.Blocker.MODIFIED_BUILD, modified.blocker)
        assertTrue("granted, it starts", decide(needsFileAccess = false).enabled)
    }

    @Test
    fun `blocked while the earlier Ente Saver is installed`() {
        // Every run stops at that gate; an enabled button would do nothing.
        val s = decide(earlierApp = true, waitReason = RunDecider.Wait.EARLIER_APP)
        assertEquals(HomeAction.Visibility.BUTTON, s.visibility)
        assertFalse(s.enabled)
        assertEquals(HomeAction.Blocker.EARLIER_APP, s.blocker)
        assertEquals(HomeAction.Note.BLOCKED, s.note)
    }

    @Test
    fun `offered when there is something to do`() {
        val s = decide()
        assertEquals(HomeAction.Visibility.BUTTON, s.visibility)
        assertTrue(s.enabled)
        assertEquals(HomeAction.Note.JUST_STARTS_IT, s.note)
    }

    @Test
    fun `hidden when the queue is empty`() {
        // A button whose only possible outcome is "nothing happened".
        assertEquals(HomeAction.Visibility.HIDDEN, decide(queued = 0).visibility)
    }

    @Test
    fun `hidden while paused`() {
        assertEquals(HomeAction.Visibility.HIDDEN, decide(paused = true).visibility)
    }

    @Test
    fun `a run in progress shows progress, not an action`() {
        val s = decide(running = true)
        assertEquals(HomeAction.Visibility.WORKING, s.visibility)
        assertFalse(s.enabled)
    }

    @Test
    fun `it overrides what the scheduler is waiting for`() {
        for (reason in listOf(
            RunDecider.Wait.NOT_CHARGING,
            RunDecider.Wait.SCREEN_ON,
            RunDecider.Wait.BUDGET_USED,
            RunDecider.Wait.PHOTO_CAP,
            RunDecider.Wait.BATTERY_SAVER
        )) {
            val s = decide(waitReason = reason)
            assertTrue(reason.name, s.enabled)
            assertEquals(reason.name, HomeAction.Note.OVERRIDES_WAITING, s.note)
        }
    }

    @Test
    fun `it never overrides a safety guard`() {
        val hot = decide(thermalThrottled = true)
        assertEquals(HomeAction.Blocker.TOO_HOT, hot.blocker)
        assertFalse(hot.enabled)
        assertEquals(HomeAction.Visibility.BUTTON, hot.visibility)

        val flat = decide(batteryPct = 9)
        assertEquals(HomeAction.Blocker.BATTERY_LOW, flat.blocker)
        assertFalse(flat.enabled)

        val full = decide(freeBytes = 200_000_000L, minFreeBytes = 1_500_000_000L)
        assertEquals(HomeAction.Blocker.NOT_ENOUGH_SPACE, full.blocker)
        assertFalse(full.enabled)
    }

    @Test
    fun `a charger makes a low battery a non-issue`() {
        val s = decide(batteryPct = 5, plugged = true)
        assertEquals(HomeAction.Blocker.NONE, s.blocker)
        assertTrue(s.enabled)
    }

    @Test
    fun `an unknown battery level does not block`() {
        // Zero means "not read yet", not "flat". Blocking on it would leave
        // the button permanently disabled on a device that reports nothing.
        assertEquals(HomeAction.Blocker.NONE, decide(batteryPct = 0).blocker)
    }

    @Test
    fun `heat wins over everything else`() {
        val s = decide(thermalThrottled = true, batteryPct = 5, freeBytes = 1)
        assertEquals(HomeAction.Blocker.TOO_HOT, s.blocker)
    }

    @Test
    fun `the verify link appears only when the app cannot check for itself`() {
        fun show(access: Boolean, removes: Boolean, graded: Boolean = false) =
            HomeAction.showVerifyLink(access, cloudRemovesItsUploads = removes, gradedInFolder = graded)
        assertTrue(show(access = false, removes = true))
        // Granted: the check is automatic, and a button implying otherwise
        // teaches people the automatic part does not work.
        assertFalse(show(access = true, removes = true))
        // Nothing to observe on a cloud that leaves its uploads in place.
        assertFalse(show(access = false, removes = false))
        assertFalse(show(access = true, removes = false))
        assertFalse(show(access = true, removes = false, graded = true))
    }

    @Test
    fun `the verify link appears with usage access when graded copies block proof`() {
        // An AGED or VERIFIED copy in the folder means Ente's traffic proves
        // nothing about any one file beside it; Ente's own free-up is the
        // one route to proof left, and it also empties the folder.
        assertTrue(HomeAction.showVerifyLink(true, cloudRemovesItsUploads = true, gradedInFolder = true))
        assertTrue(HomeAction.showVerifyLink(false, cloudRemovesItsUploads = true, gradedInFolder = true))
    }
}
