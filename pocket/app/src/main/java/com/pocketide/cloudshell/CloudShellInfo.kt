package com.pocketide.cloudshell

import android.content.Context
import com.pocketide.agents.AddedAgent
import com.pocketide.agents.Agent
import com.pocketide.core.AppJson
import com.pocketide.core.SettingsStore
import com.pocketide.link.Gcloud
import com.pocketide.link.Link
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.util.Base64

/** What a question to Cloud Shell came back with. */
sealed interface Answer<out T> {
    data class Got<T>(val value: T) : Answer<T>

    /** PocketIDE is not connected: nothing was asked, and Cloud Shell was not started for it. */
    data object NotConnected : Answer<Nothing>

    data class Failed(val why: String) : Answer<Nothing>
}

/** An extension in an agent's VS Code; [own] for the agent's own and PocketIDE's layout, which stay. */
@Serializable
data class InstalledExtension(val id: String, val version: String = "", val own: Boolean = false)

/** Every answer of info.py says whether it worked, and why not. */
interface Reply {
    val ok: Boolean
    val error: String?
}

@Serializable
data class AgentStatus(
    val agent: String,
    val port: Int = 0,
    val running: Boolean = false,
    val version: String? = null,
    /** True when the agent's sign-in file is there; null when PocketIDE cannot tell. */
    val signedIn: Boolean? = null,
    /** An agent the owner added: its extension (publisher.name) and that extension's own name. */
    val extension: String? = null,
    val name: String? = null,
)

/** Cloud Shell's machine, now. Sizes in bytes, times in epoch milliseconds. */
@Serializable
data class MachineStatus(
    override val ok: Boolean = false,
    override val error: String? = null,
    val now: Long = 0,
    val uptimeSeconds: Long = 0,
    val processors: Int = 1,
    val load: List<Double> = emptyList(),
    val memoryTotal: Long = 0,
    val memoryAvailable: Long = 0,
    val homeTotal: Long = 0,
    val homeUsed: Long = 0,
    val homeFree: Long = 0,
    val codeServer: String? = null,
    val updated: Long = 0,
    val agents: List<AgentStatus> = emptyList(),
    val browser: BrowserStatus = BrowserStatus(),
) : Reply

/** PocketIDE's browser in Cloud Shell: Chrome's [version] once downloaded; [sandbox] once it ran. */
@Serializable
data class BrowserStatus(val version: String? = null, val running: Boolean = false, val sandbox: Boolean? = null)

@Serializable
data class ChatSummary(
    val agent: String,
    val id: String,
    val title: String = "Chat",
    val project: String = "",
    val created: Long = 0,
    val updated: Long = 0,
    val tokens: Long = 0,
    val steps: Int = 0,
    val archived: Boolean = false,
)

@Serializable
data class AgentProblem(val agent: String, val error: String = "")

@Serializable
data class ChatList(
    override val ok: Boolean = false,
    override val error: String? = null,
    val now: Long = 0,
    val chats: List<ChatSummary> = emptyList(),
    /** Chats past the newest 500, not listed. */
    val more: Int = 0,
    val problems: List<AgentProblem> = emptyList(),
    /** Cloud Shell ran out of time reading them: some may be missing. */
    val partial: Boolean = false,
) : Reply

/** One message: "user", "agent", "tool" (a command or file it used) or "artifact" (Antigravity's plan, task or walkthrough). */
@Serializable
data class ChatMessage(val role: String, val text: String = "", val time: Long = 0, val name: String? = null)

@Serializable
data class ChatRead(
    override val ok: Boolean = false,
    override val error: String? = null,
    val agent: String = "",
    val id: String = "",
    val title: String = "Chat",
    val messages: List<ChatMessage> = emptyList(),
    /** Older messages not sent. */
    val earlier: Int = 0,
) : Reply

@Serializable
data class Done(override val ok: Boolean = false, override val error: String? = null) : Reply

/** The extensions in each agent's VS Code, by info.py's name for the agent. */
@Serializable
data class ExtensionList(
    override val ok: Boolean = false,
    override val error: String? = null,
    val agents: Map<String, List<InstalledExtension>> = emptyMap(),
) : Reply

@Serializable
data class Tokens(val input: Long = 0, val output: Long = 0, val cacheRead: Long = 0, val cacheWrite: Long = 0) {
    val total: Long get() = input + output + cacheRead + cacheWrite
}

/** A usage limit as the agent last wrote it down: [usedPercent] of a window of [minutes], reset at [resetsAt]. */
@Serializable
data class LimitWindow(val usedPercent: Double = 0.0, val minutes: Long? = null, val resetsAt: Long = 0)

@Serializable
data class AgentUsage(
    val day: Tokens = Tokens(),
    val week: Tokens = Tokens(),
    val chats: Int = 0,
    val limits: List<LimitWindow> = emptyList(),
    val limitsAt: Long = 0,
    val error: String? = null,
)

@Serializable
data class AntigravityUsage(val chatsDay: Int = 0, val chats: Int = 0, val steps: Int = 0, val error: String? = null)

@Serializable
data class UsageReport(
    override val ok: Boolean = false,
    override val error: String? = null,
    val now: Long = 0,
    val claude: AgentUsage = AgentUsage(),
    val codex: AgentUsage = AgentUsage(),
    val antigravity: AntigravityUsage = AntigravityUsage(),
    val partial: Boolean = false,
) : Reply

/**
 * Cloud Shell's own numbers and the agents' chats, read there by info.py (assets/cloudshell), which
 * the app sends over its open connection each time. Nothing of it is stored on the phone, and
 * nothing starts Cloud Shell: without a connection, the answer is [Answer.NotConnected].
 */
class CloudShellInfo(private val context: Context, private val link: Link, private val settings: SettingsStore) {
    private val script: ByteArray by lazy { context.assets.open(ASSET).use { it.readBytes() } }

    /** Cloud Shell's machine and agents; the agents the owner added are kept for Home as well. */
    suspend fun status(): Answer<MachineStatus> = ask(listOf("status"), MachineStatus.serializer()).also { answer ->
        if (answer is Answer.Got) {
            val added = added(answer.value)
            if (added != settings.settings.value.addedAgents) settings.update { it.copy(addedAgents = added) }
        }
    }

    suspend fun chats(): Answer<ChatList> = ask(listOf("chats"), ChatList.serializer())

    suspend fun chat(agent: Agent, id: String): Answer<ChatRead> = ask(listOf("chat", key(agent), id), ChatRead.serializer())

    suspend fun usage(): Answer<UsageReport> = ask(listOf("usage"), UsageReport.serializer())

    suspend fun extensions(): Answer<ExtensionList> = ask(listOf("extensions"), ExtensionList.serializer())

    /** Removes one chat from Cloud Shell, with its lines in the agent's prompt history. */
    suspend fun delete(agent: Agent, id: String): Answer<Done> = ask(listOf("delete", key(agent), id), Done.serializer())

    private suspend fun <T : Reply> ask(argv: List<String>, serializer: KSerializer<T>): Answer<T> {
        if (!link.connected) return Answer.NotConnected
        val said = link.ask(command(script, argv)) ?: return Answer.Failed(NO_ANSWER)
        val reply = said.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("{") }
            ?.let { runCatching { AppJson.decodeFromString(serializer, it) }.getOrNull() }
            ?: return Answer.Failed(NO_ANSWER)
        return if (reply.ok) Answer.Got(reply) else Answer.Failed(reply.error ?: NO_ANSWER)
    }

    companion object {
        const val ASSET = "cloudshell/info.py"
        private const val NO_ANSWER = "Cloud Shell did not answer. Try again."

        /** What [argv] may hold: info.py's commands, the agents' names and chat ids. */
        private val WORD = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

        /** Runs [script] with python3 in Cloud Shell: sent in the command itself, so nothing of it stays there. */
        private const val LOADER = "import base64,sys;s=base64.b64decode(sys.argv[1]);sys.argv=['info.py']+sys.argv[2:];" +
            "exec(compile(s,'info.py','exec'),{'__name__':'__main__'})"

        /** The command that runs [script] with [argv] in Cloud Shell. */
        fun command(script: ByteArray, argv: List<String>): String {
            require(argv.isNotEmpty() && argv.all { WORD.matches(it) }) { "Not a word info.py takes: $argv" }
            val encoded = Base64.getEncoder().encodeToString(script)
            return (listOf("python3", "-c", LOADER, encoded) + argv).joinToString(" ") { Gcloud.quote(it) }
        }

        /** The script's name for [agent] (its VS Code's folder in Cloud Shell). */
        fun key(agent: Agent): String = CloudShell.key(agent)

        fun agentOf(key: String): Agent? = Agent.entries.firstOrNull { key(it) == key }

        /** The agents the owner added, in [status]; anything the launcher could not have written is left out. */
        fun added(status: MachineStatus): List<AddedAgent> = status.agents.mapNotNull { each ->
            val extension = each.extension ?: return@mapNotNull null
            if (!AddedAgent.valid(each.agent, each.port, extension)) return@mapNotNull null
            AddedAgent(each.agent, each.port, extension, each.name?.trim()?.take(NAME_CHARS)?.ifBlank { null } ?: extension)
        }

        private const val NAME_CHARS = 60
    }
}
