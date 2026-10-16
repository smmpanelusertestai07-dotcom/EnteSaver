package app.entesaver

import android.content.Context
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.CapacityMath
import app.entesaver.core.logic.ItemState
import app.entesaver.data.EnteApp
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.media.PlannedEncode
import app.entesaver.media.Releaser
import app.entesaver.media.Stager
import app.entesaver.ui.components.ListTags
import app.entesaver.util.Formats
import app.entesaver.util.Storage
import app.entesaver.util.Volumes
import java.io.File
import java.util.Locale
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** How long any one piece of UI is given to appear before the test fails. */
private const val UI_TIMEOUT = 20_000L

/** How long a database side effect of a tap is given to land. */
private const val DB_TIMEOUT = 10_000L

/**
 * How long to wait between polls of the semantics tree.
 *
 * Reading it synchronises with the main thread, so a loop that spins on it
 * competes with the very device it is measuring - which on a software-emulated
 * Android is the difference between a test that waits and a test that times
 * out because nothing else could get a turn.
 */
private const val POLL_PAUSE = 50L

// Four fixtures with deliberately different sizes and dates, so "newest" and
// "largest" cannot accidentally be the same order and prove nothing.
private const val SMALL = "hf_one_small.jpg"
private const val MEDIUM = "hf_two_medium.jpg"
private const val LARGE = "hf_three_large.jpg"
private const val CLIP = "hf_four_clip.mp4"
private val FIXTURES = listOf(SMALL, MEDIUM, LARGE, CLIP)

private const val CAPTURE_BASE = 1_600_000_000_000L
private const val DAY = 86_400_000L

/**
 * Home, Files, Storage and the cloud calculator, driven on a real device
 * against a real gallery.
 *
 * The gallery is seeded with three photos of very different sizes and one
 * H.264 clip, the real scanner is run over them, and two of the photos are
 * taken through the real Stager and Releaser. Everything after that is
 * asserted against the database those steps produced - counts, orderings and
 * formatted sizes - so a screen that renders but lies fails here.
 *
 * Two deliberate choices about how this is written:
 *
 *  - Nothing is wrapped in runCatching. A control that cannot be found is a
 *    failure, not a step to skip. The suite it sits next to (UiWalkthroughTest)
 *    was a screenshot tour for exactly that reason.
 *  - Every label comes from [R.string] via [s], never from an English literal
 *    typed here, so a copy change breaks the test that asserts the copy rather
 *    than leaving it passing against words the app no longer says.
 *
 * The emulator's own gallery is not ours to control, so once the real scan has
 * been asserted to have found every fixture, the rows that are not fixtures are
 * dropped from the database. The scan is still the real scan; what follows is
 * simply deterministic.
 */
@RunWith(AndroidJUnit4::class)
class HomeFilesE2eTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    /**
     * Composition's coroutines run on the main thread, as they do in the app.
     *
     * Left at its default this rule runs every LaunchedEffect and produceState
     * on an unconfined test dispatcher, so a coroutine carries on on whichever
     * thread woke it: the Files thumbnails finish on an IO thread, the details
     * dialog's database read on Room's, and each then publishes its snapshot
     * changes from there. A dialog that has just been dismissed is off its
     * window but not yet taken apart, and Compose ran its invalidations inline
     * on that background thread while the main thread was dismantling the same
     * dialog - "Detected multithreaded access to SnapshotStateObserver", once,
     * on an API 35 emulator. A standard dispatcher queues those continuations
     * for the main thread, which drains them whenever the test waits for idle.
     */
    @get:Rule
    val compose = createEmptyComposeRule(effectContext = StandardTestDispatcher())

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val db get() = AppDb.get(context)

    private var scenario: ActivityScenario<HostActivity>? = null

    /** The album MediaFixtures writes into, as MediaStore labels it. */
    private val fixtureAlbum: String get() = MediaFixtures.TEST_ALBUM.substringAfterLast('/')

    private fun s(id: Int): String = context.getString(id)

    private fun s(id: Int, vararg args: Any): String = context.getString(id, *args)

    private fun plural(id: Int, quantity: Int, vararg args: Any): String =
        context.resources.getQuantityString(id, quantity, *args)

    // ---- lifecycle ---------------------------------------------------------

    @Before
    fun setUp() {
        TestPipeline.stopAndWait(context)
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking {
            db.clearAllTables()
            resetOptions()
        }
        seedAndProcessGallery()
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        // Tapping "Optimise now" enqueues real work; leaving it running would
        // have it compress during whatever test comes next.
        TestPipeline.stopAndWait(context)
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking { db.clearAllTables() }
        EnteApp.assumeInstalledForTest = false
    }

    /**
     * Every option this suite depends on, pinned.
     *
     * Preferences outlive clearAllTables, so a value left behind by another
     * suite - a finished onboarding, a paused queue, a chosen cloud app - would
     * quietly change which cards Home draws.
     */
    private suspend fun resetOptions() {
        val repo = OptionsRepo.get(context)
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
        repo.useDefaultFolders()
        repo.setBool(OptionsRepo.K.APP_LOCK, false)
        repo.setBool(OptionsRepo.K.PAUSE_ALL, false)
        repo.setBool(OptionsRepo.K.PLACEHOLDER_REMOVED, false)
        repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, emptySet())
        // No emulator has Ente on it. The debug build's stand-in treats it
        // as installed, so Home draws no "Ente is not installed" chip.
        EnteApp.assumeInstalledForTest = true
        repo.setString(OptionsRepo.K.CLOUD_SINGLE, EnteApp.ID)
        repo.setString(OptionsRepo.K.FIRST_CHAIN_STATE, "")
        repo.setString(OptionsRepo.K.WAIT_REASON, "NONE")
        repo.setString(OptionsRepo.K.STORAGE_VOLUME, "")
        repo.setInt(OptionsRepo.K.FOREIGN_FILES, 0)
        repo.setLong(OptionsRepo.K.LAST_RUN_AT, 0L)
    }

    /**
     * Puts real media in the gallery, runs the real scanner, then optimises and
     * releases two of the photos through the real pipeline.
     *
     * This leaves a database with two queued items and two in the upload
     * folder, which is what every counter, filter and sort below is measured
     * against.
     */
    private fun seedAndProcessGallery() = runBlocking {
        MediaFixtures.insertPhoto(
            context, name = SMALL, width = 400, height = 300, seed = 21,
            captureMillis = CAPTURE_BASE + 4 * DAY
        )
        MediaFixtures.insertPhoto(
            context, name = MEDIUM, width = 3000, height = 2000, seed = 22,
            captureMillis = CAPTURE_BASE + 3 * DAY
        )
        MediaFixtures.insertPhoto(
            context, name = LARGE, width = 6000, height = 4500, seed = 23,
            captureMillis = CAPTURE_BASE + 2 * DAY
        )
        // Every device that can record has an H.264 encoder and the emulator
        // ships the software one, so a null here is a real failure rather than
        // a reason to skip the video half of this suite.
        assertNotNull(
            "the device must be able to produce a test clip",
            MediaFixtures.insertVideo(
                context, name = CLIP, captureMillis = CAPTURE_BASE + DAY
            )
        )

        MediaScanner(context, db).scan()
        for (name in FIXTURES) {
            assertNotNull(
                "the scanner must have found $name",
                db.items().all().firstOrNull { it.displayName == name }
            )
        }
        // Anything the emulator already had in its gallery is not ours to
        // reason about, and every count below is exact.
        for (row in db.items().all()) {
            if (row.displayName !in FIXTURES) db.items().delete(row)
        }
        assertEquals("only the fixtures may remain", FIXTURES.size, db.items().all().size)

        val options = OptionsRepo.get(context).current()
        val stager = Stager(context, db)
        for (name in listOf(MEDIUM, LARGE)) {
            val queued = row(name)
            assertTrue("optimising $name failed", stager.stageOne(queued, options))
            val staged = row(name)
            val out = staged.outputBytes ?: 0L
            assertTrue(
                "the copy of $name ($out) must be smaller than the original " +
                    "(${staged.sizeBytes}) or the savings assertions mean nothing",
                out in 1 until staged.sizeBytes
            )
        }
        Releaser(context, db).releaseBatch(options, System.currentTimeMillis())
        // Counted over the fixtures rather than over the whole database. The
        // gallery on a test device is not only ours - the tour leaves a folder
        // of screenshots behind for CI to collect, and anything else the image
        // ships with is there too - so a global count says as much about what
        // else is on the phone as it does about this test. What is being
        // asserted is that these four files ended up in these four states.
        assertEquals(
            "the two optimised fixtures must be in the upload folder and the " +
                "other two still waiting, but the four are: " +
                FIXTURES.joinToString { "$it=${row(it).state}" },
            listOf(2, 2),
            listOf(
                FIXTURES.count { row(it).state == ItemState.NEW.name },
                FIXTURES.count { row(it).state == ItemState.RELEASED.name }
            )
        )
    }

    private fun clearOutputFolder() {
        for (entry in OutputInventory(context).query().orEmpty()) {
            runCatching { context.contentResolver.delete(entry.uri, null, null) }
        }
        runCatching { File(context.getExternalFilesDir(null), "stage").deleteRecursively() }
    }

    // ---- database helpers --------------------------------------------------

    private fun allRows(): List<ItemRow> = runBlocking { db.items().all() }

    private fun row(name: String): ItemRow =
        allRows().firstOrNull { it.displayName == name }
            ?: throw AssertionError("no database row for $name")

    /** The saved-bytes total exactly as Home's hero computes it. */
    private fun savedBytes(): Long = allRows().sumOf { r ->
        r.outputBytes?.let { (r.sizeBytes - it).coerceAtLeast(0L) } ?: 0L
    }

    private fun processedCount(): Int = allRows().count { it.outputBytes != null }

    private fun skippedCount(): Int =
        allRows().count { it.state == ItemState.SKIP.name && it.duplicateOf == null }

    // ---- launching and navigating -----------------------------------------

    /** Starts the app and waits until Home has actually drawn. */
    private fun launchHome(): ActivityScenario<HostActivity> {
        scenario?.close()
        val launched = ActivityScenario.launch(HostActivity::class.java)
        scenario = launched
        compose.waitForIdle()
        awaitNode(hasText(s(R.string.app_tagline)), "the Home screen")
        return launched
    }

    /**
     * Taps a bottom-bar tab.
     *
     * Not by the icon's content description: a bar item merges the
     * icon and the label into one node, and the node that lookup lands on has
     * no touch bounds of its own - every test in this class failed with
     * "failed to inject touch input" before its first assertion. The
     * selectable node carrying the label is the tab.
     */
    private fun openTab(labelRes: Int) {
        compose.onNode(NavTabs.matcher(s(labelRes))).performClick()
        compose.waitForIdle()
    }

    private fun openFiles() {
        openTab(R.string.nav_files)
        awaitNode(hasText(s(R.string.list_search)), "the Files search field")
        // The rows arrive from a database flow, so the list is waited for
        // rather than assumed to be there the moment the screen is - and it is
        // the list that is asked, not the screen. Waiting on a row being drawn
        // means waiting on it fitting, which on a shorter phone it never does.
        awaitRowInList(LARGE, "the Files list")
    }

    private fun openStorage() {
        openTab(R.string.nav_storage)
        awaitNode(hasText(s(R.string.storage_group_phone)), "the Storage screen")
    }

    // ---- assertion helpers -------------------------------------------------

    /** Waits for a node to exist, and says what was being waited for if it never does. */
    private fun awaitNode(matcher: SemanticsMatcher, what: String) {
        try {
            compose.waitUntil(timeoutMillis = UI_TIMEOUT) {
                compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (e: ComposeTimeoutException) {
            throw AssertionError("$what never appeared", e)
        }
    }

    /** Waits for a database change a tap was supposed to cause. */
    private fun awaitDb(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + DB_TIMEOUT
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            compose.waitForIdle()
        }
        throw AssertionError("$what never happened")
    }

    private fun assertShown(text: String, what: String) {
        awaitNode(hasText(text), "$what (\"$text\")")
        compose.onNodeWithText(text).assertIsDisplayed()
    }

    /** Scrolls a node into view inside a scrolling screen and asserts it is there. */
    private fun assertScrolledInto(text: String, what: String) {
        bringListContentIntoView(hasText(text))
        awaitNode(hasText(text), "$what (\"$text\")")
        compose.onNodeWithText(text).performScrollTo().assertIsDisplayed()
    }

    /**
     * If this screen has one of the framework's lists, scrolls it to this
     * content; if it has not, there is nothing to scroll and nothing to do.
     *
     * Rows are lazy, and so is anything the screen puts inside the list - the
     * "biggest files" summary is the list's own first item, so it scrolls away
     * with the rows and stops existing. Whatever asserts on such content has to
     * bring it back first rather than assume the list is still where it was.
     * A miss is left to the assertion that follows, which knows what it wanted
     * and can say so.
     */
    private fun bringListContentIntoView(matcher: SemanticsMatcher) {
        if (compose.onAllNodesWithTag(ListTags.ROWS).fetchSemanticsNodes().isEmpty()) return
        runCatching { compose.onNodeWithTag(ListTags.ROWS).performScrollToNode(matcher) }
        compose.waitForIdle()
    }

    /**
     * A node carrying this text somewhere inside it.
     *
     * For lines built from a string with placeholders whose values the test
     * cannot pin down to the byte - free space on the volume moves while the
     * test runs - the stable half is asserted rather than the whole line.
     */
    private fun assertShownContaining(text: String, what: String) {
        bringListContentIntoView(hasText(text, substring = true))
        awaitNode(hasText(text, substring = true), "$what (containing \"$text\")")
        compose.onAllNodes(hasText(text, substring = true))[0]
            .performScrollTo()
            .assertIsDisplayed()
    }

    /** One list row carries both its own name and this text. */
    private fun assertRowSays(name: String, text: String, what: String) {
        val matcher = hasText(name) and hasText(text)
        bringListContentIntoView(matcher)
        awaitNode(matcher, "$what on $name (\"$text\")")
        compose.onNode(matcher).assertIsDisplayed()
    }

    /**
     * The line starting with [lead] does not state the same size twice.
     *
     * "Cleaning Internal storage - 5.85 GB free now, about 5.85 GB after" is
     * what the hub printed whenever the saving was too small to move the
     * figure: a promise about a number, with the number unchanged. A sentence
     * that says a thing and then says it again has told the reader nothing,
     * and reads as the app being broken rather than as rounding.
     */
    private fun assertNoFigureIsStatedTwice(lead: String) {
        awaitNode(hasText(lead, substring = true), "the line about $lead")
        val line = compose.onAllNodes(hasText(lead, substring = true))
            .fetchSemanticsNodes()
            .firstNotNullOfOrNull { node ->
                node.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }
            }
            ?: throw AssertionError("the line about $lead has no text")
        val figures = Regex("""\d[\d.]*\s?(?:B|KB|MB|GB)\b""").findAll(line)
            .map { it.value }.toList()
        assertEquals(
            "\"$line\" states the same size twice, so it promises nothing",
            figures.distinct().size,
            figures.size
        )
    }

    private fun assertAbsent(text: String, why: String) {
        compose.waitForIdle()
        val found = compose.onAllNodesWithText(text).fetchSemanticsNodes().size
        assertEquals("$why - but \"$text\" is on screen", 0, found)
    }

    /** A metric tile announces itself as "label: value" and nothing else. */
    private fun assertTile(labelRes: Int, value: String) {
        val description = "${s(labelRes)}: $value"
        awaitNode(SemanticsMatcher.expectValue(
            SemanticsProperties.ContentDescription,
            listOf(description)
        ), "the \"$description\" tile")
        compose.onNodeWithContentDescription(description).performScrollTo().assertIsDisplayed()
    }

    /** No tile carries this label at all, whatever number it might hold. */
    private fun assertNoTile(labelRes: Int) {
        compose.waitForIdle()
        compose.onAllNodesWithContentDescription(s(labelRes), substring = true)
            .assertCountEquals(0)
    }

    /**
     * The named rows appear top to bottom in exactly this order.
     *
     * A sort change travels through a state flow before the list re-lays out,
     * so the order is waited for rather than read one frame after the tap - and
     * when it never arrives, the order that did is what the failure says.
     */
    private fun assertOrder(vararg names: String) {
        val expected = names.toList()
        var actual = emptyList<String>()
        val deadline = System.currentTimeMillis() + UI_TIMEOUT
        while (System.currentTimeMillis() < deadline) {
            compose.waitForIdle()
            Thread.sleep(POLL_PAUSE)
            actual = expected.sortedBy { indexInList(it) }
            if (actual == expected && expected.none { indexInList(it) < 0 }) return
        }
        throw AssertionError(
            "expected ${expected.joinToString(", ")} top to bottom, " +
                "but the list reads ${actual.joinToString(", ")}"
        )
    }

    /**
     * Exactly these fixtures are in the list, and none of the others.
     *
     * Filtering is debounced and asynchronous, so this waits for the list to
     * settle on the expected set instead of reading it mid-change - and names
     * what it actually found when it never does.
     */
    private fun assertVisibleRows(vararg names: String) {
        val expected = names.toSet()
        var actual = emptySet<String>()
        val deadline = System.currentTimeMillis() + UI_TIMEOUT
        while (System.currentTimeMillis() < deadline) {
            compose.waitForIdle()
            Thread.sleep(POLL_PAUSE)
            actual = FIXTURES.filter { indexInList(it) >= 0 }.toSet()
            if (actual == expected) return
        }
        throw AssertionError(
            "expected exactly ${names.toList()} in the list, found ${actual.toList()}"
        )
    }

    /**
     * Where the list puts this file, or -1 when it is not in the list at all.
     *
     * Asking the list rather than the screen is the whole point. A LazyColumn
     * composes only what fits, so a row below the fold has no node, no text and
     * no position - reading positions off the screen therefore reported a
     * four-row list as three rows on any device an inch shorter than the last
     * one, and scrolling to collect them could step straight over a row.
     *
     * Because the rows are keyed by their database id, the list can answer
     * directly: IndexForKey is the same semantics property performScrollToKey
     * is built on, it returns -1 for a key the list does not hold, and it needs
     * nothing to be on screen.
     */
    private fun indexInList(name: String): Int {
        // A list with nothing in it is replaced by its empty state, so there is
        // no container to ask. That is "no rows", not a broken test.
        val node = compose.onAllNodesWithTag(ListTags.ROWS).fetchSemanticsNodes()
            .singleOrNull() ?: return -1
        val indexForKey = node.config.getOrNull(SemanticsProperties.IndexForKey)
            ?: throw AssertionError("the list is not keyed, so it cannot be asked what it holds")
        return indexForKey(idOf(name))
    }

    /**
     * The database id the list keys this file by.
     *
     * Remembered because it is asked for inside polling loops and never
     * changes within a test: JUnit builds a fresh instance for each one and
     * the database is cleared around it, so there is nothing stale to carry.
     */
    private val rowIds = mutableMapOf<String, Long>()

    private fun idOf(name: String): Long = rowIds.getOrPut(name) { row(name).id }

    /**
     * Waits until the list holds this row, whether or not it is on screen.
     *
     * Which is not the same as waiting for its text. A LazyColumn composes only
     * the rows that fit, so a row below the fold has no node and no text, and
     * waiting for that text waits forever on a list that is already correct.
     * Whether a given row is below the fold depends on how tall the screen
     * happens to be: all four fixtures fit on a 1080x1920 emulator and the last
     * one does not fit on CI's, which is the entire difference between "passes
     * locally" and "fails every CI run".
     */
    private fun awaitRowInList(name: String, what: String) {
        val deadline = System.currentTimeMillis() + UI_TIMEOUT
        while (System.currentTimeMillis() < deadline) {
            compose.waitForIdle()
            Thread.sleep(POLL_PAUSE)
            if (indexInList(name) >= 0) return
        }
        throw AssertionError(
            "$what never appeared - the list holds " +
                FIXTURES.filter { indexInList(it) >= 0 }
        )
    }

    /**
     * Taps a row, having first scrolled the list to it.
     *
     * Tapping a node the list has scrolled past reaches Compose as "Failed to
     * inject touch input": the node exists in the tree but its centre is off
     * screen, so there is nowhere to put the finger. Scrolling first is what
     * every one of these taps was missing.
     */
    private fun tapRow(name: String) {
        scrollToRow(name)
        compose.onNodeWithText(name).performClick()
        compose.waitForIdle()
    }

    /** Long-presses a row, having first scrolled the list to it. */
    private fun longPressRow(name: String) {
        scrollToRow(name)
        compose.onNodeWithText(name).performTouchInput { longClick() }
        compose.waitForIdle()
    }

    /** Brings a row on screen, and fails loudly when the list does not hold it. */
    private fun scrollToRow(name: String) {
        compose.onNodeWithTag(ListTags.ROWS).performScrollToNode(hasText(name))
        compose.waitForIdle()
    }

    // ---- filter and sort sheets -------------------------------------------

    /**
     * Opens a filter chip and chooses one of its options.
     *
     * The chip carries the filter's own name until something is chosen, so it
     * is found by that name; the sheet that opens carries the same name as its
     * title, which is why the chip is tapped before the sheet exists.
     */
    private fun chooseFilter(nameRes: Int, option: String) {
        compose.onNodeWithText(s(nameRes)).performScrollTo().performClick()
        awaitNode(hasText(option), "the \"$option\" option in the ${s(nameRes)} sheet")
        compose.onNodeWithText(option).performClick()
        compose.waitForIdle()
    }

    /** The same, once the chip is already showing a chosen value. */
    private fun chooseFilterOn(nameRes: Int, currentValue: String, option: String) {
        val chip = "${s(nameRes)}: $currentValue"
        compose.onNodeWithText(chip).performScrollTo().performClick()
        awaitNode(hasText(option), "the \"$option\" option in the ${s(nameRes)} sheet")
        compose.onNodeWithText(option).performClick()
        compose.waitForIdle()
    }

    private fun assertChipReads(nameRes: Int, value: String) {
        assertShown("${s(nameRes)}: $value", "the ${s(nameRes)} chip")
    }

    // =======================================================================
    // Home
    // =======================================================================

    @Test
    fun homeShowsEveryCardAndItsCountersMatchTheSeededGallery() {
        val saved = savedBytes()
        val processed = processedCount()
        assertEquals("two files were optimised in setup", 2, processed)
        assertTrue("optimising must have saved something", saved > 0)

        launchHome()

        // The title card.
        assertScrolledInto(s(R.string.app_name), "the app name")
        assertScrolledInto(s(R.string.app_tagline), "the tagline")

        // The hero: the total, how many files it came from, and the photo half.
        // The photo figure equals the total because no video was optimised, so
        // the same string is drawn exactly twice.
        assertScrolledInto(s(R.string.hero_saved_label), "the hero's label")
        compose.onAllNodesWithText(Formats.bytes(saved)).assertCountEquals(2)
        assertScrolledInto(
            plural(R.plurals.hero_saved_sub, processed, processed),
            "the hero's file count"
        )
        assertScrolledInto(s(R.string.scope_photos), "the photos half of the hero")
        assertAbsent(
            s(R.string.scope_videos),
            "no video was optimised, so the hero must not show a videos figure"
        )

        // The status line is debounced, so it is waited for rather than read.
        assertScrolledInto(
            plural(R.plurals.status_working, 2, 2),
            "the hero's status line"
        )

        // The progress grid: one tile per count that has something to say.
        assertScrolledInto(s(R.string.section_progress), "the progress section")
        assertTile(R.string.count_waiting, Formats.count(2))
        assertTile(R.string.count_in_folder, Formats.count(2))
        assertTile(R.string.count_confirmed, Formats.count(0))
        // Nothing was skipped, so there is no tile for it - a tile reading
        // zero is a question with no answer.
        assertEquals("nothing may have been skipped", 0, skippedCount())
        assertNoTile(R.string.count_skipped)

        // The one action, offered because two files are queued.
        assertScrolledInto(s(R.string.btn_optimise_now), "the optimise button")
        assertScrolledInto(s(R.string.optimise_now_hint), "the hint under the button")
    }

    @Test
    fun homeCountTilesExplainWhatTheyCount() {
        launchHome()

        val tiles = listOf(
            Triple(R.string.count_waiting, Formats.count(2), R.string.explain_waiting),
            Triple(R.string.count_in_folder, Formats.count(2), R.string.explain_in_folder),
            Triple(R.string.count_confirmed, Formats.count(0), R.string.explain_backed_up)
        )
        for ((labelRes, value, explainRes) in tiles) {
            assertTile(labelRes, value)
            compose.onNodeWithContentDescription("${s(labelRes)}: $value").performClick()
            assertShown(s(explainRes), "the explanation of ${s(labelRes)}")
            compose.onNodeWithText(s(R.string.ok)).performClick()
            compose.waitForIdle()
            assertAbsent(s(explainRes), "OK must close the explanation")
        }
    }

    @Test
    fun homeOptimiseNowStartsARunTheAppRecords() {
        launchHome()

        assertScrolledInto(s(R.string.btn_optimise_now), "the optimise button")
        compose.onNodeWithText(s(R.string.btn_optimise_now))
            .performScrollTo()
            .assertIsEnabled()
            .performClick()

        // The button's whole job is to start a run the app then owns. It says
        // so in its own words, in the activity log.
        val startedByYou = s(R.string.activity_started_by_you)
        awaitDb("\"$startedByYou\" was never recorded in the activity log") {
            runBlocking { db.activity().recent(20) }.any { it.detail == startedByYou }
        }
    }

    @Test
    fun homeAttentionChipForAMissingCloudAppLeadsToSettings() {
        // Without the stand-in, a phone without Ente must raise the chip.
        EnteApp.assumeInstalledForTest = false
        assertFalse(
            "this test needs a phone WITHOUT Ente Photos installed",
            EnteApp.isInstalled(context)
        )

        launchHome()

        assertScrolledInto(s(R.string.section_attention), "the attention section")
        assertScrolledInto(s(R.string.chip_cloud), "the missing-cloud chip")
        compose.onNodeWithText(s(R.string.chip_cloud)).performScrollTo().performClick()
        compose.waitForIdle()

        compose.onNode(NavTabs.matcher(s(R.string.nav_options))).assertIsSelected()
    }

    // =======================================================================
    // Files
    // =======================================================================

    @Test
    fun filesListsEverySeededRowWithItsRealSizes() {
        launchHome()
        openFiles()

        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)

        // A queued file states its size and that it is waiting.
        for (name in listOf(SMALL, CLIP)) {
            val queued = row(name)
            assertRowSays(
                name,
                s(R.string.files_size_waiting, Formats.bytes(queued.sizeBytes)),
                "the size line"
            )
        }
        // An optimised one states both sizes and what that saved.
        for (name in listOf(MEDIUM, LARGE)) {
            val done = row(name)
            val out = done.outputBytes ?: throw AssertionError("$name has no copy")
            assertRowSays(
                name,
                s(
                    R.string.files_size_saving,
                    Formats.bytes(done.sizeBytes),
                    Formats.bytes(out),
                    Formats.percentOf(done.sizeBytes - out, done.sizeBytes)
                ),
                "the saving line"
            )
        }

        // State badges: two to optimise, two waiting for Ente.
        compose.onAllNodesWithText(s(R.string.state_new)).assertCountEquals(2)
        compose.onAllNodesWithText(s(R.string.state_released)).assertCountEquals(2)
    }

    @Test
    fun filesSearchNarrowsToTheMatchingRowAndBack() {
        launchHome()
        openFiles()
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)

        compose.onNode(hasSetTextAction()).performTextInput("two_medium")
        awaitRowInList(MEDIUM, "the searched-for row")
        assertVisibleRows(MEDIUM)

        // A term nothing matches quotes the term back rather than going blank.
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNode(hasSetTextAction()).performTextInput("zzz_nothing")
        assertShown(
            s(R.string.list_no_matches_for, "zzz_nothing"),
            "the no-matches message"
        )
        compose.onNodeWithText(s(R.string.list_clear_search_action)).performClick()
        compose.waitForIdle()
        awaitRowInList(SMALL, "the full list after clearing the search")
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)
    }

    @Test
    fun filesTypeFilterSeparatesPhotosFromVideos() {
        launchHome()
        openFiles()

        chooseFilter(R.string.filter_type, s(R.string.scope_videos))
        assertChipReads(R.string.filter_type, s(R.string.scope_videos))
        assertVisibleRows(CLIP)

        chooseFilterOn(R.string.filter_type, s(R.string.scope_videos), s(R.string.scope_photos))
        assertChipReads(R.string.filter_type, s(R.string.scope_photos))
        assertVisibleRows(SMALL, MEDIUM, LARGE)

        chooseFilterOn(R.string.filter_type, s(R.string.scope_photos), s(R.string.filter_all))
        assertShown(s(R.string.filter_type), "the Type chip back at its default")
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)
    }

    @Test
    fun filesAlbumFilterCountsAndSelectsTheFixtureAlbum() {
        launchHome()
        openFiles()

        // The album option states how many files are in it before it is tapped.
        val option = s(R.string.filter_album_count, fixtureAlbum, FIXTURES.size)
        chooseFilter(R.string.filter_album, option)
        assertChipReads(R.string.filter_album, fixtureAlbum)
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)

        chooseFilterOn(R.string.filter_album, fixtureAlbum, s(R.string.filter_all_albums))
        assertShown(s(R.string.filter_album), "the Album chip back at its default")
    }

    @Test
    fun filesSizeFilterExcludesEverythingBelowTheBand() {
        // The fixtures are all comfortably under ten megabytes, so the lowest
        // band must empty the list; anything else means the band is not applied.
        for (name in FIXTURES) {
            assertTrue(
                "$name is ${row(name).sizeBytes} bytes, which breaks this test's premise",
                row(name).sizeBytes < 10L * 1_000_000
            )
        }

        launchHome()
        openFiles()

        chooseFilter(R.string.filter_size, s(R.string.filter_over_10mb))
        assertChipReads(R.string.filter_size, s(R.string.filter_over_10mb))
        assertVisibleRows()
        assertShown(s(R.string.list_filtered_empty), "the filtered-empty message")

        compose.onNodeWithText(s(R.string.list_reset_filters)).performClick()
        compose.waitForIdle()
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)
    }

    @Test
    fun filesStatusFilterNarrowsToOneStageAtATime() {
        launchHome()
        openFiles()

        // "In progress" covers optimised and released; the two staged photos.
        chooseFilter(R.string.filter_status, s(R.string.filter_in_progress))
        assertChipReads(R.string.filter_status, s(R.string.filter_in_progress))
        assertVisibleRows(MEDIUM, LARGE)

        // Only rows reading "Waiting for Ente" are on screen now, so the
        // "To optimise" option in the sheet is unambiguous.
        chooseFilterOn(
            R.string.filter_status, s(R.string.filter_in_progress), s(R.string.state_new)
        )
        assertChipReads(R.string.filter_status, s(R.string.state_new))
        assertVisibleRows(SMALL, CLIP)

        chooseFilterOn(R.string.filter_status, s(R.string.state_new), s(R.string.filter_all))
        assertShown(s(R.string.filter_status), "the Status chip back at its default")
        assertVisibleRows(SMALL, MEDIUM, LARGE, CLIP)
    }

    @Test
    fun filesSortOrdersActuallyReorderTheList() {
        val byDate = FIXTURES.sortedByDescending { row(it).captureAt }
        val bySize = FIXTURES.sortedByDescending { row(it).sizeBytes }
        assertNotEquals(
            "the fixtures must not sort the same way by date and by size, " +
                "or reordering proves nothing",
            byDate,
            bySize
        )

        launchHome()
        openFiles()

        // Newest is the default the screen opens on.
        assertOrder(*byDate.toTypedArray())

        chooseFilter(R.string.filter_sort, s(R.string.list_sort_largest))
        assertOrder(*bySize.toTypedArray())

        // Most saved: only the two optimised photos have saved anything, so
        // both must sit above the two that have not been touched.
        val bySaving = listOf(MEDIUM, LARGE).sortedByDescending {
            val r = row(it)
            r.sizeBytes - (r.outputBytes ?: r.sizeBytes)
        }
        chooseFilter(R.string.filter_sort, s(R.string.list_sort_saved))
        assertOrder(bySaving[0], bySaving[1])
        assertTrue(
            "an optimised file must sort above one that saved nothing",
            indexInList(bySaving[1]) < indexInList(SMALL) &&
                indexInList(bySaving[1]) < indexInList(CLIP)
        )

        chooseFilter(R.string.filter_sort, s(R.string.list_sort_newest))
        assertOrder(*byDate.toTypedArray())
    }

    @Test
    fun filesMultiSelectSaysWhatItWillActOnAndActsOnIt() {
        launchHome()
        openFiles()

        // Long-press starts a selection, exactly as every list in the app does.
        longPressRow(SMALL)
        assertShown(s(R.string.list_selected_count, 1), "the selection bar")
        assertShown(
            s(R.string.list_select_all_matching, FIXTURES.size),
            "the select-all button"
        )

        // Add one already-optimised row: the bar must now say it will act on
        // one of the two, and name the one it is leaving alone.
        tapRow(MEDIUM)
        assertShown(s(R.string.list_selected_count, 2), "the two-row selection bar")
        val twoBytes = row(SMALL).sizeBytes + row(MEDIUM).sizeBytes
        assertShown(
            // Not "frees": this bar optimises, and optimising frees nothing
            // until the original is removed, which is a separate choice.
            plural(R.plurals.list_selection_size, 2, 2, Formats.bytes(twoBytes)),
            "the selection summary"
        )
        assertShown(s(R.string.bulk_optimise_of, 1, 2), "the \"1 of 2\" action label")
        assertShown(
            plural(R.plurals.bulk_skipped_note, 1, 1),
            "the note naming what was skipped"
        )

        // Select all: two of the four are queued, two are already optimised.
        compose.onNodeWithText(s(R.string.list_select_all_matching, FIXTURES.size)).performClick()
        assertShown(s(R.string.list_selected_count, 4), "the whole-list selection bar")
        assertShown(s(R.string.bulk_optimise_of, 2, 4), "the \"2 of 4\" action label")

        val before = row(SMALL).priorityAt
        val takenOn = row(SMALL).captureAt
        compose.onNodeWithText(s(R.string.bulk_optimise_of, 2, 4)).performClick()
        // The action brings the eligible files to the front of the queue and
        // clears the selection. The jump is asked for on its own column: the
        // date the camera recorded is not overwritten to buy a queue place.
        awaitDb("the bulk action never reached the queued files") {
            row(SMALL).priorityAt > before && row(CLIP).state == ItemState.NEW.name
        }
        assertEquals(
            "the date the camera recorded must survive a queue jump",
            takenOn, row(SMALL).captureAt
        )
        assertAbsent(
            s(R.string.list_selected_count, 4),
            "acting on the selection must end it"
        )
        assertEquals(
            "an already-optimised file must not be re-queued",
            ItemState.RELEASED.name,
            row(MEDIUM).state
        )
    }

    @Test
    fun filesRowActionsFollowTheStateOfTheRow() {
        launchHome()
        openFiles()

        // A queued file can be brought forward, or skipped for good.
        tapRow(SMALL)
        assertShown(s(R.string.detail_evidence), "the verification row")
        assertShown(s(R.string.detail_original), "the original-size row")
        compose.onAllNodesWithText(s(R.string.detail_optimise_first)).assertCountEquals(1)
        compose.onAllNodesWithText(s(R.string.never_optimise)).assertCountEquals(1)
        compose.onNodeWithText(s(R.string.ok)).performClick()
        compose.waitForIdle()

        // An optimised copy is offered neither: the work is done, and the
        // option could not undo it. It gains the two size rows instead.
        tapRow(MEDIUM)
        assertShown(s(R.string.detail_copy), "the copy-size row")
        assertShown(s(R.string.detail_saved), "the saved row")
        assertAbsent(
            s(R.string.detail_optimise_first),
            "an optimised file must not be offered optimising again"
        )
        assertAbsent(
            s(R.string.never_optimise),
            "an optimised file must not be offered \"never optimise\""
        )
        assertAbsent(
            s(R.string.detail_try_again),
            "a file that did not fail must not be offered a retry"
        )
        compose.onNodeWithText(s(R.string.ok)).performClick()
        compose.waitForIdle()
    }

    @Test
    fun skippingAFileFromFilesShowsUpOnHomeAndLeadsBack() {
        launchHome()
        openFiles()

        tapRow(SMALL)
        assertShown(s(R.string.never_optimise), "the skip action")
        compose.onNodeWithText(s(R.string.never_optimise)).performClick()

        // Skipping one photo is a decision made with one tap, so it says where
        // the list lives and offers a way back.
        assertShown(s(R.string.never_optimise_undo), "the undo message")
        assertShown(s(R.string.undo), "the undo action")
        awaitDb("the file was never skipped") { row(SMALL).state == ItemState.SKIP.name }

        // Home now has a Skipped count, and the reason behind it.
        openTab(R.string.nav_home)
        assertTile(R.string.count_skipped, Formats.count(1))
        assertTile(R.string.count_waiting, Formats.count(1))
        assertScrolledInto(
            plural(R.plurals.skipped_reason_row, 1, 1, s(R.string.skip_user_excluded)),
            "the skip reason row"
        )

        // And the count is a way back into the list it counts.
        compose.onNodeWithContentDescription(
            "${s(R.string.count_skipped)}: ${Formats.count(1)}"
        ).performScrollTo().performClick()
        compose.waitForIdle()
        compose.onNode(NavTabs.matcher(s(R.string.nav_files))).assertIsSelected()
        assertChipReads(R.string.filter_status, s(R.string.state_skip))
        assertVisibleRows(SMALL)
    }

    // =======================================================================
    // Storage
    // =======================================================================

    @Test
    fun storageShowsEveryGroupWithARealTotal() {
        // The figures the screen shows are the phone's own - the size on the
        // box, as Android's Settings reports it - never smaller than the
        // data partition StatFs measures.
        val primary = Volumes.listForDisplay(context).firstOrNull { it.isPrimary }
        assertNotNull("the device must report a primary volume", primary)
        assertTrue(
            "the shown size cannot be smaller than the partition",
            primary!!.shownTotalBytes >= primary.totalBytes
        )
        val outputBytes = runBlocking { db.items().releasedBytes() }
        assertTrue("the upload folder must be holding something", outputBytes > 0)

        launchHome()
        openStorage()

        // 1. The phone's own volumes, with a used-of-total figure.
        assertScrolledInto(s(R.string.storage_group_phone), "the phone group")
        assertScrolledInto(s(R.string.volume_internal), "the internal storage row")
        // Free space moves while the test runs, so the half that cannot -
        // the size of the volume - is what is asserted.
        assertShownContaining(
            Formats.bytes(primary.shownTotalBytes),
            "the used-of-total line"
        )

        // 2. What Ente Saver itself is holding, as a real byte total.
        assertScrolledInto(s(R.string.storage_group_own), "the app's own space group")
        assertScrolledInto(s(R.string.storage_output), "the upload folder row")
        assertScrolledInto(Formats.bytes(outputBytes), "the upload folder total")

        // 3. The ways to find room.
        assertScrolledInto(s(R.string.find_space_title), "the find space group")
        assertScrolledInto(s(R.string.hub_title), "the free up space row")
        assertScrolledInto(s(R.string.hub_entry_hint), "the free up space hint")
        assertScrolledInto(s(R.string.calc_title), "the calculator row")
        assertScrolledInto(s(R.string.calc_entry_hint), "the calculator hint")

        // 4. Clean up appears only when there is something to clean, and then
        // it states how much. A group holding zero must not be drawn at all.
        val temp = sizeOfTempDir()
        if (temp > 0) {
            assertScrolledInto(s(R.string.storage_group_cleanup), "the cleanup group")
            assertScrolledInto(Formats.bytes(temp), "the leftover-files total")
        } else {
            assertAbsent(
                s(R.string.storage_group_cleanup),
                "there is nothing to clean up, so the group must not be drawn"
            )
        }
    }

    @Test
    fun storageOpensTheHubAndTheLargestFileIsListedFirst() {
        val largestFirst = FIXTURES.sortedByDescending { row(it).sizeBytes }

        launchHome()
        openStorage()

        assertScrolledInto(s(R.string.hub_title), "the free up space row")
        compose.onNodeWithText(s(R.string.hub_title)).performScrollTo().performClick()
        compose.waitForIdle()

        assertNoFigureIsStatedTwice(s(R.string.volume_internal))

        // The largest-files section carries what those files weigh together.
        val totalBytes = FIXTURES.sumOf { row(it).sizeBytes }
        assertScrolledInto(s(R.string.find_biggest), "the largest files entry")
        assertScrolledInto(s(R.string.hub_biggest_hint), "the largest files hint")
        assertScrolledInto(Formats.bytes(totalBytes), "the largest files total")

        compose.onNodeWithText(s(R.string.find_biggest)).performScrollTo().performClick()
        awaitRowInList(largestFirst.first(), "the largest files list")

        // Every fixture is in the list, biggest at the top, with its own size.
        assertOrder(*largestFirst.toTypedArray())
        assertRowSays(
            largestFirst.first(),
            Formats.bytes(row(largestFirst.first()).sizeBytes),
            "its own size"
        )
        assertShownContaining(
            Formats.bytes(totalBytes),
            "the header stating what the whole list weighs"
        )
    }

    // =======================================================================
    // Cloud calculator
    // =======================================================================

    @Test
    fun calculatorTurnsAPlanSizeIntoNumbersThatMatchThisGallery() {
        launchHome()
        // MediaStore indexes the seeded files a beat after they are written,
        // and on a loaded emulator that beat once stretched far enough for
        // the gallery to read as 0.00 GB. The screen and this test's expected
        // figures both ask MediaScanner for the same totals, so wait until
        // the store is answering with the gallery the fixtures actually
        // wrote before either side does its arithmetic.
        awaitDb("MediaStore sees the seeded gallery") {
            galleryTotals().let { it.photoBytes > 0 && it.videoBytes > 0 }
        }
        openStorage()
        assertScrolledInto(s(R.string.calc_title), "the calculator row")
        compose.onNodeWithText(s(R.string.calc_title)).performScrollTo().performClick()
        compose.waitForIdle()

        // Ente's free plan is the starting figure, ready to be replaced.
        assertScrolledInto(s(R.string.calc_input_label), "the calculator's input label")

        // A plan size the app cannot know, typed in. Typing focuses the field
        // and the keyboard rises over the bottom of this screen; its entrance
        // animates the window insets, and imePadding moves the whole page as
        // they change - so a node scrolled into view can be somewhere else by
        // the time it is asserted on. This test is about the arithmetic, not
        // the keyboard, so the keyboard is put away before anything is read.
        compose.onNode(hasSetTextAction()).performTextReplacement("50")
        Espresso.closeSoftKeyboard()
        compose.waitForIdle()
        awaitNode(hasText(s(R.string.calc_hero_label)), "the calculator's answer")

        val expected = expectedEstimate(50.0)
        assertScrolledInto(
            s(R.string.calc_hero_value, fmt(expected.originalsGB)),
            "the headline capacity figure"
        )
        assertScrolledInto(
            s(R.string.calc_hero_caption, fmt(50.0)),
            "the caption naming the plan size"
        )
        // Two staged photos is nowhere near a representative sample, so the
        // figures must be badged as typical rather than measured.
        assertTrue(
            "with only ${processedCount()} optimised files the estimate must be typical",
            expected.typicalEstimate
        )
        assertScrolledInto(s(R.string.calc_badge_typical), "the typical-estimate badge")

        // The tiles restate the same answer as counts.
        assertTile(R.string.calc_tile_photos, Formats.count(expected.photoCount))
        assertTile(R.string.calc_tile_video_hours, Formats.hours(expected.videoHours))

        // And the gallery this phone actually holds, measured against it.
        assertScrolledInto(s(R.string.calc_your_gallery), "the gallery section")
        assertScrolledInto(
            s(
                R.string.calc_gallery_line,
                fmt(galleryGb()),
                fmt(expected.backlogGB)
            ),
            "the line comparing this gallery with the plan"
        )

        // A bigger plan must fit strictly more of the same gallery.
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNode(hasSetTextAction()).performTextInput("100")
        Espresso.closeSoftKeyboard()
        compose.waitForIdle()
        val bigger = expectedEstimate(100.0)
        assertTrue(
            "doubling the plan must fit more originals",
            bigger.originalsGB > expected.originalsGB
        )
        assertScrolledInto(
            s(R.string.calc_hero_value, fmt(bigger.originalsGB)),
            "the recalculated capacity figure"
        )
    }

    // ---- the calculator's own arithmetic, recomputed independently ---------

    private fun galleryTotals(): MediaScanner.Totals = runBlocking {
        MediaScanner(context, db).totals(OptionsRepo.get(context).current().excludedBuckets)
    }

    private fun galleryGb(): Double {
        val totals = galleryTotals()
        return (totals.photoBytes + totals.videoBytes) / CapacityMath.GB
    }

    /**
     * What the screen must be showing, worked out from this phone's gallery and
     * this phone's own processed files - the same two inputs the view model
     * feeds the calculator, read here straight from MediaStore and the database.
     */
    private fun expectedEstimate(freeGb: Double): CapacityMath.Estimate = runBlocking {
        val options = OptionsRepo.get(context).current()
        val totals = galleryTotals()
        val gallery = CapacityMath.Gallery(
            photoBytes = totals.photoBytes,
            videoBytes = totals.videoBytes,
            videoMinutes = totals.videoMinutes,
            monthlyPhotoBytes = totals.monthlyPhotoBytes,
            monthlyVideoBytes = totals.monthlyVideoBytes,
            videoCount = totals.videoCount
        )
        val ratios = CapacityMath.ratios(
            photo = db.items().photoRatioSamples(PlannedEncode.photoKey(context, options)).map {
                CapacityMath.Sample(it.sizeBytes, it.outputBytes)
            },
            video = db.items().videoRatioSamples(PlannedEncode.videoKey(options)).map {
                CapacityMath.Sample(it.sizeBytes, it.outputBytes, it.durationMs / 60_000.0)
            },
            codec = PlannedEncode.videoCodec(options.video.spec()),
            source = CapacityMath.Source.MEASURED,
            galleryPhotoMedian = if (totals.photoCount > 0) {
                totals.photoBytes / totals.photoCount
            } else {
                0L
            },
            galleryVideoMedian = if (totals.videoCount > 0) {
                totals.videoBytes / totals.videoCount
            } else {
                0L
            }
        )
        CapacityMath.estimate(
            freeGb,
            CapacityMath.CalcMode.BOTH,
            CapacityMath.defaultMixShare(gallery),
            gallery,
            ratios
        )
    }

    /** GB to two decimals, the way the calculator screen writes them. */
    private fun fmt(v: Double): String = String.format(Locale.US, "%.2f", v)

    private fun sizeOfTempDir(): Long =
        Storage.totalTempBytes(context)
}
