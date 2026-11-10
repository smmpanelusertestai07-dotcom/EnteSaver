package com.pocketide.ui.screens.cloudshell

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.Agent
import com.pocketide.cloudshell.CloudShell
import com.pocketide.docs.DocsContent
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.linux.ComputerInfo
import com.pocketide.linux.ComputerState
import com.pocketide.linux.UpdateOutcome
import com.pocketide.ui.components.ActionRow
import com.pocketide.ui.components.DialogBody
import com.pocketide.ui.components.Formats
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.components.Tone
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.ShellPage
import com.pocketide.ui.web.Browser
import com.pocketide.ui.workspace.WorkspaceActivity
import kotlinx.coroutines.launch

/**
 * The computer: Google Cloud Shell. Its account and state, its free limits, where its data is (and
 * where it is not), how to see, download and delete it, and what keeps the Google account safe.
 */
@Composable
fun CloudShellScreen(onHelp: () -> Unit, onHelpPage: (String) -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val account = settings.cloudAccount
    val unused = CloudShell.daysUnused(settings, graph.clock.now())
    val pick = rememberAccountPicker { name -> graph.settings.update { it.copy(cloudAccount = name) } }
    var again by remember { mutableStateOf(false) }
    ShellPage {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Cloud, contentDescription = null, modifier = Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Text(
                "Cloud Shell",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            IconButton(onClick = onHelp) { Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = "Help") }
        }
        Text("Google's Linux computer, where your agents work", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Gap(16.dp)
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionCard("Your computer") {
                Text(
                    "Account: $account\nLast opened from PocketIDE: " +
                        (if (unused == 0L) "today" else "$unused days ago") +
                        ". Google deletes the home folder after ${CloudShell.DELETED_AFTER_DAYS} days without use; PocketIDE " +
                        "asks for the set-up again before that.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                ActionRow {
                    PrimaryAction("Open the computer", onClick = { WorkspaceActivity.openLast(context) })
                    OutlinedButton(onClick = pick) { Text("Change account") }
                    OutlinedButton(onClick = { again = true }) { Text("Run the set-up again") }
                }
            }

            ConnectionCard()

            SectionCard("Each agent, its own VS Code") {
                Text(
                    Agent.entries.joinToString("\n") { "${it.displayName}: port ${CloudShell.port(it)}, projects in ${CloudShell.projects(it)}" } +
                        "\nEach has its own settings and extensions. Add any extension from its Extensions view (Open VSX); " +
                        "they update by themselves, and the agents are checked for updates once a day.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

            SectionCard("Free limits") {
                Text(
                    "50 hours a week (about 7 hours a day), at most 12 hours in one session. Cloud Shell stops about 40 minutes " +
                        "after you stop using it, so agents do not work on while you are away. 5 GB home folder; the set-up uses " +
                        "about 1.9 GB. Its memory is shared by everything running there: each agent's VS Code starts when you " +
                        "open it, and Usage shows the memory.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                TextButton(onClick = { Browser.open(context, CloudShell.LIMITS) }) { Text("Google's limits") }
            }

            SectionCard("Where your data is") {
                Text(
                    "Only in your Cloud Shell home folder, which only your Google account opens: each agent's projects, its " +
                        "chats and sign-in (~/.claude, ~/.codex, Antigravity's ~/.gemini/antigravity), its VS Code and the browser's profile " +
                        "(~/.pocketide). What you ask an agent, " +
                        "and the code it reads, also goes to its company. It is not in Drive, Photos or your Google Cloud " +
                        "projects, and agent chats do not show on claude.ai or chatgpt.com.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    "Tidied by itself when Cloud Shell starts: caches unused for 14 days and logs after 7 days. Chats stay until " +
                        "you delete them (Chats); Claude Code deletes its own after 30 days. Projects are never deleted.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

            SectionCard("Delete") {
                Text(
                    "A file or project: delete it in the agent's VS Code (Tools > Terminal, or ask the agent). Agent sign-ins: " +
                        "sign out in each agent, then remove the access in your Claude, ChatGPT and Google account settings. " +
                        "Everything in Cloud Shell: Google's reset steps.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                TextButton(onClick = { Browser.open(context, CloudShell.RESET) }) { Text("Google's reset steps") }
            }

            NoticeCard(
                "Use Cloud Shell yourself, while you work, as Google intends. No miners, scanners or tricks to keep it awake, " +
                    "and no public tunnels: breaking Google's rules can turn Cloud Shell off for your account.",
                tone = Tone.WARN,
                title = "Keep your Google account safe",
            )
            ActionRow {
                TextButton(onClick = { Browser.open(context, CloudShell.TERMS) }) { Text("Google Cloud terms") }
                TextButton(onClick = { Browser.open(context, CloudShell.PRIVACY) }) { Text("Google Cloud privacy") }
                TextButton(onClick = { onHelpPage(DocsContent.COMPUTER_ID) }) { Text("More in Help") }
            }
        }
    }
    if (again) {
        AlertDialog(
            onDismissRequest = { again = false },
            title = { Text("Run the set-up again?") },
            text = {
                DialogBody {
                    Text(
                        "For when Cloud Shell was reset or deleted, or an agent is missing. PocketIDE runs Cloud Shell's set-up " +
                            "again through its connection. It only adds what is missing: your projects and chats stay.",
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    again = false
                    graph.settings.update { it.copy(cloudSetUpAt = 0) }
                }) { Text("Set up again") }
            },
            dismissButton = { TextButton(onClick = { again = false }) { Text("Cancel") } },
        )
    }
}

/**
 * PocketIDE's connection on this phone: Google's gcloud (signed in as whom), its size, its updates,
 * and the ways to end it: disconnect, sign gcloud out (Google ends that sign-in too), or remove it.
 */
@Composable
@Suppress("CyclomaticComplexMethod") // One card: the connection's state and each of its buttons.
private fun ConnectionCard() {
    val context = LocalContext.current
    val graph = context.graph
    val scope = rememberCoroutineScope()
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val link by graph.link.state.collectAsStateWithLifecycle()
    val computer by graph.computer.state.collectAsStateWithLifecycle()
    val info by produceState<ComputerInfo?>(null, computer) { value = runCatching { graph.computer.info() }.getOrNull() }
    var busy by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf(false) }
    SectionCard("PocketIDE's connection (on this phone)") {
        Text(
            buildString {
                append(if (settings.gcloudAccount.isBlank()) "gcloud is not signed in." else "gcloud is signed in as ${settings.gcloudAccount}.")
                info?.let { facts ->
                    facts.gcloud?.let { append(" Google Cloud SDK $it") }
                    facts.ubuntu?.let { append(" on $it") }
                    append(", ${Formats.size(facts.systemBytes + facts.homeBytes)} in PocketIDE's private storage.")
                    append(" Updated ${Formats.ago(facts.updatedAt, graph.clock.now())}; it updates itself once a week, on Wi-Fi only.")
                }
                append(" No Google Cloud project, billing or OAuth client is made: only Cloud Shell's free hours are used.")
            },
            style = MaterialTheme.typography.bodyMedium,
        )
        busy?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        ActionRow {
            when (link) {
                LinkState.On, is LinkState.Working -> OutlinedButton(onClick = { graph.link.disconnect() }) { Text("Disconnect") }
                else -> OutlinedButton(onClick = { graph.link.connect() }, enabled = settings.gcloudAccount.isNotBlank()) { Text("Connect") }
            }
            if (link == LinkState.On) OutlinedButton(onClick = { graph.link.stopEverything() }) { Text("Stop everything") }
            OutlinedButton(enabled = busy == null && computer == ComputerState.Ready, onClick = {
                busy = "Updating Ubuntu and gcloud…"
                scope.launch {
                    val outcome = graph.computer.updateBase()
                    if (outcome is UpdateOutcome.Updated) graph.link.gcloudUpdated()
                    busy = when (outcome) {
                        UpdateOutcome.UpToDate -> "Everything is up to date."
                        is UpdateOutcome.Updated -> outcome.detail
                        is UpdateOutcome.Waiting -> outcome.why
                        is UpdateOutcome.Failed -> outcome.why
                    }
                }
            }) { Text("Update now") }
            if (settings.gcloudAccount.isNotBlank()) {
                OutlinedButton(enabled = busy == null, onClick = {
                    busy = "Signing gcloud out…"
                    scope.launch {
                        graph.link.signOut()
                        busy = "gcloud is signed out on this phone, and Google ended its sign-in."
                    }
                }) { Text("Sign gcloud out") }
            }
            TextButton(onClick = { removing = true }) { Text("Remove the connection") }
        }
    }
    if (removing) {
        AlertDialog(
            onDismissRequest = { removing = false },
            title = { Text("Remove PocketIDE's connection?") },
            text = {
                DialogBody {
                    Text(
                        "Deletes Ubuntu, Google's gcloud and its sign-in from this phone (about 500 MB). Your Cloud Shell, with " +
                            "your projects and chats, stays. The agents need the connection: PocketIDE shows its set-up again, and " +
                            "it downloads again when you open PocketIDE.",
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    removing = false
                    busy = "Removing the connection…"
                    scope.launch {
                        graph.link.signOut()
                        graph.computer.remove()
                        busy = null
                    }
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { removing = false }) { Text("Cancel") } },
        )
    }
}
