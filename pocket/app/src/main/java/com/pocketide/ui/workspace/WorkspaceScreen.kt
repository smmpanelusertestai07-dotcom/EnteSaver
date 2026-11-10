package com.pocketide.ui.workspace

import android.content.ClipboardManager
import android.net.Uri
import android.os.SystemClock
import android.view.KeyEvent
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CloseFullscreen
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.OpenInFull
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.AddedAgent
import com.pocketide.agents.AgentSlot
import com.pocketide.cloudshell.CloudShell
import com.pocketide.cloudshell.SignInCatcher
import com.pocketide.docs.DocLinks
import com.pocketide.downloads.FileOffer
import com.pocketide.downloads.HeldFile
import com.pocketide.graph
import com.pocketide.link.BrowserStart
import com.pocketide.link.LinkState
import com.pocketide.link.Problem
import com.pocketide.link.SignInResult
import com.pocketide.ui.components.AddedAgentLogo
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.components.Tone
import com.pocketide.ui.screens.cloudshell.openGooglePage
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.web.Browser
import com.pocketide.ui.web.WebPolicy
import kotlinx.coroutines.launch
import java.net.URLDecoder

/**
 * The agent's VS Code with PocketIDE's own bar above it: Back (a menu or dialog first, then what
 * covers the agent, never straight home), the three agents, Reload, Tools (the terminal, files,
 * settings, all commands: each full screen, one at a time) and a small menu. The keys a phone
 * keyboard lacks sit above the keyboard.
 */
@Composable
// One screen: each state of the connection, and each problem, has its own few lines.
@Suppress("CyclomaticComplexMethod", "LongMethod")
internal fun WorkspaceScreen(activity: WorkspaceActivity, agent: AgentSlot, onAgent: (AgentSlot) -> Unit, onHome: () -> Unit) {
    val graph = activity.graph
    val link by graph.link.state.collectAsStateWithLifecycle()
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val up by graph.link.agentsUp.collectAsStateWithLifecycle()
    val browserStart by graph.link.browser.collectAsStateWithLifecycle()
    var pageStates by remember { mutableStateOf(mapOf<String, PageState>()) }
    var notStarted by remember { mutableStateOf<String?>(null) }
    var viewer by remember { mutableStateOf<String?>(null) }
    var askOpen by remember { mutableStateOf<String?>(null) }
    var pendingFiles by remember { mutableStateOf<ValueCallback<Array<Uri>>?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var backAt by remember { mutableLongStateOf(0L) }
    var signingIn by remember { mutableStateOf(false) }
    var tools by remember { mutableStateOf(false) }
    val account = settings.gcloudAccount.ifBlank { settings.cloudAccount }
    val page = { graph.pages.page(agent.key) }
    val toast = { text: String -> Toast.makeText(activity, text, Toast.LENGTH_LONG).show() }
    val files = rememberFileFlow(graph.downloads, toast)

    val open: (String, Boolean) -> Unit = { url, fromTap ->
        when (val opening = Opening.of(url, graph.link::cloudShellPort)) {
            is Opening.CloudShellPage -> graph.link.pageUrl(opening.port, opening.path)?.let { viewer = it }
            is Opening.SignIn -> {
                // The page returns to the agent waiting on that port in Cloud Shell: the phone passes it on.
                SignInCatcher.catchOn(opening.port, graph.link::open)
                Browser.open(activity, opening.url)
            }
            is Opening.Web -> if (fromTap) Browser.open(activity, opening.url) else askOpen = opening.url
            Opening.Nowhere -> Unit
        }
    }
    val answerFiles = { uris: List<Uri> ->
        pendingFiles?.onReceiveValue(uris.toTypedArray())
        pendingFiles = null
    }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents(), answerFiles)
    // Pictures come from Android's photo picker, which needs no storage permission and shows only what the owner picks.
    val pickPictures = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(), answerFiles)

    val host = remember {
        object : PageHost {
            override fun openWindow(url: String, fromTap: Boolean) = open(url, fromTap)

            override fun leftPage(url: String) = open(url, true)

            override fun pickFiles(callback: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams) {
                pendingFiles?.onReceiveValue(null)
                pendingFiles = callback
                val accepts = params.acceptTypes.orEmpty().filter { it.isNotBlank() }
                runCatching {
                    if (accepts.isNotEmpty() && accepts.all { it.startsWith("image/") }) {
                        pickPictures.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    } else {
                        pickFiles.launch("*/*")
                    }
                }.onFailure {
                    callback.onReceiveValue(null)
                    pendingFiles = null
                }
            }

            override fun download(url: String, contentDisposition: String?, mimeType: String?, contentLength: Long, held: HeldFile?) =
                files.take(url, contentDisposition, mimeType, contentLength, fromVsCode = true, held = held)

            override fun onPageState(key: String, state: PageState) {
                pageStates = pageStates + (key to state)
            }
        }
    }
    DisposableEffect(agent) {
        onDispose { graph.pages.detach(agent.key, host) }
    }
    DisposableEffect(Unit) {
        onDispose {
            pendingFiles?.onReceiveValue(null)
            pendingFiles = null
        }
    }

    // Back: a menu or dialog, then what covers the agent, then the agent itself; home only on a second Back.
    val leave = {
        val now = SystemClock.uptimeMillis()
        if (now - backAt < BACK_AGAIN_MS) {
            onHome()
        } else {
            backAt = now
            Toast.makeText(activity, "Press Back again for PocketIDE's home", Toast.LENGTH_SHORT).show()
        }
    }
    val back = {
        val current = page()
        if (link == LinkState.On && current?.web != null) current.back(otherwise = leave) else onHome()
    }
    BackHandler(enabled = viewer == null && !tools) { back() }
    BackHandler(enabled = tools) { tools = false }

    // Reload: the agent's VS Code starts again in Cloud Shell first if it stopped there (its memory,
    // a restart of Cloud Shell), then its page loads afresh.
    val reload: () -> Unit = {
        if (link == LinkState.On) {
            pageStates = pageStates - agent.key
            graph.pages.release(agent.key)
            graph.link.agentGone(agent)
            generation++
        } else {
            graph.link.connect()
        }
    }

    // A connection that comes back tries each agent's VS Code again.
    LaunchedEffect(link) {
        if (link != LinkState.On) notStarted = null
    }

    // The browser's view opens once it runs (Tools > Browser).
    LaunchedEffect(browserStart) {
        if (browserStart == BrowserStart.Ready) {
            graph.link.pageUrl(CloudShell.BROWSER_PORT, "/")?.let { viewer = it }
            graph.link.browserShown()
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        TopBar(
            agent = agent,
            added = settings.addedAgents,
            onBack = back,
            onAgent = { picked ->
                viewer = null
                if (picked != agent) onAgent(picked)
            },
            // The whole IDE around the agent, drawn smaller; again for the agent alone, full screen.
            ideShown = page()?.wide == true,
            onIde = { page()?.let { it.run(if (it.wide) AgentPage.AGENT else AgentPage.IDE) } },
            onTools = { tools = true },
            menu = listOf(
                "Reload this VS Code" to reload,
                "PocketIDE home" to onHome,
                "Disconnect" to {
                    graph.link.disconnect()
                    onHome()
                },
                "Stop everything" to {
                    graph.link.stopEverything()
                    onHome()
                },
            ),
        )
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (val state = link) {
                LinkState.On -> {
                    val url = graph.link.agentUrl(agent)
                    when {
                        url == null -> Waiting("Connecting…", null)
                        notStarted == agent.key -> Problem(
                            "${agent.displayName}'s VS Code did not start in Cloud Shell.",
                            "Try again. If it keeps failing, Cloud Shell may be short of memory: stop an agent's VS Code " +
                                "you are not using (PocketIDE's Usage), or disconnect and connect again.",
                        ) {
                            PrimaryAction("Try again", onClick = { notStarted = null })
                            TextButton(onClick = { graph.link.disconnect() }) { Text("Disconnect") }
                        }
                        // Each agent's VS Code starts when it opens, so Cloud Shell's memory goes to the agents in use.
                        agent.key !in up -> {
                            Waiting("Starting ${agent.displayName}'s VS Code…", "The first start after a break takes a minute.")
                            LaunchedEffect(agent.key, url) {
                                if (!graph.link.openAgent(agent)) notStarted = agent.key
                            }
                        }
                        else -> {
                            key(agent.key, url, generation) {
                                AndroidView(factory = { graph.pages.attach(agent.key, url, activity, host) }, modifier = Modifier.fillMaxSize())
                            }
                            PageOverlay(pageStates[agent.key], onReload = reload)
                        }
                    }
                }
                is LinkState.Working -> Waiting(state.step, state.detail)
                LinkState.Off -> Problem("Not connected to Cloud Shell.", "Connect to open ${agent.displayName}.") {
                    PrimaryAction("Connect", onClick = { graph.link.connect() })
                }
                is LinkState.Failed -> Problem(state.why, fixOf(state.problem)) {
                    when (state.problem) {
                        Problem.SIGN_IN -> PrimaryAction("Sign in to gcloud", busy = signingIn, onClick = {
                            signingIn = true
                            scope.launch {
                                when (val result = graph.link.signIn(account)) {
                                    is SignInResult.SignedIn -> graph.link.connect()
                                    is SignInResult.Failed -> toast(result.why)
                                    SignInResult.Cancelled -> Unit
                                }
                                signingIn = false
                            }
                        })
                        Problem.CLOUD_SHELL -> {
                            PrimaryAction("Open Google's page (once)", onClick = { openGooglePage(activity, CloudShell.googlePage(account)) })
                            TextButton(onClick = { graph.link.connect() }) { Text("Try again") }
                        }
                        Problem.CONNECTOR -> PrimaryAction("Set up the connection", onClick = onHome)
                        Problem.APP_UPDATE -> PrimaryAction("Get the newest PocketIDE", onClick = { Browser.open(activity, DocLinks.RELEASES) })
                        Problem.NETWORK, Problem.OTHER -> PrimaryAction("Try again", onClick = { graph.link.connect() })
                    }
                }
            }
            viewer?.let { url ->
                PageViewer(
                    url = url,
                    shownAs = { shown -> shownAs(shown, graph.link::cloudShellPort) },
                    isDoor = { graph.link.cloudShellPort(it) != null },
                    toDoor = { next ->
                        (Opening.of(next) { null } as? Opening.CloudShellPage)?.let { graph.link.pageUrl(it.port, it.path) }
                    },
                    onOpen = open,
                    onDownload = { url, disposition, mime, length -> files.take(url, disposition, mime, length, fromVsCode = false) },
                    onClose = { viewer = null },
                )
            }
        }
        (browserStart as? BrowserStart.Starting)?.let { BrowserStarting(it.said) }
        val keysWanted = imeVisible() || settings.keysAlways
        if (keysWanted && viewer == null && link == LinkState.On) {
            KeyBar(
                onKey = { code, meta -> page()?.sendKey(code, meta) },
                onPaste = {
                    val text = activity.getSystemService(ClipboardManager::class.java)?.primaryClip
                        ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(activity)?.toString().orEmpty()
                    if (text.isEmpty()) {
                        toast("Nothing is copied yet.")
                    } else {
                        page()?.type(text) { typed -> if (!typed) toast("Long-press where you type, then tap Paste.") }
                    }
                },
            )
        }
    }

    if (tools) {
        ToolsSheet(
            enabled = link == LinkState.On && page()?.web != null,
            browserEnabled = link == LinkState.On,
            keysAlways = settings.keysAlways,
            onCommand = { command ->
                tools = false
                page()?.run(command)
            },
            onBrowser = {
                tools = false
                graph.link.startBrowser()
            },
            onFiles = {
                tools = false
                graph.link.pageUrl(FileOffer.FILES_PORT, "/f/" + Uri.encode(agent.key))?.let { viewer = it }
            },
            onKeys = { always -> graph.settings.update { it.copy(keysAlways = always) } },
            onReload = {
                tools = false
                reload()
            },
            onHome = {
                tools = false
                onHome()
            },
            onClose = { tools = false },
        )
    }

    (browserStart as? BrowserStart.Refused)?.let { refused ->
        BrowserRefused(
            refused = refused,
            current = agent,
            onStop = { other ->
                graph.link.browserShown()
                graph.pages.release(other.key)
                scope.launch {
                    if (graph.link.stopAgent(other)) graph.link.startBrowser() else toast("${other.displayName}'s VS Code did not stop. Try again.")
                }
            },
            onRetry = {
                graph.link.browserShown()
                graph.link.startBrowser()
            },
            onClose = { graph.link.browserShown() },
        )
    }

    FileFlowSheet(files, graph.downloads, toast)

    askOpen?.let { url ->
        AlertDialog(
            onDismissRequest = { askOpen = null },
            title = { Text("Open this page?") },
            text = { Text("The page wants to open ${WebPolicy.hostOf(url) ?: "a web page"} in your browser.") },
            confirmButton = {
                TextButton(onClick = {
                    Browser.open(activity, url)
                    askOpen = null
                }) { Text("Open") }
            },
            dismissButton = { TextButton(onClick = { askOpen = null }) { Text("Cancel") } },
        )
    }
}

/** How an address of the door shows in the page viewer: as the Cloud Shell address it is (localhost:PORT/…). */
private fun shownAs(url: String, doorPort: (String) -> Int?): String {
    val port = doorPort(url) ?: return url
    if (port == CloudShell.BROWSER_PORT) return "Browser · Chrome in Cloud Shell"
    if (port == FileOffer.FILES_PORT) {
        val path = Opening.pathOf(url).substringBefore('?').substringBefore('#').removePrefix("/f").removePrefix("/r").trim('/')
        return "Cloud Shell files" + (runCatching { URLDecoder.decode(path.replace("+", "%2B"), "UTF-8") }.getOrDefault(path))
            .takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty()
    }
    return "localhost:$port" + Opening.pathOf(url).takeIf { it != "/" }.orEmpty()
}

private fun fixOf(problem: Problem): String = when (problem) {
    Problem.SIGN_IN -> "Google's page opens in Chrome: pick your account and tap Allow. PocketIDE comes back by itself."
    Problem.CLOUD_SHELL -> "Google's own Cloud Shell page shows what Google needs, once (its terms, a verification); then try again."
    Problem.CONNECTOR -> "PocketIDE's home shows the set-up: about 130 MB, once."
    Problem.APP_UPDATE -> "A newer PocketIDE knows how this gcloud connects."
    Problem.NETWORK -> "When the phone is online again, tap Try again."
    Problem.OTHER -> "Tap Try again. If it keeps failing, disconnect, connect again, or restart the phone."
}

@Composable
@Suppress("LongParameterList") // One callback per button in the bar.
private fun TopBar(
    agent: AgentSlot,
    added: List<AddedAgent>,
    onBack: () -> Unit,
    onAgent: (AgentSlot) -> Unit,
    ideShown: Boolean,
    onIde: () -> Unit,
    onTools: () -> Unit,
    menu: List<Pair<String, () -> Unit>>,
) {
    var open by remember { mutableStateOf(false) }
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
            // PocketIDE's three, then the agents the owner added; the row scrolls when they do not fit.
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState())) {
                AgentSlot.all(added).forEach { each -> AgentChip(each, selected = each.key == agent.key, onClick = { onAgent(each) }) }
            }
            IconButton(onClick = onIde) {
                if (ideShown) {
                    Icon(Icons.Outlined.CloseFullscreen, contentDescription = "The agent alone, full screen")
                } else {
                    Icon(Icons.Outlined.OpenInFull, contentDescription = "The whole IDE around the agent")
                }
            }
            IconButton(onClick = onTools) {
                Icon(Icons.Outlined.Handyman, contentDescription = "Tools: terminal, files, the browser, the keys bar, all commands")
            }
            Box {
                IconButton(onClick = { open = true }) { Icon(Icons.Outlined.MoreVert, contentDescription = "More") }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    menu.forEach { (label, action) ->
                        DropdownMenuItem(text = { Text(label) }, onClick = {
                            open = false
                            action()
                        })
                    }
                }
            }
        }
    }
}

/** An agent's logo; the one on screen is framed. */
@Composable
private fun AgentChip(agent: AgentSlot, selected: Boolean, onClick: () -> Unit) {
    val frame = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent
    Box(
        Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(12.dp))
            .border(2.dp, frame, RoundedCornerShape(12.dp))
            .clickable(role = Role.Tab, onClickLabel = "Open ${agent.displayName}", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        when (agent) {
            is AgentSlot.Official -> AgentLogo(agent.agent, size = 30.dp)
            is AgentSlot.Added -> AddedAgentLogo(agent.added, size = 30.dp)
        }
    }
}

/**
 * Esc, Tab, Ctrl+C, the arrows and Enter: keys a phone's keyboard lacks, for VS Code's terminal and
 * editor. Paste types what was copied where the cursor is (a sign-in code, a command).
 */
@Composable
private fun KeyBar(onKey: (Int, Int) -> Unit, onPaste: () -> Unit) {
    val keys = listOf(
        "Esc" to (KeyEvent.KEYCODE_ESCAPE to 0),
        "Tab" to (KeyEvent.KEYCODE_TAB to 0),
        "Ctrl+C" to (KeyEvent.KEYCODE_C to (KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON)),
        "↑" to (KeyEvent.KEYCODE_DPAD_UP to 0),
        "↓" to (KeyEvent.KEYCODE_DPAD_DOWN to 0),
        "←" to (KeyEvent.KEYCODE_DPAD_LEFT to 0),
        "→" to (KeyEvent.KEYCODE_DPAD_RIGHT to 0),
        "Enter" to (KeyEvent.KEYCODE_ENTER to 0),
    )
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            TextButton(onClick = onPaste, modifier = Modifier.heightIn(min = 44.dp)) { Text("Paste") }
            keys.forEach { (label, key) ->
                TextButton(onClick = { onKey(key.first, key.second) }, modifier = Modifier.heightIn(min = 44.dp)) { Text(label) }
            }
        }
    }
}

@Composable
private fun imeVisible(): Boolean = WindowInsets.ime.getBottom(LocalDensity.current) > 0

@Composable
private fun Waiting(step: String, detail: String?) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(Modifier.size(40.dp))
        Gap(16.dp)
        Text(step, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (!detail.isNullOrBlank()) {
            Gap(8.dp)
            Text(
                detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                maxLines = 3,
            )
        }
    }
}

@Composable
private fun Problem(why: String, fix: String, actions: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.Center) {
        NoticeCard(fix, tone = Tone.WARN, title = why)
        Gap(16.dp)
        actions()
    }
}

@Composable
private fun PageOverlay(page: PageState?, onReload: () -> Unit) {
    when (page) {
        is PageState.Loading -> if (page.progress in 1 until FULL) {
            LinearProgressIndicator(progress = { page.progress / FULL.toFloat() }, modifier = Modifier.fillMaxWidth())
        }
        is PageState.Failed, PageState.Stopped -> Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center) {
                val message = if (page is PageState.Failed) page.message else "Android stopped the page to free memory. The agent kept working in Cloud Shell."
                NoticeCard(message, tone = Tone.WARN)
                Gap(16.dp)
                PrimaryAction("Reload", onClick = onReload)
            }
        }
        PageState.Ready, null -> Unit
    }
}

private const val FULL = 100
private const val BACK_AGAIN_MS = 2_000L
