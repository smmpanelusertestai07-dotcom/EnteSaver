package com.pocketide.ui.screens.extensions

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.AddedAgent
import com.pocketide.agents.AgentSlot
import com.pocketide.cloudshell.Answer
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.cloudshell.InstalledExtension
import com.pocketide.cloudshell.OpenVsx
import com.pocketide.cloudshell.OpenVsxExtension
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.AddedAgentLogo
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.components.DialogBody
import com.pocketide.ui.components.ExtensionLogo
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.components.Tone
import com.pocketide.ui.screens.live.Asking
import com.pocketide.ui.screens.live.ConnectFirst
import com.pocketide.ui.screens.live.KeepConnectionWhileShown
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.workspace.WorkspaceActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

/** Each agent's extensions, by info.py's name for the agent; null until Cloud Shell answers. */
private typealias Installed = Map<String, List<InstalledExtension>>

/**
 * Extensions: Open VSX searched from the phone, with each extension's icon, maker, downloads and
 * rating. A tap shows it whole and installs it in an agent's VS Code in Cloud Shell, or removes it;
 * what each agent's VS Code has is read live from Cloud Shell.
 */
@Composable
fun ExtensionsScreen(onBack: () -> Unit) {
    val graph = LocalContext.current.graph
    val link by graph.link.state.collectAsStateWithLifecycle()
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    var query by rememberSaveable { mutableStateOf("") }
    var found by remember { mutableStateOf<OpenVsx.Found?>(null) }
    var installed by remember { mutableStateOf<Installed?>(null) }
    var installedWhy by remember { mutableStateOf<String?>(null) }
    var picked by remember { mutableStateOf<OpenVsxExtension?>(null) }
    var asked by remember { mutableIntStateOf(0) }
    KeepConnectionWhileShown()
    LaunchedEffect(query) {
        if (query.isNotBlank()) delay(TYPING_MS)
        found = null
        found = OpenVsx.search(query)
    }
    LaunchedEffect(link == LinkState.On, asked) {
        if (link == LinkState.On) {
            installedWhy = null
            when (val answer = graph.cloudInfo.extensions()) {
                is Answer.Got -> installed = answer.value.agents
                is Answer.Failed -> installedWhy = answer.why
                Answer.NotConnected -> Unit
            }
        }
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
                Text("Extensions", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            }
            OutlinedTextField(
                value = query,
                onValueChange = { query = it.take(QUERY_LIMIT) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                singleLine = true,
                leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                placeholder = { Text("Search Open VSX") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (query.isBlank() && settings.addedAgents.isNotEmpty()) item { AddedAgentsCard(link, settings.addedAgents, onChanged = { asked++ }) }
                if (query.isBlank()) item { InstalledCard(link, installed, installedWhy, settings.addedAgents, onChanged = { asked++ }) }
                item {
                    Text(
                        if (query.isBlank()) "Most installed on Open VSX" else "On Open VSX",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.semantics { heading() },
                    )
                }
                searchResults(found, onPick = { picked = it })
            }
        }
    }
    picked?.let { extension ->
        ExtensionDialog(extension, link, installed, settings.addedAgents, onChanged = { asked++ }, onClose = { picked = null })
    }
}

/** What Open VSX answered: each extension found, or why there is none. */
private fun LazyListScope.searchResults(found: OpenVsx.Found?, onPick: (OpenVsxExtension) -> Unit) {
    when (found) {
        null -> item { Asking("Searching Open VSX…") }
        is OpenVsx.Found.Failed -> item { NoticeCard(found.why, tone = Tone.WARN) }
        is OpenVsx.Found.Some -> {
            if (found.extensions.isEmpty()) item { Text("Open VSX has nothing by that name.") }
            items(found.extensions, key = { it.id }) { extension -> ExtensionRow(extension, onClick = { onPick(extension) }) }
        }
    }
}

/** What each agent's VS Code has now, read from Cloud Shell; anything but the agent's own can go. */
@Composable
private fun InstalledCard(link: LinkState, installed: Installed?, why: String?, added: List<AddedAgent>, onChanged: () -> Unit) {
    if (link != LinkState.On) {
        ConnectFirst(link, "Each agent's extensions are")
        return
    }
    SectionCard("In each agent's VS Code") {
        if (installed == null) {
            if (why == null) {
                Asking("Asking Cloud Shell…")
            } else {
                NoticeCard(why, tone = Tone.WARN)
                TextButton(onClick = onChanged) { Text("Try again") }
            }
            return@SectionCard
        }
        AgentSlot.all(added).forEach { agent ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                AgentLogo(agent, size = 24.dp)
                Spacer(Modifier.width(8.dp))
                Text(agent.displayName, style = MaterialTheme.typography.titleSmall)
            }
            installed[agent.key].orEmpty().forEach { extension ->
                InstalledRow(agent, extension, onChanged)
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
        Text(
            "Each agent's VS Code keeps its own extensions, and they update by themselves. The agent's own and " +
                "PocketIDE's layout stay.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun InstalledRow(agent: AgentSlot, extension: InstalledExtension, onChanged: () -> Unit) {
    val graph = LocalContext.current.graph
    val scope = rememberCoroutineScope()
    var said by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        ExtensionLogo(extension.id.substringAfter('.'), size = 28.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(extension.id, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                said ?: listOf(extension.version, if (extension.own) "kept by PocketIDE" else "").filter { it.isNotBlank() }.joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
            )
        }
        if (busy) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        } else if (!extension.own) {
            TextButton(onClick = {
                busy = true
                scope.launch {
                    val done = graph.link.extension(install = false, agent, extension.id, anyPublisher = false) { said = it }
                    busy = false
                    if (done) onChanged() else said = said ?: "It was not removed. Try again."
                }
            }) { Text("Remove") }
        }
    }
}

/** One search result: icon, name, maker, downloads, rating and what it does. */
@Composable
private fun ExtensionRow(extension: OpenVsxExtension, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(onClickLabel = "Show ${extension.title}", onClick = onClick).padding(4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        ExtensionIcon(extension, 44.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    extension.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (extension.verified) {
                    Spacer(Modifier.width(4.dp))
                    Icon(Icons.Outlined.Verified, contentDescription = "Verified publisher", Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                }
            }
            Text(
                facts(extension),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            extension.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/**
 * One extension, whole, and where it goes: a button for each agent's VS Code. A publisher Open VSX
 * has not verified needs a second tap, after the warning.
 */
@Composable
private fun ExtensionDialog(
    extension: OpenVsxExtension,
    link: LinkState,
    installed: Installed?,
    added: List<AddedAgent>,
    onChanged: () -> Unit,
    onClose: () -> Unit,
) {
    val graph = LocalContext.current.graph
    val uri = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf<String?>(null) }
    var said by remember { mutableStateOf<String?>(null) }
    var unverifiedOk by remember { mutableStateOf(extension.verified) }
    val agent by produceState(false, extension.id) { value = OpenVsx.isAgent(extension) }
    val has = { slot: AgentSlot -> installed?.get(slot.key).orEmpty().any { it.id.equals(extension.id, ignoreCase = true) } }
    AlertDialog(
        onDismissRequest = { if (working == null) onClose() },
        icon = { ExtensionIcon(extension, 48.dp) },
        title = { Text(extension.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        text = {
            DialogBody {
                Text("${extension.id} ${extension.version}", style = MaterialTheme.typography.bodySmall)
                Text(facts(extension), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                extension.description?.takeIf { it.isNotBlank() }?.let { Text(it) }
                if (extension.deprecated) NoticeCard("Its publisher says it is no longer kept up to date.", tone = Tone.WARN)
                if (!extension.verified) {
                    NoticeCard(
                        "Open VSX has not verified this publisher: anyone could have published it under that name. An extension can " +
                            "use everything in your Cloud Shell. Install it only if you trust it.",
                        tone = Tone.WARN,
                    )
                }
                if (link != LinkState.On) {
                    Text("Connect to install it: the agents' VS Code is in Cloud Shell. Home > Open the computer, or Computer > Connect.")
                } else {
                    if (agent) {
                        AddAsAgent(extension, added, onAdded = onChanged)
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        Text("Or install it in an agent's VS Code:", style = MaterialTheme.typography.bodySmall)
                    }
                    AgentSlot.all(added).forEach { slot ->
                        AgentTarget(slot, installed = has(slot), working = working == slot.key, enabled = working == null) {
                            if (!unverifiedOk) {
                                unverifiedOk = true
                                said = "Tap again to install it anyway."
                                return@AgentTarget
                            }
                            working = slot.key
                            said = null
                            scope.launch {
                                val done = graph.link.extension(install = true, slot, extension.id, anyPublisher = !extension.verified) { said = it }
                                working = null
                                said = if (done) {
                                    "Installed in ${slot.displayName}'s VS Code. If it is open, reload it to use the " +
                                        "extension now: Tools > Reload this VS Code."
                                } else {
                                    said ?: "It was not installed. Try again."
                                }
                                if (done) onChanged()
                            }
                        }
                    }
                }
                said?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = { TextButton(onClick = onClose, enabled = working == null) { Text("Close") } },
        dismissButton = { TextButton(onClick = { uri.openUri(extension.page) }) { Text("Open VSX page") } },
    )
}

@Composable
private fun AgentTarget(agent: AgentSlot, installed: Boolean, working: Boolean, enabled: Boolean, onInstall: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        AgentLogo(agent, size = 28.dp)
        Spacer(Modifier.width(10.dp))
        Text(agent.displayName, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        when {
            working -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            installed -> Text("Installed", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            else -> OutlinedButton(onClick = onInstall, enabled = enabled) { Text("Install") }
        }
    }
}

/**
 * An AI agent from Open VSX as an agent of its own: its own VS Code on its own port in Cloud Shell,
 * on Home with the others and opened the same way. A publisher Open VSX has not verified needs a
 * second tap, after the dialog's warning.
 */
@Composable
private fun AddAsAgent(extension: OpenVsxExtension, added: List<AddedAgent>, onAdded: () -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var said by remember { mutableStateOf<String?>(null) }
    var unverifiedOk by remember { mutableStateOf(extension.verified) }
    val already = added.firstOrNull { it.extension.equals(extension.id, ignoreCase = true) }
    Text(
        "An AI agent: it can have its own VS Code, on its own port in Cloud Shell, and open from Home like the others.",
        style = MaterialTheme.typography.bodySmall,
    )
    when {
        already != null -> PrimaryAction("Open ${already.name}", onClick = { WorkspaceActivity.open(context, AgentSlot.Added(already)) })
        else -> PrimaryAction("Add as an agent", busy = working, onClick = {
            if (!unverifiedOk) {
                unverifiedOk = true
                said = "Tap again to add it anyway."
                return@PrimaryAction
            }
            working = true
            said = null
            scope.launch {
                val key = graph.link.addAgent(extension.id, anyPublisher = !extension.verified) { said = it }
                // Cloud Shell's list of agents, now with this one: Home shows it.
                if (key != null) graph.cloudInfo.status()
                working = false
                said = if (key != null) "Added, with its own VS Code: it is on Home." else said ?: "It was not added. Try again."
                if (key != null) onAdded()
            }
        })
    }
    said?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
}

/** The agents the owner added: open one, or remove it (its VS Code goes; its projects stay). */
@Composable
private fun AddedAgentsCard(link: LinkState, added: List<AddedAgent>, onChanged: () -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf<AddedAgent?>(null) }
    var working by remember { mutableStateOf<String?>(null) }
    var said by remember { mutableStateOf<String?>(null) }
    SectionCard("Agents you added") {
        added.forEach { agent ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                AddedAgentLogo(agent, size = 28.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(agent.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${agent.extension} · port ${agent.port}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (working == agent.key) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(onClick = { WorkspaceActivity.open(context, AgentSlot.Added(agent)) }) { Text("Open") }
                    TextButton(onClick = { removing = agent }, enabled = link == LinkState.On && working == null) { Text("Remove") }
                }
            }
        }
        said?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
    removing?.let { agent ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove ${agent.name}?") },
            text = {
                Text(
                    "Its VS Code stops and goes from Cloud Shell, with its own settings, sign-in and chats there. Your projects " +
                        "stay in ${agent.projects}. You can add it again from Open VSX.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    working = agent.key
                    said = null
                    scope.launch {
                        graph.pages.release(agent.key)
                        val done = graph.link.removeAgent(agent)
                        if (done) graph.cloudInfo.status()
                        working = null
                        said = if (done) "${agent.name} is removed." else "${agent.name} was not removed. Try again."
                        if (done) onChanged()
                    }
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } },
        )
    }
}

/** An extension's own icon from Open VSX, or its initial on a tile while there is none. */
@Composable
private fun ExtensionIcon(extension: OpenVsxExtension, size: Dp) {
    val icon by produceState(ExtensionIcons.cached(extension.id), extension.id) {
        if (value == null) value = ExtensionIcons.load(extension)
    }
    val bitmap = icon
    if (bitmap != null) {
        Image(bitmap, contentDescription = null, modifier = Modifier.size(size).clip(RoundedCornerShape(size * 0.2f)))
    } else {
        ExtensionLogo(extension.title, size = size)
    }
}

/** Icons of the extensions shown, in memory while the app runs. */
private object ExtensionIcons {
    private val memory = LruCache<String, ImageBitmap>(ICONS_KEPT)

    fun cached(id: String): ImageBitmap? = memory.get(id)

    suspend fun load(extension: OpenVsxExtension): ImageBitmap? {
        val bytes = OpenVsx.icon(extension) ?: return null
        return withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }?.also { memory.put(extension.id, it) }
    }
}

/** Publisher, downloads and rating, in a line. */
private fun facts(extension: OpenVsxExtension): String = buildList {
    add(extension.namespace)
    add("${compact(extension.downloadCount)} downloads")
    extension.averageRating?.let { add(String.format(Locale.US, "%.1f ★", it)) }
}.joinToString(" · ")

/** 9,301,251 as 9.3M; 12,400 as 12K. */
internal fun compact(count: Long): String = when {
    count >= MILLION -> String.format(Locale.US, "%.1fM", count / MILLION.toDouble()).replace(".0M", "M")
    count >= THOUSAND -> "${count / THOUSAND}K"
    else -> count.toString()
}

private const val TYPING_MS = 400L
private const val QUERY_LIMIT = 100
private const val ICONS_KEPT = 120
private const val THOUSAND = 1_000L
private const val MILLION = 1_000_000L
