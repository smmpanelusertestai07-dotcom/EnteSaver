package com.pocketide.ui

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pocketide.core.ThemeMode
import com.pocketide.docs.DocsContent
import com.pocketide.ui.lock.HiddenContentCover
import com.pocketide.ui.screens.chats.ChatsScreen
import com.pocketide.ui.screens.cloudshell.CloudShellScreen
import com.pocketide.ui.screens.cloudshell.SetUpScreen
import com.pocketide.ui.screens.data.YourDataScreen
import com.pocketide.ui.screens.help.HelpPageScreen
import com.pocketide.ui.screens.help.HelpScreen
import com.pocketide.ui.screens.home.HomeScreen
import com.pocketide.ui.screens.onboarding.WelcomeScreen
import com.pocketide.ui.screens.settings.SettingsScreen
import com.pocketide.ui.screens.usage.UsageScreen
import com.pocketide.ui.theme.PocketTheme
import com.pocketide.ui.workspace.BrowserStarting
import com.pocketide.ui.workspace.ToolsSheet
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Pictures of the app's screens as a new owner meets them, for the release notes and the owner.
 *
 * Runs only when asked (`am instrument -e tour true`), so the normal on-device run stays quick.
 * Each screen is drawn on this phone's real app state (no Google account picked yet) and saved as a
 * PNG in the app's own files, under tour/, where CI reads it with run-as.
 */
@RunWith(AndroidJUnit4::class)
class ScreenTour {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun onlyWhenAsked() {
        assumeTrue("Runs only with -e tour true", InstrumentationRegistry.getArguments().getString("tour") == "true")
    }

    @Test fun welcome() = shoot("01-welcome") { WelcomeScreen(onRead = {}, onContinue = {}) }

    @Test fun welcomeDark() = shoot("01-welcome-dark", ThemeMode.DARK) { WelcomeScreen(onRead = {}, onContinue = {}) }

    @Test fun setUp() = shoot("02-set-up") { SetUpScreen() }

    @Test fun setUpDark() = shoot("02-set-up-dark", ThemeMode.DARK) { SetUpScreen() }

    @Test fun home() = shoot("03-home") { Home() }

    @Test fun homeDark() = shoot("03-home-dark", ThemeMode.DARK) { Home() }

    @Test fun computer() = shoot("04-computer") { CloudShellScreen(onHelp = {}, onHelpPage = {}) }

    @Test fun computerDark() = shoot("04-computer-dark", ThemeMode.DARK) { CloudShellScreen(onHelp = {}, onHelpPage = {}) }

    // PocketIDE's tools, over an agent's VS Code.
    @Test fun tools() = shoot("05-tools") { Tools() }

    @Test fun toolsDark() = shoot("05-tools-dark", ThemeMode.DARK) { Tools() }

    @Test fun settings() = shoot("06-settings") { Settings() }

    @Test fun settingsDark() = shoot("06-settings-dark", ThemeMode.DARK) { Settings() }

    @Test fun yourData() = shoot("07-your-data") { YourDataScreen(onBack = {}, onHelpPage = {}) }

    @Test fun help() = shoot("08-help") { HelpScreen(onBack = {}, onOpen = {}) }

    @Test fun helpDark() = shoot("08-help-dark", ThemeMode.DARK) { HelpScreen(onBack = {}, onOpen = {}) }

    @Test fun helpAgents() = shoot("09-help-agents") { HelpPageScreen(id = "agents", onBack = {}, onOpen = {}) }

    @Test fun terms() = shoot("10-terms") { HelpPageScreen(id = DocsContent.TERMS_ID, onBack = {}, onOpen = {}) }

    // A small phone (320 dp wide) with large text: nothing may run off the screen.
    @Test fun homeSmall() = shoot("11-home-small-large-text", width = SMALL_PHONE, fontScale = LARGE_TEXT) { Home() }

    @Test fun settingsSmall() = shoot("12-settings-small-large-text", width = SMALL_PHONE, fontScale = LARGE_TEXT) { Settings() }

    @Test fun welcomeSmallDark() = shoot("13-welcome-small-large-text-dark", ThemeMode.DARK, SMALL_PHONE, LARGE_TEXT) {
        WelcomeScreen(onRead = {}, onContinue = {})
    }

    @Test fun setUpSmall() = shoot("14-set-up-small-large-text", width = SMALL_PHONE, fontScale = LARGE_TEXT) { SetUpScreen() }

    // What Recents shows while App lock is on.
    @Test fun recentsCover() = shoot("15-recents-cover") { HiddenContentCover() }

    // Not connected, as on a phone that has not opened Cloud Shell yet: they ask to connect, nothing more.
    @Test fun chats() = shoot("16-chats") { ChatsScreen(onOpen = {}) }

    @Test fun usage() = shoot("17-usage") { UsageScreen() }

    @Test fun usageDarkSmall() = shoot("18-usage-small-large-text-dark", ThemeMode.DARK, SMALL_PHONE, LARGE_TEXT) { UsageScreen() }

    // The line under the agent while Tools > Browser starts Chrome in Cloud Shell.
    @Test fun browserStarting() = shoot("19-browser-starting-small-large-text", width = SMALL_PHONE, fontScale = LARGE_TEXT) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Bottom) {
            BrowserStarting("Downloading Chrome 154.0.8037.92 (about 120 MB)...")
        }
    }

    @Composable
    private fun Home() = HomeScreen(onComputer = {}, onYourData = {}, onHelp = {}, onExtensions = {})

    @Composable
    private fun Tools() = ToolsSheet(
        enabled = true,
        browserEnabled = true,
        keysAlways = false,
        onCommand = {},
        onBrowser = {},
        onFiles = {},
        onKeys = {},
        onReload = {},
        onHome = {},
        onClose = {},
    )

    @Composable
    private fun Settings() = SettingsScreen(onYourData = {}, onHelp = {}, onHelpPage = {})

    private fun shoot(
        name: String,
        mode: ThemeMode = ThemeMode.LIGHT,
        width: Dp? = null,
        fontScale: Float? = null,
        screen: @Composable () -> Unit,
    ) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale ?: density.fontScale)) {
                PocketTheme(mode) {
                    // The same ground the app draws every screen on (PocketRoot).
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        if (width == null) screen() else Box(Modifier.width(width).fillMaxHeight()) { screen() }
                    }
                }
            }
        }
        compose.waitForIdle()
        // Agent icons arrive over the network; give them a moment.
        SystemClock.sleep(SETTLE_MS)
        compose.waitForIdle()
        val image = compose.onRoot().captureToImage().asAndroidBitmap()
        val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "tour").apply { mkdirs() }
        File(folder, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private companion object {
        const val SETTLE_MS = 2_500L
        val SMALL_PHONE = 320.dp
        const val LARGE_TEXT = 1.3f
    }
}
