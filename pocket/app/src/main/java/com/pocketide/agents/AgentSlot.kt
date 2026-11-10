package com.pocketide.agents

import com.pocketide.cloudshell.CloudShell
import kotlinx.serialization.Serializable

/**
 * An AI agent the owner added from Open VSX (Home > Extensions > Add as an agent), as Cloud Shell's
 * launcher keeps it: its name there ([key], x-<its name>), its own VS Code's [port] (8083 to 8099),
 * its extension ([extension], publisher.name) and that extension's own [name].
 */
@Serializable
data class AddedAgent(val key: String, val port: Int, val extension: String, val name: String) {
    /** Where its projects are in Cloud Shell. */
    val projects: String get() = "~/projects/$key"

    companion object {
        private val KEY = Regex("^x-[a-z0-9-]{1,30}$")
        private val EXTENSION = Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
        const val FIRST_PORT = 8083
        const val LAST_PORT = 8099

        /** True for what the launcher can have written: anything else Cloud Shell says is left out. */
        fun valid(key: String, port: Int, extension: String): Boolean =
            KEY.matches(key) && port in FIRST_PORT..LAST_PORT && EXTENSION.matches(extension)
    }
}

/**
 * An agent PocketIDE opens, each in its own VS Code on its own port in Cloud Shell: one of
 * PocketIDE's own three ([Official]), or one the owner added ([Added]).
 */
sealed interface AgentSlot {
    /** The launcher's name for it, and its VS Code's folder: claude-code, codex, antigravity, x-<name>. */
    val key: String
    val port: Int
    val displayName: String

    data class Official(val agent: Agent) : AgentSlot {
        override val key: String get() = CloudShell.key(agent)
        override val port: Int get() = CloudShell.port(agent)
        override val displayName: String get() = agent.displayName
    }

    data class Added(val added: AddedAgent) : AgentSlot {
        override val key: String get() = added.key
        override val port: Int get() = added.port
        override val displayName: String get() = added.name
    }

    companion object {
        /** The agent called [key]: one of PocketIDE's own, or one of [added]; null for any other name. */
        fun of(key: String, added: List<AddedAgent>): AgentSlot? =
            Agent.entries.firstOrNull { CloudShell.key(it) == key }?.let(::Official)
                ?: added.firstOrNull { it.key == key }?.let(::Added)

        /** PocketIDE's own three, then the ones the owner added. */
        fun all(added: List<AddedAgent>): List<AgentSlot> = Agent.entries.map(::Official) + added.map(::Added)
    }
}
