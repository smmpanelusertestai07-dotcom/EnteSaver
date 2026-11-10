package com.pocketide.downloads

import android.app.DownloadManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Base64
import androidx.core.app.NotificationCompat
import com.pocketide.R
import com.pocketide.core.Channels
import com.pocketide.core.Http
import com.pocketide.core.NotificationIds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.Call
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Proxy
import java.net.URLDecoder
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger

/** A file on its way from Cloud Shell to the phone's Downloads (Download/PocketIDE), or there. */
data class Download(
    val id: Int,
    /** Where it comes from (PocketIDE's door to Cloud Shell, or a data: address). */
    val url: String,
    val name: String,
    val mime: String,
    /** Its size in bytes; -1 until Cloud Shell says. */
    val total: Long,
    val received: Long = 0,
    val state: State = State.RUNNING,
    /** Where Android keeps it, once it is all here. */
    val saved: Uri? = null,
    val why: String? = null,
) {
    enum class State { RUNNING, DONE, FAILED, CANCELLED }

    val isApk: Boolean get() = FileKinds.isApk(name, mime)

    /** Fetched from Cloud Shell, so it can be fetched again (one a page held is gone with the page). */
    val canRetry: Boolean get() = url.startsWith("http")
}

/**
 * A file a page keeps in its own memory for PocketIDE: VS Code's Download of a file under 32 MB,
 * which reaches the WebView only as a blob: address. Its pieces are asked for on the main thread.
 */
interface HeldFile {
    val name: String
    val mime: String
    val size: Long

    /** Piece [index] in base64: "" while the page still reads it, null after the last. */
    fun piece(index: Int, answer: (String?) -> Unit)

    /** PocketIDE has it all, or stopped: the page may forget it (from any thread). */
    fun letGo()
}

/**
 * Files from Cloud Shell, saved on the phone: a link an agent gave (files.py's Download), a file a
 * page in PocketIDE offers, VS Code's own Download. The WebView cannot fetch them for Android (Cloud
 * Shell is reached only through PocketIDE's door, on this phone's loopback), so PocketIDE fetches
 * each through its door itself and writes it into Android's Downloads with MediaStore, which needs
 * no storage permission. PocketIDE installs nothing: an APK is installed from the phone's Files app,
 * whose installer asks the owner first. While one downloads, its notice shows how far it is.
 */
class Downloads(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())
    private val state = MutableStateFlow<List<Download>>(emptyList())
    private val calls = ConcurrentHashMap<Int, Call>()
    private val cancelled = ConcurrentHashMap.newKeySet<Int>()
    private val ids = AtomicInteger()

    /** Every download since the app started, newest last. */
    val items: StateFlow<List<Download>> = state

    /**
     * Through PocketIDE's door only: its addresses (<port>-<key>.localhost) are this phone's loopback,
     * and nothing else is fetched, not even where a page in Cloud Shell redirects.
     */
    private val client: OkHttpClient by lazy {
        Http.downloads.newBuilder()
            .proxy(Proxy.NO_PROXY)
            .dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    if (hostname.endsWith(DOOR_HOSTS)) listOf(InetAddress.getByName(LOOPBACK)) else Dns.SYSTEM.lookup(hostname)
            })
            .addNetworkInterceptor { chain ->
                if (!chain.request().url.host.endsWith(DOOR_HOSTS)) throw IOException("Only Cloud Shell's files, through PocketIDE's door")
                chain.proceed(chain.request())
            }
            .build()
    }

    /** Starts saving [offer]; returns its id. */
    fun start(offer: FileOffer): Int {
        val id = ids.incrementAndGet()
        state.update { it + Download(id, offer.url, offer.name, offer.mime, offer.size) }
        launch(id) { fetch(id, offer) }
        return id
    }

    /** A file a page made in its own memory (a data: address): saved as it is. */
    fun startData(url: String, name: String?): Int? {
        val (mime, bytes) = dataUrl(url) ?: return null
        val fileName = FileKinds.plainName(name, mime)
        val arrival = Arrival(fileName, FileKinds.mime(fileName, mime), bytes.size.toLong())
        val id = ids.incrementAndGet()
        state.update { it + Download(id, "data:", arrival.name, arrival.mime, arrival.total) }
        launch(id) { save(id, ByteArrayInputStream(bytes), arrival) }
        return id
    }

    /** A file a page holds ([HeldFile]), read from the page as it is saved; returns its id. */
    fun startHeld(file: HeldFile): Int {
        val id = ids.incrementAndGet()
        state.update { it + Download(id, "blob:", file.name, file.mime, file.size) }
        launch(id, after = file::letGo) {
            save(id, HeldStream(file, { main.post(it) }, { id in cancelled }), Arrival(file.name, file.mime, file.size))
        }
        return id
    }

    /** Runs download [id]'s [work] off the main thread: whatever stops it ends that download, never the app. */
    private fun launch(id: Int, after: () -> Unit = {}, work: () -> Unit) {
        scope.launch {
            runCatching(work).onFailure { error ->
                when {
                    id in cancelled -> stopped(id)
                    error is PageGone -> failed(id, PAGE_GONE)
                    error is IOException && error !is NotWritten -> failed(id, STOPPED)
                    else -> failed(id, NOT_SAVED)
                }
            }
            calls.remove(id)
            after()
        }
    }

    /** A data: address's type and bytes; null for anything else, or one too big to hold. */
    private fun dataUrl(url: String): Pair<String, ByteArray>? {
        val comma = url.indexOf(',')
        if (!url.startsWith("data:") || comma < 0 || url.length > MAX_DATA_URL) return null
        val head = url.substring("data:".length, comma)
        val body = url.substring(comma + 1)
        val bytes = runCatching {
            if (head.endsWith(";base64")) Base64.decode(body, Base64.DEFAULT) else URLDecoder.decode(body.replace("+", "%2B"), "UTF-8").toByteArray()
        }.getOrNull()
        return bytes?.let { head.substringBefore(';').ifBlank { "text/plain" } to it }
    }

    /** Fetches a download that failed once more, as it was asked for. */
    fun retry(download: Download): Int? {
        if (!download.url.startsWith("http")) return null
        dismiss(download.id)
        return start(FileOffer(download.url, download.name, download.mime, download.total, decided = true))
    }

    fun cancel(id: Int) {
        cancelled += id
        calls[id]?.cancel()
    }

    /** Forgets a finished download here (the file stays in Downloads). */
    fun dismiss(id: Int) {
        state.update { list -> list.filterNot { it.id == id && it.state != Download.State.RUNNING } }
    }

    private fun fetch(id: Int, offer: FileOffer) {
        val call = client.newCall(Request.Builder().url(offer.url).header("Accept-Encoding", "identity").build())
        calls[id] = call
        if (id in cancelled) call.cancel()
        call.execute().use { answer ->
            if (answer.isSuccessful) {
                val arrival = arrival(offer, answer.header("Content-Disposition"), answer.header("Content-Type"), answer.body.contentLength())
                save(id, answer.body.byteStream(), arrival)
            } else {
                failed(id, whyNot(answer.code))
            }
        }
    }

    /** What arrives: Cloud Shell's own name for it (unless it knows none and the page did), its type and size. */
    private fun arrival(offer: FileOffer, disposition: String?, type: String?, length: Long): Arrival {
        val named = FileKinds.name(disposition, offer.url, type)
        val name = if (named.startsWith("download") && !offer.name.startsWith("download")) offer.name else named
        return Arrival(name, FileKinds.mime(name, type ?: offer.mime), length.takeIf { it >= 0 } ?: offer.size)
    }

    /** Writes [input] into Downloads as it arrives; removes the part when it does not all arrive. */
    private fun save(id: Int, input: InputStream, arrival: Arrival) {
        update(id) { it.copy(name = arrival.name, mime = arrival.mime, total = arrival.total) }
        val resolver = context.contentResolver
        val uri = runCatching { resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, pending(arrival)) }.getOrNull()
        if (uri == null) {
            failed(id, NOT_SAVED)
            return
        }
        var received = -1L
        try {
            val got = copy(id, input, uri)
            if (arrival.total >= 0 && got < arrival.total) throw IOException("It stopped before the end")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            received = got
        } finally {
            // Not all here, or Android did not take it: no part of a file stays in Downloads.
            if (received < 0) runCatching { resolver.delete(uri, null, null) }
        }
        update(id) { it.copy(state = Download.State.DONE, received = received, total = received, saved = uri) }
        notice(id)
    }

    /** A new, still hidden file in Download/PocketIDE. */
    private fun pending(arrival: Arrival) = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, arrival.name)
        put(MediaStore.MediaColumns.MIME_TYPE, arrival.mime)
        put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }

    /** Copies [input] into [uri], showing how far it is now and then; returns how many bytes came. */
    private fun copy(id: Int, input: InputStream, uri: Uri): Long {
        val out = runCatching { context.contentResolver.openOutputStream(uri) }.getOrNull() ?: throw NotWritten()
        var shownAt = 0L
        val shown = { got: Long ->
            val now = System.currentTimeMillis()
            if (now - shownAt >= PROGRESS_MS) {
                shownAt = now
                update(id) { it.copy(received = got) }
                notice(id)
            }
        }
        return out.use { input.use { it.copyCounting(out, shown) } }
    }

    private fun failed(id: Int, why: String) {
        update(id) { it.copy(state = Download.State.FAILED, why = why) }
        notice(id)
    }

    private fun stopped(id: Int) {
        update(id) { it.copy(state = Download.State.CANCELLED) }
        notices()?.cancel(NotificationIds.DOWNLOADS + id)
    }

    private fun update(id: Int, change: (Download) -> Download) {
        state.update { list -> list.map { if (it.id == id) change(it) else it } }
    }

    private fun whyNot(code: Int): String = when (code) {
        NOT_FOUND -> "It is not in Cloud Shell any more: it was moved, renamed or deleted."
        BAD_GATEWAY -> "Cloud Shell is not connected, or nothing answers there now. Connect, then try again."
        else -> "Cloud Shell answered $code: it did not send the file."
    }

    // ---- What opens it ----

    /**
     * Opens it with an app on the phone. An APK opens in the phone's Files app instead, in
     * Download/PocketIDE: a tap on it there installs it (Android asks first), with no permission of
     * PocketIDE's own.
     */
    fun open(from: Context, download: Download): Boolean {
        val uri = download.saved ?: return false
        val tries = if (download.isApk) listOf(folderIntent(), downloadsIntent()) else listOf(viewIntent(uri, download.mime))
        return tries.any { intent -> runCatching { from.startActivity(intent) }.isSuccess }
    }

    /** Android's share sheet, to send it to another app. */
    fun share(from: Context, download: Download) {
        val uri = download.saved ?: return
        val send = Intent(Intent.ACTION_SEND).setType(download.mime).putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runCatching { from.startActivity(Intent.createChooser(send, download.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    private fun viewIntent(uri: Uri, mime: String) = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)

    /** The phone's Files app, in Download/PocketIDE. */
    private fun folderIntent() = Intent(Intent.ACTION_VIEW)
        .setDataAndType(
            DocumentsContract.buildDocumentUri(STORAGE_DOCUMENTS, "primary:${Environment.DIRECTORY_DOWNLOADS}/$FOLDER"),
            DocumentsContract.Document.MIME_TYPE_DIR,
        )
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** The phone's own downloads (Files, or the maker's Downloads app), where Download/PocketIDE is. */
    private fun downloadsIntent() = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    // ---- Its notice ----

    private fun notices(): NotificationManager? = context.getSystemService(NotificationManager::class.java)

    private fun notice(id: Int) {
        val download = state.value.firstOrNull { it.id == id } ?: return
        val manager = notices()?.takeIf { it.areNotificationsEnabled() } ?: return
        val builder = NotificationCompat.Builder(context, Channels.DOWNLOADS)
            .setContentTitle(download.name)
            .setOnlyAlertOnce(true)
        when (download.state) {
            Download.State.RUNNING -> {
                val total = download.total.takeIf { it > 0 }
                builder.setSmallIcon(android.R.drawable.stat_sys_download)
                    .setOngoing(true)
                    .setContentText(
                        FileKinds.sizeText(download.received) + (total?.let { " of ${FileKinds.sizeText(it)}" } ?: ""),
                    )
                    .setProgress(PERCENT, total?.let { (download.received * PERCENT / it).toInt() } ?: 0, total == null)
            }
            Download.State.DONE -> {
                val uri = download.saved ?: return
                val opens = PendingIntent.getActivity(
                    context,
                    id,
                    if (download.isApk) downloadsIntent() else viewIntent(uri, download.mime),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentText(if (download.isApk) context.getString(R.string.download_done_apk) else context.getString(R.string.download_done))
                    .setContentIntent(opens)
                    .setAutoCancel(true)
            }
            Download.State.FAILED -> builder.setSmallIcon(android.R.drawable.stat_notify_error).setContentText(download.why).setAutoCancel(true)
            Download.State.CANCELLED -> return manager.cancel(NotificationIds.DOWNLOADS + id)
        }
        runCatching { manager.notify(NotificationIds.DOWNLOADS + id, builder.build()) }
    }

    companion object {
        /** Download/PocketIDE, in the phone's own Downloads. */
        const val FOLDER = "PocketIDE"
        private const val LOOPBACK = "127.0.0.1"
        private const val DOOR_HOSTS = ".localhost"
        private const val STORAGE_DOCUMENTS = "com.android.externalstorage.documents"
        private const val NOT_SAVED = "Android did not let PocketIDE save it in Downloads. Is the phone's storage full?"
        private const val STOPPED = "The download stopped: Cloud Shell or the network went away. Try again."
        private const val PAGE_GONE = "VS Code's page closed before the file was all here. Download it again in VS Code."
        private const val PROGRESS_MS = 250L
        private const val PERCENT = 100
        private const val NOT_FOUND = 404
        private const val BAD_GATEWAY = 502
        private const val MAX_DATA_URL = 32 * 1024 * 1024
    }
}

/** What arrives: its name, type and size as Cloud Shell said them. */
private data class Arrival(val name: String, val mime: String, val total: Long)

/** Copies everything to [out], saying how much has come after each piece; returns the total. */
private fun InputStream.copyCounting(out: OutputStream, progress: (Long) -> Unit): Long {
    val buffer = ByteArray(COPY_BUFFER)
    var total = 0L
    var read = read(buffer)
    while (read >= 0) {
        try {
            out.write(buffer, 0, read)
        } catch (error: IOException) {
            throw NotWritten(error)
        }
        total += read
        progress(total)
        read = read(buffer)
    }
    return total
}

/** Downloads did not take it: the phone's storage is full, or Android said no. */
private class NotWritten(cause: Throwable? = null) : IOException(cause)

/** The page that held the file went away (or stopped answering) before PocketIDE had it all. */
internal class PageGone : IOException()

/**
 * A [HeldFile]'s bytes in order, for [Downloads] to save: each piece is asked of the page through
 * [onMain] (a WebView answers on the main thread) and waited for here, on the download's own thread.
 * [waitMs]: how long the page has to give each piece.
 */
internal class HeldStream(
    private val file: HeldFile,
    private val onMain: (Runnable) -> Unit,
    private val cancelled: () -> Boolean,
    private val waitMs: Long = PIECE_WAIT_MS,
) : InputStream() {
    private var next = 0
    private var piece = ByteArray(0)
    private var at = 0
    private var ended = false

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and BYTE_MASK
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (cancelled()) throw IOException("Cancelled")
        while (at == piece.size && !ended) fill()
        if (at == piece.size) return -1
        val count = minOf(length, piece.size - at)
        System.arraycopy(piece, at, buffer, offset, count)
        at += count
        return count
    }

    /** The next piece, or the end of the file. */
    private fun fill() {
        val until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(waitMs)
        var answer = ask()
        while (answer == "" && System.nanoTime() < until && !cancelled()) {
            Thread.sleep(POLL_MS)
            answer = ask()
        }
        when (answer) {
            null -> ended = true
            "" -> throw PageGone()
            else -> {
                piece = runCatching { java.util.Base64.getDecoder().decode(answer) }.getOrNull() ?: throw PageGone()
                at = 0
                next++
            }
        }
    }

    /** Piece [next] as the page answers it; [PageGone] when it does not answer at all. */
    private fun ask(): String? {
        val answer = CompletableFuture<String?>()
        onMain(Runnable { file.piece(next) { answer.complete(it) } })
        return try {
            answer.get(waitMs, TimeUnit.MILLISECONDS)
        } catch (expected: TimeoutException) {
            throw PageGone()
        }
    }

    private companion object {
        const val PIECE_WAIT_MS = 30_000L
        const val POLL_MS = 20L
        const val BYTE_MASK = 0xff
    }
}

private const val COPY_BUFFER = 64 * 1024
