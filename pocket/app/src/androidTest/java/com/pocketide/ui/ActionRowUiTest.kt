package com.pocketide.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pocketide.ui.components.ActionRow
import com.pocketide.ui.theme.PocketTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Two buttons that do not fit side by side on a 360 dp phone: the second moves to its own line whole. */
@RunWith(AndroidJUnit4::class)
class ActionRowUiTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun theSecondButtonWrapsAtTheDefaultFont() = checkWraps(fontScale = 1f)

    @Test
    fun theSecondButtonWrapsAtTheLargestFont() = checkWraps(fontScale = 2f)

    private fun checkWraps(fontScale: Float) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                PocketTheme {
                    // A list row on a 360 dp phone: 16 dp of padding on each side.
                    Box(Modifier.width(LIST_ROW)) {
                        ActionRow {
                            OutlinedButton(onClick = {}) { Text(FIRST) }
                            OutlinedButton(onClick = {}) { Text(SECOND) }
                        }
                    }
                }
            }
        }
        val first = compose.onNodeWithText(FIRST).getUnclippedBoundsInRoot()
        val second = compose.onNodeWithText(SECOND).getUnclippedBoundsInRoot()
        assertTrue("\"$SECOND\" is on its own line", second.top >= first.bottom)
    }

    private companion object {
        val LIST_ROW = 328.dp
        const val FIRST = "Open in Chrome instead"
        const val SECOND = "Stop the cloud computer"
    }
}
