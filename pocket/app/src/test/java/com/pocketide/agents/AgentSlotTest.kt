package com.pocketide.agents

import com.pocketide.cloudshell.AgentStatus
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.cloudshell.MachineStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentSlotTest {
    private val cline = AddedAgent("x-claude-dev", 8083, "saoudrizwan.claude-dev", "Cline")

    @Test
    fun `an agent is found by its Cloud Shell name, PocketIDE's own or added`() {
        assertEquals(AgentSlot.Official(Agent.CODEX), AgentSlot.of("codex", listOf(cline)))
        assertEquals(8081, AgentSlot.of("codex", emptyList())?.port)
        assertEquals(AgentSlot.Added(cline), AgentSlot.of("x-claude-dev", listOf(cline)))
        assertNull("an agent removed meanwhile", AgentSlot.of("x-claude-dev", emptyList()))
        assertNull(AgentSlot.of("vim", listOf(cline)))
        assertEquals(listOf("claude-code", "codex", "antigravity", "x-claude-dev"), AgentSlot.all(listOf(cline)).map { it.key })
        assertEquals("~/projects/x-claude-dev", cline.projects)
    }

    @Test
    fun `only what the launcher can have written is an added agent`() {
        assertTrue(AddedAgent.valid("x-claude-dev", 8083, "saoudrizwan.claude-dev"))
        assertTrue(AddedAgent.valid("x-gpt5-2", 8099, "Some-One.Agent_2"))
        listOf(
            Triple("codex", 8083, "openai.chatgpt"),
            Triple("x-", 8083, "a.b"),
            Triple("x-Claude", 8083, "a.b"),
            Triple("x-claude-dev", 8082, "a.b"),
            Triple("x-claude-dev", 8100, "a.b"),
            Triple("x-claude-dev", 8083, "a.b.c"),
            Triple("x-claude-dev", 8083, "a;b.c"),
        ).forEach { (key, port, extension) -> assertFalse("$key $port $extension", AddedAgent.valid(key, port, extension)) }
    }

    @Test
    fun `Cloud Shell's status lists the added agents, and nothing else that claims to be one`() {
        val status = MachineStatus(
            ok = true,
            agents = listOf(
                AgentStatus("codex", 8081, running = true),
                AgentStatus("x-claude-dev", 8083, extension = "saoudrizwan.claude-dev", name = " Cline "),
                AgentStatus("x-roo-cline", 8084, extension = "RooVeterinaryInc.roo-cline", name = null),
                AgentStatus("x-bad", 8080, extension = "a.b", name = "Takes an agent's port"),
                AgentStatus("../x", 8085, extension = "a.b", name = "Not a name"),
            ),
        )
        assertEquals(
            listOf(cline, AddedAgent("x-roo-cline", 8084, "RooVeterinaryInc.roo-cline", "RooVeterinaryInc.roo-cline")),
            CloudShellInfo.added(status),
        )
    }
}
