package app.entesaver

import android.content.Context
import android.os.Build
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.UiDevice
import app.entesaver.core.logic.OnboardingSteps
import app.entesaver.core.logic.OnboardingSteps.Step
import app.entesaver.core.logic.SaveMode
import app.entesaver.data.db.AppDb
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.UsageVerifier
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.ui.AppViewModel
import app.entesaver.util.Permissions
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The setup flow, driven end to end on a real device.
 *
 * Every control is found by the string the app itself ships, and every step is
 * asserted rather than photographed: if a label moves, a card stops rendering
 * or the header disagrees with [OnboardingSteps], the test fails here instead
 * of on someone's phone. Two of the cases below are regressions that were
 * reported by real users - the album detour that dumped people back at step 3,
 * and the album tick that did not survive a rotation.
 */
@RunWith(AndroidJUnit4::class)
class OnboardingE2eTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        *(TestPermissions.forThisDevice() + if (Build.VERSION.SDK_INT <= 29) arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) else emptyArray())
    )

    /** Composition's coroutines run on the main thread, as they do in the app: see HomeFilesE2eTest. */
    @get:Rule
    val compose = createEmptyComposeRule(effectContext = StandardTestDispatcher())

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val device: UiDevice get() = UiDevice.getInstance(instrumentation)

    private var scenario: ActivityScenario<HostActivity>? = null

    /** The album MediaFixtures writes into, as the picker will label it. */
    private val fixtureAlbum: String get() = MediaFixtures.TEST_ALBUM.substringAfterLast('/')

    private fun s(id: Int): String = context.getString(id)

    // ---- lifecycle ---------------------------------------------------------

    @Before
    fun setUp() {
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking {
            AppDb.get(context).clearAllTables()
            resetSetupState()
        }
        // The album step, the summary line and the trial card all say
        // something different when the gallery is empty, so setup is driven
        // against a gallery that really has an album in it.
        MediaFixtures.insertPhoto(
            context,
            name = "onboarding_fixture.jpg",
            seed = 11,
            captureMillis = 1_600_000_000_000L
        )
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        // Finishing setup schedules real background work; leaving it running
        // would have it scan and stage during whatever test runs next.
        TestPipeline.stopAndWait(context)
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking {
            AppDb.get(context).clearAllTables()
            resetSetupState(SaveMode.COPIES)
        }
    }

    /**
     * A new install's setup state: Replace on this phone, as a new install
     * starts - and, after the suite, Copies for Ente, which every other
     * suite is written against.
     */
    private suspend fun resetSetupState(mode: SaveMode = SaveMode.IN_PLACE) {
        val repo = OptionsRepo.get(context)
        repo.useDefaultFolders()
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, false)
        repo.setInt(OptionsRepo.K.ONBOARDING_STEP, 0)
        repo.setString(OptionsRepo.K.SAVE_MODE, mode.name)
        repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, emptySet())
    }

    private fun clearOutputFolder() {
        for (entry in OutputInventory(context).query().orEmpty()) {
            runCatching { context.contentResolver.delete(entry.uri, null, null) }
        }
        runCatching { File(context.getExternalFilesDir(null), "stage").deleteRecursively() }
    }

    private fun launch(): ActivityScenario<HostActivity> {
        scenario?.close()
        val launched = ActivityScenario.launch(HostActivity::class.java)
        scenario = launched
        compose.waitForIdle()
        return launched
    }

    private fun stored(): Options = runBlocking { OptionsRepo.get(context).current() }

    // ---- the step model, read from the app's own list -----------------------

    private fun titleOf(step: Step): String = s(
        when (step) {
            Step.WELCOME -> R.string.onb0_title
            Step.MEDIA -> R.string.onb1_title
            Step.ALBUMS -> R.string.onb_albums_title
            Step.SAVE_MODE -> R.string.onb_save_title
            Step.NOTIFICATIONS -> R.string.onb2_title
            Step.BATTERY -> R.string.onb3_title
            Step.USAGE -> R.string.onb4_title
            Step.CLOUD -> R.string.onb5_title
            Step.READY -> R.string.onb_ready_title
        }
    )

    /** Counted over the steps the stored way of saving space shows, as the header counts them. */
    private fun counterOf(step: Step): String {
        val visible = OnboardingSteps.visible(stored().saveMode)
        return context.getString(R.string.onb_step_counter, visible.indexOf(step) + 1, visible.size)
    }

    /**
     * Waits for [step] to be the one on screen, and checks the three things
     * that must hold on every card: the header counts this step the way
     * [OnboardingSteps] does, the position is stated exactly once, and the
     * card does not number itself in its own title.
     */
    private fun awaitStep(step: Step) {
        val counter = counterOf(step)
        val title = titleOf(step)
        compose.waitForIdle()
        compose.waitUntil(timeoutMillis = STEP_TIMEOUT) {
            compose.onAllNodesWithText(counter).fetchSemanticsNodes().size == 1 &&
                compose.onAllNodesWithText(title).fetchSemanticsNodes().size == 1
        }
        compose.onNodeWithText(title).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(counter).performScrollTo().assertIsDisplayed()
        assertFalse(
            "the card for $step numbers itself in its title: \"$title\"",
            title.any(Char::isDigit)
        )
        // Where setup is has to survive the app being killed, so the stored
        // position must follow the visible one on every move.
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            stored().onboardingStep == OnboardingSteps.indexOf(step)
        }
        assertEquals(
            "setup did not remember that it is on $step",
            OnboardingSteps.indexOf(step),
            stored().onboardingStep
        )
    }

    private fun tap(label: String) {
        compose.onNodeWithText(label).performScrollTo().performClick()
        compose.waitForIdle()
    }

    /**
     * The control that moves this step on by exactly one, without leaving the
     * app. Where the label depends on device state the precondition is
     * asserted first, so a wrong label is reported as the wrong label rather
     * than as a missing node.
     */
    private fun advanceFrom(step: Step) {
        when (step) {
            Step.WELCOME -> tap(s(R.string.onb_start))

            Step.MEDIA -> {
                assertEquals(
                    "the permission rule must give this test full media access",
                    Permissions.MediaAccess.FULL,
                    Permissions.mediaAccess(context)
                )
                tap(s(R.string.onb_next))
            }

            Step.ALBUMS -> tap(s(R.string.onb_albums_confirm))

            // Copies for Ente keeps the walk inside the app: Replace on this
            // phone sends the person to Android's All files access page
            // first (anInPlaceSetupSkipsUsageAccess walks that branch).
            Step.SAVE_MODE -> {
                tap(s(R.string.save_mode_copies))
                compose.waitUntil(timeoutMillis = STORE_TIMEOUT) { stored().saveMode == SaveMode.COPIES }
                tap(s(R.string.onb_next))
            }

            Step.NOTIFICATIONS -> {
                assertTrue(
                    "notifications must already be granted or this step opens a dialog",
                    Permissions.hasNotifications(context)
                )
                // Already allowed, there is nothing to allow: the button is
                // plain Next, and there is no Skip beside it.
                tap(s(R.string.onb_next))
            }

            Step.BATTERY -> tap(s(R.string.onb_next))

            // Not granted, the filled button opens the system usage-access
            // page and Skip is the one that stays in the app; granted, the
            // only button is Next.
            Step.USAGE -> tap(
                if (UsageVerifier.hasUsageAccess(context)) s(R.string.onb_next) else s(R.string.skip)
            )

            Step.CLOUD -> tap(s(R.string.onb_done_next))

            Step.READY -> tap(s(R.string.onb_ready_start))
        }
    }

    /** Walks from the first card to [target], asserting every card on the way. */
    private fun walkTo(target: Step) {
        var current = OnboardingSteps.ALL.first()
        awaitStep(current)
        while (current != target) {
            advanceFrom(current)
            current = OnboardingSteps.next(current)
            awaitStep(current)
        }
    }

    /**
     * Waits for the album list to arrive and returns it in the order the
     * picker renders it - which is the order [MediaScanner.buckets] returns,
     * the same call the screen makes.
     */
    private fun awaitAlbums(): List<String> {
        val albums = MediaScanner(context, AppDb.get(context)).buckets()
        assertTrue(
            "the fixture album must be offered in the picker, got $albums",
            fixtureAlbum in albums
        )
        compose.waitUntil(timeoutMillis = LOAD_TIMEOUT) {
            compose.onAllNodes(isToggleable()).fetchSemanticsNodes().size == albums.size
        }
        compose.onNodeWithText(s(R.string.folders_loading)).assertDoesNotExist()
        compose.onNodeWithText(fixtureAlbum).assertExists()
        return albums
    }

    /**
     * The tick box on the row for [album], found by the album it belongs to.
     *
     * It used to be "the nth toggleable on screen, where n is this album's
     * place in the list the database returned". That holds only while the two
     * orders agree and nothing else on the step can be toggled - and when it
     * stops holding, the failure is an assertion about the wrong row, which
     * reads as the app losing a tick it never had. The row is one toggleable
     * carrying the album's name, so it can simply be asked for by name.
     */
    /**
     * Waits for the row for [album] to settle on this state, then asserts it.
     *
     * A tick travels from the tap through the options store and back out as a
     * flow before the row can redraw, so reading the row one frame after the
     * tap is a race. This suite won that race every time until the machine had
     * two emulators and a compiler on it, and then lost it twice - which reads
     * as the app dropping a tick it had actually kept. The wait removes the
     * race; the assertion still produces the node dump when the state is
     * genuinely wrong.
     */
    private fun assertAlbumTick(album: String, on: Boolean) {
        val want = if (on) ToggleableState.On else ToggleableState.Off
        val deadline = System.currentTimeMillis() + STORE_TIMEOUT
        while (System.currentTimeMillis() < deadline) {
            compose.waitForIdle()
            val state = runCatching {
                albumTick(album).fetchSemanticsNode()
                    .config.getOrNull(SemanticsProperties.ToggleableState)
            }.getOrNull()
            if (state == want) return
            Thread.sleep(50)
        }
        if (on) albumTick(album).assertIsOn() else albumTick(album).assertIsOff()
    }

    private fun albumTick(album: String) =
        compose.onNode(isToggleable() and hasText(album, substring = true))

    // ---- the steps themselves ----------------------------------------------

    /**
     * Every card renders, and the header agrees with the one list of steps.
     *
     * "Step 6 of 7" once sat above a card headed "5." because the header
     * counted the loop index while the copy carried its own number. Both are
     * checked against [OnboardingSteps] here, on every card.
     */
    @Test
    fun everyStepRendersAndItsHeaderAgreesWithTheStepList() {
        launch()
        var current = OnboardingSteps.ALL.first()
        for ((index, step) in OnboardingSteps.ALL.withIndex()) {
            assertEquals(
                "the step list and the header cannot disagree",
                index + 1,
                OnboardingSteps.humanNumber(step)
            )
            assertEquals("walked off the step list", step, current)
            awaitStep(step)
            if (!OnboardingSteps.isLast(step)) {
                advanceFrom(step)
                current = OnboardingSteps.next(step)
            }
        }
        // The walk really did end on the summary, with the tap that starts
        // everything and nothing before it.
        compose.onNodeWithText(s(R.string.onb_ready_start))
            .performScrollTo()
            .assertIsDisplayed()
            .assertHasClickAction()
        assertFalse("nothing may start before the summary is confirmed", stored().onboardingDone)
    }

    /**
     * Replace on this phone, with Android's file access already given: the
     * step moves on with Next, and usage access - which only confirms
     * uploads from Ente Saver's folder - is never asked for.
     */
    @Test
    fun anInPlaceSetupSkipsUsageAccess() {
        if (Build.VERSION.SDK_INT >= 30) {
            InstrumentationRegistry.getInstrumentation().uiAutomation
                .executeShellCommand("appops set ${context.packageName} MANAGE_EXTERNAL_STORAGE allow")
                .close()
        }
        launch()
        val visible = OnboardingSteps.visible(SaveMode.IN_PLACE)
        assertFalse(Step.USAGE in visible)
        for ((index, step) in visible.withIndex()) {
            awaitStep(step)
            if (index == visible.lastIndex) break
            when (step) {
                Step.SAVE_MODE -> {
                    compose.waitUntil(timeoutMillis = STEP_TIMEOUT) {
                        compose.onAllNodesWithText(s(R.string.file_access_granted)).fetchSemanticsNodes().isNotEmpty()
                    }
                    tap(s(R.string.onb_next))
                }
                else -> advanceFrom(step)
            }
        }
        assertEquals(SaveMode.IN_PLACE, stored().saveMode)
    }

    /** Back walks the steps in reverse, one at a time, from the very last one. */
    @Test
    fun backFromEveryStepReturnsToTheOneBefore() {
        launch()
        walkTo(Step.READY)
        var current = Step.READY
        while (current != OnboardingSteps.ALL.first()) {
            val previous = OnboardingSteps.previous(current)
            tap(s(R.string.back))
            awaitStep(previous)
            current = previous
        }
    }

    /**
     * The first card has nowhere to go back to, so it offers no Back control
     * and the system gesture leaves the app rather than looping.
     */
    @Test
    fun theFirstStepHasNoBackControlAndSystemBackLeavesSetup() {
        val launched = launch()
        awaitStep(Step.WELCOME)
        compose.onNodeWithText(s(R.string.back)).assertDoesNotExist()

        device.pressBack()
        device.waitForIdle()
        // What "leaves the app" means depends on the Android. Up to 11, Back
        // on a task's root activity finishes it - the activity dies. From 12
        // (API 31) the system keeps the root launcher activity and moves the
        // whole task to the back instead, so a relaunch is instant - the
        // activity is stopped, not destroyed, and no code in the app decides
        // any of this. Both are the user leaving; neither is a trap. Holding
        // this test to DESTROYED on every version was holding Android 12's
        // documented behaviour against the app.
        val settled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setOf(Lifecycle.State.CREATED, Lifecycle.State.DESTROYED)
        } else {
            setOf(Lifecycle.State.DESTROYED)
        }
        val deadline = System.currentTimeMillis() + STEP_TIMEOUT
        while (System.currentTimeMillis() < deadline &&
            launched.state !in settled
        ) {
            device.waitForIdle()
        }
        assertTrue(
            "Back on the first setup card must leave the app, not trap the " +
                "user - the activity was still ${launched.state}",
            launched.state in settled
        )
        // Nothing was decided, so nothing was recorded.
        assertFalse(stored().onboardingDone)
        assertEquals(0, stored().onboardingStep)
    }

    /**
     * The reported bug, in its third form: correcting the albums from the
     * summary first dropped the user at step 3 for good, then became a
     * detour page that walked back. It is now not a navigation at all - the
     * chooser opens over the summary as a sheet, the correction is applied
     * in place, and closing the sheet leaves the user exactly where they
     * already were.
     */
    @Test
    fun choosingAlbumsFromTheSummaryHappensOnTheSummary() {
        launch()
        walkTo(Step.ALBUMS)
        val albums = awaitAlbums()

        // Untick everything, so the summary has something to complain about.
        tap(s(R.string.onb_albums_none))
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            stored().excludedBuckets.containsAll(albums)
        }

        advanceFrom(Step.ALBUMS)
        walkThroughRemainingStepsFrom(OnboardingSteps.next(Step.ALBUMS))
        awaitStep(Step.READY)

        // The summary says the setup would do nothing, and offers the fix.
        compose.onNodeWithText(s(R.string.onb_ready_no_albums))
            .performScrollTo()
            .assertIsDisplayed()
        val choose = compose.onAllNodesWithText(s(R.string.onb_ready_pick_albums))
        assertTrue(
            "the summary must offer the chooser",
            choose.fetchSemanticsNodes().isNotEmpty()
        )
        choose[0].performScrollTo().performClick()

        // The chooser is a sheet over this page, not another page: the grid
        // arrives with its Done button, and the stored position never moves
        // off the summary.
        awaitAlbums()
        compose.onNodeWithText(s(R.string.albums_sheet_done)).assertExists()
        assertEquals(OnboardingSteps.indexOf(Step.READY), stored().onboardingStep)

        // Inside the sheet nothing is walked to: the count row rides at the
        // top of the lazy grid - which performScrollTo does not support at
        // all - and the Done button is pinned under it, so both are already
        // on screen and are clicked where they stand.
        compose.onNodeWithText(s(R.string.onb_albums_all)).performClick()
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            stored().excludedBuckets.isEmpty()
        }
        compose.onNodeWithText(s(R.string.albums_sheet_done)).performClick()
        compose.waitForIdle()

        // Same page, corrected: the sheet is gone, the warning with it, and
        // nothing was walked back through.
        compose.waitUntil(timeoutMillis = STEP_TIMEOUT) {
            compose.onAllNodesWithText(s(R.string.albums_sheet_done))
                .fetchSemanticsNodes().isEmpty()
        }
        awaitStep(Step.READY)
        compose.onNodeWithText(s(R.string.onb_ready_no_albums)).assertDoesNotExist()
    }

    /**
     * Cancelling the correction - the system's own Back, exactly as a person
     * abandons a sheet - must leave the summary standing with nothing
     * changed and nowhere moved. The old detour turned this gesture into a
     * navigation of its own.
     */
    @Test
    fun dismissingTheAlbumSheetLeavesTheSummaryInPlace() {
        launch()
        walkTo(Step.ALBUMS)
        val albums = awaitAlbums()
        tap(s(R.string.onb_albums_none))
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            stored().excludedBuckets.containsAll(albums)
        }
        advanceFrom(Step.ALBUMS)
        walkThroughRemainingStepsFrom(OnboardingSteps.next(Step.ALBUMS))
        awaitStep(Step.READY)
        compose.onAllNodesWithText(s(R.string.onb_ready_pick_albums))[0]
            .performScrollTo()
            .performClick()
        awaitAlbums()
        compose.onNodeWithText(s(R.string.albums_sheet_done)).assertExists()

        device.pressBack()
        compose.waitUntil(timeoutMillis = STEP_TIMEOUT) {
            compose.onAllNodesWithText(s(R.string.albums_sheet_done))
                .fetchSemanticsNodes().isEmpty()
        }

        // Still on the summary, still complaining, nothing silently changed.
        awaitStep(Step.READY)
        compose.onNodeWithText(s(R.string.onb_ready_no_albums))
            .performScrollTo()
            .assertIsDisplayed()
        assertTrue(stored().excludedBuckets.containsAll(albums))
    }

    /**
     * The other reported bug: a tick survives the activity being recreated -
     * a rotation, a theme change, or Android rebuilding the process.
     */
    @Test
    fun aTickedAlbumStaysTickedAcrossActivityRecreation() {
        val launched = launch()
        walkTo(Step.ALBUMS)
        val albums = awaitAlbums()

        // Start from nothing ticked, then tick exactly the fixture album, so
        // the assertion is about a tick the user made and not about a default.
        tap(s(R.string.onb_albums_none))
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            stored().excludedBuckets.containsAll(albums)
        }
        assertAlbumTick(fixtureAlbum, on = false)

        albumTick(fixtureAlbum).performScrollTo().performClick()
        assertAlbumTick(fixtureAlbum, on = true)
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) {
            fixtureAlbum !in stored().excludedBuckets
        }

        launched.recreate()
        compose.waitForIdle()

        awaitStep(Step.ALBUMS)
        val afterAlbums = awaitAlbums()
        assertAlbumTick(fixtureAlbum, on = true)
        assertFalse(
            "the ticked album came back excluded after recreation",
            fixtureAlbum in stored().excludedBuckets
        )
        // And the albums the user left alone stayed left alone.
        for (album in afterAlbums.filter { it != fixtureAlbum }) {
            assertAlbumTick(album, on = false)
        }
    }

    /**
     * Finishing setup is remembered: the app opens on Home afterwards, not on
     * the welcome card.
     */
    @Test
    fun finishingSetupPersistsAndTheAppOpensOnHome() {
        launch()
        walkTo(Step.READY)
        assertFalse(stored().onboardingDone)

        tap(s(R.string.onb_ready_start))
        compose.waitUntil(timeoutMillis = STORE_TIMEOUT) { stored().onboardingDone }
        awaitHome()

        // The real check: a fresh activity, from cold.
        launch()
        awaitHome()
        compose.onNodeWithText(titleOf(Step.WELCOME)).assertDoesNotExist()
        // Not the tagline: setup and Home print the one app_tagline, so its
        // absence would be a claim about Home rather than about setup being
        // over. "Get started" exists on the welcome card and nowhere else.
        compose.onNodeWithText(s(R.string.onb_start)).assertDoesNotExist()
        assertTrue(stored().onboardingDone)
    }

    /**
     * "Try it on a few photos" is the cheapest possible answer to "what will
     * this do to my photos", so it has to be on the summary and usable
     * whenever the app can actually read the gallery.
     */
    @Test
    fun theTrialIsOfferedAndEnabledWhenMediaAccessIsFull() {
        launch()
        walkTo(Step.READY)
        assertEquals(
            Permissions.MediaAccess.FULL,
            Permissions.mediaAccess(context)
        )

        compose.onNodeWithText(s(R.string.trial_title)).performScrollTo().assertIsDisplayed()
        // Neither of the two cards that replace the offer may be showing.
        compose.onNodeWithText(s(R.string.trial_needs_access)).assertDoesNotExist()
        compose.onNodeWithText(s(R.string.trial_needs_albums)).assertDoesNotExist()

        // The button names the number it can really deliver, so accept any of
        // the labels the card is allowed to end up with.
        val runLabels = buildList {
            add(s(R.string.trial_run))
            for (n in 1..AppViewModel.TRIAL_SIZE) {
                add(context.resources.getQuantityString(R.plurals.trial_action, n, n))
            }
        }
        compose.waitUntil(timeoutMillis = STEP_TIMEOUT) {
            runLabels.any {
                compose.onAllNodesWithText(it).fetchSemanticsNodes().isNotEmpty()
            }
        }
        val shown = runLabels.first {
            compose.onAllNodesWithText(it).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(shown)
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
            .assertHasClickAction()
    }

    // ---- helpers -----------------------------------------------------------

    /** Presses on from [from] to the summary, asserting each card. */
    private fun walkThroughRemainingStepsFrom(from: Step) {
        var current = from
        awaitStep(current)
        while (!OnboardingSteps.isLast(current)) {
            advanceFrom(current)
            current = OnboardingSteps.next(current)
            awaitStep(current)
        }
    }

    private fun awaitHome() {
        compose.waitUntil(timeoutMillis = LOAD_TIMEOUT) {
            compose.onAllNodesWithText(s(R.string.nav_home)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(s(R.string.nav_home)).assertIsDisplayed()
        compose.onNodeWithText(s(R.string.nav_storage)).assertIsDisplayed()
    }

    private companion object {
        const val STEP_TIMEOUT = 10_000L
        const val STORE_TIMEOUT = 10_000L
        const val LOAD_TIMEOUT = 30_000L
    }
}
