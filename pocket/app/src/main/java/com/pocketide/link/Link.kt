package com.pocketide.link

import com.pocketide.agents.AddedAgent
import com.pocketide.agents.Agent
import com.pocketide.agents.AgentSlot
import com.pocketide.cloudshell.CloudShell
import com.pocketide.core.Clock
import com.pocketide.core.LogBackgroundFailure
import com.pocketide.core.SettingsStore
import com.pocketide.core.withConnectedTime
import com.pocketide.linux.Computer
import com.pocketide.linux.ComputerState
import com.pocketide.linux.LinuxDirs
import com.pocketide.linux.drain
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/** PocketIDE's browser in Cloud Shell, as the owner last asked for it (Tools > Browser). */
sealed interface BrowserStart {
    data object Idle : BrowserStart

    /** Starting; [said] is the launcher's latest line (Chrome's download, its libraries). */
    data class Starting(val said: String? = null) : BrowserStart

    /** It runs: its view opens. */
    data object Ready : BrowserStart

    /** It did not start: [why] in the launcher's words; [lowMemory] when Cloud Shell's memory was short. */
    data class Refused(val why: String, val lowMemory: Boolean) : BrowserStart
}

/** How gcloud's sign-in on this phone ended. */
sealed interface SignInResult {
    data class SignedIn(val account: String) : SignInResult
    data class Failed(val why: String) : SignInResult
    data object Cancelled : SignInResult
}

/**
 * PocketIDE's connection to Google Cloud Shell, made by Google's own gcloud on this phone: no
 * Google Cloud project, no key of PocketIDE's own. gcloud signs in once (Google's page, in Chrome),
 * starts Cloud Shell when it is off and opens one SSH connection to it through Google's servers.
 * Through that connection PocketIDE sets Cloud Shell up (its pinned, checked script), starts each
 * agent's VS Code there when it opens (and the browser, when asked), and brings their ports to the
 * phone as socket files only this app can open. [PortProxy] shows them to PocketIDE's own screens,
 * behind a secret key.
 *
 * It connects while the owner uses the agents and disconnects [IDLE_MS] after they leave them,
 * so Cloud Shell stops as Google intends; it never keeps Cloud Shell awake by itself.
 */
@Suppress("TooManyFunctions") // One function for each step of the connection, in the order they run.
class Link internal constructor(
    private val computer: Computer,
    private val dirs: LinuxDirs,
    private val settings: SettingsStore,
    private val holds: Holds,
    private val clock: Clock,
    private val bringBack: () -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + LogBackgroundFailure)

    /** Connect, disconnect and their follow-ups happen one at a time, in order. */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val control = Dispatchers.IO.limitedParallelism(1)

    private val mutableState = MutableStateFlow<LinkState>(LinkState.Off)
    val state: StateFlow<LinkState> = mutableState.asStateFlow()

    /** The owner asked for the connection (an agent's screen), until they disconnect or leave it. */
    @Volatile
    private var wanted = false

    @Volatile
    private var master: Process? = null
    private val masterSaid = ArrayDeque<String>()
    private var connecting: Job? = null
    private var idleStop: Job? = null
    private var retries = 0
    private var screens = 0
    private var tunnelChecked = false

    @Volatile
    private var door: PortProxy? = null
    private val forwarded = ConcurrentHashMap.newKeySet<Int>()
    private val forwardLocks = ConcurrentHashMap<Int, Any>()

    private val mutableAgentsUp = MutableStateFlow<Set<String>>(emptySet())
    private val mutableBrowser = MutableStateFlow<BrowserStart>(BrowserStart.Idle)
    private var browserStart: Job? = null

    /** The agents (by [AgentSlot.key]) whose VS Code answered on this connection ([openAgent]); empty while not connected. */
    val agentsUp: StateFlow<Set<String>> = mutableAgentsUp.asStateFlow()

    /** How the owner's last [startBrowser] went. */
    val browser: StateFlow<BrowserStart> = mutableBrowser.asStateFlow()

    @Volatile
    private var signingIn: Process? = null

    /** Since when the connection is up (UTC epoch ms); null while it is not. */
    @Volatile
    var connectedSince: Long? = null
        private set

    /** The secret every address of PocketIDE's door carries; made once and kept. */
    val key: String
        get() {
            settings.settings.value.proxyKey.takeIf { KEY.matches(it) }?.let { return it }
            val fresh = ByteArray(KEY_BYTES).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
            settings.update { if (KEY.matches(it.proxyKey)) it else it.copy(proxyKey = fresh) }
            return settings.settings.value.proxyKey
        }

    val connected: Boolean get() = state.value == LinkState.On && master?.isAlive == true

    /** [agent]'s VS Code, through PocketIDE's door; null until connected. */
    fun agentUrl(agent: AgentSlot): String? = pageUrl(agent.port, "/")

    /** [path] on Cloud Shell's [port] (its 127.0.0.1), through PocketIDE's door; null until connected. */
    fun pageUrl(port: Int, path: String): String? {
        val doorPort = door?.port?.takeIf { it > 0 } ?: return null
        val rest = if (path.startsWith("/")) path else "/$path"
        return "http://$port-$key.localhost:$doorPort$rest"
    }

    /** The Cloud Shell port an address of PocketIDE's door leads to; null for any other address. */
    fun cloudShellPort(url: String): Int? {
        val doorPort = door?.port?.takeIf { it > 0 } ?: return null
        val match = Regex("""^http://(\d{2,5})-([0-9a-f]{32})\.localhost:(\d{1,5})(?:[/?#].*)?$""").matchEntire(url.trim()) ?: return null
        val (port, givenKey, givenDoor) = match.destructured
        return port.toIntOrNull()?.takeIf { givenKey == key && givenDoor.toIntOrNull() == doorPort }
    }

    /** Connects, unless connected or connecting; safe to call from any screen. */
    fun connect() {
        scope.launch(control) {
            wanted = true
            idleStop?.cancel()
            if (connected || connecting?.isActive == true) return@launch
            retries = 0
            connecting = scope.launch(control) { connectNow() }
        }
    }

    /** Ends the connection; Cloud Shell stops by itself a while later, as it does when you close its page. */
    fun disconnect() {
        scope.launch(control) {
            wanted = false
            idleStop?.cancel()
            connecting?.cancel()
            connecting = null
            shutDown()
            mutableState.value = LinkState.Off
            holds.release(Holds.CONNECTED)
        }
    }

    /** An agent's screen came to the front: the connection is wanted again (after a drop, it reconnects). */
    fun screenShown() {
        scope.launch(control) {
            screens++
            idleStop?.cancel()
        }
        connect()
    }

    /**
     * A screen of Cloud Shell's own data (Chats, Usage) came to the front: an open connection stays
     * open while it is there; none is opened for it, so Cloud Shell never starts only to be looked at.
     * [screenHidden] when it leaves.
     */
    fun dataShown() {
        scope.launch(control) {
            screens++
            idleStop?.cancel()
        }
    }

    /** An agent's screen left the front; with none left, the connection ends after [IDLE_MS]. */
    fun screenHidden() {
        scope.launch(control) {
            screens = (screens - 1).coerceAtLeast(0)
            if (screens == 0) endWhenIdle()
        }
    }

    /** With no agent's screen in front, the connection ends after [IDLE_MS] (unless one comes back). */
    private fun endWhenIdle() {
        idleStop?.cancel()
        idleStop = scope.launch(control) {
            delay(IDLE_MS)
            if (screens == 0 && signingIn == null) disconnectNow()
        }
    }

    private suspend fun disconnectNow() {
        wanted = false
        connecting?.cancel()
        connecting = null
        shutDown()
        mutableState.value = LinkState.Off
        holds.release(Holds.CONNECTED)
    }

    private suspend fun connectNow() {
        holds.hold(Holds.CONNECTED)
        try {
            requireReady()
            checkTunnel()
            step("Starting Cloud Shell…")
            openConnection()
            prepareCloudShell()
            retries = 0
            val now = clock.now()
            settings.update { it.copy(cloudOpenedAt = now) }
            connectedSince = now
            mutableState.value = LinkState.On
            // Connected from the set-up, with no agent open: it ends by itself unless one opens.
            if (screens == 0) endWhenIdle()
        } catch (cancelled: CancellationException) {
            withContext(NonCancellable) { shutDown() }
            throw cancelled
        } catch (failure: LinkFailure) {
            shutDown()
            mutableState.value = LinkState.Failed(failure.problem, failure.why)
            holds.release(Holds.CONNECTED)
        }
    }

    private fun requireReady() {
        val computerState = computer.state.value
        if (computerState !is ComputerState.Ready && computerState !is ComputerState.Updating) {
            throw LinkFailure(Problem.CONNECTOR, "PocketIDE's connection is not set up on this phone yet.")
        }
        if (settings.settings.value.gcloudAccount.isBlank()) {
            throw LinkFailure(Problem.SIGN_IN, "Sign in to gcloud with your Google account first.")
        }
    }

    /**
     * Once per app start (and after gcloud updated itself): the tunnel must still open privately.
     * When a gcloud update changed how it opens, PocketIDE goes back to a gcloud it knows: gcloud's
     * own undo first, else the version this app pins, whose updates then wait for the next app
     * version. Only when neither works does the connection wait for an app update.
     */
    private suspend fun checkTunnel() {
        if (tunnelChecked) return
        step("Checking the connection…")
        Files.createDirectories(dirs.sockets.toPath())
        var check = collect(Gcloud.checkTunnel())
        if (check.code != 0 && GcloudSays.tunnelChanged(check.lines)) {
            step("Going back to the gcloud PocketIDE knows…")
            quiet(Gcloud.restore())
            check = collect(Gcloud.checkTunnel())
            if (check.code == 0) {
                // The same update would come back tomorrow: it waits for the next app version.
                computer.holdGcloudUpdates()
            } else if (GcloudSays.tunnelChanged(check.lines) && computer.reinstallGcloud()) {
                check = collect(Gcloud.checkTunnel())
            }
        }
        when {
            check.code == 0 -> tunnelChecked = true
            GcloudSays.tunnelChanged(check.lines) -> throw LinkFailure(
                Problem.APP_UPDATE,
                "Google's gcloud changed how it connects to Cloud Shell, so PocketIDE cannot keep the connection " +
                    "private. Get the newest PocketIDE; your projects and chats wait in Cloud Shell.",
            )
            else -> throw LinkFailure(
                Problem.OTHER,
                "PocketIDE could not check its connection" + (GcloudSays.lastWords(check.lines)?.let { ": $it" } ?: "") +
                    ". Try again; if it keeps failing, remove the connection (Computer) and set it up again.",
            )
        }
    }

    /** What a command printed, with its exit code. */
    private class Said(val code: Int, val lines: List<String>)

    private suspend fun collect(argv: List<String>): Said {
        val lines = ArrayDeque<String>()
        val code = computer.run(Gcloud.command(argv)) { line ->
            synchronized(lines) {
                lines.addLast(line)
                while (lines.size > SAID_LINES) lines.removeFirst()
            }
        }
        return Said(code, synchronized(lines) { lines.toList() })
    }

    /** After gcloud's own updater ran: the next connection checks the tunnel again. */
    fun gcloudUpdated() {
        scope.launch(control) { tunnelChecked = false }
    }

    @Suppress("ThrowsCount") // Each way the start can fail says so in its own words.
    private suspend fun openConnection() {
        clearSockets()
        Files.createDirectories(dirs.sockets.toPath())
        val process = withContext(Dispatchers.IO) {
            try {
                computer.start(Gcloud.command(Gcloud.connection()))
            } catch (expected: IllegalStateException) {
                throw LinkFailure(Problem.CONNECTOR, expected.message ?: "PocketIDE's connection is not ready.")
            }
        }
        master = process
        synchronized(masterSaid) { masterSaid.clear() }
        thread(name = "PocketIDE gcloud", isDaemon = true) {
            runCatching {
                process.inputStream.bufferedReader().forEachLine { line ->
                    synchronized(masterSaid) {
                        masterSaid.addLast(line)
                        while (masterSaid.size > SAID_LINES) masterSaid.removeFirst()
                    }
                    GcloudSays.progress(line)?.let { said ->
                        if (mutableState.value is LinkState.Working) mutableState.value = LinkState.Working(said)
                    }
                }
            }
        }
        val control = File(dirs.sockets, CONTROL_NAME)
        val connectedInTime = withTimeoutOrNull(CONNECT_TIMEOUT_MS) {
            while (!control.exists()) {
                if (!process.isAlive) {
                    delay(LAST_WORDS_MS)
                    throw GcloudSays.failure(said())
                }
                delay(POLL_MS)
            }
            true
        } ?: false
        if (!connectedInTime) {
            computer.stop(process)
            throw LinkFailure(Problem.NETWORK, "Cloud Shell did not answer within 4 minutes. Check the connection and try again.")
        }
        watch(process)
    }

    /**
     * Sets Cloud Shell up when it needs it and tells it PocketIDE's door. No VS Code starts here:
     * each starts when its agent opens ([openAgent]), so Cloud Shell's memory goes to the agents in use.
     */
    private suspend fun prepareCloudShell() {
        step("Checking Cloud Shell…")
        val current = settings.settings.value.let { it.cloudScript == CloudShell.SCRIPT_COMMIT && it.cloudSetUpAt != 0L }
        // Only a launcher that is really missing (its home reset or deleted) sets Cloud Shell up again;
        // a check the network cut short (ssh's 255) is no reason to run the whole set-up.
        when (if (current) through(Gcloud.HAS_LAUNCHER) else LAUNCHER_MISSING) {
            0 -> Unit
            LAUNCHER_MISSING -> setUp()
            else -> throw LinkFailure(Problem.NETWORK, "Cloud Shell stopped answering. Check the phone's internet, then try again.")
        }
        val port = openDoor()
        step("Preparing Cloud Shell…")
        val template = "http://{{port}}-$key.localhost:$port/"
        if (through(Gcloud.prepare(template)) != 0) {
            throw LinkFailure(Problem.OTHER, "PocketIDE could not prepare Cloud Shell. Try again, or set Cloud Shell up again.")
        }
        // The agents' ports come to the phone now, so their screens open without a wait.
        Agent.entries.forEach { forward(CloudShell.port(it)) }
    }

    /** The pinned, checked set-up script, run through the connection. */
    private suspend fun setUp() {
        // Set up before: only what changed since is fetched (a new app's set-up, or a home Google reset).
        val title = if (settings.settings.value.cloudSetUpAt != 0L) UPDATING_SET_UP else SETTING_UP
        step(title)
        val said = ArrayDeque<String>()
        val code = through(Gcloud.login(CloudShell.setupCommand)) { raw ->
            val line = GcloudSays.clean(raw)
            if (line.isNotEmpty()) {
                synchronized(said) {
                    said.addLast(line)
                    while (said.size > SAID_LINES) said.removeFirst()
                }
                mutableState.value = LinkState.Working(title, line)
            }
        }
        if (code != 0) {
            val last = synchronized(said) { said.lastOrNull() }
            throw LinkFailure(Problem.OTHER, "Cloud Shell's set-up stopped" + (last?.let { ": $it" } ?: ".") + " Try again.")
        }
        val now = clock.now()
        settings.update { it.copy(cloudScript = CloudShell.SCRIPT_COMMIT, cloudSetUpAt = now, cloudOpenedAt = now) }
    }

    private fun openDoor(): Int {
        door?.port?.takeIf { it > 0 }?.let { return it }
        val proxy = PortProxy(key) { port -> open(port) }
        val preferred = settings.settings.value.proxyPort
        var port = if (preferred in PortProxy.LOWEST_PORT..PortProxy.HIGHEST_PORT) proxy.start(preferred) else 0
        if (port == 0) port = proxy.start(0)
        if (port == 0) throw LinkFailure(Problem.OTHER, "PocketIDE could not open its private door on this phone. Restart the phone and try again.")
        door = proxy
        if (port != preferred) settings.update { it.copy(proxyPort = port) }
        return port
    }

    /** Waits for the connection to end, and says so (reconnecting while an agent's screen is in front). */
    private fun watch(process: Process) {
        thread(name = "PocketIDE connection watch", isDaemon = true) {
            runCatching { process.waitFor() }
            scope.launch(control) { ended(process) }
        }
    }

    private suspend fun ended(process: Process) {
        if (master !== process) return
        master = null
        forwarded.clear()
        mutableAgentsUp.value = emptySet()
        countConnectedTime()
        // Not wanted: disconnect says so. Still connecting: its next step fails and says why.
        if (!wanted || (connecting?.isActive == true && mutableState.value !is LinkState.On)) return
        if (screens > 0 && retries < MAX_RETRIES) {
            retries++
            mutableState.value = LinkState.Working("The connection dropped. Connecting again…")
            delay(RETRY_DELAY_MS * retries)
            if (wanted && master == null) connecting = scope.launch(control) { connectNow() }
            return
        }
        val why = GcloudSays.failure(said())
        mutableState.value = if (why.problem == Problem.OTHER || why.problem == Problem.NETWORK) {
            LinkState.Failed(Problem.NETWORK, "The connection to Cloud Shell ended: the network changed, or Cloud Shell stopped after a break.")
        } else {
            LinkState.Failed(why.problem, why.why)
        }
        holds.release(Holds.CONNECTED)
    }

    private suspend fun shutDown() {
        val process = master
        master = null
        forwarded.clear()
        mutableAgentsUp.value = emptySet()
        browserStart?.cancel()
        mutableBrowser.value = BrowserStart.Idle
        countConnectedTime()
        if (process != null) {
            if (process.isAlive) withTimeoutOrNull(CLOSE_TIMEOUT_MS) { runCatching { quiet(Gcloud.close()) } }
            computer.stop(process)
        }
        clearSockets()
    }

    /** The time the connection was up goes into the week's count (Usage), once. */
    private fun countConnectedTime() {
        val since = connectedSince ?: return
        connectedSince = null
        val now = clock.now()
        if (now > since) settings.update { it.withConnectedTime(since, now) }
    }

    /**
     * Starts [agent]'s VS Code in Cloud Shell when it is not running there, and waits until it
     * answers: true then (and the agent is in [agentsUp]); false when not connected or it did not start.
     */
    suspend fun openAgent(agent: AgentSlot): Boolean {
        if (!connected || tried(Gcloud.launcher("start", agent.key)) != 0) return false
        if (!awaitServer(agent.port)) return false
        mutableAgentsUp.update { it + agent.key }
        return true
    }

    /** [agent]'s page could not reach its VS Code: the next [openAgent] starts it again if it stopped. */
    fun agentGone(agent: AgentSlot) {
        mutableAgentsUp.update { it - agent.key }
    }

    /** Stops [agent]'s VS Code in Cloud Shell to free its memory; what the agent was doing there ends. */
    suspend fun stopAgent(agent: AgentSlot): Boolean {
        if (!connected) return false
        mutableAgentsUp.update { it - agent.key }
        return tried(Gcloud.launcher("stop", agent.key)) == 0
    }

    suspend fun stopAgent(agent: Agent): Boolean = stopAgent(AgentSlot.Official(agent))

    /**
     * Adds extension [id] (publisher.name) from Open VSX as an agent with its own VS Code and port
     * in Cloud Shell, with the launcher's words as it goes ([onLine]); its name there (x-<name>), or
     * null when it was not added. [anyPublisher] when the owner accepted an unverified publisher.
     */
    suspend fun addAgent(id: String, anyPublisher: Boolean, onLine: (String) -> Unit): String? {
        if (!connected) return null
        var key: String? = null
        val code = tried(Gcloud.agentAdd(id, anyPublisher)) { line ->
            GcloudSays.clean(line).takeIf { it.isNotEmpty() }?.let {
                if (ADDED_KEY.matches(it)) key = it else onLine(it)
            }
        }
        return key?.takeIf { code == 0 }
    }

    /** Removes an agent the owner added: its VS Code stops and goes; its projects stay in Cloud Shell. */
    suspend fun removeAgent(added: AddedAgent): Boolean {
        if (!connected) return false
        mutableAgentsUp.update { it - added.key }
        return tried(Gcloud.launcher("agent", "remove", added.key)) == 0
    }

    /**
     * Starts PocketIDE's browser in Cloud Shell (Chrome, downloaded the first time, and its view),
     * once at a time; [browser] says how it goes. It goes on when the screen that asked leaves.
     */
    fun startBrowser() {
        scope.launch(control) {
            if (browserStart?.isActive == true) return@launch
            mutableBrowser.value = BrowserStart.Starting()
            browserStart = scope.launch { mutableBrowser.value = browserStarted() }
        }
    }

    /** The screen showed what [browser] said (the view, or why not): back to [BrowserStart.Idle]. */
    fun browserShown() {
        mutableBrowser.update { if (it is BrowserStart.Ready || it is BrowserStart.Refused) BrowserStart.Idle else it }
    }

    private suspend fun browserStarted(): BrowserStart {
        if (!connected) return BrowserStart.Refused("Connect first: the browser runs in Cloud Shell.", lowMemory = false)
        val said = ArrayDeque<String>()
        val job = currentCoroutineContext()[Job]
        val code = withTimeoutOrNull(BROWSER_START_MS) {
            tried(Gcloud.launcher("browser", "start")) { line ->
                val clean = GcloudSays.clean(line)
                if (clean.isNotEmpty()) {
                    synchronized(said) {
                        said.addLast(clean)
                        while (said.size > SAID_LINES) said.removeFirst()
                    }
                    // A line read after the start was called off (disconnected) changes nothing.
                    if (job?.isActive == true) mutableBrowser.value = BrowserStart.Starting(clean)
                }
            }
        }
        val last = synchronized(said) { said.lastOrNull() }
        return when (code) {
            0 -> BrowserStart.Ready
            null -> BrowserStart.Refused("The browser took too long to start. Try again.", lowMemory = false)
            LOW_MEMORY -> BrowserStart.Refused(last ?: "Cloud Shell has too little memory free for the browser.", lowMemory = true)
            else -> BrowserStart.Refused(last ?: "The browser did not start. Try again.", lowMemory = false)
        }
    }

    /**
     * Stops everything PocketIDE runs in Cloud Shell (each agent's VS Code, the browser), then
     * disconnects: Cloud Shell has nothing of PocketIDE's left running, and stops by itself later.
     */
    fun stopEverything() {
        scope.launch {
            if (connected) {
                tried(Gcloud.launcher("stop", *Agent.entries.map(CloudShell::key).toTypedArray()))
                // One at a time: an agent removed elsewhere meanwhile stops nothing else.
                settings.settings.value.addedAgents.forEach { tried(Gcloud.launcher("stop", it.key)) }
                tried(Gcloud.launcher("browser", "stop"))
            }
            disconnect()
        }
    }

    /**
     * Installs ([install] true) or removes extension [id] in [agent]'s VS Code in Cloud Shell, with
     * the launcher's words as it goes ([onLine]); true when it worked. Never connects by itself.
     */
    suspend fun extension(install: Boolean, agent: AgentSlot, id: String, anyPublisher: Boolean, onLine: (String) -> Unit): Boolean =
        connected && tried(Gcloud.extension(install, agent.key, id, anyPublisher)) { line ->
            GcloudSays.clean(line).takeIf { it.isNotEmpty() }?.let(onLine)
        } == 0

    /**
     * [agent]'s own sign-out in Cloud Shell (claude auth logout, codex logout), with what it said
     * ([onLine]); true when it worked. Antigravity signs out in its own panel: the launcher says how.
     */
    suspend fun signOutAgent(agent: Agent, onLine: (String) -> Unit): Boolean =
        connected && tried(Gcloud.launcher("signout", CloudShell.key(agent))) { line ->
            GcloudSays.clean(line).takeIf { it.isNotEmpty() }?.let(onLine)
        } == 0

    /** Stops PocketIDE's browser in Cloud Shell (Chrome and its view). */
    suspend fun stopBrowser(): Boolean = connected && tried(Gcloud.launcher("browser", "stop")) == 0

    /**
     * What [command] printed in Cloud Shell (its output, not its errors), through the open
     * connection; null when not connected, when it failed, or when it said more than [ASK_LIMIT]
     * characters. It never connects by itself.
     */
    suspend fun ask(command: String): String? {
        if (!connected) return null
        val said = StringBuilder()
        var tooMuch = false
        val code = withTimeoutOrNull(ASK_TIMEOUT_MS) {
            try {
                computer.run(Gcloud.command(Gcloud.through(command)).copy(mergeErrors = false)) { line ->
                    if (said.length + line.length < ASK_LIMIT) said.append(line).append('\n') else tooMuch = true
                }
            } catch (expected: IllegalStateException) {
                NOT_RUN // the connection's Linux closed meanwhile
            } catch (expected: IOException) {
                NOT_RUN
            }
        }
        return said.toString().takeIf { code == 0 && !tooMuch }
    }

    private fun clearSockets() {
        dirs.sockets.listFiles()?.forEach { it.delete() }
    }

    /**
     * A connection to Cloud Shell's [port] (its 127.0.0.1), for PocketIDE's door and a sign-in's
     * return; null when not connected. Called on the door's own threads.
     */
    internal fun open(port: Int): Duplex? {
        if (master?.isAlive != true) return null
        var duplex: Duplex? = null
        var tries = 0
        while (duplex == null && tries < OPEN_TRIES && forward(port)) {
            tries++
            duplex = LocalDuplex.connect(socketFile(port))
            if (duplex == null) {
                // A socket file left from a connection that ended: forward the port again.
                forwarded.remove(port)
                socketFile(port).delete()
            }
        }
        if (duplex == null) suspect()
        return duplex
    }

    @Volatile
    private var suspectedAt = 0L

    /**
     * A port could not be reached: when gcloud still runs but its connection is gone (the network
     * changed), it is ended, and the connection starts again while an agent is open.
     */
    private fun suspect() {
        val now = System.currentTimeMillis()
        if (now - suspectedAt < SUSPECT_EVERY_MS) return
        suspectedAt = now
        scope.launch(control) {
            val process = master ?: return@launch
            if (quiet(Gcloud.check()) != 0 && master === process) computer.stop(process)
        }
    }

    private fun socketFile(port: Int) = File(dirs.sockets, "p$port.sock")

    /** Brings Cloud Shell's [port] to its socket file on the phone, once per connection. */
    @Suppress("ReturnCount") // Checked again under the lock: another request may have forwarded it meanwhile.
    private fun forward(port: Int): Boolean {
        val file = socketFile(port)
        if (port in forwarded && file.exists()) return true
        synchronized(forwardLocks.getOrPut(port) { Any() }) {
            if (port in forwarded && file.exists()) return true
            val done = runBlocking { quiet(Gcloud.forward(port)) } == 0 && file.exists()
            if (done) forwarded.add(port)
            return done
        }
    }

    /** True once Cloud Shell's [port] answers a web request (VS Code started), within [timeoutMs]. */
    suspend fun awaitServer(port: Int, timeoutMs: Long = SERVER_WAIT_MS): Boolean = withContext(Dispatchers.IO) {
        withTimeoutOrNull(timeoutMs) {
            while (!answers(port)) delay(POLL_SERVER_MS)
            true
        } ?: false
    }

    private fun answers(port: Int): Boolean {
        val duplex = open(port) ?: return false
        return duplex.use {
            runCatching {
                it.output.write("GET /healthz HTTP/1.1\r\nHost: localhost:$port\r\nConnection: close\r\n\r\n".toByteArray())
                it.output.flush()
                val status = it.input.bufferedReader(Charsets.ISO_8859_1).readLine().orEmpty()
                status.startsWith("HTTP/1.1 2") || status.startsWith("HTTP/1.0 2")
            }.getOrDefault(false)
        }
    }

    /**
     * gcloud's own sign-in: Google's page opens in Chrome (through xdg-open and [LinkOpener]),
     * the owner taps Allow, and the page returns to gcloud on this phone. Then PocketIDE comes back.
     */
    suspend fun signIn(account: String): SignInResult = withContext(Dispatchers.IO) {
        holds.hold(Holds.SIGN_IN)
        val said = ArrayDeque<String>()
        try {
            val process = try {
                computer.start(Gcloud.command(Gcloud.signIn(account)))
            } catch (expected: IllegalStateException) {
                return@withContext SignInResult.Failed(expected.message ?: "PocketIDE's connection is not set up yet.")
            }
            signingIn = process
            val code = try {
                drain(process, mergedErrors = true, onLine = { line ->
                    synchronized(said) {
                        said.addLast(line)
                        while (said.size > SAID_LINES) said.removeFirst()
                    }
                }, stop = computer::stop)
            } finally {
                if (process.isAlive) computer.stop(process)
            }
            val lines = synchronized(said) { said.toList() }
            when {
                signingIn == null -> SignInResult.Cancelled
                code == 0 -> {
                    val who = GcloudSays.signedInAs(lines) ?: account
                    settings.update { it.copy(gcloudAccount = who) }
                    bringBack()
                    SignInResult.SignedIn(who)
                }
                else -> SignInResult.Failed(GcloudSays.lastWords(lines) ?: "gcloud's sign-in stopped.")
            }
        } finally {
            signingIn = null
            holds.release(Holds.SIGN_IN)
        }
    }

    fun cancelSignIn() {
        val process = signingIn ?: return
        signingIn = null
        computer.stop(process)
    }

    /** Disconnects, then has gcloud forget its sign-in on this phone and ask Google to end it. */
    suspend fun signOut() {
        val account = settings.settings.value.gcloudAccount
        withContext(control) { disconnectNow() }
        if (account.isNotBlank()) runCatching { quiet(Gcloud.signOut(account)) }
        settings.update { it.copy(gcloudAccount = "") }
    }

    private fun said(): List<String> = synchronized(masterSaid) { masterSaid.toList() }

    private fun step(text: String) {
        mutableState.value = LinkState.Working(text)
    }

    private suspend fun quiet(argv: List<String>): Int = computer.run(Gcloud.command(argv))

    private suspend fun through(command: String, onLine: (String) -> Unit = {}): Int =
        computer.run(Gcloud.command(Gcloud.through(command)), onLine)

    /** [through], for what the owner asks from a screen: [NOT_RUN] when the connection's Linux cannot run it now. */
    private suspend fun tried(command: String, onLine: (String) -> Unit = {}): Int = try {
        through(command, onLine)
    } catch (expected: IllegalStateException) {
        NOT_RUN // closed meanwhile (removed, or updating)
    } catch (expected: IOException) {
        NOT_RUN
    }

    companion object {
        /** How long after the owner leaves the agents the connection ends. */
        const val IDLE_MS = 15 * 60 * 1000L
        private const val SETTING_UP = "Setting up Cloud Shell (about 5 minutes the first time)…"
        private const val UPDATING_SET_UP = "Updating PocketIDE's set-up in Cloud Shell (what changed only)…"

        /** test's answer when the launcher is not there. */
        private const val LAUNCHER_MISSING = 1
        private const val CONTROL_NAME = "ctl"
        private const val CONNECT_TIMEOUT_MS = 4 * 60 * 1000L
        private const val CLOSE_TIMEOUT_MS = 5_000L
        private const val SERVER_WAIT_MS = 120_000L
        private const val POLL_MS = 300L
        private const val POLL_SERVER_MS = 1_000L
        private const val LAST_WORDS_MS = 500L
        private const val RETRY_DELAY_MS = 3_000L
        private const val MAX_RETRIES = 3
        private const val OPEN_TRIES = 2
        private const val SUSPECT_EVERY_MS = 10_000L
        private const val SAID_LINES = 40
        private const val ASK_TIMEOUT_MS = 60_000L

        /** The first browser downloads Chrome (about 120 MB) and may install its libraries. */
        private const val BROWSER_START_MS = 6 * 60_000L

        /** `pocketide browser start`'s exit code when Cloud Shell has too little memory free. */
        private const val LOW_MEMORY = 3

        /** What [tried] says when the command could not run at all. */
        private const val NOT_RUN = -1
        private const val ASK_LIMIT = 4_000_000
        private const val KEY_BYTES = 16
        private val KEY = Regex("[0-9a-f]{32}")

        /** The launcher's name for an agent the owner added, the last line `pocketide agent add` prints. */
        private val ADDED_KEY = Regex("^x-[a-z0-9-]{1,30}$")
    }
}
