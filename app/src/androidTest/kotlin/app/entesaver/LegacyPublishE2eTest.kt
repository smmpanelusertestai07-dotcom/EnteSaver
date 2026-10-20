package app.entesaver

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import app.entesaver.media.LegacyMedia
import java.io.ByteArrayOutputStream
import java.io.File
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
 * A copy published the Android 9 way ([LegacyMedia]): made in a hidden
 * folder, which Android 9's scan of the whole of storage passes over, and
 * named only once it is whole. Android 10 and later publish through pending
 * items instead, so this runs on Android 9 only.
 */
@RunWith(AndroidJUnit4::class)
class LegacyPublishE2eTest {

    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forThisDevice())

    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val album = "${MediaFixtures.TEST_ALBUM}/"

    @Before
    fun setUp() {
        assumeTrue("Android 9 only", Build.VERSION.SDK_INT < Build.VERSION_CODES.Q)
        MediaFixtures.cleanUp(context)
    }

    @After
    fun tearDown() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) MediaFixtures.cleanUp(context)
    }

    private fun jpeg(seed: Int): ByteArray {
        val bitmap = MediaFixtures.makeBitmap(64, 64, seed)
        return ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)
            bitmap.recycle()
        }.toByteArray()
    }

    @Test
    fun aCopyLandsWholeUnderAFreeNameAndLeavesNothingHidden() {
        val first = LegacyMedia.publish(context, album, "legacy.jpg", "image/jpeg") { it.write(jpeg(1)) }
        val second = LegacyMedia.publish(context, album, "legacy.jpg", "image/jpeg") { it.write(jpeg(2)) }
        assertNotNull(first)
        assertNotNull(second)
        assertEquals("legacy.jpg", first!!.name)
        assertEquals("the first is never written over", "legacy (1).jpg", second!!.name)
        assertEquals("a photo in the gallery: ${first.uri}", "images", first.uri.pathSegments[1])
        val folder = LegacyMedia.folder(album)
        assertFalse("the hidden folder goes once the work is done", File(folder, LegacyMedia.WORK_DIR).exists())
        assertTrue(
            "and nothing hidden is left beside the photos",
            folder.listFiles().orEmpty().none { it.name.startsWith(".") }
        )
    }

    @Test
    fun aCopyTheScannerFilesAsAPlainFileIsTakenBack() {
        val quiet = "${MediaFixtures.TEST_ALBUM}/quiet/"
        val folder = LegacyMedia.folder(quiet).apply { mkdirs() }
        assertTrue(File(folder, ".nomedia").createNewFile())
        val published = LegacyMedia.publish(context, quiet, "unseen.jpg", "image/jpeg") { it.write(jpeg(3)) }
        assertNull("a copy no gallery lists is not published", published)
        assertFalse("and is not left on the phone", File(folder, "unseen.jpg").exists())
    }
}
