package com.pocketide.ui.web

import com.pocketide.agents.Agent
import com.pocketide.cloudshell.CloudShell
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebPolicyTest {
    @Test
    fun `Google's own Cloud Shell page and every company's page open in the browser`() {
        listOf(CloudShell.googlePage("dev@example.com"), CloudShell.SCRIPT_URL).forEach {
            assertTrue(it, WebPolicy.isWebLink(it))
        }
        Agent.entries.flatMap { listOf(it.privacyUrl, it.termsUrl, it.docsUrl, it.openVsxUrl) }.forEach {
            assertTrue(it, WebPolicy.isWebLink(it))
        }
    }

    @Test
    fun `anything that is not https to a named host goes nowhere`() {
        listOf(
            "http://github.com/login",
            "http://localhost:1455/auth/callback?code=x",
            "http://127.0.0.1:8080/",
            "https:///no-host",
            "intent://scan/#Intent;scheme=zxing;end",
            "javascript:alert(1)",
            "file:///data/data/com.pocketide/shared_prefs",
            "code-oss://google.google-antigravity/auth",
            "not a url",
            "",
        ).forEach { assertFalse(it, WebPolicy.isWebLink(it)) }
    }

    @Test
    fun `the host a note names is the one the address goes to`() {
        assertEquals("shell.cloud.google.com", WebPolicy.hostOf("https://Shell.Cloud.Google.com/?show=terminal"))
        assertNull(WebPolicy.hostOf("not a url"))
    }
}
