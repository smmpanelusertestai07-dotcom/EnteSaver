package com.pocketide.ui.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pocketide.agents.AgentSlot
import com.pocketide.cloudshell.Answer
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.graph
import com.pocketide.link.BrowserStart

/** The browser is starting in Cloud Shell: a line under the agent, with the launcher's latest words. */
@Composable
internal fun BrowserStarting(said: String?) {
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, contentColor = MaterialTheme.colorScheme.onSecondaryContainer) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("Starting the browser in Cloud Shell…", style = MaterialTheme.typography.titleSmall)
                Text(
                    said ?: "The first browser of a Cloud Shell session may install Chrome's libraries: about a minute.",
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Why the browser did not start, in the launcher's words. When Cloud Shell's memory was short, the
 * agents' VS Codes running there besides [current] can be stopped from here ([onStop]); the browser
 * starts after.
 */
@Composable
internal fun BrowserRefused(refused: BrowserStart.Refused, current: AgentSlot, onStop: (AgentSlot) -> Unit, onRetry: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val others by produceState<List<AgentSlot>?>(initialValue = null, refused) {
        value = if (!refused.lowMemory) {
            emptyList()
        } else {
            when (val answer = context.graph.cloudInfo.status()) {
                is Answer.Got -> answer.value.agents.filter { it.running }
                    .mapNotNull { AgentSlot.of(it.agent, CloudShellInfo.added(answer.value)) }
                    .filter { it.key != current.key }
                else -> emptyList()
            }
        }
    }
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (refused.lowMemory) "Not enough memory for the browser" else "The browser did not start") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(refused.why)
                when {
                    !refused.lowMemory -> Unit
                    others == null -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    others.orEmpty().isEmpty() -> Text(
                        "No other agent's VS Code runs now. Close the agent's terminals or dev servers you no longer need, then try again.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    else -> {
                        Text(
                            "Stopping an agent's VS Code ends what that agent is doing; its chats and projects stay.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        others.orEmpty().forEach { agent ->
                            OutlinedButton(onClick = { onStop(agent) }, modifier = Modifier.fillMaxWidth()) {
                                Text("Stop ${agent.displayName}'s VS Code, then start the browser", maxLines = 2)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onRetry) { Text("Try again") } },
        dismissButton = { TextButton(onClick = onClose) { Text("Close") } },
    )
}
