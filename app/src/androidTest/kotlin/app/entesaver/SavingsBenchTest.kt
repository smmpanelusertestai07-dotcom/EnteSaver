package app.entesaver

import android.app.ActivityManager
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.work.WorkManager
import app.entesaver.core.logic.BitrateCalc
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.VideoCodec
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.EncoderCaps
import app.entesaver.media.MediaScanner
import app.entesaver.media.Stager
import app.entesaver.util.DeviceTier
import java.io.File
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * How much room Ente Saver makes on a phone full of ordinary videos, and how
 * good the copies are: a measurement, not a check, and not part of the suite.
 *
 * The savings-bench workflow fills an emulator's gallery with a library made
 * to look like a real phone's - camera clips at every setting, WhatsApp
 * forwards, saved reels, downloads, screen recordings, an old phone's clips -
 * and runs this class with `-e savingsBench true`. It goes through Ente
 * Saver's own pipeline: the scanner, then the Stager exactly as a scheduled
 * run calls it, making copies (Copies for Ente) at Google Photos' Storage
 * saver limits (16 MP photos, 1080p videos). One CSV line per video says
 * what went in, what came out - read
 * from the file the app wrote, track by track - and why a file was kept as it
 * was. The copies of the files named by `-e keep` (base64url of one name per
 * line) are kept in files/savings/keep for the workflow to grade against
 * their originals; every other copy is deleted once measured. Without
 * `savingsBench` it skips, so the end-to-end suite never pays for it.
 */
@RunWith(AndroidJUnit4::class)
class SavingsBenchTest {

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val args: Bundle get() = InstrumentationRegistry.getArguments()

    @Test
    fun overThePushedLibrary() = runBlocking {
        assumeTrue("a benchmark: run with -e savingsBench true", args.getString("savingsBench") == "true")
        val expected = args.getString("expected")?.toIntOrNull() ?: 0
        val keepNames = keepList(args.getString("keep"))

        // A fresh install schedules nothing that compresses, but a run the
        // app started on its own would take files from under this loop.
        WorkManager.getInstance(context).cancelAllWork()
        val db = AppDb.get(context)
        db.clearAllTables()
        val repo = OptionsRepo.get(context)
        repo.useDefaultFolders()
        // Copies for Ente: the app writes each copy beside its original, and
        // that copy is what is measured. Replace on this phone - a new
        // install's default - would overwrite the pushed library instead.
        repo.setString(OptionsRepo.K.SAVE_MODE, SaveMode.COPIES.name)
        val options = repo.current()
        check(options.saveMode == SaveMode.COPIES) { "the benchmark measures copies, not replaced originals" }

        val out = File(context.filesDir, "savings").apply { mkdirs() }
        val keepDir = File(out, "keep").apply {
            deleteRecursively()
            mkdirs()
        }
        val csv = File(out, "savings.csv")
        csv.writeText(HEADER + "\n")

        // MediaStore indexes what was pushed in the background; measuring
        // before it is done would quietly measure part of the library.
        val waitUntil = SystemClock.elapsedRealtime() + SCAN_WAIT_MS
        var videos: List<ItemRow>
        while (true) {
            MediaScanner(context, db).scan()
            videos = db.items().byState(ItemState.NEW.name).filter { it.isVideo }
            if (videos.size >= expected || SystemClock.elapsedRealtime() > waitUntil) break
            delay(10_000)
        }
        val device = File(out, "device.txt")
        device.writeText(deviceReport(expected, videos.size, keepNames.size))
        Log.i(TAG, "found ${videos.size} of $expected videos; ${keepNames.size} copies to keep")

        val stager = Stager(context, db)
        var kept = 0
        for ((i, row) in videos.sortedBy { it.displayName }.withIndex()) {
            val started = SystemClock.elapsedRealtime()
            val error = runCatching { stager.stageOne(row, options) }.exceptionOrNull()
            val ms = SystemClock.elapsedRealtime() - started
            val after = db.items().byId(row.id) ?: row
            val staged = after.state == ItemState.STAGED.name
            val copy = after.stagePath?.let { File(it) }?.takeIf { staged && it.isFile }
            val made = copy?.let { written(it) }
            val reencoded = staged && after.lastError.isNullOrEmpty()
            val codec = VideoCodec.entries.firstOrNull { it.name == after.codecUsed }
            // The share of the standard rate the copy came out at: what the
            // app chose for this clip, times how close the encoder kept to it.
            val target = if (made != null && reencoded && codec != null && made.fps > 1) {
                BitrateCalc.targetBps(made.width, made.height, made.fps.toFloat(), codec)
            } else {
                0
            }
            val videoBps = made?.let { bps(it.videoBytes, it.durationMs) } ?: 0L
            var keptAs = ""
            if (copy != null && reencoded && after.displayName in keepNames) {
                keptAs = keepName(after.displayName, after.id, keepDir)
                copy.copyTo(File(keepDir, keptAs), overwrite = true)
                kept++
            }
            val line = listOf(
                after.displayName, after.bucket.orEmpty(), after.mimeType, after.sizeBytes, after.durationMs,
                after.state, if (staged) after.outputBytes ?: 0L else 0L,
                after.lastError.orEmpty(), after.skipReason.orEmpty(), after.codecUsed.orEmpty(),
                after.srcPixels, after.outPixels, ms, error?.javaClass?.simpleName.orEmpty(),
                keptAs, made?.width ?: 0, made?.height ?: 0, made?.rotation ?: 0, fmt(made?.fps ?: 0.0, 3),
                made?.videoMime.orEmpty(), made?.videoBytes ?: 0L, made?.audioMime.orEmpty(), made?.audioBytes ?: 0L,
                made?.channels ?: 0, made?.durationMs ?: 0L,
                made?.let { bps(after.outputBytes ?: 0L, it.durationMs) } ?: 0L, videoBps, target,
                if (target > 0) fmt(videoBps.toDouble() / target, 3) else "", after.presetUsed.orEmpty(),
                after.encoderName.orEmpty()
            ).joinToString(",") { cell(it) }
            csv.appendText(line + "\n")
            Log.i(TAG, "${i + 1}/${videos.size} $line")
            // The copy has been measured; kept, a library this size would fill
            // the emulator long before the last file.
            after.stagePath?.let { File(it).delete() }
        }
        device.appendText("kept=$kept\n")
    }

    /** One track-by-track reading of a file the app wrote. */
    private data class Written(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val fps: Double,
        val videoMime: String,
        val videoBytes: Long,
        val audioMime: String,
        val audioBytes: Long,
        val channels: Int,
        val durationMs: Long
    )

    /**
     * Sizes and formats from the file itself: every sample's size summed per
     * track (no data is read), the frame rate from the frames' own times.
     */
    private fun written(file: File): Written? = runCatching {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.absolutePath)
            var video = -1
            var audio = -1
            for (t in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(t).getString(MediaFormat.KEY_MIME).orEmpty()
                if (video < 0 && mime.startsWith("video/")) video = t
                if (audio < 0 && mime.startsWith("audio/")) audio = t
            }
            if (video < 0) return@runCatching null
            val vf = ex.getTrackFormat(video)
            val af = if (audio >= 0) ex.getTrackFormat(audio) else null
            ex.selectTrack(video)
            if (audio >= 0) ex.selectTrack(audio)
            var videoBytes = 0L
            var audioBytes = 0L
            var frames = 0
            var first = Long.MAX_VALUE
            var last = Long.MIN_VALUE
            while (true) {
                val track = ex.sampleTrackIndex
                if (track < 0) break
                val size = ex.sampleSize.coerceAtLeast(0L)
                if (track == video) {
                    videoBytes += size
                    frames++
                    first = minOf(first, ex.sampleTime)
                    last = maxOf(last, ex.sampleTime)
                } else {
                    audioBytes += size
                }
                if (!ex.advance()) break
            }
            val fps = if (frames > 1 && last > first) (frames - 1) * 1e6 / (last - first) else 0.0
            val trackUs = if (vf.containsKey(MediaFormat.KEY_DURATION)) vf.getLong(MediaFormat.KEY_DURATION) else 0L
            val durationMs = if (trackUs > 0) trackUs / 1000 else if (fps > 0) (frames * 1000 / fps).toLong() else 0L
            Written(
                width = vf.getInteger(MediaFormat.KEY_WIDTH),
                height = vf.getInteger(MediaFormat.KEY_HEIGHT),
                rotation = if (vf.containsKey(MediaFormat.KEY_ROTATION)) vf.getInteger(MediaFormat.KEY_ROTATION) else 0,
                fps = fps,
                videoMime = vf.getString(MediaFormat.KEY_MIME).orEmpty(),
                videoBytes = videoBytes,
                audioMime = af?.getString(MediaFormat.KEY_MIME).orEmpty(),
                audioBytes = audioBytes,
                channels = af?.takeIf { it.containsKey(MediaFormat.KEY_CHANNEL_COUNT) }
                    ?.getInteger(MediaFormat.KEY_CHANNEL_COUNT) ?: 0,
                durationMs = durationMs
            )
        } finally {
            ex.release()
        }
    }.getOrNull()

    private fun bps(bytes: Long, durationMs: Long): Long = if (durationMs > 0) bytes * 8000 / durationMs else 0L

    private fun fmt(value: Double, digits: Int): String = String.format(Locale.ROOT, "%.${digits}f", value)

    /** The names whose copies are kept: `-e keep` is base64url of one name per line. */
    private fun keepList(arg: String?): Set<String> {
        if (arg.isNullOrBlank()) return emptySet()
        val text = runCatching {
            String(Base64.decode(arg, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING), Charsets.UTF_8)
        }.getOrDefault("")
        return text.split('\n').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    }

    /** The kept copy's name: the original's, in characters any shell passes as they are. */
    private fun keepName(displayName: String, id: Long, dir: File): String {
        val base = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".app.mp4"
        return if (File(dir, base).exists()) "$id-$base" else base
    }

    private fun deviceReport(expected: Int, found: Int, keep: Int): String {
        val memory = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java).getMemoryInfo(memory)
        return listOf(
            "model=${Build.MANUFACTURER} ${Build.MODEL}",
            "sdk=${Build.VERSION.SDK_INT}",
            "ram_bytes=${memory.totalMem}",
            "tier=${DeviceTier.tier(context)}",
            "hevc_hardware_1080p30=${EncoderCaps.hevcFits(1920, 1080, 30f)}",
            "video_long_side=${MediaSettings.VIDEO.longSide}",
            "video_fps_cap=${MediaSettings.VIDEO.fpsCap}",
            "save_mode=${SaveMode.COPIES}",
            "expected=$expected",
            "found=$found",
            "keep_asked=$keep"
        ).joinToString("\n", postfix = "\n")
    }

    /** A CSV cell: quoted only when it has to be, so the file reads plainly. */
    private fun cell(value: Any): String {
        val s = value.toString()
        return if (s.any { it == ',' || it == '"' || it == '\n' }) "\"" + s.replace("\"", "\"\"") + "\"" else s
    }

    private companion object {
        const val TAG = "SavingsBench"
        const val SCAN_WAIT_MS = 10 * 60_000L
        const val HEADER = "name,bucket,mime,src_bytes,duration_ms,state,out_bytes,kept_reason,skip_reason," +
            "codec,src_pixels,out_pixels,ms,error," +
            "kept_file,out_width,out_height,out_rotation,out_fps,out_video_mime,out_video_bytes,out_audio_mime," +
            "out_audio_bytes,out_audio_channels,out_duration_ms,out_bps,out_video_bps,target_bps,share,preset_key," +
            "encoder"
    }
}
