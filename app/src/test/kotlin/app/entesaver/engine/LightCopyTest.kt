package app.entesaver.engine

import app.entesaver.core.logic.Defaults
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Replace-with-light must be able to keep its promise even after the cloud
 * app has collected and deleted the optimised copy - the normal state of
 * affairs by the time anyone frees up space. The copy is then remade from the
 * original at the current quality setting, and NOTHING is put in front of
 * Android's removal dialog until the landed copy has been read back, hashed
 * and opened. A remade copy is the user's file in the user's album: it never
 * enters staging, the release queue, the ledger or the scanner.
 */
class LightCopyTest {

    private val engine =
        File("src/main/kotlin/app/entesaver/engine/ReclaimEngine.kt").readText()
    private val screen =
        File("src/main/kotlin/app/entesaver/ui/screens/ReclaimScreen.kt").readText()

    /**
     * Code without its prose.
     *
     * The banned-identifier rule below is about what the pin path CALLS. Read
     * over the comments too, it also punished the sentence explaining why the
     * pin path must not call those things - so a maintainer documenting the
     * rule broke it. ProductBoundariesTest already answers this the same way:
     * "the only mention of any refused feature in the codebase is the comment
     * explaining the refusal".
     */
    private fun code(text: String): String = text.lineSequence()
        .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
        .joinToString("\n")

    @Test
    fun `the light copies album is outside everything the scanner may touch`() {
        // Pure check, not a source grep: the exact path the engine writes to,
        // in every shape MediaStore reports it.
        assertTrue(Defaults.isAppOwnedPath(Defaults.KEPT_DIR))
        assertTrue(Defaults.isAppOwnedPath("${Defaults.KEPT_DIR}/"))
        assertTrue(Defaults.isAppOwnedPath("${Defaults.KEPT_DIR}/anything/"))
        assertFalse(Defaults.isAppOwnedPath("Pictures/Light copies backup/"))
    }

    @Test
    fun `a missing local copy is remade from the original the one way files are optimised`() {
        val source = engine.substringAfter("private suspend fun pinSource")
            .substringBefore("private suspend fun writeVerified")
        assertTrue(
            "the remake must use the same limits as every other copy",
            source.contains("MediaSettings.PHOTO") && source.contains("MediaSettings.VIDEO")
        )
        assertTrue(source.contains("PhotoCompressor.compress"))
        assertTrue(source.contains("VideoCompressor.compress"))
        assertTrue(
            "a gone original means nothing to remake from - never a guess",
            source.contains("if (row.originalMissing) return null")
        )
    }

    @Test
    fun `every source of bytes is verified by hash before it is trusted`() {
        val source = engine.substringAfter("private suspend fun pinSource")
            .substringBefore("private suspend fun writeVerified")
        // The stage file and the folder copy are only accepted when they
        // still hash to what was recorded at stage time.
        assertTrue(source.contains("sha == recorded"))
        // Two empty files hash identically; that match proves nothing.
        assertTrue(engine.contains("EMPTY_SHA256"))
    }

    @Test
    fun `the landed copy is read back, hashed and opened before publish`() {
        val write = engine.substringAfter("private suspend fun writeVerified")
            .substringBefore("private fun mimeForName")
        val verifyAt = write.indexOf("landed != src.sha256")
        val decodeAt = write.indexOf("looksDecodable")
        val publishAt = write.indexOf("put(MediaStore.MediaColumns.IS_PENDING, 0)")
        val recordAt = write.indexOf("keptUri = target.toString()")
        assertTrue("read-back hash must exist", verifyAt >= 0)
        assertTrue("decode probe must exist", decodeAt >= 0)
        assertTrue("publish must exist", publishAt >= 0)
        assertTrue(
            "verification must come before the copy is published or recorded",
            verifyAt < publishAt && decodeAt < publishAt && publishAt < recordAt
        )
        assertTrue(
            "a failed verification must delete the broken row",
            write.contains("resolver.delete(target")
        )
    }

    @Test
    fun `the removal request is only built after every copy is proved`() {
        // In the engine: a row whose copy cannot be made drops out, named,
        // before its original ever reaches the uris handed to Android.
        val prepare = engine.substringAfter("suspend fun prepare")
            .substringBefore("suspend fun finish")
        val failAt = prepare.indexOf("light_copy_failed")
        val addAt = prepare.indexOf("uris += original")
        assertTrue(failAt >= 0 && addAt >= 0 && failAt < addAt)
        assertTrue(
            "the failed row must leave the batch",
            prepare.substring(failAt, addAt).contains("continue")
        )
        // In the view model: prepare() runs before any consent is asked for.
        val vm = File("src/main/kotlin/app/entesaver/ui/ReclaimViewModel.kt").readText()
        val start = vm.substringAfter("fun start(permanent")
        val preparedAt = start.indexOf("engine.prepare")
        val askedAt = start.indexOf("beginConsent(ready.uris")
        assertTrue("start() no longer prepares the batch", preparedAt >= 0)
        assertTrue("start() no longer asks for consent", askedAt >= 0)
        assertTrue("consent is asked for before the copies are proved", preparedAt < askedAt)
    }

    @Test
    fun `a remade copy never enters the pipeline`() {
        val region = code(
            engine.substringAfter("suspend fun pinLightCopy")
                .substringBefore("suspend fun removeCopiesOnly")
        )
        // The only database write in the whole pin path is the keptUri stamp.
        val writes = Regex("""db\.items\(\)\.update""").findAll(region).count()
        assertEquals("pinning may record keptUri and nothing else", 1, writes)
        assertTrue(region.contains("keptUri = target.toString()"))
        for (banned in listOf("ItemState.", "stagePath =", "outputName =",
                "outputUri =", "Releaser", "insertBatch", "ledger()")) {
            assertFalse(
                "the pin path must not touch the pipeline ($banned)",
                region.contains(banned)
            )
        }
        assertTrue(
            "the copy lands in the user's album, nowhere else",
            region.contains("Defaults.KEPT_DIR")
        )
    }

    /**
     * In place means the original's own album, and the album has to be read
     * off the original rather than rebuilt from its bucket name: two folders
     * on one phone can carry the same name, and the app's own output folder
     * must never be the answer - the scanner reads a file there as a copy
     * that came back.
     */
    @Test
    fun `an in-place copy lands in the original's real folder, never the app's`() {
        val folder = engine.substringAfter("private fun originalFolder")
            .substringBefore("private fun inPlaceName")
        // RELATIVE_PATH, or on Android 9 the path it is derived from.
        assertTrue(
            "the folder must come from the original itself",
            folder.contains("arrayOf(MediaPaths.FOLDER_COLUMN)") &&
                folder.contains("MediaPaths.relativePath(c.getString(0))")
        )
        assertTrue(
            "our own folders can never be an in-place destination",
            folder.contains("if (Defaults.isAppOwnedPath(path)) return null")
        )
        val write = engine.substringAfter("private suspend fun writeVerified")
            .substringBefore("private fun originalFolder")
        assertTrue(
            "an unreadable folder falls back to the light copies album",
            write.contains("folder ?: \"\${Defaults.KEPT_DIR}/\"")
        )
        assertTrue(
            "and the copy must report where it actually landed",
            write.contains("Pinned(target, inPlace = folder != null)")
        )
    }

    /**
     * The timeline must not move. A gallery sorts on date-taken where there
     * is one and on the modified date otherwise - which is most video - so a
     * copy that carried only date-taken would jump to today on exactly the
     * files people notice most.
     */
    @Test
    fun `an in-place copy carries the original's dates`() {
        val write = engine.substringAfter("private suspend fun writeVerified")
            .substringBefore("private fun originalFolder")
        assertTrue(write.contains("put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt)"))
        assertTrue(
            write.contains("put(MediaStore.MediaColumns.DATE_MODIFIED, row.dateModified)")
        )
    }

    /**
     * The one real risk of writing into a scanned album: the next scan meets
     * the replacement, fingerprints it as something new, and optimises an
     * already optimised photo - losing quality every round and sending the
     * cloud a second copy of a file it already holds. The row is re-pointed
     * at the new file under the fingerprint the scanner itself will compute,
     * so the two meet as one photo, in a state that never re-queues.
     */
    @Test
    fun `an in-place replacement is never optimised a second time`() {
        val finish = engine.substringAfter("private suspend fun finishLocked")
            .substringBefore("private suspend fun recordBatch")
        assertTrue(
            "the new file's identity must be read back from MediaStore",
            finish.contains("identityOf(p.uri)")
        )
        for (field in listOf(
            "fingerprint = identity?.fingerprint",
            "contentUri = identity?.uri?.toString()",
            "mediaStoreId = identity?.mediaStoreId",
            "sizeBytes = identity?.sizeBytes",
            "dateModified = identity?.dateModified"
        )) {
            assertTrue("the row must follow the file it now stands for ($field)",
                finish.contains(field))
        }
        // Present only when the replacement could really be read back.
        assertTrue(finish.contains("originalMissing = identity == null"))
        // And the fingerprint is the scanner's own, not one invented here.
        val identity = engine.substringAfter("private fun identityOf")
            .substringBefore("Prepares a batch that removes originals")
        assertTrue(identity.contains("Fingerprint.fp16(name, size, modified)"))
    }

    /**
     * The guard against re-optimising a light copy does not rest on a value
     * the OS rewrites.
     *
     * The existing rule above pins the row to the file's identity, and that
     * identity is `fp16(name, size, dateModified)`. In place, the two updates
     * that set the copy's timeline write DATE_MODIFIED through ContentValues,
     * which does not touch the file's own mtime - so the row said one date and
     * the file said another. MediaProvider re-stats a file whose size or mtime
     * disagrees with its row and rewrites DATE_MODIFIED from the disk, which
     * silently changed the fingerprint the whole guard hung on. The copy then
     * read as a new photo: optimised again, and a second, worse copy of a
     * photo the cloud already held went back up.
     *
     * Two things now stop it, and this asserts both, because either one alone
     * is a single point of failure on someone else's phone.
     */
    @Test
    fun `the anti-re-optimise guard survives a media rescan`() {
        // 1. The file's real mtime is set, so there is no disagreement for
        //    MediaProvider to resolve. Releaser does this for its own output.
        val write = engine.substringAfter("private suspend fun writeVerified")
            .substringBefore("private fun inPlaceName")
        assertTrue(
            "the in-place copy must have its own mtime stamped, not just the row",
            write.contains("setLastModified(row.dateModified * 1000)")
        )
        assertTrue(
            "the mtime comes from the file MediaStore actually wrote",
            write.contains("MediaStore.MediaColumns.DATA")
        )

        // 2. Even if it drifts anyway, the scanner refuses the file by an
        //    identity that cannot drift.
        val scanner = File("src/main/kotlin/app/entesaver/media/MediaScanner.kt").readText()
        val scan = scanner.substringAfter("suspend fun scan()").substringBefore("private suspend fun recordReturnedCopy")
        assertTrue(
            "the scanner must know which files are kept light copies",
            scan.contains("keptCopies()")
        )
        assertTrue(
            "and skip them by content URI or MediaStore id, not by fingerprint",
            Regex("""keptByUri\[f\.uri\]|keptById\[f\.mediaStoreId\]""").containsMatchIn(scan)
        )
        // 3. But a number alone is not an identity: a restored row can carry
        //    another phone's MediaStore id, and that must not hide a real
        //    photo from the queue. The file has to look like the copy.
        assertTrue(
            "the skip must confirm the file is the copy the row describes",
            scan.contains("KeptCopies.isRowsCopy(")
        )
    }

    /**
     * A remade photo is held to the phone's memory ceiling exactly as the
     * background pass is, and a remake that takes the app down leaves a note
     * that keeps the same file from doing it again on the next try.
     */
    @Test
    fun `a remade copy respects the memory ceiling and the crash-loop guard`() {
        val source = code(
            engine.substringAfter("private suspend fun pinSource")
                .substringBefore("private suspend fun writeVerified")
        )
        assertTrue(
            "the remake must be capped like Stager's encode",
            source.contains("DeviceTier.fit(context, MediaSettings.PHOTO)")
        )
        val skipAt = source.indexOf("if (row.id == remakeDiedOn) return null")
        val noteAt = source.indexOf("InFlight.beginRemake(")
        val workAt = source.indexOf("PhotoCompressor.compress")
        val endAt = source.indexOf("InFlight.endRemake(")
        assertTrue("a file that took the app down sits the batch out", skipAt >= 0)
        assertTrue("the note is written before the work", noteAt in (skipAt + 1) until workAt)
        assertTrue("and cleared once the work comes back", endAt > workAt)
        assertTrue(source.substring(workAt, endAt).contains("finally"))
        // Read once, before the first remake of a batch overwrites it.
        val prepare = code(
            engine.substringAfter("suspend fun prepare").substringBefore("for (row in rows)")
        )
        assertTrue(prepare.contains("InFlight.recoverRemake(context)"))
    }

    /**
     * The kept copy must land under a name the scanner's skip and "Remove the
     * light copy" recognise, with its real type - or not be kept at all.
     */
    @Test
    fun `a light copy is only kept under a name it can be found by`() {
        val write = engine.substringAfter("private suspend fun writeVerified")
            .substringBefore("private fun originalFolder")
        val nameAt = write.indexOf("KeptCopies.belongsTo(landedName")
        val recordAt = write.indexOf("keptUri = target.toString()")
        assertTrue("the landed name must be read back and checked", nameAt >= 0)
        assertTrue("before the copy is recorded", nameAt < recordAt)
        val mime = engine.substringAfter("private fun mimeForName")
            .substringBefore("private fun looksDecodable")
        assertTrue(
            "the copy's type comes from the full table, HEIC and WebP included",
            mime.contains("FormatResolver.mimeOf(name, fallback)")
        )
    }

    /**
     * After consent the originals are gone, so finish() must get every row's
     * bookkeeping and the history written whatever one row does - and the
     * re-key to an in-place copy must not fight the scanner for the
     * fingerprint's unique index.
     */
    @Test
    fun `finishing a batch survives one row's bookkeeping failing`() {
        val finish = engine.substringAfter("private suspend fun finishLocked")
            .substringBefore("private suspend fun recordBatch")
        val loop = finish.substringBefore("private suspend fun settleFreed")
        assertTrue(loop.contains("settleFreed(row, kept, inPlace, now)"))
        assertTrue(
            "a failing row must not throw out of the batch",
            Regex("""catch \(e: Exception\)""").containsMatchIn(loop)
        )
        assertTrue(
            "the history is keyed by the fingerprint the row now carries",
            loop.contains("recorded += row.copy(fingerprint = historyKey)")
        )
        assertTrue(finish.contains("claimFingerprint(cur.id, identity.fingerprint)"))
        assertTrue(finish.contains("ReclaimRules.isUntouchedStray("))
        assertTrue(
            "a copy left in the upload folder goes with its original",
            finish.contains("ReclaimRules.leavesUploadCopy(start.state, copy)")
        )
    }

    /**
     * A row freed in place stands for its light copy; when its original is
     * restored the row has to point back at it, or the next scan queues the
     * original as new and a second copy goes up to the cloud.
     */
    @Test
    fun `restoring an in-place original points its row back at it`() {
        val restored = engine.substringAfter("suspend fun onRestored")
        assertTrue(restored.contains("row.contentUri == row.keptUri"))
        assertTrue(restored.contains("identityOf(it)"))
        assertTrue(restored.contains("claimFingerprint(cur.id, original.fingerprint)"))
        assertTrue(restored.contains("fingerprint = original.fingerprint"))
        assertTrue(restored.contains("contentUri = original.uri.toString()"))
        assertTrue(
            "a row that could not be pointed back must not offer its copy as an original",
            restored.contains("if (inPlace && !claimed) return@withTransaction")
        )
        assertFalse(
            "the copy beside it must stay known to the scanner",
            restored.contains("keptUri = null")
        )
    }

    @Test
    fun `refusing the removal still takes the copy back`() {
        val finish = engine.substringAfter("private suspend fun finishLocked")
            .substringBefore("private suspend fun recordBatch")
        assertTrue(finish.contains("unpinLightCopy(it.uri)"))
    }

    @Test
    fun `the in-place trade is stated where the choice is made`() {
        val strings = File("src/main/res/values/strings.xml").readText()
        for (name in listOf(
            "kept_in_place_title", "kept_in_place_body", "kept_in_place_warning"
        )) {
            assertTrue("$name must exist", strings.contains("name=\"$name\""))
        }
        val warning = strings.substringAfter("name=\"kept_in_place_warning\">")
            .substringBefore("</string>")
        // The two things that genuinely change, said outright.
        assertTrue("the extension change must be stated", warning.contains(".jpg"))
        assertTrue(
            "and that the album file is no longer the cloud's twin",
            warning.contains("byte-for-byte")
        )
        assertTrue(screen.contains("InPlaceChoice"))
        assertTrue(
            "the switch belongs to the mode it changes",
            screen.contains("if (option == mode) InPlaceChoice(rvm)")
        )
    }

    @Test
    fun `a dropped item is named on screen, with the reason`() {
        val strings = File("src/main/res/values/strings.xml").readText()
        assertTrue(strings.contains("name=\"skip_light_copy_failed\""))
        assertTrue(strings.contains("name=\"reclaim_mode_replace_note\""))
        assertTrue(screen.contains("skipReasonLabel"))
        assertTrue(screen.contains("reclaim_mode_replace_note"))
    }
}
