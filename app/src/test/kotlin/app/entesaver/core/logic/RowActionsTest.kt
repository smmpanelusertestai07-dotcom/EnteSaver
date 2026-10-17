package app.entesaver.core.logic

import app.entesaver.core.logic.RowActions.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RowActionsTest {

    private fun row(
        state: ItemState,
        evidence: Evidence = Evidence.NONE,
        neverOptimise: Boolean = false,
        originalMissing: Boolean = false,
        originalKept: Boolean = false
    ) = RowActions.Row(state, evidence, neverOptimise, originalMissing, originalKept)

    @Test
    fun `a waiting file can be pushed forward or skipped`() {
        val actions = RowActions.forItem(row(ItemState.NEW))
        assertEquals(
            listOf(Action.OPEN, Action.OPTIMISE_FIRST, Action.NEVER_OPTIMISE),
            actions
        )
    }

    @Test
    fun `an optimised copy is never offered never-optimise`() {
        // The work is done, so the option could not undo anything. Offering it
        // is what made a phone show three optimised files and two in the
        // folder with no way to tell why.
        for (state in listOf(ItemState.STAGED, ItemState.RELEASED, ItemState.DONE)) {
            val actions = RowActions.forItem(row(state))
            assertFalse(
                "$state must not offer never-optimise",
                Action.NEVER_OPTIMISE in actions
            )
            assertFalse("$state must not offer optimise-first", Action.OPTIMISE_FIRST in actions)
        }
    }

    @Test
    fun `remove from phone appears only with per-file proof`() {
        assertFalse(
            Action.REMOVE_FROM_PHONE in RowActions.forItem(
                row(ItemState.DONE, Evidence.NONE)
            )
        )
        assertFalse(
            "an aged guess is not proof",
            Action.REMOVE_FROM_PHONE in RowActions.forItem(row(ItemState.DONE, Evidence.AGED))
        )
        assertFalse(
            "a size match alone is not per-file proof",
            Action.REMOVE_FROM_PHONE in RowActions.forItem(row(ItemState.DONE, Evidence.VERIFIED))
        )
        assertTrue(
            Action.REMOVE_FROM_PHONE in RowActions.forItem(
                row(ItemState.DONE, Evidence.CONFIRMED_EXACT)
            )
        )
        assertTrue(
            Action.REMOVE_FROM_PHONE in RowActions.forItem(
                row(ItemState.DONE, Evidence.CONFIRMED_PACED)
            )
        )
    }

    @Test
    fun `a skipped file can be retried, or skipped for good`() {
        val actions = RowActions.forItem(row(ItemState.SKIP))
        assertEquals(listOf(Action.OPEN, Action.TRY_AGAIN, Action.NEVER_OPTIMISE), actions)
    }

    @Test
    fun `a file the user skipped for good offers the way back`() {
        val actions = RowActions.forItem(row(ItemState.NEW, neverOptimise = true))
        assertTrue(Action.ALLOW_AGAIN in actions)
        assertFalse(Action.NEVER_OPTIMISE in actions)
        assertFalse("a skipped file is not queued ahead", Action.OPTIMISE_FIRST in actions)
    }

    @Test
    fun `a missing original can only be looked at`() {
        assertEquals(
            listOf(Action.OPEN),
            RowActions.forItem(
                row(ItemState.DONE, Evidence.CONFIRMED_EXACT, originalMissing = true)
            )
        )
    }

    @Test
    fun `an already reclaimed file offers nothing further`() {
        assertEquals(listOf(Action.OPEN), RowActions.forItem(row(ItemState.FREED)))
        assertEquals(listOf(Action.OPEN), RowActions.forItem(row(ItemState.FREED_KEPT)))
    }

    @Test
    fun `a file replaced on this phone can be put back while its original is kept`() {
        assertEquals(
            listOf(Action.OPEN, Action.PUT_BACK),
            RowActions.forItem(row(ItemState.FREED_KEPT, originalKept = true))
        )
        // Past its 30 days, or deleted: there is nothing to put back.
        assertEquals(listOf(Action.OPEN), RowActions.forItem(row(ItemState.FREED_KEPT, originalKept = false)))
        // And never for a file that is not on the phone any more.
        assertEquals(
            listOf(Action.OPEN),
            RowActions.forItem(row(ItemState.FREED_KEPT, originalMissing = true, originalKept = true))
        )
        // Nor, by a stray flag, for any other state.
        for (state in ItemState.entries - ItemState.FREED_KEPT) {
            assertFalse("$state", Action.PUT_BACK in RowActions.forItem(row(state, originalKept = true)))
        }
    }

    @Test
    fun `a mixed selection splits into eligible and skipped, with the counts`() {
        // CC6.1: five selected, two already optimised - the bar must offer
        // "Optimise 3 of 5" and name the two it skips.
        val rows = listOf(
            1L to row(ItemState.NEW),
            2L to row(ItemState.NEW),
            3L to row(ItemState.SKIP),
            4L to row(ItemState.RELEASED),
            5L to row(ItemState.DONE)
        )
        val split = RowActions.splitForOptimise(rows)
        assertEquals(listOf(1L, 2L, 3L), split.eligibleIds)
        assertEquals(3, split.eligible)
        assertEquals(2, split.skipped)
    }

    @Test
    fun `zero eligible means the action is hidden, and the split says so`() {
        // CC6.2: hidden, not greyed - a control that can do nothing for this
        // selection is absent.
        val rows = listOf(
            1L to row(ItemState.RELEASED),
            2L to row(ItemState.DONE)
        )
        assertEquals(0, RowActions.splitForOptimise(rows).eligible)
    }

    /**
     * How the Free up bar decides, written the way the screen writes it: a
     * row may be removed exactly when forItem offers REMOVE_FROM_PHONE. The
     * screen asks that question directly, so the test asks it directly too -
     * a helper that restated the rule and that nothing called would prove
     * nothing about what the bar actually does.
     */
    private fun removable(rows: List<RowActions.Row>): Int =
        rows.count { Action.REMOVE_FROM_PHONE in RowActions.forItem(it) }

    @Test
    fun `free up offers removal only where there is per-file proof`() {
        // CC6.3: the same rule, for removal.
        val rows = listOf(
            row(ItemState.DONE, Evidence.CONFIRMED_EXACT),
            row(ItemState.DONE, Evidence.NONE),
            row(ItemState.DONE, Evidence.CONFIRMED_PACED)
        )
        assertEquals(2, removable(rows))
        assertFalse(
            Action.REMOVE_FROM_PHONE in RowActions.forItem(row(ItemState.DONE, Evidence.NONE))
        )
    }

    @Test
    fun `removal ignores what has no proof, is gone, or is already reclaimed`() {
        val rows = listOf(
            row(ItemState.DONE, Evidence.CONFIRMED_EXACT),
            row(ItemState.DONE, Evidence.CONFIRMED_PACED),
            row(ItemState.DONE, Evidence.NONE),
            row(ItemState.FREED, Evidence.CONFIRMED_EXACT),
            row(ItemState.DONE, Evidence.CONFIRMED_EXACT, originalMissing = true)
        )
        assertEquals(2, removable(rows))
    }
}
