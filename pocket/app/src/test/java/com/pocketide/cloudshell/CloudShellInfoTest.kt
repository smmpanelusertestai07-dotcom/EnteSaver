package com.pocketide.cloudshell

import com.pocketide.agents.Agent
import com.pocketide.core.AppJson
import com.pocketide.core.Settings
import com.pocketide.core.connectedFor
import com.pocketide.core.withConnectedTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class CloudShellInfoTest {
    private val script = listOf("src/main/assets", "app/src/main/assets").map { File(it, CloudShellInfo.ASSET) }.first { it.isFile }

    /** The very command the app sends, run by a shell as Cloud Shell's would, in a home of its own. */
    private fun run(vararg argv: String): String {
        val home = Files.createTempDirectory("home").toFile()
        try {
            val process = ProcessBuilder("bash", "-c", CloudShellInfo.command(script.readBytes(), argv.toList()))
                .apply { environment()["HOME"] = home.path }
                .redirectErrorStream(false)
                .start()
            val out = process.inputStream.bufferedReader().readText()
            assertTrue("info.py ran in time", process.waitFor(60, TimeUnit.SECONDS))
            assertEquals(out, 0, process.exitValue())
            return out.trim()
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `the command runs info py from inside itself and its answers read as PocketIDE expects`() {
        val status = AppJson.decodeFromString(MachineStatus.serializer(), run("status"))
        assertTrue(status.error, status.ok)
        assertTrue(status.memoryTotal > 0 && status.homeTotal > 0 && status.processors >= 1)
        assertEquals(Agent.entries.map { CloudShellInfo.key(it) }, status.agents.map { it.agent })
        assertEquals(Agent.entries.map { CloudShell.port(it) }, status.agents.map { it.port })
        val chats = AppJson.decodeFromString(ChatList.serializer(), run("chats"))
        assertTrue(chats.ok)
        assertTrue(chats.chats.isEmpty())
        val usage = AppJson.decodeFromString(UsageReport.serializer(), run("usage"))
        assertTrue(usage.ok)
        assertEquals(0L, usage.claude.week.total)
        val missing = AppJson.decodeFromString(ChatRead.serializer(), run("chat", "codex", "nothing-here"))
        assertFalse(missing.ok)
        assertEquals("That chat is not in Cloud Shell any more.", missing.error)
    }

    @Test
    fun `only words reach the command, never a path or a shell's own syntax`() {
        listOf("../x", "a b", "\$(reboot)", "x;y", "", "-rf", "a/b", "'", "*").forEach { word ->
            assertThrows(IllegalArgumentException::class.java) { CloudShellInfo.command(byteArrayOf(1), listOf("chat", "codex", word)) }
        }
        assertThrows(IllegalArgumentException::class.java) { CloudShellInfo.command(byteArrayOf(1), emptyList()) }
        val command = CloudShellInfo.command("print(1)".toByteArray(), listOf("chat", "claude-code", "11111111-2222-3333-4444-555555555555"))
        assertTrue(command, command.startsWith("'python3' '-c' "))
        assertTrue(command.endsWith(" 'chat' 'claude-code' '11111111-2222-3333-4444-555555555555'"))
    }

    @Test
    fun `each agent has the name info py knows it by`() {
        Agent.entries.forEach { assertEquals(it, CloudShellInfo.agentOf(CloudShellInfo.key(it))) }
        assertEquals(null, CloudShellInfo.agentOf("vim"))
    }

    @Test
    fun `a newer info py's extra fields are fine, and a missing one has its default`() {
        val chat = AppJson.decodeFromString(
            ChatRead.serializer(),
            """{"ok":true,"agent":"codex","id":"x","title":"T","messages":[{"role":"user","text":"hi","time":1,"mood":"new"}],"future":1}""",
        )
        assertEquals("hi", chat.messages.single().text)
        assertEquals(0, chat.earlier)
    }

    @Test
    fun `the week's connected time adds up only what falls in the window`() {
        val hour = 3_600_000L
        val now = 100 * 24 * hour
        val week = 7 * 24 * hour
        var settings = Settings()
            .withConnectedTime(now - 10 * 24 * hour, now - 10 * 24 * hour + hour) // too old: dropped
            .withConnectedTime(now - week - hour, now - week + hour) // half in the window
            .withConnectedTime(now - 3 * hour, now - 2 * hour)
        assertEquals(4, settings.connectedTimes.size)
        assertEquals(2 * hour, settings.connectedFor(now, week))
        assertEquals(2 * hour + 30 * 60_000L, settings.connectedFor(now, week, openSince = now - 30 * 60_000L))
        settings = Settings(connectedTimes = listOf(5L)) // half a pair, as a damaged file might hold
        assertEquals(0L, settings.connectedFor(now, week))
    }
}
