package app.entesaver

import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasNoClickAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.OutputLayout
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.OutputPaths
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.ThemeMode
import app.entesaver.data.EnteApp
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.ui.Lock
import app.entesaver.util.Formats
import app.entesaver.util.Volumes
import java.io.File
import kotlin.math.abs
import kotlinx.coroutines.flow.first
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

/** How long any single asynchronous step (DataStore write, navigation) may take. */
private const val UI_TIMEOUT = 15_000L

/**
 * Every control on the Settings screen, driven the way a person drives it.
 *
 * The rules this suite holds itself to, because a settings test that does not
 * hold them is decoration:
 *
 *  - Nothing is wrapped in runCatching. A control that cannot be found fails
 *    the test; that is the entire point of looking for it.
 *  - Labels come from the app's own resources, so renaming a string breaks the
 *    string, not the test.
 *  - Changing a setting is only half a pass. The other half is that the screen
 *    now says the new value, that OptionsRepo holds it, and that it is still
 *    there after the activity is destroyed and rebuilt.
 *
 * Two helpers do the heavy lifting, and both exist because of how this screen
 * is built. [nearest] picks the control that belongs to a given card: the
 * settings column is one flat semantics tree with no test tags, and several
 * cards offer literally the same segment label ("Unlimited" is on two cards,
 * "3 GB" on two more), so "the matching node closest to this card's hint" is
 * the only honest way to say which one is meant. [assertCardValue] reads the
 * value the collapsed card prints next to its title - the app's own promise
 * that "the value shown here is the same word the expanded control is
 * showing" - and checks it against the choice just made.
 */
@RunWith(AndroidJUnit4::class)
class SettingsE2eTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    /**
     * Empty, because the activity has to be launched *after* the options have
     * been seeded: HostActivity reads onboardingDone on its first frame, and a
     * rule that launches for us would launch before @Before runs.
     *
     * Composition's coroutines run on the main thread, as they do in the app
     * (see HomeFilesE2eTest). Left unconfined, an album cover that finished
     * loading on an IO thread recomposed the album picker there while it was
     * being dismissed - slowly enough on Android 9 to crash the recreate after.
     */
    @get:Rule
    val compose = createEmptyComposeRule(effectContext = StandardTestDispatcher())

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val device: UiDevice get() = UiDevice.getInstance(instrumentation)

    private var scenario: ActivityScenario<HostActivity>? = null

    // ---- lifecycle ---------------------------------------------------------

    @Before
    fun setUp() {
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking { AppDb.get(context).clearAllTables() }
        writeKnownOptions()
        // One real photo in a real album, so the album picker has something to
        // tick. Small on purpose: this suite is about controls, not encoding.
        MediaFixtures.insertPhoto(
            context,
            name = "settings_e2e_album.jpg",
            width = 640,
            height = 480,
            seed = 11
        )
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking { AppDb.get(context).clearAllTables() }
        // Settings are process-wide state; leaving this suite's choices behind
        // would silently change what every later test starts from.
        writeKnownOptions()
        EnteApp.assumeInstalledForTest = false
    }

    /** The starting point every test below asserts against. */
    private fun writeKnownOptions() = runBlocking {
        val repo = OptionsRepo.get(context)
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
        repo.useDefaultFolders()
        repo.setInt(OptionsRepo.K.ONBOARDING_STEP, 0)
        repo.setString(OptionsRepo.K.SCOPE, BackupScope.ALL.name)
        repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, emptySet())
        repo.setString(OptionsRepo.K.OUTPUT_MODE, OutputMode.SINGLE.name)
        repo.setString(OptionsRepo.K.CLOUD_SINGLE, EnteApp.ID)
        repo.setString(OptionsRepo.K.SPEED, SpeedMode.SMART.name)
        // Custom, so the three figures are on screen to be changed; the test
        // of Automatic switches it on itself.
        repo.setBool(OptionsRepo.K.SPACE_AUTO, false)
        repo.setInt(OptionsRepo.K.DAILY_CAP_MB, Defaults.DAILY_CAP_MB)
        repo.setInt(OptionsRepo.K.MIN_FREE_MB, Defaults.MIN_FREE_MB)
        repo.setInt(OptionsRepo.K.MAX_EXTRA_MB, Defaults.MAX_EXTRA_MB)
        repo.setString(OptionsRepo.K.THEME, ThemeMode.SYSTEM.name)
        repo.setBool(OptionsRepo.K.DYNAMIC_COLOR, false)
        repo.setString(OptionsRepo.K.STORAGE_VOLUME, "")
        repo.setBool(OptionsRepo.K.APP_LOCK, false)
        repo.setBool(OptionsRepo.K.WARNINGS_NOTIF, true)
        repo.setBool(OptionsRepo.K.PAUSE_ALL, false)
    }

    private fun clearOutputFolder() {
        for (entry in OutputInventory(context).query().orEmpty()) {
            context.contentResolver.delete(entry.uri, null, null)
        }
        File(context.getExternalFilesDir(null), "stage").deleteRecursively()
    }

    // ---- the tests ---------------------------------------------------------

    /** 1. Media type, and 2. Albums. */
    @Test
    fun mediaTypeAndAlbumSelectionChangeAndSurviveRecreate() {
        openSettings()
        showAdvanced()
        val hint = s(R.string.opt_scope_hint)

        assertCardValue(hint, s(R.string.scope_all))
        tap(segment(hint, s(R.string.scope_videos)))
        awaitOption("media type") { it.scope == BackupScope.VIDEOS }
        assertCardValue(hint, s(R.string.scope_videos))

        tap(segment(hint, s(R.string.scope_photos)))
        awaitOption("media type") { it.scope == BackupScope.PHOTOS }
        assertCardValue(hint, s(R.string.scope_photos))
        // Leaving one kind out says what that means for Ente.
        compose.onNodeWithText(s(R.string.scope_left_out_warning)).performScrollTo().assertIsDisplayed()

        // Albums. The button prints the current selection, so it is both the
        // control and the read-out.
        compose.onNodeWithText(s(R.string.folders_all)).performScrollTo().performClick()
        awaitNode(isCheckbox, "the album picker never listed a single album")
        val albums = compose.onAllNodes(isCheckbox).fetchSemanticsNodes().size
        assertTrue("the album picker must offer at least one album", albums >= 1)

        // Untick the first album. Which album it is does not matter; that it is
        // excluded, counted and stored does.
        compose.onAllNodes(isCheckbox)[0].assertIsOn().performClick()
        awaitOption("excluded albums") { it.excludedBuckets.size == 1 }
        compose.onAllNodes(isCheckbox)[0].assertIsOff()
        val excluded = options().excludedBuckets.single()

        // The button counts albums on the phone - "2 of 3 albums" - not the
        // stored list, which also holds folders the picker never shows.
        val total = MediaScanner(context, AppDb.get(context)).albums().size
        val oneOut = context.resources.getQuantityString(R.plurals.folders_included, total, total - 1, total)
        compose.onNodeWithText(s(R.string.ok)).performClick()
        compose.waitForIdle()
        compose.onNodeWithText(oneOut).performScrollTo().assertIsDisplayed()

        recreateAndOpenSettings()
        showAdvanced()
        assertEquals(PHOTOS_SHOULD_SURVIVE, BackupScope.PHOTOS, options().scope)
        assertEquals("the excluded album was lost", setOf(excluded), options().excludedBuckets)
        assertCardValue(hint, s(R.string.scope_photos))
        compose.onNodeWithText(oneOut).performScrollTo().assertIsDisplayed()

        // Put it back through the same dialog, so the control is proven in
        // both directions.
        compose.onNodeWithText(oneOut).performScrollTo().performClick()
        awaitNode(isCheckbox, "the album picker never listed a single album")
        compose.onAllNodes(isCheckbox)[0].performClick()
        awaitOption("excluded albums") { it.excludedBuckets.isEmpty() }
        compose.onNodeWithText(s(R.string.ok)).performClick()
        compose.waitForIdle()
        compose.onNodeWithText(s(R.string.folders_all)).performScrollTo().assertIsDisplayed()
    }

    /** 3. Upload folder layout, its confirmation, and the copy-path button. */
    @Test
    fun folderLayoutIsConfirmedBeforeItChanges() {
        openSettings()
        showAdvanced()
        val hint = s(R.string.opt_output_hint)

        compose.onNodeWithText(s(R.string.folder_pick_one)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(Defaults.OUTPUT_DIR).performScrollTo().assertIsDisplayed()

        // Cancelling must change nothing at all.
        tap(segment(hint, s(R.string.output_separate)))
        awaitNode(
            hasText(s(R.string.output_switch_title)),
            "changing the layout must ask first"
        )
        compose.onNodeWithText(s(R.string.cancel)).performClick()
        awaitNodeGone(hasText(s(R.string.output_switch_title)), "the layout dialog stayed up")
        assertEquals(
            "cancelling the layout dialog must not change the layout",
            OutputMode.SINGLE,
            options().outputMode
        )
        compose.onNodeWithText(s(R.string.folder_pick_one)).performScrollTo().assertIsDisplayed()

        // Confirming must change it, and the printed paths must follow.
        tap(segment(hint, s(R.string.output_separate)))
        awaitNode(hasText(s(R.string.output_switch_title)), "changing the layout must ask first")
        compose.onNodeWithText(s(R.string.output_switch_confirm)).performClick()
        awaitOption("folder layout") { it.outputMode == OutputMode.SEPARATE }
        awaitNodeGone(hasText(s(R.string.output_switch_title)), "the layout dialog stayed up")
        compose.onNodeWithText(s(R.string.folder_pick_two)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(Defaults.OUTPUT_DIR_PHOTOS).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(Defaults.OUTPUT_DIR_VIDEOS).performScrollTo().assertIsDisplayed()

        // The copy button, which is the only reason the paths are printed.
        val paths = OutputPaths.current(OutputLayout(OutputMode.SEPARATE))
        val clipboard =
            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        compose.onNodeWithText(
            context.resources.getQuantityString(R.plurals.copy_path, paths.size)
        ).performScrollTo().performClick()
        compose.waitUntil(UI_TIMEOUT) { clipboardText(clipboard) == paths.joinToString("\n") }
        assertEquals(
            "the copy button must put the exact folder paths on the clipboard",
            paths.joinToString("\n"),
            clipboardText(clipboard)
        )

        recreateAndOpenSettings()
        showAdvanced()
        assertEquals(OutputMode.SEPARATE, options().outputMode)
        compose.onNodeWithText(s(R.string.folder_pick_two)).performScrollTo().assertIsDisplayed()
    }

    /** 4. Ente Photos. */
    @Test
    fun enteCardOffersTheInstallPagesUntilEnteIsThere() {
        val hint = s(R.string.cloud_intended)
        // No emulator has Ente: the card says so and offers the three places
        // it is installed from, rather than a button that would do nothing.
        EnteApp.assumeInstalledForTest = false
        openSettings()
        assertCardValue(hint, s(R.string.cloud_not_installed_mark))
        for (label in listOf(R.string.ente_install_play, R.string.ente_install_fdroid, R.string.ente_install_web)) {
            compose.onNodeWithText(s(label)).performScrollTo().assertIsDisplayed()
        }
        compose.onNodeWithText(s(R.string.cl_ente)).performScrollTo().assertIsDisplayed()

        // Back from installing it: the card knows without being reopened.
        EnteApp.assumeInstalledForTest = true
        recreateAndOpenSettings()
        assertCardValue(hint, s(R.string.cloud_installed_mark))
        compose.onNodeWithText(context.getString(R.string.onb5_open, EnteApp.LABEL)).performScrollTo().assertIsDisplayed()
        assertEquals(0, compose.onAllNodesWithText(s(R.string.ente_install_play)).fetchSemanticsNodes().size)
    }

    /** 5. Speed, and 6. Daily upload limit. */
    @Test
    fun speedAndDailyLimitChangeAndSurviveRecreate() {
        openSettings()
        val speedHint = s(R.string.opt_speed_hint)
        val capHint = s(R.string.opt_daily_cap_hint)

        assertCardValue(speedHint, s(R.string.speed_smart))
        compose.onNodeWithText(s(R.string.speed_smart_note)).performScrollTo().assertIsDisplayed()

        tap(segment(speedHint, s(R.string.speed_charging)))
        awaitOption("speed") { it.speed == SpeedMode.CHARGING_ONLY }
        assertCardValue(speedHint, s(R.string.speed_charging))
        compose.onNodeWithText(s(R.string.speed_charging_note)).performScrollTo()
            .assertIsDisplayed()

        tap(segment(speedHint, s(R.string.speed_fast)))
        awaitOption("speed") { it.speed == SpeedMode.FAST }
        assertCardValue(speedHint, s(R.string.speed_fast))
        compose.onNodeWithText(s(R.string.speed_fast_note)).performScrollTo().assertIsDisplayed()

        // A named figure first...
        showAdvanced()
        val oneGb = Formats.mbLabel(1000)
        tap(segment(capHint, oneGb))
        awaitOption("daily limit") { it.dailyCapMb == 1000 }
        assertCardValue(capHint, oneGb)

        // ...then the one that has to carry a warning with it.
        tap(segment(capHint, s(R.string.unlimited)))
        awaitOption("daily limit") { it.dailyCapMb == -1 }
        assertCardValue(capHint, s(R.string.unlimited))
        compose.onNodeWithText(s(R.string.unlimited_warning)).performScrollTo()
            .assertIsDisplayed()

        recreateAndOpenSettings()
        showAdvanced()
        assertEquals(SpeedMode.FAST, options().speed)
        assertEquals(-1, options().dailyCapMb)
        assertCardValue(speedHint, s(R.string.speed_fast))
        assertCardValue(capHint, s(R.string.unlimited))
    }

    /** 7. The two space limits that sound alike. */
    @Test
    fun bothSpaceLimitsChangeIndependentlyAndSurviveRecreate() {
        openSettings()
        showAdvanced()
        val freeHint = s(R.string.space_min_free_body)
        val extraHint = s(R.string.space_max_extra_body)

        assertCardValue(freeHint, Formats.mbLabel(Defaults.MIN_FREE_MB))
        assertCardValue(extraHint, Formats.mbLabel(Defaults.MAX_EXTRA_MB))

        // Deliberately different values: these two cards offer the same chip
        // labels, so equal values would let a mix-up pass unnoticed.
        val free = Defaults.MIN_FREE_CHOICES_MB.last { it != Defaults.MIN_FREE_MB }
        val extra = Defaults.MAX_EXTRA_CHOICES_MB.first {
            it > 0 && it != Defaults.MAX_EXTRA_MB && it != free
        }
        tap(segment(freeHint, Formats.mbLabel(free)))
        awaitOption("minimum free space") { it.minFreeMb == free }
        assertCardValue(freeHint, Formats.mbLabel(free))
        assertEquals(
            "changing the phone-space limit must not touch the app's own limit",
            Defaults.MAX_EXTRA_MB,
            options().maxExtraMb
        )

        tap(segment(extraHint, Formats.mbLabel(extra)))
        awaitOption("space for our own copies") { it.maxExtraMb == extra }
        assertCardValue(extraHint, Formats.mbLabel(extra))
        assertEquals("the phone-space limit moved on its own", free, options().minFreeMb)

        // Each card states a live figure under the control; the numbers are the
        // device's, so only the labelled line is asserted.
        compose.onNode(hasText(placeholderPrefix(R.string.space_now_free), substring = true))
            .assertExists()
        compose.onNode(hasText(placeholderPrefix(R.string.space_now_using), substring = true))
            .assertExists()

        recreateAndOpenSettings()
        showAdvanced()
        assertEquals(free, options().minFreeMb)
        assertEquals(extra, options().maxExtraMb)
        assertCardValue(freeHint, Formats.mbLabel(free))
        assertCardValue(extraHint, Formats.mbLabel(extra))
    }

    /** 7a. Space limits follow the phone until someone picks their own. */
    @Test
    fun spaceLimitsFollowThePhoneUntilSetByHand() {
        runBlocking { OptionsRepo.get(context).setBool(OptionsRepo.K.SPACE_AUTO, true) }
        openSettings()
        showAdvanced()
        val hint = s(R.string.opt_space_hint)
        val switchLabel = s(R.string.space_auto_switch)

        // Automatic: nothing to pick, and the figures are the app's own.
        assertCardValue(hint, s(R.string.space_auto))
        switchNear(switchLabel).assertIsOn()
        compose.onNodeWithText(s(R.string.opt_daily_cap_hint)).assertDoesNotExist()

        // Custom puts the three figures on screen.
        tap(switchNear(switchLabel))
        awaitOption("space limits") { !it.spaceAuto }
        assertCardValue(hint, s(R.string.space_custom))
        awaitNode(hasText(s(R.string.opt_daily_cap_hint)), "Custom did not show the daily amount")

        recreateAndOpenSettings()
        showAdvanced()
        assertFalse("Custom was lost", options().spaceAuto)
        switchNear(switchLabel).assertIsOff()

        // And back to Automatic, through the same switch.
        tap(switchNear(switchLabel))
        awaitOption("space limits") { it.spaceAuto }
        awaitNodeGone(hasText(s(R.string.opt_daily_cap_hint)), "Automatic left the custom figures up")
    }

    /**
     * 7b. Storage location.
     *
     * The card only exists on a phone with more than one volume, so both
     * outcomes are asserted rather than one of them being skipped.
     */
    @Test
    fun storageLocationIsOfferedOnlyWhenThereIsAChoice() {
        val volumes = Volumes.list(context)
        openSettings()
        showAdvanced()

        if (volumes.size <= 1) {
            compose.onNodeWithText(s(R.string.opt_volume)).assertDoesNotExist()
            return
        }

        val hint = s(R.string.opt_volume_hint)
        awaitNode(hasText(s(R.string.opt_volume)), "a phone with two volumes must offer a choice")
        compose.onNodeWithText(s(R.string.opt_volume)).performScrollTo().assertIsDisplayed()
        segment(hint, s(R.string.volume_internal)).assertExists()

        // Moving between volumes applies to new files only, so it is confirmed.
        tap(segment(hint, s(R.string.volume_internal)))
        awaitNode(hasText(s(R.string.volume_switch_title)), "switching volume must ask first")
        compose.onNodeWithText(s(R.string.cancel)).performClick()
        awaitNodeGone(hasText(s(R.string.volume_switch_title)), "the volume dialog stayed up")
        assertEquals("cancelling must leave the volume alone", "", options().storageVolume)

        // A card that failed the writability probe is absent, not greyed, so
        // the second chip is only there when it can really be written to.
        val sdChips = compose
            .onAllNodes(hasText(s(R.string.volume_sd)) and hasClickAction())
            .fetchSemanticsNodes()
        if (sdChips.isEmpty()) {
            compose.onNodeWithText(s(R.string.volume_sd_unwritable)).assertIsDisplayed()
            return
        }
        val card = volumes.first { !it.isPrimary }.mediaVolumeName
        tap(segment(hint, s(R.string.volume_sd)))
        awaitNode(hasText(s(R.string.volume_switch_title)), "switching volume must ask first")
        compose.onNodeWithText(s(R.string.volume_switch_confirm)).performClick()
        awaitOption("storage volume") { it.storageVolume == card }
        compose.onNodeWithText(s(R.string.volume_sd_note)).performScrollTo().assertIsDisplayed()

        recreateAndOpenSettings()
        assertEquals(card, options().storageVolume)
    }

    /** 8. Optimisation: nothing to choose, what this phone will do, and the info button. */
    @Test
    fun optimisationSaysWhatThisPhoneDoesAndExplainsItself() {
        openSettings()
        val hint = s(R.string.opt_optimise_hint)
        assertCardValue(hint, s(R.string.optimise_value))
        // No preset to pick: every phone optimises one way. ("Custom" is
        // still a word on this screen - the space limits use it.)
        for (gone in listOf(R.string.preset_balanced, R.string.preset_smallest, R.string.preset_best)) {
            compose.onAllNodes(hasText(s(gone))).assertCountEquals(0)
        }
        compose.onNodeWithText(s(R.string.optimise_kept_whole)).performScrollTo().assertIsDisplayed()
        // Every video keeps its own codec, size and frame rate.
        compose.onNodeWithText(s(R.string.optimise_videos)).performScrollTo().assertIsDisplayed()
        // No emulator has an HEVC chip, or one for 4K, and the card says
        // what that means rather than quietly encoding in software.
        compose.onNodeWithText(s(R.string.video_hevc_none)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(s(R.string.video_4k_none)).performScrollTo().assertIsDisplayed()

        // The (i) beside it opens the page that explains it.
        compose.onAllNodesWithContentDescription(s(R.string.quality_explained_title))[0]
            .performScrollTo()
            .performClick()
        awaitNode(
            hasText(s(R.string.quality_explained_title)) and hasNoClickAction(),
            "the info button did not open the quality page"
        )
        compose.onNodeWithText(s(R.string.quality_looks_photo)).performScrollTo().assertIsDisplayed()
        awaitNodeGone(hasText(hint), "Settings stayed under the quality page")
        compose.onNodeWithContentDescription(s(R.string.back)).performClick()
        awaitNode(hasText(hint), "Back did not return to Settings")
    }

    /** 10. Theme, and the wallpaper-colours switch that lives inside it. */
    @Test
    fun everyThemeChoiceAndDynamicColourStick() {
        openSettings()
        val hint = s(R.string.opt_theme_hint)

        assertCardValue(hint, s(R.string.theme_system))

        tap(segment(hint, s(R.string.theme_light)))
        awaitOption("theme") { it.theme == ThemeMode.LIGHT }
        assertCardValue(hint, s(R.string.theme_light))

        tap(segment(hint, s(R.string.theme_dark)))
        awaitOption("theme") { it.theme == ThemeMode.DARK }
        assertCardValue(hint, s(R.string.theme_dark))

        tap(segment(hint, s(R.string.theme_system)))
        awaitOption("theme") { it.theme == ThemeMode.SYSTEM }
        assertCardValue(hint, s(R.string.theme_system))

        // Back to dark, so the value under test is not also the default.
        tap(segment(hint, s(R.string.theme_dark)))
        awaitOption("theme") { it.theme == ThemeMode.DARK }

        val dynamicLabel = s(R.string.theme_dynamic)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            // No wallpaper colours before Android 12, so no switch there that
            // would flip and change nothing.
            compose.onAllNodesWithText(dynamicLabel).assertCountEquals(0)
            recreateAndOpenSettings()
            assertEquals(ThemeMode.DARK, options().theme)
            assertCardValue(hint, s(R.string.theme_dark))
            return
        }
        switchNear(dynamicLabel).assertIsOff()
        tap(switchNear(dynamicLabel))
        awaitOption("wallpaper colours") { it.dynamicColor }
        switchNear(dynamicLabel).assertIsOn()

        recreateAndOpenSettings()
        assertEquals(ThemeMode.DARK, options().theme)
        assertTrue("wallpaper colours were lost", options().dynamicColor)
        assertCardValue(hint, s(R.string.theme_dark))
        switchNear(dynamicLabel).assertIsOn()

        // And off again, through the same control.
        tap(switchNear(dynamicLabel))
        awaitOption("wallpaper colours") { !it.dynamicColor }
        switchNear(dynamicLabel).assertIsOff()
    }

    /** 12. Alerts and 13. Pause - the two switches that toggle from the row. */
    @Test
    fun alertsAndPauseToggleFromTheRowAndSurviveRecreate() {
        openSettings()
        val alertsHint = s(R.string.opt_warnings_hint)
        val pauseHint = s(R.string.opt_pause_hint)

        switchNear(alertsHint).assertIsOn()
        switchNear(pauseHint).assertIsOff()

        // The whole card is the target for this one: SwitchCard promises that
        // tapping anywhere on the row toggles it.
        compose.onNode(hasText(alertsHint)).performScrollTo().performClick()
        awaitOption("alerts") { !it.warningsNotif }
        switchNear(alertsHint).assertIsOff()

        // ...and the switch itself for the other.
        tap(switchNear(pauseHint))
        awaitOption("pause") { it.pauseAll }
        switchNear(pauseHint).assertIsOn()

        recreateAndOpenSettings()
        assertFalse("alerts came back on by themselves", options().warningsNotif)
        assertTrue("the pause was lost", options().pauseAll)
        switchNear(alertsHint).assertIsOff()
        switchNear(pauseHint).assertIsOn()

        // Both back, through the same controls.
        tap(switchNear(alertsHint))
        awaitOption("alerts") { it.warningsNotif }
        switchNear(alertsHint).assertIsOn()
        compose.onNode(hasText(pauseHint)).performScrollTo().performClick()
        awaitOption("pause") { !it.pauseAll }
        switchNear(pauseHint).assertIsOff()
    }

    /**
     * 11. App lock.
     *
     * The lock proves identity before it is enabled, and both possible devices
     * are asserted: one with no screen lock must refuse and say why, one with a
     * screen lock must leave the setting off when the prompt is cancelled.
     * Either way, "on" is never reached by tapping alone - which is the whole
     * guarantee.
     */
    @Test
    fun appLockIsNeverEnabledWithoutProvingIdentity() {
        val canEnable = Lock.canEnable(context)
        openSettings()
        val hint = s(R.string.opt_lock_hint)

        switchNear(hint).assertIsOff()
        tap(switchNear(hint))

        if (canEnable) {
            // The system prompt is up; cancelling it must leave the gate shut.
            // Waited for explicitly - a Back sent before the prompt exists would
            // navigate the app instead, and prove nothing.
            val prompt = By.textContains(s(R.string.lock_title))
            assertTrue(
                "enabling the lock must ask the phone to prove who is holding it",
                device.wait(Until.hasObject(prompt), UI_TIMEOUT)
            )
            device.pressBack()
            assertTrue(
                "the lock prompt did not go away",
                device.wait(Until.gone(prompt), UI_TIMEOUT)
            )
            compose.waitForIdle()
        } else {
            awaitNode(
                hasText(s(R.string.lock_enable_needs_credential)),
                "a phone with no screen lock must be told why the lock cannot be enabled"
            )
        }

        assertFalse(
            "the app lock must not switch on until identity has been proved",
            options().appLock
        )
        switchNear(hint).assertIsOff()

        recreateAndOpenSettings()
        assertFalse("the app lock enabled itself across a recreate", options().appLock)
        switchNear(hint).assertIsOff()
    }

    /** 14. The list of files the user excluded, and its Clear button. */
    @Test
    fun excludedFilesCardCountsAndClears() {
        runBlocking {
            AppDb.get(context).items().insert(
                ItemRow(
                    fingerprint = "settings-e2e-excluded",
                    displayName = "excluded_by_user.jpg",
                    sizeBytes = 1_234_567,
                    dateModified = 0,
                    captureAt = 0,
                    mimeType = "image/jpeg",
                    isVideo = false,
                    state = ItemState.SKIP.name,
                    neverOptimise = true
                )
            )
        }
        openSettings()
        showAdvanced()

        val hint = s(R.string.never_optimise_hint)
        compose.onNodeWithText(s(R.string.never_optimise_title)).performScrollTo()
            .assertIsDisplayed()
        assertCardValue(hint, Formats.count(1))
        compose.onNodeWithText(
            context.resources.getQuantityString(R.plurals.never_optimise_count, 1, 1)
        ).performScrollTo().assertIsDisplayed()

        compose.onNodeWithText(s(R.string.never_optimise_clear)).performScrollTo().performClick()
        compose.waitUntil(UI_TIMEOUT) { neverOptimiseCount() == 0 }
        assertEquals("the excluded list was not cleared", 0, neverOptimiseCount())

        // With nothing excluded the card has no reason to exist any more.
        awaitNodeGone(
            hasText(s(R.string.never_optimise_title)),
            "the excluded-files card stayed after the list was cleared"
        )

        recreateAndOpenSettings()
        showAdvanced()
        compose.onNodeWithText(s(R.string.never_optimise_title)).assertDoesNotExist()
    }

    /**
     * 15/16. Save backup and Restore.
     *
     * Only as far as the password dialog: both buttons hand off to the system
     * document picker, and the encrypted round trip is covered elsewhere.
     */
    @Test
    fun savingABackupAsksForAPasswordAndCanBeAbandoned() {
        openSettings()
        showAdvanced()

        compose.onNodeWithText(s(R.string.transfer_import)).performScrollTo().assertIsEnabled()
        compose.onNodeWithText(s(R.string.transfer_export)).performScrollTo().performClick()

        awaitNode(hasText(s(R.string.backup_password_title)), "no password dialog appeared")
        compose.onNodeWithText(s(R.string.backup_password_body)).assertExists()
        compose.onNodeWithText(s(R.string.backup_password_lost_warning)).assertExists()
        // Export asks twice, so a typo cannot lock the file away for good.
        assertEquals(
            "the export dialog must ask for the password and its repeat",
            2,
            compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().size
        )
        assertTextAppears(s(R.string.backup_password_label))
        assertTextAppears(s(R.string.backup_password_confirm))
        // Nothing typed yet, so there is nothing to confirm.
        compose.onNodeWithText(s(R.string.ok)).assertIsNotEnabled()
        // The other button saves without a password; it is not a way out.
        compose.onNodeWithText(s(R.string.backup_password_skip)).assertIsEnabled()

        device.pressBack()
        awaitNodeGone(
            hasText(s(R.string.backup_password_title)),
            "Back did not close the password dialog"
        )
        // Abandoning must be exactly that: nothing saved, nothing changed.
        compose.onNodeWithText(s(R.string.transfer_export)).assertIsEnabled()
        assertEquals(
            "abandoning the backup dialog changed a setting",
            OutputMode.SINGLE,
            options().outputMode
        )
    }

    /** 17. Help. */
    @Test
    fun helpRowOpensHelpAndBackReturnsToSettings() {
        openSettings()
        compose.onNode(hasText(s(R.string.help_entry))).performScrollTo().performClick()

        awaitNode(hasText(s(R.string.help_faq)), "the Help row did not open Help")
        compose.onNodeWithText(s(R.string.help_deleted)).performScrollTo().assertIsDisplayed()
        awaitNodeGone(hasText(s(R.string.opt_optimise_hint)), "Settings stayed under Help")

        compose.onNodeWithContentDescription(s(R.string.back)).performClick()
        awaitNode(hasText(s(R.string.opt_optimise_hint)), "Back did not return to Settings")
        compose.onNodeWithText(s(R.string.options_footer)).performScrollTo().assertIsDisplayed()
    }

    /** 18. Activity. */
    @Test
    fun activityRowOpensActivityAndSystemBackReturnsToSettings() {
        openSettings()
        compose.onNode(hasText(s(R.string.activity_entry))).performScrollTo().performClick()

        awaitNode(
            hasText(s(R.string.activity_filter_all)),
            "the Activity row did not open Activity"
        )
        awaitNodeGone(hasText(s(R.string.opt_optimise_hint)), "Settings stayed under Activity")

        device.pressBack()
        awaitNode(hasText(s(R.string.opt_optimise_hint)), "Back did not return to Settings")
        compose.onNodeWithText(s(R.string.options_footer)).performScrollTo().assertIsDisplayed()
    }

    // ---- driving the app ---------------------------------------------------

    /** Launches the app (once per test) and lands on the Settings tab. */
    private fun openSettings() {
        if (scenario == null) {
            scenario = ActivityScenario.launch(HostActivity::class.java)
        }
        val tab = s(R.string.nav_options)
        compose.waitUntil(UI_TIMEOUT) {
            compose.onAllNodes(NavTabs.matcher(tab)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNode(NavTabs.matcher(tab)).performClick()
        awaitNode(hasText(s(R.string.opt_optimise_hint)), "the Settings screen never appeared")
    }

    /** Unfolds Advanced, where the settings most people never change live; nothing if it is open. */
    private fun showAdvanced() {
        if (compose.onAllNodes(hasText(s(R.string.opt_advanced_hide))).fetchSemanticsNodes().isEmpty()) {
            compose.onNodeWithText(s(R.string.opt_advanced_show)).performScrollTo().performClick()
        }
        awaitNode(hasText(s(R.string.opt_space_hint)), "Advanced did not open")
    }

    /** Destroys and rebuilds the activity, then comes back to Settings. */
    private fun recreateAndOpenSettings() {
        requireNotNull(scenario) { "the activity was never launched" }.recreate()
        openSettings()
    }

    // ---- finding controls --------------------------------------------------

    /**
     * The node matching [matcher] that is laid out closest to the card
     * identified by [hint].
     *
     * The settings column carries no test tags and repeats several segment
     * labels across cards, so proximity to the card's own hint line is what
     * says which control is meant. Everything on the screen is measured, even
     * the parts scrolled off, so this is exact rather than viewport-dependent.
     */
    private fun nearest(hint: String, matcher: SemanticsMatcher): SemanticsNodeInteraction {
        val anchor = compose.onNode(hasText(hint))
            .fetchSemanticsNode("exactly one node must carry the hint \"$hint\"")
            .positionInRoot.y
        val found = compose.onAllNodes(matcher).fetchSemanticsNodes()
        assertTrue(
            "nothing on the screen matches ${matcher.description}, wanted next to \"$hint\"",
            found.isNotEmpty()
        )
        var best = 0
        var bestGap = Float.MAX_VALUE
        found.forEachIndexed { index, node ->
            val gap = abs(node.positionInRoot.y - anchor)
            if (gap < bestGap) {
                bestGap = gap
                best = index
            }
        }
        return compose.onAllNodes(matcher)[best]
    }

    /** One segment of the chooser on the card identified by [hint]. */
    private fun segment(hint: String, label: String): SemanticsNodeInteraction =
        nearest(hint, hasText(label) and hasClickAction())

    /**
     * The switch belonging to [label] - either a SwitchCard's hint line or the
     * label of the plain switch row inside the theme card.
     */
    private fun switchNear(label: String): SemanticsNodeInteraction =
        nearest(label, isToggleable())

    private fun tap(node: SemanticsNodeInteraction) {
        node.performScrollTo().performClick()
    }

    // ---- assertions --------------------------------------------------------

    /**
     * Asserts that the card identified by [hint] prints [expected] as the
     * value next to its title.
     *
     * The value is a plain Text (the segments are the clickable nodes), and it
     * sits one line above the hint, so a node with the right text within a
     * line or two of the hint is that card's read-out and nothing else's.
     */
    private fun assertCardValue(hint: String, expected: String) {
        val anchor = compose.onNode(hasText(hint))
            .fetchSemanticsNode("exactly one node must carry the hint \"$hint\"")
            .positionInRoot.y
        val window = with(compose.density) { 64.dp.toPx() }
        val shown = compose.onAllNodes(hasText(expected) and hasNoClickAction())
            .fetchSemanticsNodes()
            .any { abs(it.positionInRoot.y - anchor) <= window }
        assertTrue(
            "the setting \"$hint\" does not show \"$expected\" as its current value",
            shown
        )
    }

    /** [text] is somewhere on screen - for text a dialog may lay out more than once. */
    private fun assertTextAppears(text: String) {
        assertTrue(
            "\"$text\" is not on the screen",
            compose.onAllNodes(hasText(text)).fetchSemanticsNodes().isNotEmpty()
        )
    }

    private fun awaitNode(matcher: SemanticsMatcher, why: String) {
        compose.waitUntil(UI_TIMEOUT) {
            compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()
        }
        assertTrue(why, compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty())
    }

    private fun awaitNodeGone(matcher: SemanticsMatcher, why: String) {
        compose.waitUntil(UI_TIMEOUT) {
            compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty()
        }
        assertTrue(why, compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty())
    }

    private fun awaitOption(what: String, predicate: (Options) -> Boolean) {
        compose.waitUntil(UI_TIMEOUT) { predicate(options()) }
        assertTrue("$what was never stored (options now: ${options()})", predicate(options()))
    }

    // ---- reading the app's own state ---------------------------------------

    private fun options(): Options = runBlocking { OptionsRepo.get(context).current() }

    private fun neverOptimiseCount(): Int =
        runBlocking { AppDb.get(context).items().neverOptimiseCountFlow().first() }

    private fun clipboardText(clipboard: ClipboardManager): String? =
        clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()

    private fun s(id: Int): String = context.getString(id)

    /** The fixed part of a string with a placeholder, for substring matching. */
    private fun placeholderPrefix(id: Int): String = context.getString(id, "").trim()

    private companion object {
        const val PHOTOS_SHOULD_SURVIVE = "the media type was lost across a recreate"

        val isCheckbox: SemanticsMatcher =
            SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Checkbox)
    }
}
