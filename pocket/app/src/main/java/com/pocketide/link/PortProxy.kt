package com.pocketide.link

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/** Both directions of one connection to a port in Cloud Shell. */
interface Duplex : Closeable {
    val input: InputStream
    val output: OutputStream

    /** Says the request is complete (the other side sees the end of the stream), keeping the answer open. */
    fun endOutput()
}

/**
 * PocketIDE's private door to Cloud Shell's ports, on this phone's own address (127.0.0.1) only.
 *
 * Every request names the Cloud Shell port and this app's secret key in its host,
 * `http://<port>-<key>.localhost:<proxy port>/`; one without the key gets 403, so other apps on
 * the phone, which can reach any loopback port, cannot use it. The request goes on through
 * Google's gcloud connection ([open]) as if it came from Cloud Shell itself (localhost), which
 * code-server and Antigravity's own page expect. An answer's redirects to Cloud Shell's localhost
 * come back as this proxy's addresses, and a page that allows only localhost to frame it also
 * allows the proxy's addresses (Antigravity's panel inside its VS Code).
 *
 * One request is PocketIDE's own on an agent's VS Code address: an upload to [DROP_PATH] goes to
 * Cloud Shell's file drop ([DROP_PORT], files.py) instead, so the page sends the phone's files there
 * as to itself, which its own security policy allows. Nothing else of files.py is reached that way,
 * and no other page (a dev server, say) reaches it at all: the owner's files open only from files.py's
 * own address, which no other page can read.
 */
class PortProxy(
    private val key: String,
    private val open: (Int) -> Duplex?,
) : Closeable {
    private val connections: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "PocketIDE proxy").apply { isDaemon = true }
    }

    @Volatile
    private var server: ServerSocket? = null

    /** The port it listens on, or 0 when it is not listening. */
    val port: Int get() = server?.localPort ?: 0

    /** Listens on [wanted] (0: any free port); returns the port, or 0 when it could not. */
    @Suppress("ReturnCount") // Already listening, could not listen, listening now.
    @Synchronized
    fun start(wanted: Int): Int {
        server?.let { return it.localPort }
        val socket = try {
            ServerSocket(wanted, BACKLOG, InetAddress.getByName(LOOPBACK))
        } catch (expected: IOException) {
            return 0
        }
        server = socket
        thread(name = "PocketIDE proxy accept", isDaemon = true) { accept(socket) }
        return socket.localPort
    }

    override fun close() {
        synchronized(this) {
            server?.close()
            server = null
        }
    }

    private fun accept(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (expected: SocketException) {
                return // closed
            }
            connections.execute { client.use { serve(it) } }
        }
    }

    /** One connection from the WebView: checked, then passed on both ways until either side ends. */
    @Suppress("ReturnCount") // Each refusal answers the WebView and ends there.
    internal fun serve(client: Socket) {
        client.soTimeout = HEAD_TIMEOUT_MS
        val fromClient = BufferedInputStream(client.getInputStream(), BUFFER)
        val head = readHead(fromClient) ?: return
        val parsed = Head.parse(head) ?: return reply(client, BAD_REQUEST)
        val addressed = target(parsed.header("host")) ?: return reply(client, FORBIDDEN)
        val (request, target) = Rewrite.route(parsed, addressed)
        val upstream = runCatching { open(target) }.getOrNull() ?: return reply(client, NOT_RUNNING)
        client.soTimeout = 0
        upstream.use {
            upstream.output.write(Rewrite.request(request, target))
            upstream.output.flush()
            val upload = thread(name = "PocketIDE proxy up", isDaemon = true) {
                pump(fromClient, upstream.output) { runCatching { upstream.endOutput() } }
            }
            val fromUpstream = BufferedInputStream(upstream.input, BUFFER)
            val answer = readHead(fromUpstream)
            if (answer != null) {
                val response = Head.parse(answer)
                client.getOutputStream().write(response?.let { Rewrite.response(it, key, port) } ?: answer)
                pump(fromUpstream, client.getOutputStream()) {}
            } else {
                // Nothing listens on that port in Cloud Shell (yet): say so, instead of an empty answer.
                reply(client, NOTHING_THERE)
            }
            runCatching { client.shutdownOutput() }
            upload.join(UPLOAD_GRACE_MS)
        }
    }

    /** The Cloud Shell port [host] names, when it carries this app's key; null otherwise. */
    internal fun target(host: String?): Int? {
        val match = HOST.matchEntire(host?.trim()?.lowercase(Locale.ROOT) ?: return null) ?: return null
        val port = match.groupValues[1].toIntOrNull() ?: return null
        val given = match.groupValues[2].toByteArray()
        if (!MessageDigest.isEqual(given, key.lowercase(Locale.ROOT).toByteArray())) return null
        return port.takeIf { it in LOWEST_PORT..HIGHEST_PORT }
    }

    private fun reply(client: Socket, status: String) {
        val body = status.substringAfter(' ').toByteArray()
        val answer = "HTTP/1.1 $status\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.size}\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        runCatching {
            client.getOutputStream().apply {
                write(answer.toByteArray(Charsets.ISO_8859_1))
                write(body)
                flush()
            }
        }
    }

    internal companion object {
        const val LOOPBACK = "127.0.0.1"

        /** Cloud Shell's file drop (files.py), and the path its uploads take from an agent's VS Code page. */
        const val DROP_PORT = 6081
        const val DROP_PATH = "/__pocketide/drop/"
        const val DROP_UPLOAD = "${DROP_PATH}upload"

        /** Each agent's VS Code in Cloud Shell: PocketIDE's three from 8080, the owner's own up to 8099. */
        val VS_CODE_PORTS = 8080..8099
        const val LOWEST_PORT = 1024
        const val HIGHEST_PORT = 65535
        private const val BACKLOG = 64
        private const val HEAD_TIMEOUT_MS = 30_000
        private const val UPLOAD_GRACE_MS = 2_000L
        private const val MAX_HEAD = 64 * 1024
        private const val BUFFER = 64 * 1024
        private const val FORBIDDEN = "403 Forbidden"
        private const val BAD_REQUEST = "400 Bad Request"
        private const val NOT_RUNNING = "502 Cloud Shell is not connected"
        private const val NOTHING_THERE = "502 Nothing answers on this port in Cloud Shell yet"
        private const val END_OF_HEAD = 0x0d0a0d0a
        private const val BITS_PER_BYTE = 8

        /** `<port>-<32 hex key>.localhost[:port]`. */
        private val HOST = Regex("""(\d{2,5})-([0-9a-f]{32})\.localhost(?::\d{1,5})?""")

        /** The bytes up to and including the blank line that ends an HTTP head; null when the stream ends first. */
        fun readHead(input: InputStream): ByteArray? {
            val head = ByteArrayOutputStream()
            // The last four bytes read, as one number: CR LF CR LF ends the head.
            var last = 0
            while (head.size() < MAX_HEAD) {
                val byte = try {
                    input.read()
                } catch (expected: IOException) {
                    -1
                }
                if (byte < 0) break
                head.write(byte)
                last = (last shl BITS_PER_BYTE) or byte
                if (last == END_OF_HEAD) return head.toByteArray()
            }
            return null
        }

        fun pump(from: InputStream, to: OutputStream, atEnd: () -> Unit) {
            val buffer = ByteArray(BUFFER)
            try {
                while (true) {
                    val read = from.read(buffer)
                    if (read < 0) break
                    to.write(buffer, 0, read)
                    to.flush()
                }
            } catch (expected: IOException) {
                // one side went away; the other is closed by the caller
            }
            atEnd()
        }
    }
}

/** An HTTP head: its first line and headers, in order, as sent. */
internal class Head(val first: String, val headers: List<Pair<String, String>>) {
    fun header(name: String): String? = headers.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second

    fun bytes(): ByteArray = buildString {
        append(first).append("\r\n")
        headers.forEach { (name, value) -> append(name).append(": ").append(value).append("\r\n") }
        append("\r\n")
    }.toByteArray(Charsets.ISO_8859_1)

    companion object {
        @Suppress("ReturnCount") // No first line, or a header line without a name.
        fun parse(raw: ByteArray): Head? {
            val lines = String(raw, Charsets.ISO_8859_1).split("\r\n").filter { it.isNotEmpty() }
            val first = lines.firstOrNull() ?: return null
            val headers = lines.drop(1).map { line ->
                val colon = line.indexOf(':')
                if (colon <= 0) return null
                line.substring(0, colon).trim() to line.substring(colon + 1).trim()
            }
            return Head(first, headers)
        }
    }
}

/** How a request and its answer change on the way through [PortProxy]. */
internal object Rewrite {
    /**
     * Where a request to Cloud Shell's [port] goes: an upload an agent's VS Code page sends to
     * [PortProxy.DROP_UPLOAD] goes to the file drop, without the prefix; any other stays as it is.
     */
    fun route(head: Head, port: Int): Pair<Head, Int> {
        val parts = head.first.split(' ')
        val target = parts.getOrNull(1).orEmpty()
        val dropped = parts.size == REQUEST_LINE_PARTS && parts[0] == "POST" && port in PortProxy.VS_CODE_PORTS &&
            (target == PortProxy.DROP_UPLOAD || target.startsWith("${PortProxy.DROP_UPLOAD}?"))
        if (!dropped) return head to port
        val rest = "/" + parts[1].removePrefix(PortProxy.DROP_PATH)
        return Head("${parts[0]} $rest ${parts[2]}", head.headers) to PortProxy.DROP_PORT
    }

    private val HOP_BY_HOP = setOf("connection", "keep-alive", "proxy-connection", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "forwarded")

    /** A page at one of the door's addresses (http://<port>-<key>.localhost:<door's port>), at the start of an address. */
    private val DOOR_PAGE = Regex("""^https?://(\d{2,5})-[0-9a-f]{32}\.localhost(?::\d+)?(?=/|$)""", RegexOption.IGNORE_CASE)
    private const val REQUEST_LINE_PARTS = 3
    private const val FRAME_ANCESTORS = "frame-ancestors"
    private const val PROXY_ANCESTORS = "http://*.localhost:*"

    /** As if from Cloud Shell's own localhost; one request for each connection, unless it upgrades to a WebSocket. */
    fun request(head: Head, port: Int): ByteArray {
        val local = "localhost:$port"
        val upgrade = head.header("connection")?.contains("upgrade", ignoreCase = true) == true &&
            head.header("upgrade") != null
        val headers = head.headers.mapNotNull { (name, value) ->
            when (name.lowercase(Locale.ROOT)) {
                "host" -> name to local
                "origin" -> name to sender(value.trim(), port)
                "referer" -> name to sender(value, port)
                in HOP_BY_HOP -> null
                else -> name to value
            }
        } + ("Connection" to if (upgrade) "Upgrade" else "close")
        return Head(head.first, headers).bytes()
    }

    /**
     * Who [value] (an Origin, or the start of a Referer) says sent a request to Cloud Shell's [port]: a
     * page at one of the door's addresses comes from its own port's localhost, as on a computer, so
     * each server's own origin checks hold (code-server lets only its own page open its connection; a
     * dev server's page is not VS Code). An agent's VS Code page, the owner's IDE, uses the other ports
     * as its own (Antigravity's panel). Any other origin stays as it was ("null" for a page in a
     * sandbox, a site): the key is in none of them, and it never goes on.
     */
    fun sender(value: String, port: Int): String {
        val door = DOOR_PAGE.find(value) ?: return value
        val from = door.groupValues[1].toIntOrNull()
        val seen = if (from == null || from in PortProxy.VS_CODE_PORTS) port else from
        return "http://localhost:$seen" + value.substring(door.range.last + 1)
    }

    /**
     * The answer as the WebView should see it: a redirect to Cloud Shell's localhost goes to the
     * proxy's address for that port, and a page that lets only localhost frame it also lets the
     * proxy's addresses (they are this phone's loopback too).
     */
    fun response(head: Head, key: String, proxyPort: Int): ByteArray {
        val headers = head.headers.map { (name, value) ->
            when (name.lowercase(Locale.ROOT)) {
                "location" -> name to location(value, key, proxyPort)
                "content-security-policy" -> name to framing(value)
                else -> name to value
            }
        }
        return Head(head.first, headers).bytes()
    }

    fun location(value: String, key: String, proxyPort: Int): String {
        val match = Regex("""^https?://(?:localhost|127\.0\.0\.1):(\d{1,5})(/.*)?$""", RegexOption.IGNORE_CASE).matchEntire(value)
            ?: return value
        return "http://${match.groupValues[1]}-$key.localhost:$proxyPort${match.groupValues[2].ifEmpty { "/" }}"
    }

    fun framing(policy: String): String = policy.split(';').joinToString(";") { part ->
        val trimmed = part.trim()
        if (trimmed.startsWith(FRAME_ANCESTORS, ignoreCase = true) && PROXY_ANCESTORS !in trimmed) {
            part.replaceFirst(Regex("(?i)$FRAME_ANCESTORS"), "$FRAME_ANCESTORS $PROXY_ANCESTORS")
        } else {
            part
        }
    }
}
