package com.pocketide.ui.screens.chats

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.Agent
import com.pocketide.cloudshell.Answer
import com.pocketide.cloudshell.ChatList
import com.pocketide.cloudshell.ChatSummary
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.components.Formats
import com.pocketide.ui.components.Tone
import com.pocketide.ui.screens.live.Asking
import com.pocketide.ui.screens.live.ConnectFirst
import com.pocketide.ui.screens.live.KeepConnectionWhileShown
import com.pocketide.ui.shell.FinePrint
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.OutlinedCard
import com.pocketide.ui.shell.ShellPage

/**
 * Every chat of the three agents, newest first, read from Cloud Shell each time this page shows.
 * Nothing of them is kept on the phone.
 */
@Composable
fun ChatsScreen(onOpen: (ChatSummary) -> Unit) {
    val graph = LocalContext.current.graph
    val link by graph.link.state.collectAsStateWithLifecycle()
    var answer by remember { mutableStateOf<Answer<ChatList>?>(null) }
    var asking by remember { mutableStateOf(false) }
    var again by remember { mutableIntStateOf(0) }
    var only by rememberSaveable { mutableStateOf<String?>(null) }
    KeepConnectionWhileShown()
    // Read again each time the page comes back (a chat deleted, a new one started meanwhile).
    LifecycleStartEffect(Unit) {
        again++
        onStopOrDispose { }
    }
    LaunchedEffect(link == LinkState.On, again) {
        if (link == LinkState.On) {
            asking = true
            answer = graph.cloudInfo.chats()
            asking = false
        }
    }
    ShellPage {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Forum, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Text(
                "Chats",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            IconButton(onClick = { again++ }, enabled = link == LinkState.On && !asking) {
                Icon(Icons.Outlined.Refresh, contentDescription = "Read again")
            }
        }
        Text(
            "Each agent's chats, as they are in Cloud Shell.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Gap(12.dp)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(selected = only == null, onClick = { only = null }, label = { Text("All") })
            Agent.entries.forEach { agent ->
                val key = CloudShellInfo.key(agent)
                FilterChip(selected = only == key, onClick = { only = key }, label = { Text(agent.displayName) })
            }
        }
        Gap(12.dp)
        val shown = answer
        when {
            link != LinkState.On -> ConnectFirst(link, "The chats")
            asking && shown == null -> Asking("Reading the chats in Cloud Shell…")
            shown is Answer.Failed -> NoticeCard(shown.why, tone = Tone.WARN)
            shown is Answer.Got -> ChatRows(shown.value, only, onOpen)
            else -> Unit
        }
        FinePrint(
            "Read from Cloud Shell over PocketIDE's private connection each time you open this page; nothing of " +
                "them is kept on this phone. Each agent keeps its own (Claude Code ~/.claude, Codex ~/.codex, " +
                "Antigravity ~/.gemini/antigravity).",
        )
    }
}

@Composable
private fun ChatRows(list: ChatList, only: String?, onOpen: (ChatSummary) -> Unit) {
    val chats = list.chats.filter { only == null || it.agent == only }
    list.problems.forEach { problem ->
        val name = CloudShellInfo.agentOf(problem.agent)?.displayName ?: problem.agent
        NoticeCard("$name's chats could not be read (${problem.error}).", tone = Tone.WARN)
        Gap(8.dp)
    }
    if (chats.isEmpty()) {
        NoticeCard("No chats yet. They show here once you talk to an agent.")
        return
    }
    OutlinedCard {
        chats.forEachIndexed { index, chat ->
            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            ChatRow(chat, list.now) { onOpen(chat) }
        }
    }
    if (list.more > 0) FinePrint("${list.more} older chats are not listed.")
    if (list.partial) FinePrint("Cloud Shell took long to read them all: some may be missing. Read again.")
}

@Composable
private fun ChatRow(chat: ChatSummary, now: Long, onClick: () -> Unit) {
    val agent = CloudShellInfo.agentOf(chat.agent)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clickable(onClickLabel = "Open the chat", onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (agent != null) AgentLogo(agent, size = 32.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(chat.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val where = chat.project.substringAfterLast('/').ifBlank { agent?.displayName.orEmpty() }
            Text(
                listOf(where, Formats.ago(chat.updated, now), if (chat.archived) "archived" else "").filter { it.isNotBlank() }.joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
