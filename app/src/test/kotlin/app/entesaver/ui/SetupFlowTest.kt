package app.entesaver.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The first ten minutes of owning this app, held to what the screens promise.
 *
 * Every rule here comes from a real run on a real phone: a card headed "1."
 * under a header reading "Step 2 of 8", a restore button nobody could explain,
 * a trial that refused to run during setup, a correction that threw the user
 * five steps back, and a ticked album that came back unticked after a restart.
 */
class SetupFlowTest {

    private val strings = File("src/main/res/values/strings.xml").readText()
    private fun src(path: String) = File("src/main/kotlin/app/entesaver/$path").readText()

    private val entry = Regex(
        """<string name="([^"]+)"[^>]*>(.*?)</string>""",
        RegexOption.DOT_MATCHES_ALL
    )

    private fun stringsNamed(prefix: String): List<Pair<String, String>> =
        entry.findAll(strings)
            .map { it.groupValues[1] to it.groupValues[2] }
            .filter { it.first.startsWith(prefix) }
            .toList()

    @Test
    fun `no card counts the steps - the stepper already does`() {
        // "Step 2 of 8" over a card headed "1. Media permission" is two
        // counters disagreeing in the same glance. One counter, in one place.
        val numbered = Regex("""^\s*\d+\s*[.)]\s""")
        val offenders = stringsNamed("onb")
            .filter { (name, body) -> name.endsWith("_title") && numbered.containsMatchIn(body) }
            .map { it.first }
        assertTrue("these setup titles number themselves: $offenders", offenders.isEmpty())
    }

    @Test
    fun `restoring says what it is for, and a wrong file says what to pick`() {
        assertTrue(strings.contains("name=\"onb0_import_hint\""))
        val hint = stringsNamed("onb0_import_hint").single().second
        assertTrue("the hint must say who it is for", hint.contains("Only if"))
        assertTrue("the hint must promise photos are untouched", hint.contains("never touches your photos"))
        assertTrue(
            "the welcome step must render the hint beside the button",
            src("ui/screens/OnboardingScreen.kt").contains("onb0_import_hint")
        )
        val failed = stringsNamed("transfer_failed").single().second
        assertTrue("a wrong file must say nothing changed", failed.contains("nothing was changed"))
        assertTrue("and name what to pick instead", failed.contains("Save and restore settings"))
    }

    @Test
    fun `a correction from the summary happens on the summary`() {
        val onb = src("ui/screens/OnboardingScreen.kt")
        // The chooser opens over the summary as a sheet. Nothing navigates
        // away, so the old detour - a jump back to step 3 with a promise to
        // return, a flag to cancel, and a Back rule of its own - has nothing
        // left to manage and must be gone entirely.
        assertFalse("the detour flag should be gone", onb.contains("returnToSummary"))
        assertFalse("and its cancel machinery with it", onb.contains("leaveDetour"))
        assertTrue("the chooser is a sheet over the summary", onb.contains("ModalBottomSheet("))
        val ready = onb.substringAfter("Step.READY ->")
        assertTrue(
            "the no-albums warning must open the sheet in place",
            Regex("""OutlinedButton\(\s*onClick = \{ choosingAlbums = true \}""").containsMatchIn(ready)
        )
        assertTrue(
            "the trial card must open the same sheet",
            ready.contains("{ choosingAlbums = true }")
        )
        // A sheet measures its content with no ceiling, so the sheet's one
        // scroller is the bounded grid, with the count row and the Done
        // button riding inside it as spanned rows.
        val sheet = onb.substringAfter("fun AlbumChooserSheetBody")
        assertTrue(sheet.contains("AlbumGrid("))
        // The grid takes its ceiling from the box it is in, never from a
        // constant: three albums used to show as two with no hint of a third.
        assertFalse("no fixed ceiling on the grid", sheet.contains("maxHeight ="))
        val grid = src("ui/components/AlbumPicker.kt")
        assertTrue(grid.contains("BoxWithConstraints(modifier.fillMaxWidth())"))
        assertTrue("and it says when there is more below", grid.contains("state.canScrollForward"))
        assertTrue(sheet.contains("footer ="))
        // One rule decides what Back means, and both the gesture and the
        // button go through it; with no detour, it is one card back, always.
        assertTrue("Back must have a handler at all", onb.contains("BackHandler(enabled = step > 0)"))
        assertTrue("the gesture and the button must agree", onb.contains("BackHandler(enabled = step > 0) { backOneStep() }"))
        assertTrue("the Back button must use it too", onb.contains("TextButton(onClick = { backOneStep() })"))
        val back = onb.substringAfter("fun backOneStep()").substringBefore("BackHandler")
        assertTrue("Back steps back one card", back.contains("goTo(step - 1)"))
    }

    @Test
    fun `no card offers the same action twice`() {
        // The summary used to render two identical "Choose albums" buttons a
        // few dp apart whenever no album was ticked - one beside the warning
        // that explains why, one inside the trial card - and the usage step
        // carried two filled buttons that both simply moved on.
        val onb = src("ui/screens/OnboardingScreen.kt")
        val ready = onb.substringAfter("Step.READY ->")
        assertTrue(
            "the trial card must not repeat the warning's Choose albums button",
            ready.contains("onChooseAlbums = if (includedAlbums == 0 && allAlbums.isNotEmpty())")
        )
        val usage = onb.substringAfter("Step.USAGE ->").substringBefore("Step.CLOUD ->")
        assertEquals(
            "the usage step may have exactly one filled button",
            0,
            Regex("""\bButton\(onClick""").findAll(usage).count()
        )
        // Carrying on without it is Skip, as on every optional step - not an
        // outlined "Done, next" on a step nobody has done. Once access is
        // granted the step says so and offers only the way on.
        assertFalse("one way to carry on, styled like every other step's", usage.contains("OutlinedButton("))
        assertEquals("Skip only while there is something to skip", 1, Regex("""onSkip = """).findAll(usage).count())
        assertTrue("granted, the step says so", usage.contains("R.string.onb4_granted"))
        assertTrue("re-checked on return from the system page", usage.contains("Lifecycle.Event.ON_RESUME"))
        // The battery step had "Done, next" and "Skip" side by side, doing
        // exactly the same thing.
        val battery = onb.substringAfter("Step.BATTERY ->").substringBefore("Step.USAGE ->")
        assertFalse("the battery step has one way on", battery.contains("onSkip"))
        val notify = onb.substringAfter("Step.NOTIFICATIONS ->").substringBefore("Step.BATTERY ->")
        assertTrue(
            "the button says Allow only when there is something to allow",
            notify.contains("if (notifOn) R.string.onb_next else R.string.onb2_grant")
        )
        assertTrue(
            "below Android 13 a blocked phone is sent to the switch, not past it",
            notify.contains("else -> OemPages.openNotificationSettings(context)")
        )
    }

    @Test
    fun `the trial is offered on a chosen album, not on a scan that has not run`() {
        val trial = src("ui/components/TrialCard.kt")
        assertTrue(trial.contains("albumsChosen"))
        assertTrue(trial.contains("trial_needs_albums"))
        assertTrue(trial.contains("trial_ready"))
        // The old rule hid the button whenever nothing was queued, which is
        // every phone during setup, because the scan runs inside the trial.
        assertFalse(trial.contains("if (size > 0) {\n            OutlinedButton"))
        val vm = src("ui/AppViewModel.kt")
        val run = vm.substringAfter("fun startTestRun").substringBefore("// ---- Free-up")
        assertTrue("the trial must scan before it picks", run.contains("MediaScanner(ctx, db).scan("))
        // The card promises photos "from the albums you chose", and the scan
        // just inventoried the whole phone - so the pick must carry the
        // exclusion set. Shipped without it, the trial optimised three photos
        // from albums the user had just declined.
        assertTrue(
            "the trial must pick from ticked albums only",
            run.contains("newestNewPhotos(TRIAL_SIZE, o.excludedBuckets)")
        )
        assertTrue(
            "and the trial count must follow the same ticks",
            vm.contains("flatMapLatest { db.items().waitingPhotoCountFlow(it) }")
        )
        // Setup and Home ask the same question of the same card.
        assertTrue(src("ui/screens/OnboardingScreen.kt").contains("albumsChosen = includedAlbums > 0"))
        val home = src("ui/screens/HomeScreen.kt")
        assertTrue(home.contains("albumsChosen ="))
        assertTrue(home.contains("onChooseAlbums ="))
        assertFalse(
            "Home must not hide the card just because nothing is queued yet",
            home.contains("processed == 0 && trialSize > 0")
        )
    }

    @Test
    fun `the album choice states how much gallery it involves`() {
        // "2 albums" could be forty photos or eighteen gigabytes, and the
        // decision on that screen is exactly how much to hand over.
        assertTrue(strings.contains("name=\"onb_albums_size\""))
        val vm = src("ui/AppViewModel.kt")
        assertTrue(vm.contains("val selectedAlbumBytes"))
        assertTrue(
            "an unmeasured size must be absent, never zero",
            vm.contains("MutableStateFlow<Long?>(null)")
        )
        val refresh = vm.substringAfter("fun refreshSelectedAlbumBytes")
            .substringBefore("fun loadBuckets")
        assertTrue("it must not guess under partial access", refresh.contains("MediaAccess.FULL"))
        // Setup and Settings show the same measured figure for the same choice.
        for (screen in listOf("OnboardingScreen.kt", "OptionsScreen.kt")) {
            val text = src("ui/screens/$screen")
            assertTrue("$screen must show it", text.contains("onb_albums_size"))
            assertTrue("$screen must re-measure on a tick", text.contains("refreshSelectedAlbumBytes"))
        }
    }

    @Test
    fun `a snapshot restores once per install, and never over a live choice`() {
        val recovery = src("engine/StartupRecovery.kt")
        assertTrue(recovery.contains("if (o.restoreDone) return 0"))
        assertTrue(recovery.contains("RESTORE_DONE"))
        // The shipped bug: "restore whenever the item table is empty" was true
        // on every launch until the first file was optimised, and each launch
        // re-imported the snapshot's settings - a ticked album came back
        // unticked after every restart.
        assertTrue(recovery.contains("importOptions = untouched"))
        assertTrue(recovery.contains("!o.onboardingDone && o.onboardingStep == 0"))
        val store = src("engine/SnapshotStore.kt")
        assertTrue(store.contains("importOptions && snapshot.options.isNotEmpty()"))
        // A reinstall without gallery access must not skip the one screen
        // that asks for it.
        assertTrue(recovery.contains("MediaAccess.FULL"))
    }

    @Test
    fun `the app lock covers the whole app`() {
        val app = src("ui/App.kt")
        assertTrue(app.contains("val needsLock = options.appLock && !unlocked"))
        assertFalse(
            "a lock that covers only some routes is walked around by a tab tap",
            app.contains("route in Routes.LOCKED")
        )
        assertFalse("the route list it used should be gone", app.contains("val LOCKED = setOf"))
        assertTrue("the tab bar must not stay live under the lock", app.contains("if (!needsLock &&"))
        // Still re-armed every time the app leaves the foreground - except
        // for a trip the app itself sent the person on, which comes back
        // through within a bounded grace (Errand) and re-locks past it.
        assertTrue(app.contains("if (Errand.expecting()) Errand.left() else vm.relock()"))
        assertTrue(app.contains("if (Errand.returnedNeedsLock()) vm.relock()"))
        val locked = src("ui/screens/LockedScreen.kt")
        // On RESUME, not on first composition: the screen composes while the
        // activity is only started, and a prompt asked for then can be
        // dropped by the system, leaving a button that looks like the app
        // forgot to ask.
        assertTrue("the prompt opens itself", locked.contains("Lifecycle.Event.ON_RESUME"))
        assertTrue(locked.substringAfter("Lifecycle.Event.ON_RESUME").take(80).contains("onOpened()"))
        assertFalse("not from a one-shot effect", locked.contains("LaunchedEffect(Unit) { onUnlock() }"))
        // By itself once per locking. Every resume used to ask, and on
        // Android 10 cancelling the PIN pad is itself a resume - a prompt
        // that could only be escaped by being answered.
        assertTrue(
            "the automatic prompt is spent once per locking",
            Regex("""if \(!vm\.lockAutoPrompted\) \{\s+vm\.lockAutoPrompted = true\s+unlockPrompt\(\)""").containsMatchIn(app)
        )
        val vm = src("ui/AppViewModel.kt")
        assertTrue(
            "and given back when the lock closes again",
            Regex("""fun relock\(\) \{\s+unlocked\.value = false\s+lockAutoPrompted = false""").containsMatchIn(vm)
        )
        assertTrue("never two prompts stacked", app.contains("if (vm.lockPromptOpen) return@prompt"))
        // The app turns with the phone, which stops and restarts the
        // activity. That is not leaving the app, and must not lock it.
        val stop = app.substringAfter("LifecycleEventEffect(Lifecycle.Event.ON_STOP) {").substringBefore("\n    }")
        assertTrue(
            "turning the phone must not lock the app",
            stop.indexOf("isChangingConfigurations == true) return") in 0 until stop.indexOf("vm.relock()")
        )
        assertTrue("and it shows the app's own mark", locked.contains("BrandMark(size = 72.dp)"))
    }

    @Test
    fun `an alert tapped on a locked phone waits instead of crashing`() {
        val app = src("ui/App.kt")
        val effect = app.substringAfter("LaunchedEffect(deepLink").substringBefore("Scaffold(")
        // While the app is locked there is no NavHost in composition, so the
        // controller has no graph and navigating into it throws.
        assertTrue(
            "the deep link must re-evaluate when the lock opens",
            app.contains("LaunchedEffect(deepLink, needsLock)")
        )
        assertTrue(
            "and must not navigate while the gate is shut",
            effect.contains("if (needsLock) return@LaunchedEffect")
        )
        val clearAt = effect.indexOf("clearDeepLink")
        val guardAt = effect.indexOf("if (needsLock)")
        assertTrue(
            "the link must not be consumed before it is honoured",
            guardAt in 0 until clearAt
        )
    }

    @Test
    fun `the gallery is only enumerated where its answer is used`() {
        val home = src("ui/screens/HomeScreen.kt")
        val startup = home.substringAfter("LaunchedEffect(Unit) {").substringBefore("}")
        assertFalse(
            "reading the album list walks the whole gallery; it must not run " +
                "on every visit to Home",
            startup.contains("loadBuckets")
        )
        assertTrue(
            "it belongs with the one card that reads it",
            home.substringAfter("if (processed == 0) {").substringBefore("TrialCard(")
                .contains("vm.loadBuckets()")
        )
    }

    @Test
    fun `About states the requirement plainly, with nothing hidden behind Advanced`() {
        val help = src("ui/screens/HelpScreens.kt")
        assertTrue(help.contains("about_requires_min"))
        // The network promise stays on the page; the build-chain facts that
        // once filled a "Technical details" card (package name, build number,
        // signing fingerprint) moved to the release notes, where the person
        // comparing a downloaded file actually is.
        assertTrue(help.contains("about_network_none"))
        assertFalse("build-chain facts left About", help.contains("about_tech_title"))
        assertFalse("the fingerprint left About", help.contains("EXPECTED_CERT_SHA256"))
        assertTrue(help.contains("about_permissions_title"))
        assertFalse("the Advanced expander is gone", help.contains("about_advanced"))
        // Finished software: the page must not talk about installing a newer
        // APK, because there will never be one.
        assertFalse("no update wording on About", help.contains("about_updates"))
        assertTrue(
            "the update string itself is gone",
            stringsNamed("about_updates").isEmpty()
        )
        val requires = stringsNamed("about_requires_min").single().second
        assertTrue("the minimum must be named", requires.contains("Android 9 or newer"))
        assertTrue("and what it is tested against", requires.contains("Android 16"))
    }

    @Test
    fun `Ente has a face, installed or not, and setup notices it arriving`() {
        // Installed, Ente's own icon from the phone; not installed, a tile in
        // Ente's green - never a logo shipped inside this APK.
        val parts = File("src/main/kotlin/app/entesaver/ui/components/EnteParts.kt").readText()
        assertTrue(parts.contains("if (installed) EnteApp.icon(context) else null"))
        assertTrue(parts.contains(".background(EnteGreen)"))
        for (screen in listOf("OnboardingScreen.kt", "OptionsScreen.kt")) {
            val text = File("src/main/kotlin/app/entesaver/ui/screens/$screen").readText()
            assertTrue("$screen must use the shared icon", Regex("""EnteIcon\(installed = \w+\)""").containsMatchIn(text))
            // Both invite leaving to install Ente; both must notice it on
            // the way back rather than show the answer from before.
            assertTrue(
                "$screen must ask again whether Ente is installed on return",
                text.contains("LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refreshEnte() }")
            )
            assertTrue("$screen offers the three install pages", text.contains("EnteInstallButtons("))
        }
        // The pages open in the phone's own store or browser; this app has no
        // internet permission and downloads nothing itself.
        val ente = File("src/main/kotlin/app/entesaver/data/EnteApp.kt").readText()
        assertTrue(ente.contains("Intent(Intent.ACTION_VIEW, Uri.parse(source.uri))"))
        assertTrue("the test stand-in is inert in a release build", ente.contains("(BuildConfig.DEBUG && assumeInstalledForTest)"))
    }
}
