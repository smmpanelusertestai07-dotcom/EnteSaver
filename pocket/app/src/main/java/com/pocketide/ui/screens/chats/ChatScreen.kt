package com.pocketide.ui.screens.chats

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.Agent
import com.pocketide.cloudshell.Answer
import com.pocketide.cloudshell.ChatMessage
import com.pocketide.cloudshell.ChatRead
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.core.Ist
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.components.Tone
import com.pocketide.ui.screens.live.Asking
import com.pocketide.ui.screens.live.ConnectFirst
import com.pocketide.ui.screens.live.KeepConnectionWhileShown
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.workspace.WorkspaceActivity
import kotlinx.coroutines.launch

/** One chat as the agent wrote it down in Cloud Shell: what was said, the commands and files it used. */
@Composable
fun ChatScreen(agentKey: String, id: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val agent = CloudShellInfo.agentOf(agentKey)
    val link by graph.link.state.collectAsStateWithLifecycle()
    var answer by remember { mutableStateOf<Answer<ChatRead>?>(null) }
    var deleting by remember { mutableStateOf(false) }
    var deleteWhy by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    KeepConnectionWhileShown()
    LaunchedEffect(link == LinkState.On) {
        if (link == LinkState.On && agent != null && answer !is Answer.Got) answer = graph.cloudInfo.chat(agent, id)
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            ChatBar(
                agent = agent,
                title = (answer as? Answer.Got)?.value?.title ?: agent?.displayName.orEmpty(),
                canDelete = agent != null && agent != Agent.ANTIGRAVITY,
                deleteEnabled = link == LinkState.On && !deleting,
                onBack = onBack,
                onDelete = { confirm = true },
            )
            Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) { ChatBody(agent, link, answer) }
            deleteWhy?.let { NoticeCard(it, tone = Tone.WARN, modifier = Modifier.padding(horizontal = 16.dp)) }
            if (agent != null) {
                OutlinedButton(
                    onClick = { WorkspaceActivity.open(context, agent) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                ) { Text("Open ${agent.displayName}") }
            }
        }
    }
    if (confirm && agent != null) {
        DeleteChatDialog(agent, onDismiss = { confirm = false }) {
            confirm = false
            deleting = true
            scope.launch {
                when (val done = graph.cloudInfo.delete(agent, id)) {
                    is Answer.Got -> onBack()
                    is Answer.Failed -> deleteWhy = done.why
                    Answer.NotConnected -> deleteWhy = "Connect first: the chat is in Cloud Shell."
                }
                deleting = false
            }
        }
    }
}

@Composable
private fun ChatBar(agent: Agent?, title: String, canDelete: Boolean, deleteEnabled: Boolean, onBack: () -> Unit, onDelete: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
        if (agent != null) AgentLogo(agent, size = 28.dp)
        Spacer(Modifier.width(10.dp))
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        if (canDelete) {
            IconButton(onClick = onDelete, enabled = deleteEnabled) { Icon(Icons.Outlined.Delete, contentDescription = "Delete this chat") }
        }
    }
}

@Composable
private fun ChatBody(agent: Agent?, link: LinkState, answer: Answer<ChatRead>?) {
    when {
        agent == null -> NoticeCard("This chat is from an agent PocketIDE does not know.", tone = Tone.WARN)
        link != LinkState.On && answer !is Answer.Got -> Column { ConnectFirst(link, "The chats") }
        answer == null -> Asking("Reading the chat in Cloud Shell…")
        answer is Answer.Failed -> NoticeCard(answer.why, tone = Tone.WARN)
        answer is Answer.Got -> Messages(answer.value, agent)
        else -> Unit
    }
}

@Composable
private fun DeleteChatDialog(agent: Agent, onDismiss: () -> Unit, onDelete: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete this chat?") },
        text = {
            Text(
                "It is deleted from Cloud Shell, with its lines in ${agent.displayName}'s prompt history. ${agent.displayName} " +
                    "cannot go back to it, and this cannot be undone. Your project's files stay.",
            )
        },
        confirmButton = { TextButton(onClick = onDelete) { Text("Delete") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Keep") } },
    )
}

@Composable
private fun Messages(chat: ChatRead, agent: Agent) {
    SelectionContainer {
        LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (chat.earlier > 0) {
                item {
                    Text(
                        "${chat.earlier} earlier messages are not shown.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
            }
            if (chat.messages.isEmpty()) {
                item { NoticeCard("Nothing in this chat can be shown here: open ${agent.displayName} to see it.") }
            }
            items(chat.messages) { message -> Message(message, agent) }
            item { Spacer(Modifier.size(8.dp)) }
        }
    }
}

@Composable
private fun Message(message: ChatMessage, agent: Agent) {
    when (message.role) {
        "user" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Box(Modifier.fillMaxWidth(BUBBLE_WIDTH), contentAlignment = Alignment.CenterEnd) {
                Bubble(message.text, MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer, message.time)
            }
        }
        "agent" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth(BUBBLE_WIDTH), contentAlignment = Alignment.CenterStart) {
                Bubble(message.text, MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.colorScheme.onSurface, message.time)
            }
        }
        "artifact" -> Column(
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceContainerLow, RoundedCornerShape(12.dp))
                .padding(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Description, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(8.dp))
                Text("${agent.displayName}'s ${message.name ?: "file"}", style = MaterialTheme.typography.labelLarge)
            }
            Text(message.text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
        }
        else -> Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Terminal, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            Text(
                message.text,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun Bubble(text: String, color: androidx.compose.ui.graphics.Color, onColor: androidx.compose.ui.graphics.Color, time: Long) {
    Column(
        Modifier
            .widthIn(max = 520.dp)
            .background(color, RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = onColor)
        if (time > 0) {
            Text(
                Ist.dateTime(time),
                style = MaterialTheme.typography.labelSmall,
                color = onColor.copy(alpha = TIME_ALPHA),
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

private const val BUBBLE_WIDTH = 0.88f
private const val TIME_ALPHA = 0.7f
