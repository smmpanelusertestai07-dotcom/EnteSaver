package app.entesaver.media

import android.content.Context
import android.net.Uri
import app.entesaver.core.logic.OptimisedMark
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Reads a file for the note an optimised file carries ([OptimisedMark]).
 *
 * A file up to [WHOLE_FILE_BYTES] is read whole: a photo's note may sit
 * behind large metadata blocks, past any fixed head. A larger one is read at
 * its head and tail and, as an MP4, box by box to its index - which a long
 * clip has after its video, far from both ends.
 */
internal object MarkReader {

    private const val WHOLE_FILE_BYTES = 16L * 1024 * 1024

    /** The largest MP4 index read whole for the note; a longer one is not looked into. */
    private const val MAX_MOOV_BYTES = 16L * 1024 * 1024

    /** Top-level boxes walked before giving up on finding the index. */
    private const val MAX_BOXES = 64

    fun isMarked(context: Context, uri: Uri, size: Long): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            FileInputStream(pfd.fileDescriptor).channel.use { channel ->
                val length = if (size > 0) size else channel.size()
                if (length <= WHOLE_FILE_BYTES) {
                    OptimisedMark.isMarked(read(channel, 0, length.toInt()))
                } else {
                    val head = read(channel, 0, OptimisedMark.HEAD_BYTES)
                    val tail = read(channel, length - OptimisedMark.TAIL_BYTES, OptimisedMark.TAIL_BYTES)
                    OptimisedMark.isMarked(head, tail) || indexMarked(channel, head, length)
                }
            }
        } ?: false
    } catch (e: Exception) {
        false
    }

    /** Whether the MP4 index ('moov'), wherever it sits, carries the note. */
    private fun indexMarked(channel: FileChannel, head: ByteArray, length: Long): Boolean {
        if (head.size < 8 || String(head, 4, 4, Charsets.US_ASCII) != "ftyp") return false
        var at = 0L
        repeat(MAX_BOXES) {
            if (at + 8 > length) return false
            val header = read(channel, at, 16)
            if (header.size < 8) return false
            var size = beInt(header, 0).toLong() and 0xFFFFFFFFL
            if (size == 1L) {
                if (header.size < 16) return false
                size = (beInt(header, 8).toLong() shl 32) or (beInt(header, 12).toLong() and 0xFFFFFFFFL)
            } else if (size == 0L) {
                size = length - at
            }
            if (size < 8) return false
            if (String(header, 4, 4, Charsets.US_ASCII) == "moov") {
                return size <= MAX_MOOV_BYTES && OptimisedMark.isMarked(read(channel, at, size.toInt()))
            }
            at += size
        }
        return false
    }

    private fun beInt(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xFF) shl 24) or ((b[at + 1].toInt() and 0xFF) shl 16) or
            ((b[at + 2].toInt() and 0xFF) shl 8) or (b[at + 3].toInt() and 0xFF)

    private fun read(channel: FileChannel, at: Long, n: Int): ByteArray {
        val buffer = ByteBuffer.allocate(n)
        var pos = at
        while (buffer.hasRemaining()) {
            val r = channel.read(buffer, pos)
            if (r <= 0) break
            pos += r
        }
        return buffer.array().copyOf(buffer.position())
    }
}
