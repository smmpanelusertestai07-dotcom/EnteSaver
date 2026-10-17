package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingStepsTest {

    @Test
    fun `the header number and the step list can never disagree`() {
        // The bug this guards: the header counted from a loop index while each
        // card carried its number in the copy, so "Step 6 of 7" sat above a
        // card headed "5.". One list, one number.
        for ((index, step) in OnboardingSteps.ALL.withIndex()) {
            assertEquals(index + 1, OnboardingSteps.humanNumber(step))
            assertEquals(step, OnboardingSteps.at(index))
        }
    }

    @Test
    fun `the total is the list, not a literal`() {
        assertEquals(OnboardingSteps.ALL.size, OnboardingSteps.TOTAL)
        assertEquals(OnboardingSteps.TOTAL, OnboardingSteps.humanNumber(OnboardingSteps.ALL.last()))
    }

    @Test
    fun `walking off either end stays inside the list`() {
        assertEquals(OnboardingSteps.ALL.first(), OnboardingSteps.previous(OnboardingSteps.ALL.first()))
        assertEquals(OnboardingSteps.ALL.last(), OnboardingSteps.next(OnboardingSteps.ALL.last()))
        assertEquals(OnboardingSteps.ALL.first(), OnboardingSteps.at(-5))
        assertEquals(OnboardingSteps.ALL.last(), OnboardingSteps.at(99))
    }

    @Test
    fun `setup starts at welcome and ends at the start button`() {
        assertEquals(OnboardingSteps.Step.WELCOME, OnboardingSteps.ALL.first())
        assertTrue(OnboardingSteps.isLast(OnboardingSteps.Step.READY))
    }

    @Test
    fun `albums come straight after the permission that makes them readable`() {
        // Asking which albums to back up before read access is granted would
        // show an empty list, which reads as "there are no albums".
        assertEquals(
            OnboardingSteps.Step.ALBUMS,
            OnboardingSteps.next(OnboardingSteps.Step.MEDIA)
        )
    }

    @Test
    fun `only the steps that touch someone's photos are mandatory`() {
        assertTrue(OnboardingSteps.isRequired(OnboardingSteps.Step.MEDIA))
        assertTrue(OnboardingSteps.isRequired(OnboardingSteps.Step.ALBUMS))
        // Everything else is a permission the app can run without, so it must
        // stay skippable - a setup that cannot be finished is a dead app.
        assertFalse(OnboardingSteps.isRequired(OnboardingSteps.Step.NOTIFICATIONS))
        assertFalse(OnboardingSteps.isRequired(OnboardingSteps.Step.BATTERY))
        assertFalse(OnboardingSteps.isRequired(OnboardingSteps.Step.USAGE))
        assertFalse(OnboardingSteps.isRequired(OnboardingSteps.Step.CLOUD))
        assertFalse(OnboardingSteps.isRequired(OnboardingSteps.Step.READY))
    }

    @Test
    fun `how space is saved is asked right after the albums, before anything happens to them`() {
        assertEquals(OnboardingSteps.Step.SAVE_MODE, OnboardingSteps.next(OnboardingSteps.Step.ALBUMS))
    }

    @Test
    fun `replacing in place never asks for usage access, copies do`() {
        val inPlace = OnboardingSteps.visible(SaveMode.IN_PLACE)
        assertFalse(OnboardingSteps.Step.USAGE in inPlace)
        assertEquals(OnboardingSteps.ALL - OnboardingSteps.Step.USAGE, inPlace)
        assertEquals(OnboardingSteps.ALL, OnboardingSteps.visible(SaveMode.COPIES))
        // Both still start at welcome and end at the start button.
        for (mode in SaveMode.entries) {
            assertEquals(OnboardingSteps.Step.WELCOME, OnboardingSteps.visible(mode).first())
            assertEquals(OnboardingSteps.Step.READY, OnboardingSteps.visible(mode).last())
        }
    }
}
