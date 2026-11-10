package com.pocketide.linux

import com.pocketide.core.await
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

/** A download that is not the pinned file. The bad copy is already deleted. */
internal class ChecksumMismatch(val fileName: String) : IOException("$fileName did not match its published checksum")

/** A download that could not finish, said plainly. What arrived is kept and continued next time. */
internal class DownloadFailed(message: String, val worthRetrying: Boolean = true) : IOException(message)

/** Fetches a pinned file into place (production: [Downloader]). */
internal fun interface Fetcher {
    suspend fun fetch(pin: PinnedDownload, target: File, onProgress: (Long) -> Unit): File
}

/**
 * Resumable, verified downloads. A partial file is continued with an HTTP Range request, so a
 * dropped signal does not start 225 MB over; the result is kept only when its size and SHA-256
 * match the pin, and a file already in place is checked again before it is trusted.
 */
internal class Downloader(
    private val client: OkHttpClient,
    private val retryDelaysMs: List<Long> = listOf(2_000, 5_000, 15_000),
) : Fetcher {

    override suspend fun fetch(pin: PinnedDownload, target: File, onProgress: (Long) -> Unit): File =
        withContext(Dispatchers.IO) {
            if (matches(target, pin)) {
                onProgress(pin.bytes)
                return@withContext target
            }
            Files.deleteIfExists(target.toPath())
            target.parentFile?.let { Files.createDirectories(it.toPath()) }
            val part = File(target.parentFile, target.name + PART)
            var attempt = 0
            while (true) {
                try {
                    transfer(pin, part, onProgress)
                    break
                } catch (failure: IOException) {
                    if (!retryable(failure) || attempt >= retryDelaysMs.size) throw plain(failure, pin)
                    delay(retryDelaysMs[attempt++])
                }
            }
            if (sha256(part) != pin.sha256) {
                Files.deleteIfExists(part.toPath())
                throw ChecksumMismatch(pin.fileName)
            }
            Files.move(part.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            target
        }

    private suspend fun transfer(pin: PinnedDownload, part: File, onProgress: (Long) -> Unit) {
        var have = if (part.isFile) part.length() else 0L
        if (have > pin.bytes) {
            Files.delete(part.toPath())
            have = 0
        }
        if (have == pin.bytes) return
        val request = Request.Builder().url(pin.url)
            .apply { if (have > 0) header("Range", "bytes=$have-") }
            .build()
        client.newCall(request).await().use { response ->
            if (response.code == 416) {
                // The server's file is shorter than what is already here: start again.
                Files.delete(part.toPath())
                throw DownloadFailed("The server could not continue the download")
            }
            val append = resumes(response, have)
            if (!append) have = 0
            receive(response, pin, part, append, have, onProgress)
        }
        if (part.length() < pin.bytes) throw DownloadFailed("The download stopped early")
    }

    /** True when the server continues at [have]; false when it sends the whole file again. */
    private fun resumes(response: Response, have: Long): Boolean = when (response.code) {
        206 -> {
            val start = response.header("Content-Range")
                ?.removePrefix("bytes ")?.substringBefore('-')?.trim()?.toLongOrNull()
            if (start != have) throw DownloadFailed("The server continued the download at the wrong place")
            true
        }
        200 -> false
        // A missing file or a refusal does not change a few seconds later; a busy server may.
        else -> throw DownloadFailed(
            "The download server answered ${response.code}",
            worthRetrying = response.code >= 500 || response.code == 408 || response.code == 429,
        )
    }

    private suspend fun receive(
        response: Response,
        pin: PinnedDownload,
        part: File,
        append: Boolean,
        start: Long,
        onProgress: (Long) -> Unit,
    ) {
        var done = start
        var reported = 0L
        FileOutputStream(part, append).use { output ->
            response.body.byteStream().use { input ->
                val buffer = ByteArray(BUFFER)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (done + read > pin.bytes) {
                        output.close()
                        Files.deleteIfExists(part.toPath())
                        throw ChecksumMismatch(pin.fileName)
                    }
                    output.write(buffer, 0, read)
                    done += read
                    if (done - reported >= REPORT_BYTES || done == pin.bytes) {
                        reported = done
                        onProgress(done)
                    }
                }
            }
        }
    }

    private fun retryable(failure: IOException) =
        failure !is ChecksumMismatch && failure !is FileSystemException && !outOfSpace(failure) &&
            (failure as? DownloadFailed)?.worthRetrying != false

    /** Network failures in the owner's words; disk and checksum failures keep their own type. */
    private fun plain(failure: IOException, pin: PinnedDownload): IOException = when {
        !retryable(failure) || failure is DownloadFailed -> failure
        failure is UnknownHostException -> DownloadFailed("The phone could not reach ${pin.url.toHttpUrl().host}")
        failure is SocketTimeoutException -> DownloadFailed("The connection timed out")
        else -> DownloadFailed("The connection dropped")
    }

    private fun matches(file: File, pin: PinnedDownload) =
        file.isFile && file.length() == pin.bytes && sha256(file) == pin.sha256

    companion object {
        private const val PART = ".part"
        private const val BUFFER = 64 * 1024
        private const val REPORT_BYTES = 512L * 1024

        fun outOfSpace(failure: Exception): Boolean =
            failure.message.orEmpty().let { it.contains("No space left") || it.contains("ENOSPC") }

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return hex(digest.digest())
        }

        fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

        /** The files a download of [pin] may leave in [directory]. */
        fun filesFor(pin: PinnedDownload, directory: File) =
            listOf(File(directory, pin.fileName), File(directory, pin.fileName + PART))

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }
}
