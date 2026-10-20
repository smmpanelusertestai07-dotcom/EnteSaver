package app.entesaver

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two promises with no natural home in any other test: what this app will
 * never grow into, and how little it is allowed to interrupt.
 *
 * Both are the kind of thing that erodes by good intentions - one clever
 * feature, one extra notification at a time - so they are stated as tests
 * rather than as a paragraph nobody re-reads.
 */
class ProductBoundariesTest {

    private val main = File("src/main/kotlin/app/entesaver")

    private fun code(): List<Pair<String, String>> =
        main.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .map { it.name to it.readText() }
            .toList()

    /** Comment lines: where a refusal is allowed to be *named* and explained. */
    private fun withoutComments(text: String): String = text.lineSequence()
        .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
        .joinToString("\n")

    @Test
    fun `the refused features never grow back`() {
        // Every one of these was considered and refused on purpose: they need
        // judgement about a photograph that no app should make on someone
        // else's behalf, or they need the internet, or they create second
        // copies in a cloud the owner is paying for.
        val banned = mapOf(
            "similar-photo detection" to Regex("""similarityScore|findSimilar|perceptualHash|pHash\b"""),
            "blur or quality scoring" to Regex("""blurScore|sharpnessScore|qualityScore"""),
            "automatic deletion of originals" to Regex("""autoDeleteOriginals|deleteOriginalsAutomatically"""),
            "cloud recommendations or prices" to Regex("""recommendCloud|pricePerGb|planPrice"""),
            "re-optimise everything" to Regex("""reoptimiseAll|reprocessAll|optimiseEverything""")
        )
        val offenders = mutableListOf<String>()
        for ((name, body) in code()) {
            val live = withoutComments(body)
            for ((feature, pattern) in banned) {
                if (pattern.containsMatchIn(live)) offenders += "$name introduces $feature"
            }
        }
        assertTrue(offenders.joinToString("; "), offenders.isEmpty())
    }

    @Test
    fun `nothing in the app can reach a scheduler that only reminds`() {
        // A background job whose only outcome is a notification is an app
        // nagging its owner. Every scheduled path here does work.
        val scheduler = File(main, "work/Scheduler.kt").readText()
        assertFalse(scheduler.contains("reminder"))
        val workers = File(main, "work").listFiles()!!.filter { it.extension == "kt" }
        assertTrue("the worker set stays small and each one does work", workers.size <= 6)
    }

    @Test
    fun `clearing leftover work files cannot delete work in progress`() {
        // The button is in Storage and in the Free up hub, so it can be
        // pressed while a compression is writing its output. Deleting that
        // file costs the user the item they asked for.
        val storage = File(main, "util/Storage.kt").readText()
        assertTrue(storage.contains("TEMP_ABANDONED_MS"))
        val clean = storage.substringAfter("fun cleanTemp(").substringBefore("\n    }")
        assertTrue(
            "young files must be skipped, not deleted",
            clean.contains("if (now - f.lastModified() < TEMP_ABANDONED_MS) return@forEach")
        )
        // Long enough to be beyond any single run, short enough that a crash
        // is cleaned up on the same day.
        val hours = Regex("""TEMP_ABANDONED_MS = (\d+)L \* 60 \* 1000""")
            .find(storage)!!.groupValues[1].toInt()
        assertTrue("an abandoned file is one no run could still own", hours >= 60)
    }

    @Test
    fun `there are exactly two notification channels, and the retired one is removed`() {
        val notifications = File(main, "util/Notifications.kt").readText()
        val created = Regex("""createNotificationChannel\(""").findAll(notifications).count()
        assertEquals("one channel for work, one for problems - no more", 2, created)
        assertTrue(notifications.contains("CH_WORKING"))
        assertTrue(notifications.contains("CH_ALERTS"))
        assertTrue(
            "an upgrade must not leave a dead channel in system settings",
            notifications.contains("deleteNotificationChannel(CH_LEGACY_WARNINGS)")
        )
        // The working channel must stay silent and badge-free: it is on screen
        // for as long as a run lasts.
        val working = notifications.substringAfter("val working = NotificationChannel")
            .substringBefore("val alerts")
        assertTrue(working.contains("IMPORTANCE_LOW"))
        assertTrue(working.contains("setSound(null, null)"))
        assertTrue(working.contains("enableVibration(false)"))
        assertTrue(working.contains("setShowBadge(false)"))
    }

    @Test
    fun `an alert repeats at most once a day, and mutes for a week`() {
        val notifications = File(main, "util/Notifications.kt").readText()
        assertTrue(notifications.contains("DEDUP_MS = 86_400_000L"))
        assertTrue(notifications.contains("MUTE_MS = 7 * 86_400_000L"))
        assertTrue("every alert must be able to open the screen it is about",
            notifications.contains("EXTRA_ROUTE"))
    }

    @Test
    fun `the app keeps working when notifications are denied`() {
        val notifications = File(main, "util/Notifications.kt").readText()
        // Posting is gated on permission and every post is wrapped, so a
        // refusal is silence - never a crash and never a blocked run.
        assertTrue(notifications.contains("fun canPost"))
        val alert = notifications.substringAfter("fun alert(").substringBefore("private fun post(")
        assertTrue("alerts must check permission before posting", alert.contains("canPost"))
        val post = notifications.substringAfter("private fun post(")
        assertTrue("the post itself checks again", post.contains("if (!canPost(context)) return"))
        assertTrue(
            "and survives permission being revoked between the check and the notify",
            post.contains("catch (e: SecurityException)")
        )
        // The foreground notification is the one exception - it must exist for
        // the service - and it is taken down on every exit path.
        assertTrue(notifications.contains("fun clearWorking"))
        val worker = File(main, "work/CompressWorker.kt").readText()
        assertTrue(
            "the ongoing icon must never outlive the run",
            worker.contains("Notifications.clearWorking")
        )
    }

    /**
     * A figure on one screen may not be a different question from the screen
     * it links to.
     *
     * The Free up space hub summed `reclaimCandidates()` straight - every
     * original with any evidence at all - and printed it as "you could free
     * about X". The Reclaim screen behind that card put the same rows through
     * `ReclaimRules.isEligible`, which refuses anything under thirty days
     * settled, anything while the cloud app is missing or flagged, anything
     * too small, and any favourite. So the card advertised gigabytes and the
     * list opened empty - most visibly in a user's first month, which is
     * everyone at first. Room's own comment shows this class of bug was
     * already fixed once and fixed from the wrong end.
     *
     * `ReclaimEligibility` is now the only caller of the raw query, so the
     * two answers cannot drift apart again.
     */
    @Test
    fun `only the shared gate decides what can be freed`() {
        val allowed = setOf("ReclaimEligibility.kt", "Db.kt")
        val offenders = code()
            .filter { (name, _) -> name !in allowed }
            .filter { (_, text) -> withoutComments(text).contains("reclaimCandidates()") }
            .map { (name, _) -> name }
        assertTrue(
            "these ask the database for raw candidates instead of asking " +
                "ReclaimEligibility what may actually be freed: $offenders",
            offenders.isEmpty()
        )
    }

    @Test
    fun `every name that runs the compressor is one runningFlow watches`() {
        // Home hides "Optimise now" while a run is going, because the running
        // one holds the lock and a second would do nothing. That decision is
        // runningFlow's, and it watched two of the three names that start a
        // CompressWorker - so through a run triggered by taking a photo the
        // button was offered and the tap was swallowed.
        //
        // Resolved through the request VARIABLE each call is handed, per
        // function. Nothing coarser works: one function enqueues the
        // compressor and the maintenance pass side by side, and "the text near
        // the call" is fooled by a comment that merely names CompressWorker.
        val src = withoutComments(
            File("src/main/kotlin/app/entesaver/work/Scheduler.kt").readText()
        )
        val enqueue = Regex(
            """enqueueUnique(?:Periodic)?Work\(\s*(W_[A-Z_]+)\s*,[^,]+,\s*(\w+)\s*\)"""
        )
        val starters = src.split(Regex("""\n    (?:private )?fun """))
            .flatMap { fn ->
                enqueue.findAll(fn).filter { call ->
                    val request = call.groupValues[2]
                    Regex("""val $request = [^\n]*WorkRequestBuilder<CompressWorker>""")
                        .containsMatchIn(fn)
                }.map { it.groupValues[1] }
            }
            .toSet()
        assertTrue("no compression work found - has Scheduler moved?", starters.size >= 2)

        val watched = src.split(Regex("""\n    (?:private )?fun """))
            .single { it.startsWith("runningFlow(") }
        val unwatched = starters.filterNot { watched.contains(it) }
        assertTrue(
            "these start a compression run but runningFlow cannot see them, " +
                "so Home offers a button the running one will refuse: $unwatched",
            unwatched.isEmpty()
        )
    }

    @Test
    fun `a selection bar counts the same set it sizes`() {
        // Three screens made the same mistake: the count came from the whole
        // selection and the size from the rows the filters happened to be
        // showing. A tick survives a filter change, so narrowing the list left
        // "10 selected" beside the size of six, above a button that acted on
        // six - and on the duplicates screen the same split understated how
        // much was about to be removed, because that removal re-scans
        // everything.
        //
        // Whatever a bar counts, it must size, and its action must reach the
        // same set. `selection.size` beside a `selectedBytes` computed from a
        // filtered list is the shape that keeps coming back.
        val screens = File("src/main/kotlin/app/entesaver/ui/screens")
            .walkTopDown().filter { it.isFile && it.extension == "kt" }
        val offenders = mutableListOf<String>()
        for (f in screens) {
            val text = withoutComments(f.readText())
            Regex("""selectionSummary\(\s*([A-Za-z.]+)\s*,\s*Formats\.bytes\((\w+)\)""")
                .findAll(text)
                .forEach { m ->
                    val counted = m.groupValues[1]
                    // The size is derived from some list; find which.
                    val sizeFrom = Regex("""val ${m.groupValues[2]} = remember\((\w+)""")
                        .find(text)?.groupValues?.get(1)
                    // Only the mismatch that misleads: a whole-selection
                    // count beside a size summed over the rows the filters
                    // happen to be showing. Summing the selection over the
                    // FULL list is right - that is what the duplicates dialog
                    // does, because its removal re-scans everything.
                    //
                    // These four names are what a filtered list is called in
                    // this codebase; a new one has to be added here, which is
                    // the point at which someone re-reads this rule.
                    val filtered = setOf("shown", "rows", "chosen", "visible")
                    if (counted == "selection.size" && sizeFrom in filtered) {
                        offenders += "${f.name}: counts $counted but sizes over the filtered $sizeFrom"
                    }
                }
        }
        assertTrue(
            "a bar must count the set it sizes and acts on: $offenders",
            offenders.isEmpty()
        )
    }

    @Test
    fun `a modified build cannot remove anything`() {
        // TamperCheck's contract says a mismatched signing certificate
        // "disables the Free-up tool and all deletions", and the banner on Home
        // tells the user deleting is turned off and stays off. Neither was
        // true. The flag reached a banner and one hidden button; every path
        // that removes a file ran exactly as before - originals, duplicate
        // extras, restores from the trash, leftover work files.
        //
        // This matters more than an unkept promise. That banner appears when
        // the signing certificate does not match, which is what an APK signed
        // with someone else's key looks like - and the private key really was
        // published for eleven releases. The one moment the check exists for is
        // the one where it did nothing.
        val vms = File("src/main/kotlin/app/entesaver/ui")
        val entryPoints = mapOf(
            "ReclaimViewModel.kt" to listOf(
                "fun start(permanent: Boolean) {",
                "fun removeDuplicateExtras(chosen: Set<Long>) {",
                "fun restore(batch: ReclaimBatchRow, items: List<ReclaimItemRow>) {"
            ),
            "AppViewModel.kt" to listOf(
                "fun requestDelete(uris: List<Uri>, onDone: (List<Uri>) -> Unit): IntentSender? {",
                // Deletes a gallery file the person kept, with no system
                // dialog in between. It was the one path the promise missed.
                "fun removeKeptCopy(row: ItemRow) {"
            )
        )
        val ungated = mutableListOf<String>()
        for ((file, signatures) in entryPoints) {
            val text = File(vms, file).readText()
            for (sig in signatures) {
                val body = text.substringAfter(sig, "")
                assertTrue("$file no longer has `$sig`", body.isNotEmpty())
                // The refusal has to be the first thing the function does, not
                // a check somewhere after the work has started.
                if (!body.take(700).contains("TamperCheck.isModified")) {
                    ungated += "$file: ${sig.substringBefore('(')}"
                }
            }
        }
        assertTrue(
            "these remove files without checking the signature first, while the " +
                "app tells the user deleting is turned off: $ungated",
            ungated.isEmpty()
        )
    }

    @Test
    fun `Home waits for the database before it claims anything`() {
        // The counts start when Home subscribes, so the first frame was drawn
        // from the initial value - zeros - and zeros are a statement, not an
        // absence: "nothing waiting, nothing backed up", written out as a
        // sentence above a trial offer, one frame before the real numbers
        // arrived and both vanished. The offer also enumerated the gallery.
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        assertTrue("counters must start unknown", vm.contains("val counters: StateFlow<Counters?>"))
        assertTrue("processed must start unknown", vm.contains("val processedCount: StateFlow<Int?>"))
        val home = File("src/main/kotlin/app/entesaver/ui/screens/HomeScreen.kt").readText()
        assertTrue(home.contains("val loaded = countersRead != null && processedRead != null"))
        assertTrue(
            "the all-clear sentence waits for the counts",
            home.contains("if (loaded && counters.waiting == 0 && counters.inFolder == 0 && counters.confirmed == 0)")
        )
        assertTrue(
            "the trial offer, and the gallery read behind it, wait for the counts",
            home.contains("if (loaded && (processed == 0 || testRunning || !testItems.isNullOrEmpty()))")
        )
    }

    @Test
    fun `an original is read back before it is put in front of the delete dialog`() {
        // A row finds its original by MediaStore id, and an id survives an
        // edit: "Save" in a gallery editor rewrites the bytes under the same
        // number. The old row - whose copy the cloud actually holds - still
        // pointed at that number, so Free up space offered the EDITED photo
        // as "the cloud has this", and confirming would have removed the one
        // version nothing had ever collected.
        val engine = File("src/main/kotlin/app/entesaver/engine/ReclaimEngine.kt").readText()
        val prepare = engine.substringAfter("suspend fun prepare(").substringBefore("suspend fun finish")
        val check = prepare.indexOf("OriginalCheck.unchanged(")
        val offer = prepare.indexOf("uris += original")
        assertTrue("prepare() must read the original back", check > 0)
        assertTrue("and must do so before the address is offered", offer > check)
        assertTrue(
            "a changed original retires the row for good, ids and all",
            prepare.substringAfter("OriginalCheck.unchanged(").substringBefore("uris += original")
                .contains("mediaStoreId = null")
        )
        val screen = File("src/main/kotlin/app/entesaver/ui/screens/ReclaimScreen.kt").readText()
        assertTrue(
            "the reason reaches the user in their own words",
            screen.contains("\"original_changed\" -> stringResource(R.string.skip_original_changed)")
        )
    }

    @Test
    fun `a copy Android will not let the app delete is asked about, not retried forever`() {
        // Copies adopted after a reinstall belong to the install that made
        // them; a silent delete throws, was caught, and was retried every
        // hour while the copies kept counting against the space allowance -
        // until the resource gate stopped every run, for good.
        val maintain = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val lazy = maintain.substringAfter("private suspend fun lazyDelete(")
        assertTrue(lazy.contains("catch (e: SecurityException)"))
        assertTrue(lazy.contains("repo.addCopiesNeedingConsent(listOf(id))"))
        val reclaim = File("src/main/kotlin/app/entesaver/engine/ReclaimEngine.kt").readText()
        val copiesOnly = reclaim.substringAfter("private suspend fun removeCopiesOnlyLocked(")
            .substringBefore("val batchId")
        assertTrue(copiesOnly.contains("catch (e: SecurityException)"))
        assertTrue(copiesOnly.contains("addCopiesNeedingConsent(listOf(row.id))"))
        // Home asks through Android's own dialog, and the rows are marked as
        // the app's doing BEFORE the dialog, so the maintenance pass cannot
        // read the file's absence as the cloud having collected it.
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        val remove = vm.substringAfter("fun removeConsentCopies()").substringBefore("private fun finishConsentCopies")
        assertTrue(remove.take(400).contains("TamperCheck.isModified"))
        val mark = remove.indexOf("appDeletedCopy = true")
        val ask = remove.indexOf("requestDelete(uris)")
        assertTrue("mark first, then ask", mark in 1 until ask)
        val home = File("src/main/kotlin/app/entesaver/ui/screens/HomeScreen.kt").readText()
        assertTrue(home.contains("visible = consentCopies.isNotEmpty() && !tampered"))
        assertTrue(home.contains("vm.removeConsentCopies()"))
    }

    @Test
    fun `a storage gate that stops a run is a reason on Home`() {
        val worker = File("src/main/kotlin/app/entesaver/work/CompressWorker.kt").readText()
        val gate = worker.substringAfter("val resource = Gates.resourceGate(").substringBefore("val batch =")
        assertTrue(
            "the resource gate must write the wait reason Home reads",
            gate.contains("RunDecider.waitForResource(resource).name")
        )
        val home = File("src/main/kotlin/app/entesaver/ui/screens/HomeScreen.kt").readText()
        for (wait in listOf("SPACE_FULL", "LOW_SPACE", "VOLUME_MISSING")) {
            assertTrue("Home must have words for $wait", home.contains("RunDecider.Wait.$wait ->"))
        }
        // And a paused or half-permitted run still re-arms the FAST trigger
        // it consumed, or new photos wait for the half-hourly pass instead.
        val early = worker.substringAfter("if (!options.onboardingDone) return Result.success()")
            .substringBefore("val db = AppDb.get(app)")
        assertEquals("both early exits re-arm", 2, Regex("reschedule\\(app, repo\\)").findAll(early).count())
    }

    /**
     * The repository holds the two apps' source, and nothing else.
     *
     * It used to hold a front page, a Hinglish quick start, a verification
     * matrix and a frozen audit - four documents, ninety thousand words, kept
     * in step by hand with an app that changed every day. The quick start was
     * already describing a screen this release removes. Nobody who installs
     * Ente Saver reads any of it: they read the app, which answers the same
     * questions from the same source the behaviour comes from, and cannot
     * drift from it.
     *
     * So what a person needs is in the app - Help, the FAQ, Privacy and
     * Terms, About - and what a release needs is written by the release
     * workflow at the moment it publishes. The repository is Ente Saver's
     * source and what builds and checks it, and nothing else.
     */
    @Test
    fun `the repository carries source and no documents`() {
        val root = generateSequence(File(".").absoluteFile) { it.parentFile }
            .first { File(it, ".github/workflows").isDirectory }
        // What the repository carries is what git carries, not what happens
        // to be sitting in a working copy. The two differ in the one way
        // that matters here: CI decodes the real signing keystore into the
        // workspace before it runs these tests, and .gitignore keeps it out
        // of the repository - so a filesystem walk failed this rule on every
        // CI run while passing on every desk. A key that IS committed is
        // still caught, which is the whole point.
        val tracked = runCatching {
            val out = ProcessBuilder("git", "ls-files", "-z")
                .directory(root).redirectErrorStream(true).start()
            val names = out.inputStream.bufferedReader().readText()
            if (out.waitFor() != 0) null else names.split('\u0000').filter { it.isNotEmpty() }
        }.getOrNull()
        assertTrue("git must be able to list the repository", tracked != null)

        val documents = tracked!!.filter { it.lowercase().endsWith(".md") }
        assertTrue("these belong inside the apps, or nowhere: $documents", documents.isEmpty())

        // And nothing that unlocks anything. A key in a public repository is
        // a key anyone can sign an Ente Saver with.
        val keys = tracked.filter { name ->
            setOf(".jks", ".keystore", ".p12", ".pfx", ".pem").any { name.lowercase().endsWith(it) }
        }
        assertTrue("a signing key must never be committed: $keys", keys.isEmpty())
    }

    @Test
    fun `every file a source-text rule reads is a declared test input`() {
        // The build cache is on and the CI action restores it, so a test
        // whose inputs Gradle does not know about can replay its previous
        // verdict over a file it never read - on CI, not only locally.
        val build = File("build.gradle.kts").readText()
        val block = build.substringAfter("tasks.withType<Test>().configureEach {").substringBefore("\n}")
        for (path in listOf(
            "gradle/wrapper/gradle-wrapper.properties",
            "src/main/AndroidManifest.xml",
            ".github/workflows",
            "src/main/kotlin",
            "src/main/res",
            "src/androidTest"
        )) {
            assertTrue("$path must be a declared input of the unit tests", block.contains("\"$path\""))
        }
        // The naming rule reads every tracked file, so a list of named files
        // is always one file short: gradle.properties and gradlew were
        // missing from it. The whole tree has to be the input, unfiltered.
        val property = "withPropertyName(\"sourceTextRuleRepositoryTree\")"
        assertTrue("the whole repository must be a declared input of the unit tests", block.contains(property))
        val tree = block.substringBefore(property).substringAfterLast("inputs.files(")
        assertTrue("the repository input must be the root tree", tree.contains("rootProject.fileTree(\".\")"))
        assertFalse("the repository input must not narrow itself to some files", tree.contains("include("))
    }

    /**
     * The return from "Confirm uploads" is the only moment a missing copy is
     * read as collected by Ente. It used to be a 24-hour window every pass
     * read from a setting, so the hourly worker counted copies a person had
     * cleared by hand as uploaded - and offered their originals a month later.
     *
     * The window is stored now, so a return to a new process still counts it,
     * but every other pass reads it only to leave those copies alone.
     */
    @Test
    fun `only the return from Ente reads a missing copy as collected`() {
        val engine = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        assertFalse("no pass may read the old 24-hour setting", engine.contains("confirmFlowStartedAt"))
        val hourly = engine.substringAfter("private suspend fun runLocked").substringBefore("private inline fun step")
        assertTrue(hourly.contains("step { detectGone(o, now, entries, summary) }"))
        // Other passes are only ever held back by the stored window.
        val gone = engine.substringAfter("private suspend fun detectGone").substringBefore("private suspend fun repairStalePending")
        assertTrue(gone.contains("val held = if (window == null) repo.current().confirmWindow else null"))
        assertTrue(gone.contains("val collected = window != null && EvidenceRules.collectedByFreeUp("))
        assertFalse("a held window must never grant proof", gone.contains("collectedByFreeUp(held"))
        // The window is stored before Ente opens, and handed to one pass only.
        val start = vm.substringAfter("fun startConfirmFlow()").substringBefore("fun dismissConfirmResult")
        assertTrue(start.indexOf("openConfirmWindow(tappedAt)") in 0 until start.indexOf("EnteApp.launch(ctx)"))
        assertTrue("a tap under way ignores a second one", start.contains("if (confirmJob?.isActive == true || !inFront) return"))
        // So does a tap after Ente was asked to open and before the screen
        // is left: it would replace the stored window, then drop it.
        assertTrue(start.contains("if (tappedAt - enteLaunchedAt in 0 until ENTE_LAUNCH_GRACE_MS) return"))
        assertTrue(
            "noted before the launch",
            start.indexOf("enteLaunchedAt = System.currentTimeMillis()") in 0 until start.indexOf("EnteApp.launch(ctx)")
        )
        assertFalse("the view model never hands a window to a pass itself", vm.contains("confirmPass(window"))
        val resumed = vm.substringAfter("fun onResumed()").substringBefore("fun onMediaChanged")
        assertTrue(resumed.contains("MaintainEngine(ctx).returnPass()"))
        assertTrue("the return ends the launch", resumed.indexOf("enteLaunchedAt = 0L") in 0 until resumed.indexOf("returnPass()"))
        assertTrue(vm.substringAfter("fun quickMaintain()").take(200).contains("confirmPass() }"))
        // The return pass spends the window it judged.
        val ret = engine.substringAfter("suspend fun returnPass()").substringBefore("private suspend fun confirmPassLocked")
        assertTrue(ret.indexOf("confirmPassLocked(window)") in 0 until ret.lastIndexOf("repo.clearConfirmWindow(window.openedAt)"))
    }

    /**
     * One VERIFIED or AGED copy left in the folder used to switch off paced
     * proof and the per-item limit for as long as the folder kept it - in
     * practice for good, and the copies then sent in bulk became the next
     * blockers. Then a timer took a VERIFIED copy out of the list a window
     * after its batch was verified - though the batch may have been paid by
     * camera photos, and Ente's late send of the copy was credited to a newer
     * one. Paced proof, attribution and pacing read one list that time never
     * shortens; aloneInFlight finds nothing alone beside any other copy in it
     * or any copy that left during the window, and only Pacing.releaseLimit
     * lifts the limit. Home offers Ente's free-up while graded copies stay.
     */
    @Test
    fun `graded copies in the folder do not end paced proof for good`() {
        val engine = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val waiting = engine.substringAfter("private suspend fun unprovenWaiting(").substringBefore("// ---- d)")
        assertTrue(waiting.contains("db.batches().verifiedOfReleased()"))
        assertTrue(waiting.contains("return waiting\n"))
        assertFalse(waiting.contains("isTimedOut"))
        assertFalse(engine.contains("EvidenceRules.competing("))
        val rules = File("src/main/kotlin/app/entesaver/core/logic/EvidenceRules.kt").readText()
        assertFalse(rules.contains("fun competing("))
        assertFalse(rules.contains("verifiedAt, "))
        val release = engine.substringAfter("private suspend fun pacedRelease(").substringBefore("val releasedToday")
        assertTrue(release.contains("Pacing.releaseLimit("))
        assertFalse(release.contains("Pacing.releaseSlots("))
        for (fn in listOf("private suspend fun pacedEvidence(", "private suspend fun pacedRelease(")) {
            assertTrue(fn, engine.substringAfter(fn).substringBefore("\n    }\n").contains("unprovenWaiting(now)"))
        }
        // Paced proof and attribution hand the measured bytes to the one rule.
        val paced = engine.substringAfter("private suspend fun pacedEvidence(").substringBefore("\n    }\n")
        assertTrue(paced.contains("EvidenceRules.aloneInFlight(waiting, leftDuring(waiting), now, tx)"))
        assertTrue(rules.contains("val alone = aloneInFlight(waiting, left, now, txSinceEarliest)"))
        val gone = engine.substringAfter("private suspend fun detectGone(").substringBefore("\n    }\n")
        assertTrue(gone.contains("EvidenceRules.attributeTraffic(waiting, leftDuring(waiting), txShared, now)"))
        // A copy that left the folder during the window is read, whatever
        // state it is in now, by when it left (LeftFolderQueryTest runs the
        // query; the test below holds every writer to recording it).
        val left = engine.substringAfter("private suspend fun leftDuring(").substringBefore("\n    }\n")
        assertTrue(left.contains("db.items().leftReleasedSince(since)"))
        assertTrue(left.contains("leftAt = row.leftAt"))
        assertFalse(left.contains("updatedAt"))
        // No size arithmetic decides that a neighbour sent nothing.
        assertFalse(rules.contains("MAX_GRADED"))
        val home = File("src/main/kotlin/app/entesaver/ui/screens/HomeScreen.kt").readText()
        assertTrue(home.contains("gradedInFolder = gradedInFolder"))
    }

    /**
     * The block of the `copy(` call a `state = ` argument sits in, so a
     * write can be read as a whole.
     */
    private fun copyBlockAround(text: String, at: Int): String {
        val start = text.lastIndexOf("copy(", at)
        var depth = 0
        for (i in start + "copy".length until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> if (--depth == 0) return text.substring(start, i + 1)
            }
        }
        return text.substring(start)
    }

    private fun stateWrites(body: String): List<String> =
        Regex("""(?<!val )\bstate = """).findAll(body).map { copyBlockAround(body, it.range.first) }.toList()

    /**
     * When a copy left the folder decides whether Ente's traffic can be
     * credited to the copy beside it, so every write that takes a row out of
     * RELEASED records it - a copy sent back to the queue too, whose release
     * time goes - and no other write moves it. It used to be read from the
     * row's last change, which any bookkeeping bumps, and only while the row
     * kept its release time, which a re-send clears.
     */
    @Test
    fun `every way out of the folder records when the copy left`() {
        val engine = File(main, "engine/MaintainEngine.kt").readText()
        fun fn(name: String) = engine.substringAfter("private suspend fun $name(").substringBefore("\n    }\n")
        // The passes that take RELEASED rows somewhere else.
        var leaving = 0
        for (name in listOf("detectGone", "repairStalePending", "lazyDelete")) {
            val writes = stateWrites(fn(name))
            assertTrue("$name writes a state", writes.isNotEmpty())
            for (w in writes) {
                assertTrue("$name: a leave must record when: $w", w.contains("leftFolderAt = "))
                assertFalse("$name: a leave must keep its record: $w", w.contains("leftFolderAt = null"))
            }
            leaving += writes.size
        }
        assertEquals("detectGone's eight ways out, the stale-pending repair and lazy delete", 10, leaving)
        // Passes over rows that are not in the folder never touch it.
        for (name in listOf("promoteGone", "originalsPresence", "verifyBatches", "ageEvidence", "pacedEvidence")) {
            assertFalse(name, fn(name).contains("leftFolderAt"))
        }
        assertEquals(
            "recorded nowhere but on the way out",
            leaving,
            Regex("""leftFolderAt = """).findAll(engine).count()
        )

        // Free up settles RELEASED rows too, and a restore or a failed copy
        // check may meet one: each records the leave, if it is one.
        val reclaim = File(main, "engine/ReclaimEngine.kt").readText()
        val reclaimWrites = stateWrites(reclaim)
        assertEquals(3, reclaimWrites.size)
        for (w in reclaimWrites) assertTrue(w, w.contains("leftFolderAt = cur.leftFolderAtAfter(") || w.contains("leftFolderAt = row.leftFolderAtAfter("))

        // So do the screens' writers that can meet a RELEASED row.
        for (file in listOf("ui/AppViewModel.kt", "ui/ReclaimViewModel.kt")) {
            val text = File(main, file).readText()
            for (marker in listOf("fun setNeverOptimise(", "private fun finishConsentCopies(")) {
                if (!text.contains(marker)) continue
                val body = text.substringAfter(marker).substringBefore("\n    }\n")
                for (w in stateWrites(body)) assertTrue("$file: $w", w.contains("leftFolderAtAfter("))
            }
        }

        // Into the folder again, a row carries no earlier leave; a restored
        // copy found missing is dated when that was found, and so is every
        // restored copy the pass did not find, before the restore counts as
        // matched.
        val releaser = File(main, "media/Releaser.kt").readText()
        val release = stateWrites(releaser).single { it.contains("ItemState.RELEASED.name") }
        assertTrue(release, release.contains("leftFolderAt = null"))
        val reattach = stateWrites(File(main, "engine/ReattachEngine.kt").readText())
        assertEquals(2, reattach.size)
        assertTrue(reattach[0], reattach[0].contains("leftFolderAt = null"))
        assertTrue(reattach[1], reattach[1].contains("leftFolderAt = now"))
        val reattachText = File(main, "engine/ReattachEngine.kt").readText()
        val stamp = reattachText.indexOf("db.items().stampRestoredLeft(now)")
        assertTrue("the pass dates what it did not find", stamp > 0)
        assertTrue(stamp < reattachText.indexOf("repo.setBool(OptionsRepo.K.COPIES_REATTACHED, true)"))
    }

    /**
     * A restore can land mid-run, and its copies are matched to the folder
     * only on the next run. Read by their last change, they stopped counting
     * for a copy released after the restore, and Ente sending one of them
     * could be credited to that copy.
     */
    @Test
    fun `restored copies count as in the folder until they are matched`() {
        val engine = File(main, "engine/MaintainEngine.kt").readText()
        val body = engine.substringAfter("private suspend fun leftDuring(").substringBefore("\n    }\n")
        assertTrue(body, body.contains("if (!ReattachEngine.pending(context))"))
        // Watched for a week after a restore: the flag is set only by a pass
        // after the watch, and a restore starts the watch.
        val reattach = File(main, "engine/ReattachEngine.kt").readText()
        assertTrue(reattach.contains("if (!watching) repo.setBool(OptionsRepo.K.COPIES_REATTACHED, true)"))
        val store = File(main, "engine/SnapshotStore.kt").readText()
        // Only a history that brought copies back starts the watch; one that
        // did not marks the restore looked at. Date and request go in one
        // write, which leaving the screen cannot cut short.
        assertTrue(store.contains("optionsRepo.markRestored(restoredCopies, System.currentTimeMillis())"))
        assertTrue(store.substringBefore("optionsRepo.markRestored(").substringAfterLast("withContext(").startsWith("NonCancellable)"))
        val repoText = File(main, "data/prefs/OptionsRepo.kt").readText()
        val mark = repoText.substringAfter("suspend fun markRestored(").substringBefore("\n    }\n")
        assertTrue(mark, mark.contains("restoredCopies -> p[K.RESTORED_AT] = now"))
        assertTrue(mark, mark.contains("(p[K.RESTORED_AT] ?: 0L) == 0L && (p[K.COPIES_REATTACHED] ?: false) -> p[K.RESTORED_AT] = 1L"))
        assertTrue(mark, mark.contains("p[K.COPIES_REATTACHED] = false"))
        // The flag is cleared last: the branch before it reads it.
        val asked = mark.indexOf("p[K.COPIES_REATTACHED] = false")
        assertTrue(mark, mark.indexOf("restoredCopies -> p[K.RESTORED_AT] = now") in 0 until asked)
        assertTrue(mark, mark.indexOf("-> p[K.RESTORED_AT] = 1L") in 0 until asked)
        // And both the check and the write sit inside the uncancellable block.
        val held = store.substringAfter("withContext(NonCancellable) {").substringBefore("if (importOptions &&")
        assertTrue(held, held.contains("countByState(") && held.contains("optionsRepo.markRestored("))
        // A date ahead of the clock is never written back.
        assertTrue(reattach.contains("ReattachRules.watching(minOf(restoredAt, now), now)"))
        assertTrue(body, body.contains("provenAt = null"))
        // Read before the copies that left, which the pass dates before it
        // marks the restore matched: one list or the other always has each.
        assertTrue(body, body.indexOf("db.items().restoredUnmatched()") in 0 until body.indexOf("leftReleasedSince("))
        // Paced proof and attribution both read it, and both drop a single
        // copy's claim when what is in flight changed while they read.
        assertEquals(2, Regex("""leftDuring\(waiting\)""").findAll(engine).count())
        assertEquals(2, Regex("""stillInFlight\(waiting\)""").findAll(engine).count())
        // Only where a single copy's claim is on the table.
        assertTrue(engine.contains("if (EvidenceRules.Attribution.PER_FILE !in it.values || stillInFlight(waiting))"))
    }

    /**
     * "Confirm uploads" opens Ente straight away. Taking the window used to
     * wait for a running pass to finish, so the button looked dead - and a
     * window taken late, with Ente opened from the background or not at all,
     * credited copies the person had cleared by hand in the meantime.
     */
    @Test
    fun `the confirm tap does not wait for a maintenance pass`() {
        val engine = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val open = engine.substringAfter("suspend fun openConfirmWindow(").substringBefore("suspend fun dropConfirmWindow")
        assertFalse(open.contains("Locks.maintain"))
        assertFalse(open.contains("confirmPassLocked"))
        assertTrue("stored before it is returned", open.indexOf("repo.setConfirmWindow(window)") in 0 until open.indexOf("return window"))
        val vm = File("src/main/kotlin/app/entesaver/ui/AppViewModel.kt").readText()
        val start = vm.substringAfter("fun startConfirmFlow()").substringBefore("fun dismissConfirmResult")
        assertTrue(
            "a window whose Ente did not open is dropped",
            start.contains("val opened = inFront && run {") &&
                start.contains("if (!opened && window != null)") &&
                start.contains("engine.dropConfirmWindow(window.openedAt)")
        )
        // A return that found nothing says to tap first, then free up: freed
        // first, the copies are gone before the tap and never in its window.
        val strings = File("src/main/res/values/strings.xml").readText()
        val none = strings.substringAfter("name=\"confirm_none_text\">").substringBefore("</string>")
        assertTrue(none.indexOf("Tap Confirm uploads") in 0 until none.indexOf("Free up space"))
    }

    @Test
    fun `the maintenance pass runs one at a time`() {
        // Locks exists because "WorkManager's unique names stop two workers
        // racing, but the UI can start a trial run, an Optimise now, or a
        // removal while a scheduled run is mid-way" - its own words. The
        // maintenance pass took none of them, and TWO paths start it: the
        // hourly MaintainWorker, and CompressWorker at the end of every
        // compression run. Different unique names, so nothing serialised them,
        // with the UI able to ask for a confirm pass on top.
        //
        // Two passes over the same rows is how self-heal reverts an item
        // another pass has just released - back to NEW, staged file forgotten -
        // and the cloud receives it a second time.
        val engine = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val entries = listOf("run()", "confirmPass()", "returnPass()")
        val ungated = entries.filterNot { entry ->
            Regex(
                """suspend fun ${Regex.escape(entry.dropLast(2))}\([^)]*\)[^\n]*""" +
                    """Locks\.maintain\.withLock"""
            ).containsMatchIn(engine)
        }
        assertTrue(
            "these start a maintenance pass without taking Locks.maintain, so " +
                "two passes can write the same rows: $ungated",
            ungated.isEmpty()
        )
        // And it must not take the other three, or holding this one could
        // deadlock against a release or a removal already in flight.
        val body = engine.substringAfter("private suspend fun runLocked")
        for (other in listOf("Locks.release", "Locks.reclaim", "Locks.ledger")) {
            assertFalse(
                "the maintenance pass must not also take $other while holding " +
                    "Locks.maintain - that is a deadlock waiting for a busy phone",
                body.contains("$other.withLock")
            )
        }
    }

    /**
     * A result the user is waiting for has to reach them.
     *
     * "Export the list" wrote a CSV, set a done-or-failed message, and that
     * was the end of it: nothing in the app read the property, so the button
     * did its work in silence either way. Someone who picked a folder the
     * write could not reach was left believing they had the list of the
     * photographs they were about to remove.
     */
    @Test
    fun `every message a view model sets is read by a screen`() {
        val screens = File("src/main/kotlin/app/entesaver/ui")
            .walkTopDown()
            .filter { it.isFile && it.extension == "kt" && !it.name.endsWith("ViewModel.kt") }
            .joinToString("\n") { withoutComments(it.readText()) }
        val unread = mutableListOf<String>()
        for (file in File("src/main/kotlin/app/entesaver/ui")
            .walkTopDown()
            .filter { it.isFile && it.name.endsWith("ViewModel.kt") }) {
            val declared = Regex("""val\s+(\w*[Mm]essage)\s*=\s*MutableStateFlow""")
                .findAll(withoutComments(file.readText()))
                .map { it.groupValues[1] }
            for (name in declared) {
                if (!screens.contains(".$name")) unread += "${file.name}: $name"
            }
        }
        assertTrue(
            "these are set for the user and never shown to them, so the action " +
                "that set one succeeds and fails in exactly the same silence: $unread",
            unread.isEmpty()
        )
    }

    /**
     * The weakest grade of proof is never assumed on the user's behalf.
     *
     * Three grades can offer an original for removal, and one of them - a
     * day's outgoing byte total adding up - says a day's photographs went out,
     * not that this photograph did. The rule has always said in writing that
     * it counts "only behind an explicit opt-in", and every call site passed
     * the literal `true` instead, while the opt-in it names sat in settings
     * with a setter no screen reached. So the app offered originals on that
     * proof with nobody having agreed to anything, and the mark on the tab -
     * which did read the setting - disagreed with the screen it led to.
     */
    @Test
    fun `the weakest proof is offered only where the user asked for it`() {
        val offenders = mutableListOf<String>()
        for ((name, text) in code()) {
            for (m in Regex("""allowVerifiedBySize\s*=\s*true""").findAll(withoutComments(text))) {
                offenders += "$name: ${m.value}"
            }
        }
        assertTrue(
            "these offer an original for removal on a day's byte total without " +
                "asking the user, which the rule they call says must be an " +
                "explicit opt-in: $offenders",
            offenders.isEmpty()
        )
        // And the switch that answers it has to exist on a screen.
        val options = File("src/main/kotlin/app/entesaver/ui/screens/OptionsScreen.kt").readText()
        assertTrue(
            "the opt-in is read but no screen lets anyone give it",
            options.contains("vm.setFreeUpVerified30(")
        )
    }

    /**
     * Opening a photo goes to the viewer the phone already chose.
     *
     * Wrapping the view intent in `createChooser` put the full "Open with"
     * sheet - WhatsApp, Drive, the lot - in front of every long-press on an
     * album, every time, with no way to say "always". A plain `ACTION_VIEW`
     * is what Android's own "Just once / Always" dialog is for; the chooser
     * is kept only for a phone with no viewer at all, where the plain start
     * throws.
     */
    @Test
    fun `a file opens in the phone's chosen viewer and the chooser is only the fallback`() {
        val peek = File(main, "ui/components/AlbumPicker.kt").readText()
            .substringAfter("private fun peekAlbum(")
            .substringBefore("\n}\n")
        val viewer = File(main, "ui/AppViewModel.kt").readText()
            .substringAfter("fun openInViewer(")
            .substringBefore("\n    }\n")
        for ((name, body) in listOf("peekAlbum" to peek, "openInViewer" to viewer)) {
            val plain = body.indexOf("startActivity(view)")
            val fallback = body.indexOf("catch (e: ActivityNotFoundException)")
            val chooser = body.indexOf("createChooser(view")
            assertTrue("$name must start the view intent as it is", plain >= 0)
            assertTrue("$name must keep a fallback for a phone with no viewer", fallback > plain)
            assertTrue("$name may only use the chooser as that fallback", chooser > fallback)
            assertEquals("$name wraps the first attempt in a chooser", 1, Regex("createChooser").findAll(body).count())
        }
    }

    @Test
    fun `one light copy is made at a time, from a row read under the lock`() {
        // The Home trial and the scheduled run both pick the newest photos,
        // and nothing kept them apart: a trial tapped mid-run encoded the
        // same photo twice at once, on a phone sized for one decode.
        val stager = File("src/main/kotlin/app/entesaver/media/Stager.kt").readText()
        val entry = stager.substringAfter("suspend fun stageOne(").substringBefore("private fun identityOf")
        assertTrue("stageOne must hold Locks.stage", entry.contains("Locks.stage.withLock"))
        val lock = entry.indexOf("Locks.stage.withLock")
        val reread = entry.indexOf("db.items().byId(row.id)")
        assertTrue("and read the row again once it holds it", reread > lock)
        assertTrue("and check it is still waiting for the same file", entry.contains("StageRules.verdict("))
        assertFalse(
            "the batch row the caller holds must not reach the encoder",
            entry.contains("stageLocked(row,")
        )
        // The scan's retiring of edited-in-place rows takes the same lock.
        val scanner = File("src/main/kotlin/app/entesaver/media/MediaScanner.kt").readText()
        assertTrue(
            scanner.substringAfter("private suspend fun retireReplaced").contains("Locks.stage.withLock")
        )
        // So does Free up's remake: the screen waiting on it is no reason for
        // a second full-size decode beside the background one. It takes its
        // turn (StageTurn, which holds Locks.stage) rather than wait on the
        // lock row by row behind a run that keeps encoding.
        val remake = File("src/main/kotlin/app/entesaver/engine/ReclaimEngine.kt").readText()
            .substringAfter("private suspend fun pinSource(")
            .substringBefore("private suspend fun writeVerified(")
        val held = remake.indexOf("if (!turn.take()) return null")
        assertTrue("the Free-up remake must hold its turn at Locks.stage", held >= 0)
        assertFalse("and never wait on the lock for each row", remake.contains("Locks.stage.withLock"))
        for (step in listOf("InFlight.beginRemake(", "DeviceTier.fit(", "VideoCompressor.compress(")) {
            assertTrue("$step must run inside it", remake.indexOf(step) > held)
        }
    }

    @Test
    fun `Free up takes the encoder once a batch, and the run gives way`() {
        // Each remake waited on Locks.stage with no limit, row by row, and
        // the background run took it back between rows: one more encode -
        // up to twenty minutes for a clip - ahead of every row, on a bare
        // spinner (StageTurnTest has the turn itself).
        val engine = File("src/main/kotlin/app/entesaver/engine/ReclaimEngine.kt").readText()
        val prepare = engine.substringAfter("suspend fun prepare(").substringBefore("private suspend fun prepareRows(")
        assertTrue("one turn for the batch", prepare.contains("val turn = stageTurn(onWaiting)"))
        assertTrue("given back whatever happens", prepare.indexOf("turn.close()") > prepare.indexOf("} finally {"))
        val rows = engine.substringAfter("private suspend fun prepareRows(").substringBefore("suspend fun finish(")
        assertTrue("the same turn for every row", rows.contains("pinLightCopy(row, options, now, remakeDiedOn, turn)"))
        assertTrue("a remake left out for it is named as such", rows.contains("if (turn.refusals > refusedBefore) STAGE_BUSY"))
        val pin = engine.substringAfter("suspend fun pinLightCopy(").substringBefore("private class PinSource")
        assertTrue("a caller with no batch gets a turn of its own", pin.contains("val own = turn ?: stageTurn()"))
        assertTrue("and gives it back", pin.contains("if (turn == null) own.close()"))
        // The background run starts no new file while Free up wants it.
        val worker = File("src/main/kotlin/app/entesaver/work/CompressWorker.kt").readText()
        val yieldAt = worker.indexOf("if (Locks.runShouldYield()) break@loop")
        assertTrue("the run must give way to Free up", yieldAt >= 0)
        assertTrue("before it starts the file", yieldAt < worker.indexOf("stager.stageInRun("))
        // The wait is on screen, and so is a remake left out for it.
        val vm = File("src/main/kotlin/app/entesaver/ui/ReclaimViewModel.kt").readText()
        assertTrue(vm.contains("{ waitingForStage.value = it }"))
        val screen = File("src/main/kotlin/app/entesaver/ui/screens/ReclaimScreen.kt").readText()
        assertTrue(screen.contains("rvm.waitingForStage.collectAsStateWithLifecycle()"))
        assertTrue(screen.contains("R.string.freeup_waiting_for_stage"))
        assertTrue(screen.contains("ReclaimEngine.STAGE_BUSY -> stringResource(R.string.skip_stage_busy)"))
    }

    @Test
    fun `the run measures a file's time once the encoder is free`() {
        // The time left and the battery charge were read before stageOne
        // waited on Locks.stage. Behind a Free-up remake or a restore, the
        // encoder was handed a budget minutes too large - past the job's
        // limit, where Android stops it mid-encode - and the wait was charged
        // to the day's video allowance as encoding.
        val stager = File("src/main/kotlin/app/entesaver/media/Stager.kt").readText()
        val run = stager.substringAfter("suspend fun stageInRun(").substringBefore("suspend fun stageHeld(")
        val lock = run.indexOf("Locks.stage.withLock")
        assertTrue(lock >= 0)
        assertTrue("measured inside the lock", run.indexOf("val lockedAt = System.currentTimeMillis()") > lock)
        assertTrue(run.contains("val remaining = deadlineAt - lockedAt"))
        assertTrue("asked again before it starts", run.indexOf("if (!fits(remaining))") in 0 until run.indexOf("stageHeld("))
        assertTrue("a file not started counts no try", run.contains("RunStage(started = false, ok = false, encodeMs = 0L)"))
        assertTrue(run.contains("encodeMs = System.currentTimeMillis() - lockedAt"))
        val worker = File("src/main/kotlin/app/entesaver/work/CompressWorker.kt").readText()
        assertFalse("no budget measured before the wait", worker.contains("runRemainingMs"))
        assertTrue(worker.contains("RunDecider.batteryCost(power.plugged, row.isVideo, ok, staged.encodeMs)"))
        assertTrue("a file not started is left for the next run", worker.contains("if (row.isVideo) later += row.id\n                        continue"))
    }

    @Test
    fun `self-heal and reattach never write a stale row over a restore`() {
        // A restore taking a staged row over, or parking it as never
        // optimise, deletes its staged file mid-transaction. Self-heal read
        // the row before that, found the file gone and wrote the old row back
        // as NEW: the excluded photo was encoded and published, or one Ente
        // had was sent again. Self-heal holds Locks.maintain and may not take
        // the restore's locks, so its write checks instead.
        val engine = File("src/main/kotlin/app/entesaver/engine/MaintainEngine.kt").readText()
        val heal = engine.substringAfter("private suspend fun selfHealStage(").substringBefore("private suspend fun originalsPresence(")
        assertTrue(heal.contains("db.items().unstageIfStill(row.id, path, now)"))
        assertFalse("never the row read before", heal.contains("db.items().update("))
        val dao = File("src/main/kotlin/app/entesaver/data/db/Db.kt").readText()
        val query = dao.substringBefore("suspend fun unstageIfStill(").substringAfterLast("@Query(")
        assertTrue(query.contains("WHERE id = :id AND state = 'STAGED' "))
        assertTrue(query.contains("AND stagePath IS :path"))
        // Reattach reads rows and writes them back whole; it takes the
        // restore's locks, in the restore's order, round all of it.
        val reattach = File("src/main/kotlin/app/entesaver/engine/ReattachEngine.kt").readText()
        assertTrue(reattach.contains("Locks.stage.withLock { Locks.release.withLock { runLocked() } }"))
        val locked = reattach.substringAfter("private suspend fun runLocked()")
        assertTrue("the flag is read again under the locks", locked.contains("if (!pending(context)) return"))
        assertTrue(locked.contains("repo.setBool(OptionsRepo.K.COPIES_REATTACHED, true)"))
        // Rows already settled are never written: Free up may be acting on
        // them, and this pass reads and writes whole rows.
        assertFalse(locked.contains("ItemState.DONE.name &&"))
    }

    @Test
    fun `a Free up the person agreed to is written down whatever happens next`() {
        // After Android's dialog the originals are gone. A database error
        // in the bookkeeping used to end the app with no history and no
        // undo, and leaving the screen cancelled it halfway.
        val vm = File(main, "ui/ReclaimViewModel.kt").readText()
        val consented = vm.substringAfter("private fun finishLegacy(")
        assertEquals(
            "every consented batch must finish through the one guarded path",
            1, Regex("""engine\.finish\(""").findAll(consented).count()
        )
        val guarded = consented.substringAfter("private fun finishConsented(").substringBefore("\n    }\n")
        assertTrue("it must outlive the screen", guarded.contains("withContext(NonCancellable)"))
        assertTrue("and catch what the bookkeeping throws", guarded.contains("catch (e: Exception)"))
        assertTrue("and say so in Activity", guarded.contains("R.string.activity_reclaim_unrecorded"))
    }

    @Test
    fun `an encode never writes its stale row over one a restore settled meanwhile`() {
        // Stager read the row once, encoded for up to twenty minutes, and
        // wrote that row back whole. A restore taking it over as one Ente
        // already had, or parking it as never optimise, was undone, and the
        // copy was published anyway.
        val stager = File("src/main/kotlin/app/entesaver/media/Stager.kt").readText()
        val after = stager.substringAfter("private suspend fun stageLocked(").substringBefore("private suspend fun skip(")
        assertFalse(
            "every write after the encode must go through settle()",
            after.contains("db.items().update(")
        )
        assertTrue(after.contains("val written = settle(row) { cur ->"))
        assertTrue("an unwanted copy is not left to be published", after.contains("if (!written) stageFile.delete()"))
        val settle = stager.substringAfter("private suspend fun settle(")
        assertTrue(settle.contains("db.withTransaction {"))
        assertTrue(settle.contains("StageRules.stillWaiting("))
        val fail = stager.substringAfter("private suspend fun fail(").substringBefore("private suspend fun settle(")
        assertFalse("a failure counts on the row as it is now", fail.contains("db.items().update("))
    }

    @Test
    fun `a restore and the start-up repair wait for the encode, in one lock order`() {
        // stage, then release, then ledger. Nothing holding release or
        // ledger takes stage, and an encode holding stage takes nothing.
        val names = listOf("Locks.stage.withLock", "Locks.release.withLock", "Locks.ledger.withLock")
        val store = File("src/main/kotlin/app/entesaver/engine/SnapshotStore.kt").readText()
        val merge = store.substringAfter("suspend fun merge(").substringBefore("private suspend fun mergeLocked(")
        val order = names.map { merge.indexOf(it) }
        assertTrue("merge must take stage, release, ledger in that order: $order", order.all { it >= 0 } && order == order.sorted())
        val recovery = File("src/main/kotlin/app/entesaver/engine/StartupRecovery.kt").readText()
        val repair = recovery.substringAfter("private suspend fun repairQueueOnce()").substringBefore("    /**")
        val repairOrder = names.map { repair.indexOf(it) }
        assertTrue("the repair takes them the same way: $repairOrder", repairOrder.all { it >= 0 } && repairOrder == repairOrder.sorted())
        assertTrue("the flag is set only after the repair landed", repair.indexOf("QUEUE_REPAIRED") > repair.indexOf("db.withTransaction"))
        assertTrue(recovery.contains("runCatching { repairQueueOnce() }"))
        // Nothing that holds one of the other locks reaches the stage lock.
        val main = File("src/main/kotlin/app/entesaver")
        for (f in main.walkTopDown().filter { it.isFile && it.extension == "kt" }) {
            val text = f.readText()
            for (outer in listOf("Locks.release.withLock {", "Locks.ledger.withLock {", "Locks.maintain.withLock {")) {
                var at = text.indexOf(outer)
                while (at >= 0) {
                    val body = text.substring(at, minOf(text.length, at + 1500))
                    assertFalse(
                        "${f.name} takes the stage lock while holding ${outer.substringBefore(".withLock")}",
                        body.contains("Locks.stage.withLock") || body.contains("Locks.stage.tryLock") ||
                            body.contains("Locks.stage.lock(") || body.contains(".take()")
                    )
                    at = text.indexOf(outer, at + 1)
                }
            }
        }
    }

    @Test
    fun `a video the run cut short waits, and the wait is a counted try`() {
        // An as-is copy is final: made because the run had five minutes
        // left, it was the full-size file Ente kept for good.
        val video = File("src/main/kotlin/app/entesaver/media/VideoCompressor.kt").readText()
        val end = video.substringAfter("fallback?.let { return it }").substringBefore("private suspend fun runTransform")
        assertTrue(
            "the cut-short case must be decided before the as-is copy",
            end.indexOf("throw OutOfTime(") in 0 until end.indexOf("copyAsIs(")
        )
        val stager = File("src/main/kotlin/app/entesaver/media/Stager.kt").readText()
        val late = stager.indexOf("catch (late: VideoCompressor.OutOfTime)")
        assertTrue(
            "Stager must catch it before the general failure",
            late in 0 until stager.indexOf("catch (e: Exception)", late.coerceAtLeast(0))
        )
        val caught = stager.substring(late).substringBefore("catch (e: Exception)")
        // Counted, so a phone whose runs never give the whole budget sets the
        // clip aside after three tries instead of starting it in every run.
        assertTrue("and must count it as a try", caught.contains("fail(row, OUT_OF_TIME)"))
        assertFalse("never as an as-is copy", caught.contains("copyAsIs("))
    }
}
