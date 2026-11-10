package com.pocketide.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Test

class OpeningTest {
    private val key = "0123456789abcdef0123456789abcdef"

    /** The door as Link names it: http://<port>-<key>.localhost:4000/… */
    private val door: (String) -> Int? = { url ->
        Regex("""^http://(\d+)-$key\.localhost:4000(?:[/?#].*)?$""").matchEntire(url)?.groupValues?.get(1)?.toInt()
    }

    @Test
    fun `Cloud Shell's localhost opens in the page viewer`() {
        assertEquals(Opening.CloudShellPage(3000, "/"), Opening.of("http://localhost:3000", door))
        assertEquals(Opening.CloudShellPage(5173, "/app?x=1#top"), Opening.of("http://127.0.0.1:5173/app?x=1#top", door))
        assertEquals(Opening.CloudShellPage(8080, "/?folder=/p"), Opening.of("http://8080-$key.localhost:4000/?folder=/p", door))
        assertEquals("a system port is not an agent's", Opening.Nowhere, Opening.of("http://localhost:80/", door))
    }

    @Test
    fun `a sign-in page opens in Chrome, with the port its return comes to`() {
        val codex = "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=s"
        assertEquals(Opening.SignIn(codex, 1455), Opening.of(codex, door))
        val google = "https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A40111%2Fauth%2Fcallback"
        assertEquals(Opening.SignIn(google, 40111), Opening.of(google, door))
    }

    @Test
    fun `other web pages go to Chrome, and nothing else opens`() {
        assertEquals(Opening.Web("https://docs.anthropic.com/x"), Opening.of("https://docs.anthropic.com/x", door))
        listOf("http://example.com/", "intent://x#Intent;end", "javascript:alert(1)", "file:///etc/passwd", "vscode://x", "not a url")
            .forEach { assertEquals(it, Opening.Nowhere, Opening.of(it, door)) }
    }
}
