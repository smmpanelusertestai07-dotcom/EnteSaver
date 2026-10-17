package app.entesaver.media

import android.content.Context
import android.net.Uri
import app.entesaver.core.logic.OptimisedMark

/** Reads a file's head and tail for the note an optimised file carries ([OptimisedMark]). */
internal object MarkReader {

    fun isMarked(context: Context, uri: Uri, size: Long): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            java.io.FileInputStream(pfd.fileDescriptor).channel.use { channel ->
                val length = if (size > 0) size else channel.size()
                val head = read(channel, 0, minOf(length, OptimisedMark.HEAD_BYTES.toLong()).toInt())
                // The rest of a small file, or the last part of a large one.
                val tailFrom = maxOf(head.size.toLong(), length - OptimisedMark.TAIL_BYTES)
                val tail = if (tailFrom < length) read(channel, tailFrom, (length - tailFrom).toInt()) else ByteArray(0)
                OptimisedMark.isMarked(head, tail)
            }
        } ?: false
    } catch (e: Exception) {
        false
    }

    private fun read(channel: java.nio.channels.FileChannel, at: Long, n: Int): ByteArray {
        val buffer = java.nio.ByteBuffer.allocate(n)
        var pos = at
        while (buffer.hasRemaining()) {
            val r = channel.read(buffer, pos)
            if (r <= 0) break
            pos += r
        }
        return buffer.array().copyOf(buffer.position())
    }
}
