package com.pocketide.cloudshell

import com.pocketide.link.Duplex
import com.pocketide.link.PortProxy
import java.io.BufferedInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Catches a sign-in page's return on this phone. An agent in Cloud Shell that signs in with a
 * browser has the page return to http://localhost:PORT/..., which on a phone is the phone itself.
 * While PocketIDE listens on that port (only on this phone's own address, only for a few minutes),
 * each request goes on, unchanged, through PocketIDE's connection to the agent waiting on the same
 * port in Cloud Shell, and its answer comes back: the agent is signed in as on a computer. When
 * PocketIDE is not listening (Android closed it, or another app has the port), the page says
 * "localhost refused to connect". Nothing it passes on is kept or logged.
 */
object SignInCatcher {
    private const val WAIT_MS = 10 * 60 * 1000
    private const val READ_MS = 5_000

    /** How long the port stays open after the return went through, for the page the agent shows next. */
    private const val AFTER_RETURN_MS = 60_000L
    private val listening = ConcurrentHashMap.newKeySet<Int>()

    /** Listens on [port] for a sign-in's return, for [WAIT_MS]; [relay] connects to Cloud Shell's same port. */
    fun catchOn(port: Int, relay: (Int) -> Duplex?) {
        if (!SignInReturn.isAgentPort(port) || !listening.add(port)) return
        val server = runCatching { ServerSocket(port, BACKLOG, InetAddress.getByName(PortProxy.LOOPBACK)) }.getOrNull()
        if (server == null) {
            listening.remove(port) // another app has it: the page says "refused"; starting the sign-in again tries anew
            return
        }
        thread(name = "PocketIDE sign-in $port", isDaemon = true) {
            server.use { relayAll(it, port, relay) }
            listening.remove(port)
        }
    }

    /** Every request to the port goes on to Cloud Shell until [AFTER_RETURN_MS] after the first one, or [WAIT_MS]. */
    private fun relayAll(server: ServerSocket, port: Int, relay: (Int) -> Duplex?) {
        val until = System.currentTimeMillis() + WAIT_MS
        var closeAt = until
        while (System.currentTimeMillis() < closeAt) {
            server.soTimeout = (closeAt - System.currentTimeMillis()).coerceAtLeast(1).toInt()
            val client = runCatching { server.accept() }.getOrNull() ?: break
            if (closeAt == until) closeAt = minOf(until, System.currentTimeMillis() + AFTER_RETURN_MS)
            thread(name = "PocketIDE sign-in $port relay", isDaemon = true) { client.use { relayOne(it, port, relay) } }
        }
    }

    /** One request and its answer, both ways, unchanged. */
    internal fun relayOne(client: Socket, port: Int, relay: (Int) -> Duplex?) {
        client.soTimeout = READ_MS
        val fromClient = BufferedInputStream(client.getInputStream())
        val head = PortProxy.readHead(fromClient) ?: return
        val upstream = relay(port) ?: return replyNotConnected(client)
        client.soTimeout = 0
        upstream.use {
            it.output.write(head)
            it.output.flush()
            val upload = thread(name = "PocketIDE sign-in up", isDaemon = true) {
                PortProxy.pump(fromClient, it.output) { runCatching { it.endOutput() } }
            }
            PortProxy.pump(it.input, client.getOutputStream()) {}
            runCatching { client.shutdownOutput() }
            upload.join(UPLOAD_GRACE_MS)
        }
    }

    private fun replyNotConnected(client: Socket) {
        val body = "PocketIDE is not connected to Cloud Shell. Open the agent in PocketIDE and sign in again.".toByteArray()
        val head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.size}\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        runCatching {
            client.getOutputStream().apply {
                write(head.toByteArray(Charsets.ISO_8859_1))
                write(body)
                flush()
            }
        }
    }

    private const val BACKLOG = 8
    private const val UPLOAD_GRACE_MS = 2_000L
}
