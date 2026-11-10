package com.pocketide.cloudshell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

class SignInCatcherTest {
    @Test
    @Suppress("NestedBlockDepth") // The agent in Cloud Shell, the phone's port and the browser, each open at once.
    fun `connected, the return goes on unchanged to the agent waiting in Cloud Shell`() {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { agent ->
            val seen = java.util.concurrent.atomic.AtomicReference<String>()
            val agentThread = kotlin.concurrent.thread(isDaemon = true) {
                agent.accept().use { socket ->
                    seen.set(String(com.pocketide.link.PortProxy.readHead(socket.getInputStream())!!, Charsets.ISO_8859_1))
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nsigned in".toByteArray())
                }
            }
            val relay = { _: Int ->
                val upstream = Socket("127.0.0.1", agent.localPort)
                object : com.pocketide.link.Duplex {
                    override val input = upstream.getInputStream()
                    override val output = upstream.getOutputStream()
                    override fun endOutput() = upstream.shutdownOutput()
                    override fun close() = upstream.close()
                } as com.pocketide.link.Duplex?
            }
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { phone ->
                Socket("127.0.0.1", phone.localPort).use { browser ->
                    browser.getOutputStream().write("GET /auth/callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost:1455\r\n\r\n".toByteArray())
                    phone.accept().use { SignInCatcher.relayOne(it, 1455, relay) }
                    val answer = browser.getInputStream().bufferedReader().readText()
                    assertTrue(answer, answer.endsWith("signed in"))
                }
            }
            agentThread.join(5_000)
            assertTrue(seen.get(), seen.get().startsWith("GET /auth/callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost:1455\r\n"))
        }
    }

    @Test
    fun `nothing is caught outside 1024 to 65535`() {
        // catchOn returns at once for these: no socket, no thread.
        listOf(80, 1023, 70000).forEach { port -> SignInCatcher.catchOn(port) { null } }
        assertFalse(SignInReturn.isAgentPort(80))
        assertTrue(SignInReturn.isAgentPort(8090))
    }
}
