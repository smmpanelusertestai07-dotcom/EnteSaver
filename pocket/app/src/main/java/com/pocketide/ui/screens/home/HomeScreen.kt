package com.pocketide.ui.screens.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.AddedAgent
import com.pocketide.agents.Agent
import com.pocketide.agents.AgentSlot
import com.pocketide.cloudshell.CloudShell
import com.pocketide.core.AppFolders
import com.pocketide.core.OldComputer
import com.pocketide.docs.DocsContent
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.ActionRow
import com.pocketide.ui.components.AddedAgentLogo
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.screens.cloudshell.SignInHelpDialog
import com.pocketide.ui.shell.BrandMark
import com.pocketide.ui.shell.FinePrint
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.OutlinedCard
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.SectionLabel
import com.pocketide.ui.shell.ShellPage
import com.pocketide.ui.workspace.WorkspaceActivity

/**
 * Home: the computer, Google Cloud Shell, and PocketIDE's connection to it; the three agents, each
 * opening its own VS Code inside PocketIDE.
 */
@Composable
fun HomeScreen(onComputer: () -> Unit, onYourData: () -> Unit, onHelp: () -> Unit, onExtensions: () -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val link by graph.link.state.collectAsStateWithLifecycle()
    var signIn by remember { mutableStateOf<Agent?>(null) }
    val oldComputer = remember { OldComputer(AppFolders.of(context).oldComputer).exists() }
    // Cloud Shell's list of agents, the ones the owner added there too, once connected.
    LaunchedEffect(link == LinkState.On) {
        if (link == LinkState.On) graph.cloudInfo.status()
    }
    ShellPage {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BrandMark(36.dp)
            Spacer(Modifier.width(12.dp))
            Text(
                "PocketIDE",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            IconButton(onClick = onHelp) { Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = "Help") }
        }
        Text(DocsContent.TAGLINE, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Gap(16.dp)
        if (oldComputer) {
            NoticeCard(
                "PocketIDE 5's phone computer is still on this phone, with its projects. Save them as a zip, then delete it " +
                    "to free the space.",
                title = "Your old phone computer",
            )
            TextButton(onClick = onYourData) { Text("Open Your data") }
            Gap(8.dp)
        }
        OutlinedCard {
            ListRow(
                leading = { Icon(Icons.Outlined.Cloud, contentDescription = null, modifier = Modifier.size(28.dp), tint = MaterialTheme.colorScheme.primary) },
                title = "Google Cloud Shell",
                subtitle = settings.cloudAccount,
                onClick = onComputer,
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Column(Modifier.padding(16.dp)) {
                Text(connectionText(link), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Gap(12.dp)
                // The computer opens in PocketIDE (the last agent's VS Code), connecting on the way.
                ActionRow {
                    PrimaryAction("Open the computer", onClick = { WorkspaceActivity.openLast(context) })
                    when (link) {
                        LinkState.On -> OutlinedButton(onClick = { graph.link.disconnect() }) { Text("Disconnect") }
                        is LinkState.Working -> OutlinedButton(onClick = { graph.link.disconnect() }) { Text("Stop") }
                        else -> Unit
                    }
                    // Each agent's VS Code and the browser stop in Cloud Shell, then PocketIDE disconnects.
                    if (link == LinkState.On) TextButton(onClick = { graph.link.stopEverything() }) { Text("Stop everything") }
                }
            }
        }
        SectionLabel("Agents")
        OutlinedCard {
            Agent.entries.forEach { agent ->
                AgentRow(agent, onOpen = { WorkspaceActivity.open(context, agent) }, onSignIn = { signIn = agent })
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
            // AI agents the owner added from Open VSX: each with its own VS Code on its own port.
            settings.addedAgents.forEach { added ->
                AddedAgentRow(added, onOpen = { WorkspaceActivity.open(context, AgentSlot.Added(added)) })
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
            ListRow(
                leading = { Icon(Icons.Outlined.Extension, contentDescription = null, modifier = Modifier.size(28.dp)) },
                title = "Extensions and more agents",
                subtitle = "Search Open VSX: add an AI agent with its own VS Code, or install in an agent's; they update by themselves",
                onClick = onExtensions,
            )
        }
        Gap(12.dp)
        FinePrint(
            "An agent opens inside PocketIDE, alone and full screen: Back closes a menu or a file and returns to the agent, " +
                "the IDE button at the top shows the whole IDE around it, Tools has the terminal, files and the browser, and the " +
                "keys a phone keyboard lacks sit above the keyboard. PocketIDE disconnects 15 minutes after you leave the agents; " +
                "Cloud Shell then stops by itself.",
        )
    }
    signIn?.let { agent -> SignInHelpDialog(agent) { signIn = null } }
}

private fun connectionText(state: LinkState): String = when (state) {
    LinkState.On -> "Connected. Tap an agent: its VS Code opens here."
    is LinkState.Working -> state.step
    is LinkState.Failed -> state.why
    LinkState.Off -> "Open the computer, or tap an agent: it opens here and connects. After a break Cloud Shell takes about a minute to start."
}

/** An agent: its logo and maker; a tap opens its VS Code, the key how it signs in. */
@Composable
private fun AgentRow(agent: Agent, onOpen: () -> Unit, onSignIn: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .clickable(onClickLabel = "Open ${agent.displayName}", onClick = onOpen)
            .padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentLogo(agent, size = 40.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(agent.displayName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "${agent.maker} · ${CloudShell.projects(agent)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onSignIn) { Icon(Icons.Outlined.Key, contentDescription = "How to sign in to ${agent.displayName}") }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(8.dp))
    }
}

/** An agent the owner added: its own icon and name; a tap opens its own VS Code. */
@Composable
private fun AddedAgentRow(added: AddedAgent, onOpen: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .clickable(onClickLabel = "Open ${added.name}", onClick = onOpen)
            .padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AddedAgentLogo(added, size = 40.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(added.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "Added · ${added.projects}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(8.dp))
    }
}

@Composable
internal fun ListRow(leading: @Composable () -> Unit, title: String, subtitle: String?, onClick: () -> Unit, enabled: Boolean = true) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) { leading() }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
