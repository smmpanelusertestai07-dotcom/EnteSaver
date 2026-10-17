package app.entesaver

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.work.WorkManager
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.PhotoSettings
import app.entesaver.core.logic.VideoSettings
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.EncoderCaps
import app.entesaver.media.MediaScanner
import app.entesaver.media.Stager
import app.entesaver.util.DeviceTier
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * How much room the Balanced preset makes on a phone full of ordinary videos:
 * a measurement, not a check, and not part of the suite.
 *
 * The savings-bench workflow fills an emulator's gallery with a library made
 * to look like a real phone's - camera clips at every setting, WhatsApp
 * forwards, saved reels, downloads, screen recordings - and runs this class
 * with `-e savingsBench true`. It goes through Ente Saver's own pipeline: the
 * scanner, then the Stager exactly as a scheduled run calls it, under Balanced
 * (16 MP photos, 1080p videos - what Google Photos calls Storage saver). One
 * CSV line per video says what went in, what came out, and why a file was
 * kept as it was. Without the argument it skips, so the end-to-end suite never
 * pays for it.
 */
@RunWith(AndroidJUnit4::class)
class SavingsBenchTest {

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val args: Bundle get() = InstrumentationRegistry.getArguments()

    @Test
    fun balancedOverThePushedLibrary() = runBlocking {
        assumeTrue("a benchmark: run with -e savingsBench true", args.getString("savingsBench") == "true")
        val expected = args.getString("expected")?.toIntOrNull() ?: 0

        // A fresh install schedules nothing that compresses, but a run the
        // app started on its own would take files from under this loop.
        WorkManager.getInstance(context).cancelAllWork()
        val db = AppDb.get(context)
        db.clearAllTables()
        val repo = OptionsRepo.get(context)
        repo.useDefaultFolders()
        repo.setPhoto(PhotoSettings())
        repo.setVideo(VideoSettings())
        val options = repo.current()

        val out = File(context.filesDir, "savings").apply { mkdirs() }
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
        File(out, "device.txt").writeText(deviceReport(expected, videos.size))
        Log.i(TAG, "found ${videos.size} of $expected videos")

        val stager = Stager(context, db)
        for ((i, row) in videos.sortedBy { it.displayName }.withIndex()) {
            val started = SystemClock.elapsedRealtime()
            val error = runCatching { stager.stageOne(row, options) }.exceptionOrNull()
            val ms = SystemClock.elapsedRealtime() - started
            val after = db.items().byId(row.id) ?: row
            val line = listOf(
                after.displayName, after.bucket.orEmpty(), after.mimeType, after.sizeBytes, after.durationMs,
                after.state, if (after.state == ItemState.STAGED.name) after.outputBytes ?: 0L else 0L,
                after.lastError.orEmpty(), after.skipReason.orEmpty(), after.codecUsed.orEmpty(),
                after.srcPixels, after.outPixels, ms, error?.javaClass?.simpleName.orEmpty()
            ).joinToString(",") { cell(it) }
            csv.appendText(line + "\n")
            Log.i(TAG, "${i + 1}/${videos.size} $line")
            // The copy has been measured; kept, a library this size would fill
            // the emulator long before the last file.
            after.stagePath?.let { File(it).delete() }
        }
    }

    private fun deviceReport(expected: Int, found: Int): String {
        val memory = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java).getMemoryInfo(memory)
        return listOf(
            "model=${Build.MANUFACTURER} ${Build.MODEL}",
            "sdk=${Build.VERSION.SDK_INT}",
            "ram_bytes=${memory.totalMem}",
            "tier=${DeviceTier.tier(context)}",
            "hevc_hardware_1080p30=${EncoderCaps.hevcFits(1920, 1080, 30f)}",
            "preset_video=${VideoSettings().preset}",
            "expected=$expected",
            "found=$found"
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
            "codec,src_pixels,out_pixels,ms,error"
    }
}
