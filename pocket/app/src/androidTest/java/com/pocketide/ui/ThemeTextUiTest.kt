package com.pocketide.ui

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.core.graphics.ColorUtils
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pocketide.core.ThemeMode
import com.pocketide.ui.lock.CONTENT_HIDDEN
import com.pocketide.ui.lock.HiddenContentCover
import com.pocketide.ui.shell.ShellPage
import com.pocketide.ui.theme.PocketTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Text on a page with nothing else under it (the lock and first-run screens) takes the theme's
 * colour. Material's default text colour is black, which is invisible on the dark background.
 */
@RunWith(AndroidJUnit4::class)
class ThemeTextUiTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun pageTextIsLightInTheDarkTheme() {
        compose.setContent { PocketTheme(ThemeMode.DARK) { ShellPage { Text(WORDS) } } }
        assertTrue("some light text on the dark page", share(capture()) { it > LIGHT } > MIN_TEXT_SHARE)
    }

    @Test
    fun pageTextIsDarkInTheLightTheme() {
        compose.setContent { PocketTheme(ThemeMode.LIGHT) { ShellPage { Text(WORDS) } } }
        assertTrue("some dark text on the light page", share(capture()) { it < DARK } > MIN_TEXT_SHARE)
    }

    @Test
    fun theRecentsCoverShowsNothingButItsOwnMarks() {
        compose.setContent { PocketTheme(ThemeMode.LIGHT) { HiddenContentCover() } }
        compose.onNodeWithContentDescription(CONTENT_HIDDEN).assertExists()
        // Black but for the dim eye and the grey words: nothing bright, whatever the theme.
        assertTrue("nothing bright on the cover", share(capture()) { it > LIGHT } == 0.0)
    }

    private fun capture(): Bitmap = compose.onRoot().captureToImage().asAndroidBitmap()

    /** The share of pixels whose luminance (0 to 1) passes [test]. */
    private fun share(image: Bitmap, test: (Double) -> Boolean): Double {
        val pixels = IntArray(image.width * image.height)
        image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
        return pixels.count { test(ColorUtils.calculateLuminance(it)) }.toDouble() / pixels.size
    }

    private companion object {
        const val WORDS = "Agentic development on your phone. Agentic development on your phone."
        const val LIGHT = 0.5
        const val DARK = 0.1
        const val MIN_TEXT_SHARE = 0.0005
    }
}
