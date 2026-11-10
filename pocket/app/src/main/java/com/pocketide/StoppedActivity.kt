package com.pocketide

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.pocketide.ui.components.Tone
import com.pocketide.ui.shell.CenteredTitle
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.QuietAction
import com.pocketide.ui.shell.SecondaryAction
import com.pocketide.ui.shell.ShellPage
import com.pocketide.ui.theme.PocketTheme

/**
 * Says that an error stopped PocketIDE, with its details to copy for a report ([StopNote]). It
 * runs in its own process and uses none of the app's parts, so it works whatever went wrong.
 */
class StoppedActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val details = StopNote.pending(this) ?: NO_DETAILS
        onBackPressedDispatcher.addCallback(this) { close() }
        setContent {
            PocketTheme {
                StoppedScreen(details, onCopy = { copy(details) }, onOpen = ::openApp, onClose = ::close)
            }
        }
    }

    private fun copy(details: String) {
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("PocketIDE error", details))
        // Android 13 and newer confirm a copy themselves.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
    }

    private fun openApp() {
        StopNote.clear(this)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        finish()
    }

    private fun close() {
        StopNote.clear(this)
        finish()
    }

    private companion object {
        const val NO_DETAILS = "No details were kept."
    }
}

@Composable
private fun StoppedScreen(details: String, onCopy: () -> Unit, onOpen: () -> Unit, onClose: () -> Unit) {
    ShellPage {
        Gap(24.dp)
        CenteredTitle(
            Icons.Outlined.ErrorOutline,
            "PocketIDE stopped",
            "An error closed the app. Copy the details to report it; they stay on this phone unless you share them.",
            tone = Tone.ERROR,
        )
        Gap(24.dp)
        PrimaryAction("Copy details", onClick = onCopy)
        Gap(12.dp)
        SecondaryAction("Open PocketIDE", onClick = onOpen)
        QuietAction("Close", onClick = onClose)
        Gap(16.dp)
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHighest,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            SelectionContainer {
                Text(
                    details,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}
