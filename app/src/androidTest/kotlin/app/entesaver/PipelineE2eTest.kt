package app.entesaver

import android.content.ContentValues
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.FolderName
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.QualityTarget
import app.entesaver.core.logic.VideoCodec
import app.entesaver.data.db.AppDb
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.MaintainEngine
import app.entesaver.media.EncoderCaps
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.media.Releaser
import app.entesaver.media.Stager
import app.entesaver.media.VideoCompressor
import app.entesaver.media.VideoQuality
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The real end-to-end run on a device: put genuine photos and a video into the
 * gallery, drive the actual pipeline, then check what landed in the upload
 * folder - sizes, dates, EXIF - and that the originals were never touched.
 */
@RunWith(AndroidJUnit4::class)
class PipelineE2eTest {

    /** Any failure below leaves a picture of the screen behind it. */
    @get:Rule
    val shotOnFailure = ScreenshotOnFailure()

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val captureAt = 1_600_000_000_000L

    @Before
    fun setUp() {
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
        runBlocking {
            AppDb.get(context).clearAllTables()
            OptionsRepo.get(context).useDefaultFolders()
            OptionsRepo.get(context).setConfirmWindow(null)
        }
    }

    @After
    fun tearDown() {
        MediaFixtures.cleanUp(context)
        clearOutputFolder()
    }

    @Test
    fun photosAreOptimisedReleasedAndDatedCorrectly() = runBlockingTest {
        val originals = (1..3).map { i ->
            MediaFixtures.insertPhoto(
                context,
                name = "e2e_photo_$i.jpg",
                seed = i,
                captureMillis = captureAt
            )
        }
        val originalSizes = originals.map { sizeOf(it) }
        assertTrue("fixtures should be non-trivial", originalSizes.all { it > 200_000 })

        val db = AppDb.get(context)
        val options = OptionsRepo.get(context).current()
        val found = MediaScanner(context, db).scan()
        assertTrue("scanner must see the fixtures", found >= 3)

        val queued = db.items().byState(ItemState.NEW.name)
            .filter { it.displayName.startsWith("e2e_photo_") }
        assertEquals(3, queued.size)

        val stager = Stager(context, db)
        for (row in queued) {
            assertTrue("staging ${row.displayName} failed", stager.stageOne(row, options))
        }

        val staged = db.items().staged().filter { it.displayName.startsWith("e2e_photo_") }
        assertEquals(3, staged.size)
        for (row in staged) {
            val out = row.outputBytes ?: 0
            assertTrue("copy must exist", File(row.stagePath!!).exists())
            assertTrue(
                "copy of ${row.displayName} ($out) must be smaller than ${row.sizeBytes}",
                out in 1 until row.sizeBytes
            )
            assertNotNull("sha must be recorded", row.outputSha256)
        }

        val released = Releaser(context, db).releaseBatch(options, System.currentTimeMillis())
        assertEquals(3, released)

        // For photos, DATE_TAKEN is MediaProvider's own derivation from EXIF -
        // it ignores what an app writes - so the contract the app can actually
        // keep is that the copy carries the original's shooting metadata, and
        // that its capture date matches the original's whenever MediaStore
        // reports one at all. The EXIF assertions below are the real check.
        val originalTaken = dateTakenOf(originals.first())
        val recordedCaptureAt = staged.first().captureAt
        assertTrue(
            "the app must have recorded a capture date, got $recordedCaptureAt",
            recordedCaptureAt > 0
        )

        val inFolder = OutputInventory(context).query()
        assertNotNull("the output folder must be readable", inFolder)
        assertEquals(3, inFolder!!.size)
        for (entry in inFolder) {
            assertEquals(Defaults.OUTPUT_DIR, entry.relPath.trimEnd('/'))
            // Android 9 records no owner for a file at all.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                assertTrue("copy must be owned by us", entry.ownedByUs)
            }
            if (originalTaken > 0 && entry.dateTaken > 0) {
                assertTrue(
                    "copy DATE_TAKEN ${entry.dateTaken} must match the original's " +
                        "$originalTaken (app recorded $recordedCaptureAt)",
                    abs(entry.dateTaken - originalTaken) < 2000
                )
            }
            // The optimised copy keeps the shooting metadata.
            context.contentResolver.openInputStream(entry.uri)!!.use { input ->
                val exif = ExifInterface(input)
                assertEquals(
                    "2020:09:13 12:26:40",
                    exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                )
                assertEquals("EnteSaverTest", exif.getAttribute(ExifInterface.TAG_MAKE))
                assertNotNull("GPS must survive", exif.latLong)
                assertEquals(
                    "orientation must be baked in",
                    ExifInterface.ORIENTATION_NORMAL,
                    exif.getAttributeInt(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_UNDEFINED
                    )
                )
            }
        }

        // The whole point of the app: originals are exactly as they were.
        originals.forEachIndexed { index, uri ->
            assertEquals(
                "original ${index + 1} must be untouched",
                originalSizes[index],
                sizeOf(uri)
            )
        }

        // Bookkeeping pass must run clean over real data.
        MaintainEngine(context).run()
        val after = db.items().released().filter { it.displayName.startsWith("e2e_photo_") }
        assertEquals(3, after.size)
    }

    @Test
    fun videoIsOptimisedOrSafelyCopied() = runBlockingTest {
        // Every Android device that can record has an H.264 encoder, and the
        // emulator carries the software one, so a null here is a real failure
        // rather than a reason to pass quietly. A test that returns early on
        // the very condition it exists to exercise proves nothing.
        val uri = MediaFixtures.insertVideo(context, "e2e_clip.mp4")
        assertNotNull("the device must be able to produce a test clip", uri)
        uri!!
        val srcSize = sizeOf(uri)
        val db = AppDb.get(context)
        val options = OptionsRepo.get(context).current()
        MediaScanner(context, db).scan()

        val row = db.items().byState(ItemState.NEW.name)
            .firstOrNull { it.displayName == "e2e_clip.mp4" }
        assertNotNull("scanner must see the clip", row)

        assertTrue("video staging must succeed", Stager(context, db).stageOne(row!!, options))
        val staged = db.items().staged().first { it.displayName == "e2e_clip.mp4" }
        val out = staged.outputBytes ?: 0
        assertTrue("a copy must exist", out > 0)
        // Either it compressed, or it fell back to an as-is copy - never bigger.
        assertTrue("copy must not be larger than the source", out <= srcSize)
        assertTrue(File(staged.stagePath!!).exists())
    }

    /**
     * A clip that goes in with sound comes out with sound.
     *
     * The export sequence names which tracks it carries, and the exporter
     * strips any it does not name - so the one-line choice of how that
     * sequence is built decides whether every optimised video keeps its
     * audio. The wrong choice would fail no other test: the copy would be
     * smaller, valid, and silent.
     */
    @Test
    fun videoKeepsItsSound() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(context, "e2e_talkie.mp4", withAudio = true)
        assertNotNull("the device must be able to produce a clip with an audio track", uri)
        assertTrue("the fixture itself must carry audio", hasAudioTrack(uri!!.toString()))
        val db = AppDb.get(context)
        val options = OptionsRepo.get(context).current()
        MediaScanner(context, db).scan()
        val row = db.items().byState(ItemState.NEW.name)
            .firstOrNull { it.displayName == "e2e_talkie.mp4" }
        assertNotNull("scanner must see the clip", row)
        assertTrue("video staging must succeed", Stager(context, db).stageOne(row!!, options))
        val staged = db.items().staged().first { it.displayName == "e2e_talkie.mp4" }
        val path = staged.stagePath!!
        assertTrue(File(path).exists())
        assertTrue(
            "the optimised copy lost its audio track",
            hasAudioTrack(path)
        )
    }

    /**
     * The other half of the promise: a clip that goes in silent comes out
     * silent. Naming audio in the export sequence makes Media3 generate a
     * silent track for a clip that has none - a timelapse would come back
     * with an audio track it never had, larger and lying about itself.
     */
    @Test
    fun videoOnlyClipGainsNoSound() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(context, "e2e_silent.mp4")
        assertNotNull("the device must be able to produce a test clip", uri)
        assertFalse("the fixture itself must be silent", hasAudioTrack(uri!!.toString()))
        val db = AppDb.get(context)
        val options = OptionsRepo.get(context).current()
        MediaScanner(context, db).scan()
        val row = db.items().byState(ItemState.NEW.name)
            .firstOrNull { it.displayName == "e2e_silent.mp4" }
        assertNotNull("scanner must see the clip", row)
        assertTrue("video staging must succeed", Stager(context, db).stageOne(row!!, options))
        val staged = db.items().staged().first { it.displayName == "e2e_silent.mp4" }
        assertFalse(
            "the optimised copy of a silent clip was given an audio track",
            hasAudioTrack(staged.stagePath!!)
        )
    }

    /**
     * A 60 fps clip keeps every frame: a copy keeps everything about a video
     * but its bitrate, and its smoothness is part of it.
     */
    @Test
    fun aSixtyFpsClipKeepsEveryFrame() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_sixty.mp4", width = 640, height = 360, frames = 120, fps = 60
        )
        assertNotNull("the device must be able to produce a 60 fps clip", uri)
        val src = File(context.cacheDir, "sixty_out").apply { mkdirs() }
        val result = VideoCompressor.compress(
            context, uri!!, "e2e_sixty.mp4", "video/mp4", sizeOf(uri),
            MediaSettings.VIDEO, src
        )
        try {
            assertFalse(
                "the clip must be re-encoded, got ${result.reason} (${result.detail}; source ${sizeOf(uri)} bytes)",
                result.asIs
            )
            val frames = videoFrames(result.file.absolutePath)
            assertTrue("every one of the 120 frames is kept, counted $frames", frames in 118..122)
            assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, videoMime(result.file.absolutePath))
        } finally {
            result.file.delete()
        }
    }

    /**
     * A camera's clip comes back the same in all but its bitrate: H.264
     * still, the same size shown the same way round, stored with the same
     * rotation, every frame, and the place and date it was filmed.
     */
    @Test
    fun aCameraClipKeepsItsCodecSizeRotationPlaceAndDate() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_same.mp4", width = 640, height = 360, frames = 60, fps = 30,
            rotation = 90, place = 28.6139f to 77.2090f
        )
        assertNotNull("the device must be able to produce a test clip", uri)
        val out = File(context.cacheDir, "same_out").apply { mkdirs() }
        val result = VideoCompressor.compress(
            context, uri!!, "e2e_same.mp4", "video/mp4", sizeOf(uri), MediaSettings.VIDEO, out
        )
        try {
            assertFalse("the clip must be re-encoded, got ${result.reason} (${result.detail})", result.asIs)
            assertEquals(VideoCodec.H264, result.codec)
            val copy = result.file.absolutePath
            assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, videoMime(copy))
            val was = meta { setDataSource(context, uri) }
            val now = meta { setDataSource(copy) }
            assertEquals("shown at the same size", was.shown, now.shown)
            assertEquals("stored with the same rotation", was.rotation, now.rotation)
            assertEquals("the place it was filmed", was.place, now.place)
            assertTrue("the original carries a place to keep: ${was.place}", was.place.isNotEmpty())
            assertEquals("the date it was filmed", was.date, now.date)
            val frames = videoFrames(copy)
            assertTrue("every one of the 60 frames is kept, counted $frames", frames in 58..62)
        } finally {
            result.file.delete()
        }
    }

    /**
     * A copy is kept only once it measures as looking like its original: the
     * score it reached is kept with it, at the target or above. And the
     * measure itself reads a file against an exact copy of itself as the
     * same picture.
     */
    @Test
    fun aCopyIsKeptOnlyWhenItMeasuresAsLookingLikeItsOriginal() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_vmaf.mp4", width = 640, height = 360, frames = 90, fps = 30, textured = true
        )
        assertNotNull("the device must be able to produce a test clip", uri)
        val out = File(context.cacheDir, "vmaf_out").apply { mkdirs() }
        val result = VideoCompressor.compress(
            context, uri!!, "e2e_vmaf.mp4", "video/mp4", sizeOf(uri), MediaSettings.VIDEO, out
        )
        try {
            assertFalse("the clip must be re-encoded, got ${result.reason} (${result.detail})", result.asIs)
            val vmaf = Regex("vmaf=([0-9.]+)").find(result.reason)?.groupValues?.get(1)?.toDoubleOrNull()
            assertNotNull("the copy's score is kept with it: ${result.reason}", vmaf)
            assertTrue("it reaches the target: $vmaf", vmaf!! >= QualityTarget.SEARCH_VMAF)
            val same = File(out, "same.mp4")
            context.contentResolver.openInputStream(uri)!!.use { input -> same.outputStream().use { input.copyTo(it) } }
            val probe = VideoCompressor.probe(context, uri)!!
            val quality = VideoQuality.of(context, uri, probe.durationMs, probe.fps, probe.width, probe.height)
            assertNotNull("the original's frames must be readable", quality)
            val self = quality!!.score(same)
            assertNotNull("an exact copy's frames must be readable", self)
            assertTrue("an exact copy scores as the same picture, got ${self!!.vmaf}", self.vmaf > 95)
        } finally {
            result.file.delete()
            out.deleteRecursively()
        }
    }

    /**
     * A long clip's rate is looked for on short stretches of it first, and
     * the whole clip is copied once at what they found: the same promise as
     * any other copy, kept a quicker way. A test clip of seconds takes that
     * path with the length it starts at lowered for it.
     */
    @Test
    fun aLongClipIsSearchedOnStretchesOfItselfFirst() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_long.mp4", width = 640, height = 360, frames = 600, fps = 30, textured = true
        )
        assertNotNull("the device must be able to produce a test clip", uri)
        val out = File(context.cacheDir, "long_out").apply { mkdirs() }
        VideoCompressor.excerptsAboveMsForTest = 1_000L
        try {
            val result = VideoCompressor.compress(
                context, uri!!, "e2e_long.mp4", "video/mp4", sizeOf(uri), MediaSettings.VIDEO, out
            )
            assertFalse("the clip must be re-encoded, got ${result.reason} (${result.detail})", result.asIs)
            assertTrue("its stretches were searched first: ${result.reason}", "excerpts=" in result.reason)
            val vmaf = Regex("vmaf=([0-9.]+)").find(result.reason)?.groupValues?.get(1)?.toDoubleOrNull()
            assertTrue("the whole copy reaches the target: $vmaf", vmaf != null && vmaf >= QualityTarget.SEARCH_VMAF)
            val frames = videoFrames(result.file.absolutePath)
            assertTrue("every one of the 600 frames is kept, counted $frames", frames in 594..606)
            result.file.delete()
        } finally {
            VideoCompressor.excerptsAboveMsForTest = null
            out.deleteRecursively()
        }
    }

    /**
     * A clip stored upright with no rotation - a screen recording, a reel -
     * is written upright too: the same stored size and the same rotation tag,
     * not laid on its side and marked to be turned back.
     */
    @Test
    fun aPortraitClipIsStoredUprightAsItWas() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_upright.mp4", width = 360, height = 640, frames = 60, fps = 30
        )
        assertNotNull("the device must be able to produce a portrait clip", uri)
        val out = File(context.cacheDir, "upright_out").apply { mkdirs() }
        val result = VideoCompressor.compress(
            context, uri!!, "e2e_upright.mp4", "video/mp4", sizeOf(uri), MediaSettings.VIDEO, out
        )
        try {
            assertFalse("the clip must be re-encoded, got ${result.reason} (${result.detail})", result.asIs)
            val was = meta { setDataSource(context, uri) }
            val now = meta { setDataSource(result.file.absolutePath) }
            assertEquals("stored the same way round", was.width to was.height, now.width to now.height)
            assertEquals("with the same rotation tag", was.rotation, now.rotation)
        } finally {
            result.file.delete()
        }
    }

    /**
     * An HEVC clip is never written as H.264: a copy keeps its codec, so on
     * a phone without an HEVC chip - every emulator - it stays as it is.
     */
    @Test
    fun anHevcClipIsNeverWrittenAsH264() = runBlockingTest {
        val uri = MediaFixtures.insertVideo(
            context, "e2e_hevc.mp4", width = 320, height = 240, frames = 30, fps = 30,
            mime = MediaFormat.MIMETYPE_VIDEO_HEVC
        )
        assumeTrue("this device cannot make an HEVC clip", uri != null)
        val out = File(context.cacheDir, "hevc_out").apply { mkdirs() }
        val result = VideoCompressor.compress(
            context, uri!!, "e2e_hevc.mp4", "video/mp4", sizeOf(uri), MediaSettings.VIDEO, out
        )
        try {
            if (result.asIs) {
                if (!EncoderCaps.hardwareFits(MediaFormat.MIMETYPE_VIDEO_HEVC, 320, 240, 30f)) {
                    assertEquals(VideoCompressor.CHIP_CANNOT_KEEP, result.reason)
                }
            } else {
                assertEquals(VideoCodec.HEVC, result.codec)
                assertEquals(MediaFormat.MIMETYPE_VIDEO_HEVC, videoMime(result.file.absolutePath))
            }
        } finally {
            result.file.delete()
        }
    }

    /** A video's size, rotation, date and place, as Android's own reader gives them. */
    private data class Meta(val width: Int, val height: Int, val rotation: Int, val date: String, val place: String) {
        val shown: Pair<Int, Int> get() = if (rotation % 180 != 0) height to width else width to height
    }

    private fun meta(open: MediaMetadataRetriever.() -> Unit): Meta {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.open()
            Meta(
                mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0,
                mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0,
                mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0,
                mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE).orEmpty(),
                mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION).orEmpty()
            )
        } finally {
            mmr.release()
        }
    }

    private fun videoFrames(path: String): Int {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            }
            extractor.selectTrack(track)
            var frames = 0
            while (extractor.sampleTime >= 0) {
                frames++
                extractor.advance()
            }
            frames
        } finally {
            extractor.release()
        }
    }

    private fun videoMime(path: String): String? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount).map { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) }
                .firstOrNull { it?.startsWith("video/") == true }
        } finally {
            extractor.release()
        }
    }

    /** True when the container at [source] (a path or a content URI) has an audio track. */
    private fun hasAudioTrack(source: String): Boolean {
        val ex = MediaExtractor()
        return try {
            if (source.startsWith("content:")) {
                ex.setDataSource(context, Uri.parse(source), null)
            } else {
                ex.setDataSource(source)
            }
            (0 until ex.trackCount).any { i ->
                ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            }
        } finally {
            runCatching { ex.release() }
        }
    }

    /**
     * A copy that leaves the folders the app looks at is read as collected,
     * and its original is offered for deletion. So when the person picks a
     * new folder, the copies still waiting in the old one must stay watched:
     * here maintenance runs while the "back from Ente's Free up space" window
     * is open - the moment every missing copy counts as uploaded - and the
     * waiting copies must still be seen. Only once they really leave are they
     * confirmed, and only then is the old folder let go.
     */
    @Test
    fun aNewFolderNeverMakesWaitingCopiesLookUploaded() = runBlockingTest {
        val moved = FolderName.pathOf("E2eMovedFolder")
        val repo = OptionsRepo.get(context)
        try {
            (1..2).forEach { i ->
                MediaFixtures.insertPhoto(
                    context,
                    name = "e2e_move_$i.jpg",
                    seed = 20 + i,
                    captureMillis = captureAt
                )
            }
            val db = AppDb.get(context)
            MediaScanner(context, db).scan()
            val stager = Stager(context, db)
            val before = repo.current()
            for (row in db.items().byState(ItemState.NEW.name).filter { it.displayName.startsWith("e2e_move_") }) {
                assertTrue(stager.stageOne(row, before))
            }
            assertEquals(2, Releaser(context, db).releaseBatch(before, System.currentTimeMillis()))

            repo.setFolders(mapOf(OutFolder.SINGLE to moved))
            val after = repo.current()
            assertTrue(
                "the old folder must be remembered: ${after.pastOutputRoots}",
                after.pastOutputRoots.any { it.trimEnd('/') == Defaults.OUTPUT_DIR }
            )

            assertNotNull(MaintainEngine(context).openConfirmWindow())
            MaintainEngine(context).confirmPass()
            MaintainEngine(context).run()
            val waiting = db.items().released().filter { it.displayName.startsWith("e2e_move_") }
            assertEquals("copies still in the old folder are still waiting", 2, waiting.size)
            assertTrue(waiting.all { it.outputRelPath?.trimEnd('/') == Defaults.OUTPUT_DIR })

            // A new copy goes to the new folder.
            MediaFixtures.insertPhoto(context, name = "e2e_move_3.jpg", seed = 23, captureMillis = captureAt)
            MediaScanner(context, db).scan()
            val third = db.items().byState(ItemState.NEW.name).single { it.displayName == "e2e_move_3.jpg" }
            assertTrue(stager.stageOne(third, after))
            assertEquals(1, Releaser(context, db).releaseBatch(after, System.currentTimeMillis()))
            assertEquals(1, OutputInventory(context).query(listOf(moved)).orEmpty().size)
            assertEquals(
                moved,
                db.items().released().single { it.displayName == "e2e_move_3.jpg" }.outputRelPath?.trimEnd('/')
            )

            // Ente collects the old folder's copies: now they are confirmed,
            // and the emptied folder is let go.
            for (entry in OutputInventory(context).query(listOf(Defaults.OUTPUT_DIR)).orEmpty()) {
                context.contentResolver.delete(entry.uri, null, null)
            }
            assertEquals(2, MaintainEngine(context).returnPass())
            MaintainEngine(context).run()
            assertTrue(
                "collected copies are no longer waiting",
                db.items().released().none { it.displayName == "e2e_move_1.jpg" || it.displayName == "e2e_move_2.jpg" }
            )
            assertTrue(
                "copies there at the tap and gone on the return were collected",
                waiting.all { db.items().byId(it.id)?.evidence == Evidence.CONFIRMED_EXACT.name }
            )
            assertTrue(
                "the emptied old folder is let go",
                repo.current().pastOutputRoots.none { it.trimEnd('/') == Defaults.OUTPUT_DIR }
            )
        } finally {
            for (entry in OutputInventory(context).query(listOf(moved)).orEmpty()) {
                runCatching { context.contentResolver.delete(entry.uri, null, null) }
            }
            repo.useDefaultFolders()
        }
    }

    /**
     * A folder renamed in a file manager takes its copies with it. They are
     * gone from the folder the app watches, but not gone: even inside the
     * "back from Ente's Free up space" window, a copy that still exists is
     * followed to where it is, never counted as collected.
     */
    @Test
    fun aCopyMovedElsewhereIsFollowedNotCountedAsUploaded() = runBlockingTest {
        val elsewhere = "Pictures/E2eRenamedByHand/"
        val repo = OptionsRepo.get(context)
        try {
            MediaFixtures.insertPhoto(context, name = "e2e_moved_1.jpg", seed = 31, captureMillis = captureAt)
            val db = AppDb.get(context)
            MediaScanner(context, db).scan()
            val options = repo.current()
            val row = db.items().byState(ItemState.NEW.name).single { it.displayName == "e2e_moved_1.jpg" }
            assertTrue(Stager(context, db).stageOne(row, options))
            assertEquals(1, Releaser(context, db).releaseBatch(options, System.currentTimeMillis()))
            val released = db.items().released().single { it.displayName == "e2e_moved_1.jpg" }

            // A person renames a folder long after a release; here it is the
            // very next moment, while the release's own gallery nudge may still
            // be rescanning the folder. A rescan that read the copy before the
            // move and writes after it puts the copy's row back where it was.
            awaitGalleryRescan(released.outputRelPath!!)
            val window = MaintainEngine(context).openConfirmWindow()!!
            assertTrue("the copy is there at the tap", released.id in window.presentAtTap)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val moved = ContentValues().apply { put(MediaStore.MediaColumns.RELATIVE_PATH, elsewhere) }
                assertEquals(1, context.contentResolver.update(Uri.parse(released.outputUri), moved, null, null))
            } else {
                moveOnDisk(Uri.parse(released.outputUri), elsewhere)
            }

            // The gallery finishes a move in its own time - Android 12 may
            // even give the file a new address - so the return pass runs
            // again and again, until the copy has been followed. At no pass
            // may it be counted as collected: it still exists.
            var after = db.items().byId(released.id)!!
            for (pass in 1..10) {
                MaintainEngine(context).confirmPass(window)
                after = db.items().byId(released.id)!!
                assertEquals("a moved copy is still waiting (pass $pass)", ItemState.RELEASED.name, after.state)
                if (after.outputRelPath?.trimEnd('/') == elsewhere.trimEnd('/')) break
                delay(500)
            }
            assertEquals(elsewhere.trimEnd('/'), after.outputRelPath?.trimEnd('/'))
        } finally {
            for (entry in OutputInventory(context).query(listOf(elsewhere)).orEmpty()) {
                runCatching { context.contentResolver.delete(entry.uri, null, null) }
            }
            repo.setConfirmWindow(null)
        }
    }

    /**
     * "Confirm uploads" believes only what left the folder after the tap.
     * A copy cleared by hand before it - the gallery, a cleaner app - must
     * never be counted as collected by Ente on the return, and outside the
     * one return pass no missing copy is counted as collected at all.
     */
    @Test
    fun onlyCopiesThereAtTheTapCountAsCollected() = runBlockingTest {
        val db = AppDb.get(context)
        val options = OptionsRepo.get(context).current()
        (1..3).forEach { i ->
            MediaFixtures.insertPhoto(context, name = "e2e_tap_$i.jpg", seed = 40 + i, captureMillis = captureAt)
        }
        MediaScanner(context, db).scan()
        for (row in db.items().byState(ItemState.NEW.name).filter { it.displayName.startsWith("e2e_tap_") }) {
            assertTrue(Stager(context, db).stageOne(row, options))
        }
        assertEquals(3, Releaser(context, db).releaseBatch(options, System.currentTimeMillis()))
        val rows = db.items().released().filter { it.displayName.startsWith("e2e_tap_") }
            .associateBy { it.displayName }
        val before = rows.getValue("e2e_tap_1.jpg")
        val during = rows.getValue("e2e_tap_2.jpg")
        val later = rows.getValue("e2e_tap_3.jpg")

        // Cleared by hand before the tap.
        assertEquals(1, context.contentResolver.delete(Uri.parse(before.outputUri), null, null))
        val window = MaintainEngine(context).openConfirmWindow()!!
        assertFalse(before.id in window.presentAtTap)
        assertTrue(during.id in window.presentAtTap)

        // Collected while the person is in Ente, judged on the return.
        assertEquals(1, context.contentResolver.delete(Uri.parse(during.outputUri), null, null))
        assertEquals(1, MaintainEngine(context).returnPass())
        assertEquals(Evidence.CONFIRMED_EXACT.name, db.items().byId(during.id)?.evidence)
        assertTrue(
            "a copy gone before the tap is not counted as uploaded",
            db.items().byId(before.id)?.evidence != Evidence.CONFIRMED_EXACT.name
        )

        // Cleared after the return: an ordinary pass never counts it.
        assertEquals(1, context.contentResolver.delete(Uri.parse(later.outputUri), null, null))
        MaintainEngine(context).run()
        MaintainEngine(context).confirmPass()
        assertTrue(
            "a copy gone outside the return pass is not counted as uploaded",
            db.items().byId(later.id)?.evidence != Evidence.CONFIRMED_EXACT.name
        )
    }

    /**
     * A pass that runs while the person is on Ente's free-up screen - the
     * hourly worker, the end of a compress run - leaves the copies Ente is
     * collecting for the return to judge. The return reads the window from
     * storage, so a fresh engine, as a new process would build, still counts
     * them; and the window is spent by that one pass.
     */
    @Test
    fun aPassDuringTheEnteVisitLeavesCollectedCopiesForTheReturn() = runBlockingTest {
        val db = AppDb.get(context)
        val repo = OptionsRepo.get(context)
        try {
            val options = repo.current()
            MediaFixtures.insertPhoto(context, name = "e2e_held_1.jpg", seed = 51, captureMillis = captureAt)
            MediaScanner(context, db).scan()
            val row = db.items().byState(ItemState.NEW.name).single { it.displayName == "e2e_held_1.jpg" }
            assertTrue(Stager(context, db).stageOne(row, options))
            assertEquals(1, Releaser(context, db).releaseBatch(options, System.currentTimeMillis()))
            val released = db.items().released().single { it.displayName == "e2e_held_1.jpg" }
            awaitGalleryRescan(released.outputRelPath!!)
            val window = MaintainEngine(context).openConfirmWindow()!!
            assertTrue(released.id in window.presentAtTap)
            assertEquals(window, repo.current().confirmWindow)

            // Ente collects it, and ordinary passes run before the return.
            assertEquals(1, context.contentResolver.delete(Uri.parse(released.outputUri), null, null))
            MaintainEngine(context).run()
            MaintainEngine(context).confirmPass()
            val during = db.items().byId(released.id)!!
            assertEquals("left for the return", ItemState.RELEASED.name, during.state)
            assertEquals(Evidence.NONE.name, Evidence.parse(during.evidence).name)
            assertEquals(released.resendCount, during.resendCount)

            assertEquals(1, MaintainEngine(context).returnPass())
            assertEquals(Evidence.CONFIRMED_EXACT.name, db.items().byId(released.id)?.evidence)
            assertNull("the window is spent", repo.current().confirmWindow)
            assertNull("a second return judges nothing", MaintainEngine(context).returnPass())
        } finally {
            repo.setConfirmWindow(null)
        }
    }

    /**
     * A window nobody came back to within the hour holds nothing: it is
     * cleared, and its copies are judged by the normal rules - never
     * counted as collected, and never left waiting on it for good.
     */
    @Test
    fun aClosedWindowIsClearedAndItsCopiesJudgedNormally() = runBlockingTest {
        val db = AppDb.get(context)
        val repo = OptionsRepo.get(context)
        try {
            val options = repo.current()
            MediaFixtures.insertPhoto(context, name = "e2e_late_1.jpg", seed = 61, captureMillis = captureAt)
            MediaScanner(context, db).scan()
            val row = db.items().byState(ItemState.NEW.name).single { it.displayName == "e2e_late_1.jpg" }
            assertTrue(Stager(context, db).stageOne(row, options))
            assertEquals(1, Releaser(context, db).releaseBatch(options, System.currentTimeMillis()))
            val released = db.items().released().single { it.displayName == "e2e_late_1.jpg" }
            awaitGalleryRescan(released.outputRelPath!!)
            val tappedAt = System.currentTimeMillis() - Defaults.CONFIRM_WINDOW_MS - 1
            val window = MaintainEngine(context).openConfirmWindow(tappedAt)!!
            assertTrue(released.id in window.presentAtTap)

            assertEquals(1, context.contentResolver.delete(Uri.parse(released.outputUri), null, null))
            MaintainEngine(context).run()
            assertNull("a closed window is cleared", repo.current().confirmWindow)
            assertNull(MaintainEngine(context).returnPass())
            assertFalse(db.items().byId(released.id)?.evidence == Evidence.CONFIRMED_EXACT.name)
        } finally {
            repo.setConfirmWindow(null)
        }
    }

    @Test
    fun skippedAndEmptyStatesDoNotCrash() = runBlockingTest {
        val db = AppDb.get(context)
        // No fixtures at all: every stage must be a no-op, not an exception.
        MediaScanner(context, db).scan()
        Releaser(context, db).releaseBatch(
            OptionsRepo.get(context).current(),
            System.currentTimeMillis()
        )
        MaintainEngine(context).run()
    }

    /** JUnit needs void test methods; this pins the return type to Unit. */
    private fun runBlockingTest(body: suspend () -> Unit) {
        runBlocking { body() }
    }

    private fun sizeOf(uri: Uri): Long =
        context.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null
        )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: 0L

    private fun dateTakenOf(uri: Uri): Long =
        context.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null
        )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: 0L

    /**
     * Returns once every gallery rescan this process has asked for so far is
     * done. Rescans run one after another on the process's one background
     * thread, so a rescan of our own, queued behind them, ends after they do.
     */
    private fun awaitGalleryRescan(relPath: String) {
        val done = CountDownLatch(1)
        MediaScannerConnection.scanFile(
            context, arrayOf("${Environment.getExternalStorageDirectory()}/$relPath"), null
        ) { _, _ -> done.countDown() }
        assertTrue("the gallery rescan did not finish", done.await(60, TimeUnit.SECONDS))
    }

    /**
     * A move the way a file manager makes one on Android 9, which has no
     * RELATIVE_PATH to change: the file itself goes to [relativeDir], and
     * MediaStore is told its new path.
     */
    @Suppress("DEPRECATION")
    private fun moveOnDisk(item: Uri, relativeDir: String) {
        val from = context.contentResolver.query(
            item, arrayOf(MediaStore.MediaColumns.DATA), null, null, null
        )!!.use { c -> assertTrue("the copy must be in MediaStore", c.moveToFirst()); File(c.getString(0)) }
        val dir = File(Environment.getExternalStorageDirectory(), relativeDir.trim('/')).apply { mkdirs() }
        val to = File(dir, from.name)
        assertTrue("the copy must move on disk", from.renameTo(to))
        val path = ContentValues().apply { put(MediaStore.MediaColumns.DATA, to.absolutePath) }
        assertEquals(1, context.contentResolver.update(item, path, null, null))
    }

    private fun clearOutputFolder() {
        for (entry in OutputInventory(context).query().orEmpty()) {
            runCatching { context.contentResolver.delete(entry.uri, null, null) }
        }
        runCatching {
            File(context.getExternalFilesDir(null), "stage").deleteRecursively()
        }
    }
}
