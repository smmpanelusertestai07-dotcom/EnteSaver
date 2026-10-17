package app.entesaver

import android.content.Context
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkQuery
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.SaveMode
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.work.Scheduler
import java.util.concurrent.TimeUnit

/**
 * Stops the app's own background pipeline, and waits until it has stopped.
 *
 * [Scheduler.cancelAll] is the app asking WorkManager to cancel: it hands back
 * an Operation and returns immediately, and a worker that is already running
 * keeps running until it next looks at whether it was stopped. A test that
 * seeds a gallery straight afterwards is seeding it underneath a live worker,
 * which then optimises the fixtures itself - so which file ends in which state
 * is a race between the test and the app.
 *
 * That race is what "the two optimised fixtures must be in the upload folder
 * and the other two still waiting: expected [2, 2] but was [0, 3]" was: three
 * of the four files had been through the pipeline, and only two of them by the
 * test's own hand. It reads as the app releasing files it should not have,
 * which is the most alarming thing this app could possibly do, and it is not
 * what happened.
 *
 * So: cancel, block until the cancellation has actually been applied, then
 * wait for WorkManager to report nothing running or waiting to run.
 */
object TestPipeline {

    private const val TIMEOUT_MS = 30_000L
    private const val POLL_MS = 100L

    fun stopAndWait(context: Context) {
        Scheduler.cancelAll(context)
        val wm = WorkManager.getInstance(context)
        // cancelAllWork covers anything an earlier test, or the app's own
        // launch, enqueued under a name this object does not know about.
        runCatching { wm.cancelAllWork().result.get(TIMEOUT_MS, TimeUnit.MILLISECONDS) }

        val deadline = System.currentTimeMillis() + TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            if (busyWork(wm).isEmpty()) return
            Thread.sleep(POLL_MS)
        }
        val left = busyWork(wm).joinToString { "${it.state}" }
        throw AssertionError(
            "the app's background work was still $left after ${TIMEOUT_MS / 1000}s, " +
                "so anything seeded now would be processed by it as well as by the test"
        )
    }

    private fun busyWork(wm: WorkManager): List<WorkInfo> = runCatching {
        wm.getWorkInfos(
            WorkQuery.fromStates(WorkInfo.State.RUNNING, WorkInfo.State.ENQUEUED)
        ).get(TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }.getOrDefault(emptyList())
}

/**
 * The folders a new install has: the defaults, nothing moved away from.
 *
 * An install that was already in use is kept on its old folder the first
 * time options are read (OptionsRepo.pinLegacyFolders). The suites mark
 * setup done straight away, so whichever happened to read options first
 * would otherwise decide which folder every later test saw.
 *
 * And Copies for Ente, the mode those folders belong to. Setup stores the
 * mode it was given, so a suite that went through Replace on this phone
 * would otherwise hand it to every suite after it; the ones that test
 * Replace on this phone set it themselves, after this.
 */
suspend fun OptionsRepo.useDefaultFolders() {
    setString(OptionsRepo.K.SAVE_MODE, SaveMode.COPIES.name)
    setBool(OptionsRepo.K.FOLDERS_PINNED, true)
    setFolders(mapOf(OutFolder.SINGLE to "", OutFolder.PHOTOS to "", OutFolder.VIDEOS to ""))
    setStringSet(OptionsRepo.K.PAST_OUTPUT_ROOTS, emptySet())
    setBool(OptionsRepo.K.NEW_FOLDER_PENDING, false)
}
