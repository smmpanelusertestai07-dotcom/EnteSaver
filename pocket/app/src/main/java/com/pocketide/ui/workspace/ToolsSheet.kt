package com.pocketide.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pocketide.ui.shell.BrandMark

/** One of the tools: what it shows and the layout extension's command that opens it (see pagescript.js). */
private data class Tool(val title: String, val detail: String, val icon: ImageVector, val command: String)

private val TOOLS = listOf(
    Tool("Agent", "Back to the agent, full screen", Icons.Outlined.SmartToy, "agent"),
    Tool("Open a file", "Find a file in this project by its name", Icons.Outlined.Description, "files"),
    Tool("Terminal", "A command line in this project, full screen", Icons.Outlined.Terminal, "terminal"),
    Tool("Install from a link", "An extension (.vsix) Open VSX does not have, from its maker", Icons.Outlined.CloudDownload, "vsix"),
    Tool("All commands", "Everything VS Code can do", Icons.AutoMirrored.Outlined.List, "commands"),
)

/**
 * PocketIDE's tools over an agent's VS Code: each opens full screen in that VS Code, one at a time,
 * and Back returns to the agent. [enabled] is false until VS Code is on screen. The browser (the
 * Chrome the agents use in Cloud Shell, live) needs only the connection: [browserEnabled].
 */
@Composable
@Suppress("LongParameterList") // One callback per kind of row.
internal fun ToolsSheet(
    enabled: Boolean,
    browserEnabled: Boolean,
    keysAlways: Boolean,
    onCommand: (String) -> Unit,
    onBrowser: () -> Unit,
    onFiles: () -> Unit,
    onKeys: (Boolean) -> Unit,
    onReload: () -> Unit,
    onHome: () -> Unit,
    onClose: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = SCRIM))
            .clickable(interactionSource = null, indication = null, onClickLabel = "Close the tools", onClick = onClose),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                // A tap on the sheet itself stays on the sheet (and is no button for TalkBack).
                .pointerInput(Unit) { detectTapGestures {} },
        ) {
            Column(
                Modifier
                    .navigationBarsPadding()
                    .verticalScroll(rememberScrollState())
                    .padding(top = 12.dp, bottom = 12.dp),
            ) {
                Row(Modifier.padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    BrandMark(28.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        "Tools",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f).semantics { heading() },
                    )
                    IconButton(onClick = onClose) { Icon(Icons.Outlined.Close, contentDescription = "Close") }
                }
                TOOLS.forEach { tool ->
                    ToolRow(tool.title, tool.detail, tool.icon, enabled = enabled) { onCommand(tool.command) }
                }
                ToolRow(
                    "Files",
                    "This agent's files in Cloud Shell: see any of them, download it, or install an APK",
                    Icons.Outlined.Folder,
                    enabled = browserEnabled,
                    onClick = onFiles,
                )
                ToolRow(
                    "Browser",
                    "Chrome in Cloud Shell, which the agents use: watch it live, or take over",
                    Icons.Outlined.Language,
                    enabled = browserEnabled,
                    onClick = onBrowser,
                )
                ToolRow(
                    "Keys bar",
                    if (keysAlways) {
                        "Esc, Tab, Ctrl+C and the arrows stay on screen: tap to show them only with the keyboard"
                    } else {
                        "Esc, Tab, Ctrl+C and the arrows show with the keyboard: tap to keep them on screen"
                    },
                    Icons.Outlined.Keyboard,
                    onClick = { onKeys(!keysAlways) },
                )
                HorizontalDivider(Modifier.padding(vertical = 4.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ToolRow("Reload this VS Code", "When it looks stuck; the agent keeps working in Cloud Shell", Icons.Outlined.Refresh, onClick = onReload)
                ToolRow("PocketIDE home", "The agents keep running here", Icons.Outlined.Home, onClick = onHome)
            }
        }
    }
}

@Composable
private fun ToolRow(title: String, detail: String, icon: ImageVector, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else DISABLED)
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private const val SCRIM = 0.4f
private const val DISABLED = 0.4f
