package com.pocketide.ui.screens.settings

import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.Gavel
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.BuildConfig
import com.pocketide.PocketApp
import com.pocketide.core.ThemeMode
import com.pocketide.docs.DocLinks
import com.pocketide.docs.DocsContent
import com.pocketide.graph
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.lock.canLock
import com.pocketide.ui.shell.LocalBottomBarPadding
import com.pocketide.ui.web.Browser

/** The few choices PocketIDE has, each with what it does. Defaults are the private, safe ones. */
@Composable
fun SettingsScreen(onYourData: () -> Unit, onHelp: () -> Unit, onHelpPage: (String) -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val lockable = (context as? FragmentActivity)?.let(::canLock) == true
    val update = graph.settings::update

    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)

        SectionCard("Appearance") {
            InfoItem(Icons.Outlined.DarkMode, "Theme", null)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                val modes = listOf(ThemeMode.SYSTEM to "Phone", ThemeMode.LIGHT to "Light", ThemeMode.DARK to "Dark")
                modes.forEachIndexed { index, (mode, label) ->
                    SegmentedButton(
                        selected = settings.theme == mode,
                        onClick = { update { it.copy(theme = mode) } },
                        shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                    ) { Text(label) }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Toggle(Icons.Outlined.Palette, "Wallpaper colours", "Colours from your wallpaper instead of PocketIDE's violet", settings.dynamicColor) { on ->
                    update { it.copy(dynamicColor = on) }
                }
            }
        }

        SectionCard("Privacy and security") {
            Toggle(
                Icons.Outlined.Fingerprint,
                "App lock",
                if (lockable) "Asks for your screen lock, and hides the app in Recents" else "Set a screen lock in Android's settings to use this",
                settings.appLock && lockable,
                enabled = lockable,
            ) { on ->
                // The owner is here already: the lock starts from the next time the app opens.
                if (on) (context.applicationContext as PocketApp).appLock.unlock()
                update { it.copy(appLock = on) }
            }
            Link(Icons.Outlined.Storage, "Your data", "Where everything is, and deleting it", onYourData)
        }

        SectionCard("About") {
            Link(Icons.AutoMirrored.Outlined.MenuBook, "Help", "How PocketIDE works, and answers", onHelp)
            Link(Icons.Outlined.Gavel, "Terms of use", null) { onHelpPage(DocsContent.TERMS_ID) }
            Link(Icons.Outlined.PrivacyTip, "Privacy policy", null) { onHelpPage(DocsContent.PRIVACY_ID) }
            Link(Icons.AutoMirrored.Outlined.Article, "Open-source licences", null) { onHelpPage(DocsContent.NOTICES_ID) }
            Link(Icons.Outlined.Code, "Source code", "PocketIDE's own code, on GitHub") { Browser.open(context, DocLinks.REPOSITORY) }
            InfoItem(Icons.Outlined.Info, "PocketIDE ${BuildConfig.VERSION_NAME}", DocsContent.TAGLINE)
        }
        androidx.compose.foundation.layout.Spacer(Modifier.height(LocalBottomBarPadding.current))
    }
}

@Composable
private fun InfoItem(icon: ImageVector, title: String, detail: String?) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = detail?.let { { Text(it) } },
        leadingContent = { Icon(icon, contentDescription = null) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    )
}

@Composable
private fun Link(icon: ImageVector, title: String, detail: String?, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = detail?.let { { Text(it) } },
        leadingContent = { Icon(icon, contentDescription = null) },
        trailingContent = {
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.clickable(onClick = onClick),
    )
}

@Composable
private fun Toggle(icon: ImageVector, title: String, detail: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        leadingContent = { Icon(icon, contentDescription = null) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange, enabled = enabled) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    )
}
