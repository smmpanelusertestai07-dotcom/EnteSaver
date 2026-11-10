package com.pocketide.link

import com.pocketide.linux.GuestConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class GcloudTest {
    @Test
    fun `gcloud signs in with Google's page in Chrome, for the picked account`() {
        assertEquals(listOf(Gcloud.GCLOUD, "auth", "login", "dev@example.com", "--launch-browser"), Gcloud.signIn("dev@example.com"))
        assertEquals(listOf(Gcloud.GCLOUD, "auth", "login", "--launch-browser"), Gcloud.signIn(""))
        assertEquals("/opt/pocketide/bin/xdg-open", Gcloud.env["BROWSER"])
        assertEquals("usage reports stay off", "true", Gcloud.env["CLOUDSDK_CORE_DISABLE_USAGE_REPORTING"])
        assertEquals("nobody types into it", "1", Gcloud.env["CLOUDSDK_CORE_DISABLE_PROMPTS"])
    }

    @Test
    fun `the connection's tunnel stays private, and ssh reaches it through the socket file`() {
        assertEquals("/opt/pocketide/bin/gcloud-python", Gcloud.env["CLOUDSDK_PYTHON"])
        assertEquals(Gcloud.TUNNEL, Gcloud.env["POCKETIDE_TUNNEL"])
        val connection = Gcloud.connection()
        assertEquals(listOf(Gcloud.GCLOUD, "cloud-shell", "ssh", "--quiet"), connection.take(4))
        listOf(
            "--ssh-flag=-N",
            "--ssh-flag=-oProxyCommand=nc -U ${Gcloud.TUNNEL}",
            "--ssh-flag=-oControlMaster=yes",
            "--ssh-flag=-oControlPath=${Gcloud.CONTROL}",
            "--ssh-flag=-oStreamLocalBindUnlink=yes",
        ).forEach { assertTrue(it, it in connection) }
        assertFalse("no command of its own", connection.any { it.startsWith("--command") })
        assertTrue(Gcloud.TUNNEL.startsWith("/tmp/pi/") && Gcloud.CONTROL.startsWith("/tmp/pi/"))
    }

    @Test
    fun `later commands only use the open connection, as the app's own user`() {
        val forward = Gcloud.forward(8080)
        assertEquals(listOf("/usr/bin/ssh", "-S", Gcloud.CONTROL, "-oControlMaster=no", "-oBatchMode=yes"), forward.take(5))
        assertTrue(forward.containsAll(listOf("-O", "forward", "-L", "/tmp/pi/p8080.sock:127.0.0.1:8080")))
        assertEquals("check", Gcloud.check()[Gcloud.check().indexOf("-O") + 1])
        assertEquals("exit", Gcloud.close()[Gcloud.close().indexOf("-O") + 1])
        assertEquals("ls", Gcloud.through("ls").last())
        // ssh's shared connection admits only its own user id; PRoot's faked root differs between runs.
        val command = Gcloud.command(Gcloud.forward(8080))
        assertFalse(command.asRoot)
        assertEquals(GuestConfig.USER, command.env["USER"])
    }

    @Test
    fun `commands for Cloud Shell are quoted for its shell`() {
        assertEquals("'it'\\''s'", Gcloud.quote("it's"))
        assertEquals("bash -lc 'echo \$HOME'", Gcloud.login("echo \$HOME"))
        val template = "http://{{port}}-0123456789abcdef0123456789abcdef.localhost:40123/"
        val prepare = Gcloud.prepare(template)
        assertTrue(prepare, prepare.startsWith("bash -lc '"))
        assertTrue(prepare, prepare.contains("~/.local/bin/pocketide proxy-uri '\\''$template'\\''; ~/.local/bin/pocketide --quiet"))
    }

    @Test
    fun `the launcher takes only plain words`() {
        assertEquals("bash -lc '~/.local/bin/pocketide '\\''start'\\'' '\\''claude-code'\\'''", Gcloud.launcher("start", "claude-code"))
        assertEquals("bash -lc '~/.local/bin/pocketide '\\''browser'\\'' '\\''stop'\\'''", Gcloud.launcher("browser", "stop"))
        listOf("", "start;reboot", "\$(id)", "a b", "Start", "../x").forEach { word ->
            assertThrows(IllegalArgumentException::class.java) { Gcloud.launcher("start", word) }
        }
        assertThrows(IllegalArgumentException::class.java) { Gcloud.launcher() }
        // An added agent's name has digits too (x-gpt5-helper).
        assertEquals("bash -lc '~/.local/bin/pocketide '\\''stop'\\'' '\\''x-gpt5-helper'\\'''", Gcloud.launcher("stop", "x-gpt5-helper"))
    }

    @Test
    fun `an agent is added only by its extension's own name`() {
        assertEquals(
            "bash -lc '~/.local/bin/pocketide '\\''agent'\\'' '\\''add'\\'' '\\''saoudrizwan.claude-dev'\\'''",
            Gcloud.agentAdd("saoudrizwan.claude-dev", anyPublisher = false),
        )
        assertTrue(Gcloud.agentAdd("Some-One.agent", anyPublisher = true).endsWith("'\\''any'\\'''"))
        listOf("", "claude-dev", "a.b.c", "x;reboot.y", "\$(id).x", "a .b", "-x.y").forEach { id ->
            assertThrows(IllegalArgumentException::class.java) { Gcloud.agentAdd(id, anyPublisher = false) }
        }
    }
}
