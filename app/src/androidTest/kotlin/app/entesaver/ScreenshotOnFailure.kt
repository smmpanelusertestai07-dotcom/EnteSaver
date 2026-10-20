package app.entesaver

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import java.io.File
import org.junit.rules.TestWatcher
import org.junit.runner.Description

/**
 * Photographs the screen the moment a test fails.
 *
 * An assertion says what it wanted and what it got. It does not say what was
 * on the screen, and the difference between those two is most of the work.
 * "Free a set amount is not displayed" was true for an hour before anyone
 * could see that the row was drawn perfectly well, just further down a list
 * the test was scrolling the wrong way; "the consent dialog never showed a
 * deny button" is still open, and the picture of that dialog is the answer.
 *
 * The shot goes where the tour's shots go - Pictures/CSTestShots, which adb
 * and CI already collect - under a name that starts with `fail-`, so the
 * failures sort together and are obvious in a folder of ordinary screens.
 * Nothing here can fail the test it is watching: the test has already
 * failed, and a broken camera must not replace the real reason with its own.
 */
class ScreenshotOnFailure : TestWatcher() {

    override fun failed(e: Throwable, description: Description) {
        runCatching {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val context = instrumentation.targetContext
            val device = UiDevice.getInstance(instrumentation)
            val name = "fail-%s-%s".format(
                description.className.substringAfterLast('.'),
                description.methodName
            )
            // Android 9 has no RELATIVE_PATH, and a test that was granted no
            // storage access cannot write into shared storage there at all.
            // The shell can, so it takes the picture straight into the
            // folder adb pulls.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStorageDirectory(), SHOT_DIR)
                device.executeShellCommand("mkdir -p ${dir.absolutePath}")
                device.executeShellCommand("screencap -p ${File(dir, "$name.png").absolutePath}")
                return@runCatching
            }
            val temp = File(context.cacheDir, "$name.png")
            if (!device.takeScreenshot(temp) || !temp.exists()) return@runCatching

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "$name.png")
                put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
                put(MediaStore.MediaColumns.RELATIVE_PATH, SHOT_DIR)
            }
            val collection =
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            context.contentResolver.insert(collection, values)?.let { uri ->
                context.contentResolver.openOutputStream(uri)?.use { it.write(temp.readBytes()) }
            }
            temp.delete()
        }
    }

    companion object {
        /**
         * The tour's folder, deliberately. It is already pulled by the CI job
         * and by anyone debugging locally, and the pipeline only ever looks at
         * Pictures/CloudSaver, so nothing in here reaches the app under test.
         */
        const val SHOT_DIR = "Pictures/CSTestShots"
    }
}
