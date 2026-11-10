package com.pocketide.ui.screens.live

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleStartEffect
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.components.Tone
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.PrimaryAction

/**
 * While a page of Cloud Shell's own data (Chats, Usage) is in front, an open connection stays open;
 * none is opened for it: Cloud Shell starts only when the owner taps Connect.
 */
@Composable
fun KeepConnectionWhileShown() {
    val link = LocalContext.current.graph.link
    LifecycleStartEffect(link) {
        link.dataShown()
        onStopOrDispose { link.screenHidden() }
    }
}

/** What a page of Cloud Shell's data shows until PocketIDE is connected: why, and Connect. */
@Composable
fun ConnectFirst(state: LinkState, what: String) {
    val link = LocalContext.current.graph.link
    SectionCard("Cloud Shell is not connected") {
        when (state) {
            is LinkState.Working -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Text(state.step, style = MaterialTheme.typography.bodyMedium)
            }
            is LinkState.Failed -> {
                NoticeCard(state.why, tone = Tone.WARN)
                PrimaryAction("Try again", onClick = { link.connect() })
            }
            else -> {
                Text(
                    "$what live in Cloud Shell. Connect to read them: Cloud Shell starts in about a minute after a " +
                        "break, and PocketIDE disconnects 15 minutes after you leave.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                PrimaryAction("Connect", onClick = { link.connect() })
            }
        }
    }
}

/** A short wait while Cloud Shell answers. */
@Composable
fun Asking(text: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator()
        Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 12.dp))
    }
}
