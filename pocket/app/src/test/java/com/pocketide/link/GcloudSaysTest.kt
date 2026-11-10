package com.pocketide.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GcloudSaysTest {
    private fun problem(vararg lines: String) = GcloudSays.failure(lines.toList()).problem

    @Test
    fun `what gcloud says becomes what the owner can do`() {
        // Word for word what gcloud 587 prints without a sign-in (run on Ubuntu 26.04).
        assertEquals(
            Problem.SIGN_IN,
            problem(
                "ERROR: (gcloud.cloud-shell.ssh) You do not currently have an active account selected.",
                "Please run:", "", "  \$ gcloud auth login", "",
                "to obtain new credentials.",
            ),
        )
        assertEquals(Problem.SIGN_IN, problem("ERROR: (gcloud.cloud-shell.ssh) There was a problem refreshing your current auth tokens: invalid_grant"))
        assertEquals(
            Problem.CLOUD_SHELL,
            problem(
                "ERROR: (gcloud.cloud-shell.ssh) Your account is unverified. " +
                    "Please verify your account at https://x or at https://shell.cloud.google.com.",
            ),
        )
        assertEquals(Problem.CLOUD_SHELL, problem("ERROR: (gcloud.cloud-shell.ssh) FAILED_PRECONDITION: Accept the Terms of Service first."))
        assertEquals(Problem.CLOUD_SHELL, problem("ERROR: (gcloud.cloud-shell.ssh) RESOURCE_EXHAUSTED: weekly quota exceeded"))
        assertEquals(Problem.CLOUD_SHELL, problem("ERROR: (gcloud.cloud-shell.ssh) The Cloud Shell machine did not start."))
        assertEquals(Problem.NETWORK, problem("ERROR: gcloud crashed (ConnectionError): HTTPSConnectionPool: Max retries exceeded"))
        assertEquals(Problem.APP_UPDATE, problem("ImportError: PocketIDE: this gcloud ${GcloudSays.TUNNEL_CHANGED}; update PocketIDE."))
        assertEquals(Problem.OTHER, problem("ERROR: (gcloud.cloud-shell.ssh) Something new."))
    }

    @Test
    fun `only a changed gcloud makes the check ask for gcloud to be put back`() {
        // Word for word what private_tunnel.py --check prints (run against gcloud 587 and a changed copy).
        val changed = "private tunnel: PocketIDE: this gcloud opens its Cloud Shell tunnel in a new way; update PocketIDE. " +
            "(ModuleNotFoundError: No module named 'googlecloudsdk.command_lib.cloud_shell.tunnel')"
        assertTrue(GcloudSays.tunnelChanged(listOf("Listening on local port [22].", changed)))
        // The phone's own problem (here the 7.0.0 one: the socket's folder) is said as it is, not as a gcloud change.
        val phone = "private tunnel: PhoneProblem: /tmp/pi/tunnel.sock: No such file or directory"
        assertFalse(GcloudSays.tunnelChanged(listOf(phone)))
        assertEquals(phone, GcloudSays.lastWords(listOf("Tunnel stopped.", phone)))
        assertFalse(GcloudSays.tunnelChanged(listOf("Listening on local port [22].", "Tunnel stopped.", "private tunnel: ok")))
    }

    @Test
    fun `the last words drop gcloud's prefix and terminal colours`() {
        assertEquals("Something new.", GcloudSays.lastWords(listOf("x", "ERROR: (gcloud.cloud-shell.ssh) Something new.", "")))
        assertEquals("Done.", GcloudSays.lastWords(listOf("\u001B[1mDone.\u001B[0m")))
        assertNull(GcloudSays.lastWords(listOf("", " ")))
    }

    @Test
    fun `the signed-in account and the progress come from gcloud's own lines`() {
        assertEquals("dev@example.com", GcloudSays.signedInAs(listOf("", "You are now logged in as [dev@example.com].", "Your current project is [None].")))
        assertNull(GcloudSays.signedInAs(listOf("Go to the following link in your browser")))
        assertEquals("Starting Cloud Shell (up to a minute after a break)…", GcloudSays.progress("Starting your Cloud Shell machine..."))
        assertEquals("Connecting to Cloud Shell…", GcloudSays.progress("Listening on local port [22]."))
        assertNull(GcloudSays.progress("Automatic authentication with GCP CLI tools in Cloud Shell is disabled."))
    }
}
