package app.entesaver

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.MediaStore
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.UiDevice
import app.entesaver.data.db.AppDb
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.MediaScanner
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walks the real UI on the device and photographs every screen, so the design
 * can be reviewed from CI artifacts after each change.
 *
 * It also asserts. The previous version wrapped every navigation step in
 * runCatching, which made it a tour rather than a test: two of its screens had
 * been looking in the wrong place for months - the calculator was expected on
 * Home when it is reached from Storage, and the largest-files list was
 * expected on Storage when it is reached from the Free up space hub - and the
 * suite passed the whole time. Nothing here is allowed to fail quietly now.
 */
private const val SHOT_DIR = "Pictures/CSTestShots/"

/** The album name MediaStore gives [SHOT_DIR], as the app sees it. */
private const val SHOT_ALBUM = "CSTestShots"

@RunWith(AndroidJUnit4::class)
class UiWalkthroughTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    @get:Rule
    val compose = createEmptyComposeRule()

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target: Context get() = instrumentation.targetContext
    private val device: UiDevice get() = UiDevice.getInstance(instrumentation)

    private fun s(id: Int): String = target.getString(id)

    private fun s(id: Int, vararg args: Any): String = target.getString(id, *args)

    @Before
    fun seedGallery() {
        // Several cards only exist once there is something to act on, so the
        // tour needs a real gallery behind it or it photographs empty states
        // and proves nothing about the screens that matter.
        MediaFixtures.cleanUp(target)
        runBlocking {
            AppDb.get(target).clearAllTables()
            for (i in 1..3) {
                MediaFixtures.insertPhoto(
                    target, name = "tour_photo_$i.jpg", seed = i, captureMillis = 1_600_000_000_000L
                )
            }
            MediaScanner(target, AppDb.get(target)).scan()
        }
    }

    @After
    fun clearGallery() {
        MediaFixtures.cleanUp(target)
        runBlocking { AppDb.get(target).clearAllTables() }
    }

    /**
     * Android 11+ hides /sdcard/Android/data from adb, so screenshots are
     * published through MediaStore into Pictures/CSTestShots, which adb can
     * pull. (The pipeline only ever looks at Pictures/CloudSaver, so these
     * never interfere with it.)
     */
    private fun publish(name: String, png: ByteArray) {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "$name.png")
            put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
            put(MediaStore.MediaColumns.RELATIVE_PATH, SHOT_DIR)
        }
        val collection = MediaStore.Images.Media
            .getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = target.contentResolver.insert(collection, values) ?: return
        target.contentResolver.openOutputStream(uri)?.use { it.write(png) }
    }

    private fun shoot(name: String) {
        compose.waitForIdle()
        device.waitForIdle()
        val temp = File(target.cacheDir, "$name.png")
        if (device.takeScreenshot(temp) && temp.exists()) {
            publish(name, temp.readBytes())
            temp.delete()
        }
    }

    /**
     * Taps the row called exactly this, scrolling to it first.
     *
     * Needed wherever a substring would match twice: Settings carries a
     * "Help and info" heading above its "Help" row, and openRow demands a
     * single match, so asking it for "Help" is an error - and asking a
     * heading to navigate does nothing at all.
     */
    private fun ComposeTestRule.openExactRow(label: String) {
        await(hasText(label), label)
        onAllNodes(hasText(label)).onFirst().performScrollTo().performClick()
        waitForIdle()
    }

    /** Scrolls a labelled row into view and taps it. Fails loudly if absent. */
    private fun ComposeTestRule.openRow(label: String) {
        val row = hasText(label, substring = true)
        // performScrollTo only reaches a node that already exists, and a lazy
        // list composes nothing it is not showing - so a row further down the
        // Files list is not merely off screen, it is absent from the tree and
        // no wait will conjure it. Ask the list to scroll to it by name first.
        // It is allowed to fail: on a screen with no list, or a row already in
        // view, there is nothing to do and the wait below reports the truth.
        runCatching { onAllNodes(hasScrollAction()).onFirst().performScrollToNode(row) }
        await(row, label)
        onNode(row).performScrollTo().performClick()
        waitForIdle()
    }

    /**
     * Waits for something before touching it.
     *
     * Every row this tour opens comes from a database query that runs off the
     * main thread, and `waitForIdle` returns as soon as composition is quiet -
     * which it is, drawing an empty list, while the query is still running.
     * On a quick emulator the first rows had usually landed by then and on a
     * slower one they had not, so the tour failed on a row that was about to
     * appear, differently on each Android version. Nothing here is asserting
     * that a screen is fast; it is asserting what the screen says. So it
     * waits.
     */
    private fun ComposeTestRule.await(matcher: SemanticsMatcher, what: String) {
        try {
            waitUntil(WAIT_MS) { onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
        } catch (e: ComposeTimeoutException) {
            // The timeout says only that a wait expired. Name the thing that
            // never arrived, so the next reader does not start from scratch.
            throw AssertionError("\"$what\" never appeared", e)
        }
    }

    /**
     * Asserts the label we expect to have landed on is on screen.
     *
     * onFirst matters: a tab's own name is drawn in the bar as well as on the
     * screen it opens, so "at most one node" is simply false for every tab in
     * the app. What is being asserted is that the label is present and
     * displayed, not that it is unique.
     */
    private fun ComposeTestRule.assertOn(label: String) {
        await(hasText(label, substring = true), label)
        onAllNodes(hasText(label, substring = true)).onFirst().assertIsDisplayed()
    }

    /**
     * Asserts a bottom-bar tab is the selected one.
     *
     * This is what "we navigated" actually means; finding the tab's text
     * proves only that the bar is drawn, which it always is.
     */
    private fun ComposeTestRule.assertTabSelected(label: String) {
        onNode(hasText(label) and isSelectable() and isSelected()).assertExists()
    }

    private fun setOnboardingDone(done: Boolean) = runBlocking {
        val repo = OptionsRepo.get(target)
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, done)
        repo.setInt(OptionsRepo.K.ONBOARDING_STEP, 0)
        // Two settings, one reason: the tour has to be looking at its own
        // three photographs and nothing else.
        //
        // Settings survive a test, because they are meant to survive a
        // restart, and a class earlier in the run leaves an album unticked on
        // purpose - so the scope is reset rather than inherited.
        //
        // And the tour publishes its screenshots into the gallery, because
        // that is the only folder adb can pull from. The app then inventories
        // them, correctly: they are images in Pictures, and it has no way to
        // know they are photographs of itself. By the middle of a run there
        // were more than twenty, all newer than the three fixtures, so they
        // filled the top of the Files list and pushed `tour_photo_1.jpg` off
        // the bottom of the screen - and a row a lazy list has not composed
        // does not exist to look for, however long anything waits for it.
        // Excluding that album is what a person would do with a folder they
        // did not want touched, and it also stops the tour photographing the
        // app offering to optimise its own screenshots.
        repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, setOf(SHOT_ALBUM))
    }

    private fun setTheme(mode: String) = runBlocking {
        OptionsRepo.get(target).setString(OptionsRepo.K.THEME, mode)
    }

    /**
     * Photographs the main screens with the dark palette forced on.
     *
     * Material 3 leaves LocalContentColor to Surface rather than to
     * MaterialTheme, so a missing one paints unstyled text black - which looks
     * perfectly fine in light mode and is invisible in dark. Only a dark-mode
     * shot catches that, and the emulator runs light by default.
     */
    @Test
    fun everyMainScreenRendersInDarkTheme() {
        setOnboardingDone(true)
        setTheme("DARK")
        try {
            ActivityScenario.launch(HostActivity::class.java).use {
                shoot("50-dark-home")
                compose.onNodeWithText(s(R.string.nav_storage)).performClick()
                compose.assertTabSelected(s(R.string.nav_storage))
                shoot("51-dark-storage")
                compose.onNodeWithText(s(R.string.nav_options)).performClick()
                shoot("52-dark-settings")
                compose.onNodeWithText(s(R.string.nav_files)).performClick()
                shoot("53-dark-files")
            }
        } finally {
            setTheme("SYSTEM")
        }
    }

    /** Renders the launcher icon itself so the logo can be reviewed too. */
    @Test
    fun appIconRenders() {
        val sizes = listOf(192, 432)
        for (size in sizes) {
            val drawable = target.getDrawable(R.mipmap.ic_launcher)!!
            val bitmap = Bitmap.createBitmap(
                size, size, Bitmap.Config.ARGB_8888
            )
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val bytes = ByteArrayOutputStream().also {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }.toByteArray()
            publish("00-app-icon-$size", bytes)
            bitmap.recycle()
        }
        // The Photos icon the icon pack and the shortcut give Ente, drawn the same way.
        val photos = target.getDrawable(R.mipmap.ic_shortcut_photos)!!
        val bitmap = Bitmap.createBitmap(432, 432, Bitmap.Config.ARGB_8888)
        photos.setBounds(0, 0, 432, 432)
        photos.draw(Canvas(bitmap))
        val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        publish("01-photos-icon-432", png)
        bitmap.recycle()
        // The monochrome layer must exist for themed icons on Android 13+.
        val mono = target.getDrawable(R.drawable.ic_launcher_monochrome)
        assertNotNull(mono)
    }

    @Test
    fun onboardingLooksRight() {
        setOnboardingDone(false)
        ActivityScenario.launch(HostActivity::class.java).use {
            shoot("10-onboarding-welcome")
            compose.onNodeWithText(s(R.string.onb_start)).performClick()
            compose.waitForIdle()
            shoot("11-onboarding-permission")
            // Media access is already granted by the rule, so the permission
            // step is satisfied and its continue button must be there.
            compose.onNodeWithText(s(R.string.onb_next)).performClick()
            compose.waitForIdle()
            shoot("12-onboarding-step")
        }
    }

    @Test
    fun everyMainScreenRenders() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            shoot("20-home")

            compose.onNodeWithText(s(R.string.nav_files)).performClick()
            compose.assertTabSelected(s(R.string.nav_files))
            shoot("21-files")

            compose.onNodeWithText(s(R.string.nav_storage)).performClick()
            compose.assertTabSelected(s(R.string.nav_storage))
            shoot("22-storage")

            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            shoot("23-settings-top")
            // Scroll through the long settings list to catch layout problems.
            compose.onAllNodes(hasText(s(R.string.opt_photos_hint))).onFirst()
                .performScrollTo().assertIsDisplayed()
            shoot("24-settings-quality")
            compose.openRow(s(R.string.opt_advanced_show))
            compose.onAllNodes(hasText(s(R.string.opt_space_hint))).onFirst()
                .performScrollTo().assertIsDisplayed()
            shoot("25a-settings-advanced")
            compose.onAllNodes(hasText(s(R.string.transfer_export), substring = true)).onFirst()
                .performScrollTo().assertIsDisplayed()
            shoot("25-settings-backup")
        }
    }

    /** The calculator is reached from Storage, not from Home. */
    @Test
    fun calculatorOpensFromStorage() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_storage)).performClick()
            compose.openRow(s(R.string.calc_title))
            compose.assertOn(s(R.string.calc_title))
            shoot("26-calculator")
        }
    }

    @Test
    fun activityScreenRenders() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            // Activity lives under Settings now, with the other reference
            // material, rather than competing for room on Home.
            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            compose.openRow(s(R.string.nav_activity))
            compose.assertOn(s(R.string.nav_activity))
            shoot("27-activity")
        }
    }

    @Test
    fun helpSectionIsReachableFromSettings() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            compose.onAllNodes(hasText(s(R.string.opt_group_help), substring = true)).onFirst()
                .performScrollTo().assertIsDisplayed()
            shoot("28-settings-help")
        }
    }

    /** The largest-files list is reached through the Free up space hub. */
    @Test
    fun largestFilesOpensFromTheFreeUpHub() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_storage)).performClick()
            compose.openRow(s(R.string.hub_title))
            compose.assertOn(s(R.string.hub_title))
            shoot("29a-free-space-hub")
            compose.openRow(s(R.string.find_biggest))
            compose.assertOn(s(R.string.find_biggest))
            shoot("29-biggest-space-users")
        }
    }

    @Test
    fun encryptedBackupDialogOpens() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            compose.openRow(s(R.string.opt_advanced_show))
            compose.openRow(s(R.string.transfer_export))
            shoot("30-backup-password-dialog")
        }
    }

    /**
     * The screens a tap opens, rather than the ones a tab does.
     *
     * Every defect this suite has caught by eye was on a screen it happened to
     * photograph, and the tour only ever photographed top-level screens. A
     * file's own details, a list with a selection running, and the page people
     * reach when they are worried are three of the places most worth looking
     * at, and none of them had a picture.
     */
    @Test
    fun theScreensBehindATapArePhotographedToo() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_files)).performClick()
            compose.waitForIdle()

            // A file's own details: sizes, what has been proved about it, and
            // the actions its current state allows.
            compose.openRow("tour_photo_1.jpg")
            compose.assertOn(s(R.string.detail_original))
            shoot("31-file-detail")
            compose.onNodeWithText(s(R.string.ok)).performClick()
            compose.waitForIdle()

            // A selection running, with the bar that says what it will act on.
            // The dialog above closes on an animation, so the row underneath
            // is waited for rather than assumed back.
            compose.await(hasText("tour_photo_1.jpg", substring = true), "the file row")
            compose.onNode(hasText("tour_photo_1.jpg"))
                .performScrollTo()
                .performTouchInput { longClick() }
            compose.waitForIdle()
            compose.assertOn(s(R.string.list_selected_count, 1))
            shoot("32-files-selection")
        }
    }

    /** The page someone opens when they think they have lost something. */
    @Test
    fun theIfSomethingIsDeletedPageIsPhotographed() {
        setOnboardingDone(true)
        ActivityScenario.launch(HostActivity::class.java).use {
            compose.onNodeWithText(s(R.string.nav_options)).performClick()
            compose.openExactRow(s(R.string.nav_help))
            compose.assertOn(s(R.string.help_deleted))
            compose.openExactRow(s(R.string.help_deleted))
            compose.assertOn(s(R.string.help_deleted))
            shoot("33-help-if-something-is-deleted")
        }
    }

    private companion object {
        /**
         * Long enough for a cold query on the slowest emulator in the matrix,
         * short enough that a screen which never draws still fails the run.
         */
        const val WAIT_MS = 15_000L
    }
}
