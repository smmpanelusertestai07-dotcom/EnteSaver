package com.pocketide

import android.app.UiModeManager
import android.content.Intent
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import com.pocketide.core.ThemeMode
import com.pocketide.ui.PocketRoot
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * The app's screens. Screenshots are always allowed. With App lock on, Recents shows a cover
 * instead of the screen (see [PocketRoot]); the lock itself is part of [PocketRoot] too. A sign-in
 * page in Chrome may sit above it; bringing this activity back to the front (its launch mode, or
 * CLEAR_TOP) closes that page.
 */
class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // An error stopped the app last time, and Android did not let its note open then.
        if (StopNote.pending(this) != null) {
            startActivity(Intent(this, StoppedActivity::class.java))
            finish()
            return
        }
        systemBars(graph.settings.settings.value.theme)
        lifecycleScope.launch {
            graph.settings.settings.map { it.appLock to it.theme }.distinctUntilChanged().collect { (lock, theme) ->
                hideInRecents(lock)
                followTheme(theme)
                systemBars(theme)
            }
        }
        setContent { PocketRoot(activity = this) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    /**
     * Android 13 and newer keep no picture of the screen for Recents while App lock is on; older
     * versions keep the picture of the cover that [PocketRoot] draws when the app leaves the front.
     */
    private fun hideInRecents(lock: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(!lock)
    }

    /**
     * Status and navigation bar icons in the app's own light or dark choice, which can differ from
     * the phone's: dark icons on a dark app would be invisible.
     */
    private fun systemBars(theme: ThemeMode) {
        val dark = { resources: Resources ->
            when (theme) {
                ThemeMode.SYSTEM -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
                ThemeMode.LIGHT -> false
                ThemeMode.DARK -> true
            }
        }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT, dark),
            navigationBarStyle = SystemBarStyle.auto(LIGHT_SCRIM, DARK_SCRIM, dark),
        )
    }

    /**
     * Android 12 and newer take the app's own light or dark choice, so the system's screens (the
     * account chooser among them) match the app.
     */
    private fun followTheme(theme: ThemeMode) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val mode = when (theme) {
            ThemeMode.SYSTEM -> UiModeManager.MODE_NIGHT_AUTO
            ThemeMode.LIGHT -> UiModeManager.MODE_NIGHT_NO
            ThemeMode.DARK -> UiModeManager.MODE_NIGHT_YES
        }
        getSystemService(UiModeManager::class.java)?.setApplicationNightMode(mode)
    }

    private companion object {
        // The scrims enableEdgeToEdge uses by default behind three-button navigation.
        private val LIGHT_SCRIM = Color.argb(0xe6, 0xFF, 0xFF, 0xFF)
        private val DARK_SCRIM = Color.argb(0x80, 0x1b, 0x1b, 0x1b)
    }
}
