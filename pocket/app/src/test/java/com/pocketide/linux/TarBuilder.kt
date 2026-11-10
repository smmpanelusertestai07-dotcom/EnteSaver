package com.pocketide.linux

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.GZIPOutputStream

/**
 * Writes small tar.gz archives byte by byte, so tests control every header field, including
 * the ones a safe extractor must refuse.
 */
class TarBuilder {
    private val out = ByteArrayOutputStream()

    fun dir(name: String, mode: Int = 0b111_101_101) = entry(name, '5', ByteArray(0), mode)

    fun file(name: String, text: String, mode: Int = 0b110_100_100) = entry(name, '0', text.toByteArray(), mode)

    fun symlink(name: String, target: String) = entry(name, '2', ByteArray(0), 0b111_111_111, linkName = target)

    fun hardlink(name: String, target: String) = entry(name, '1', ByteArray(0), 0b110_100_100, linkName = target)

    /** A file whose name is too long for the header, carried in a GNU "././@LongLink" record first. */
    fun gnuLongFile(name: String, text: String): TarBuilder {
        entry("././@LongLink", 'L', (name + "\u0000").toByteArray(), 0)
        return entry(name.take(99), '0', text.toByteArray(), 0b110_100_100)
    }

    /** A file whose path (and optionally link target) come from a pax extended header. */
    fun paxFile(path: String, text: String): TarBuilder {
        entry("PaxHeaders/x", 'x', paxRecords("path" to path), 0)
        return entry("short-name", '0', text.toByteArray(), 0b110_100_100)
    }

    fun paxSymlink(path: String, target: String): TarBuilder {
        entry("PaxHeaders/y", 'x', paxRecords("path" to path, "linkpath" to target), 0)
        return entry("short-link", '2', ByteArray(0), 0b111_111_111, linkName = "short-target")
    }

    /** A ustar entry whose directory part sits in the 155-byte prefix field. */
    fun prefixedFile(prefix: String, name: String, text: String) =
        entry(name, '0', text.toByteArray(), 0b110_100_100, prefix = prefix)

    fun entry(
        name: String,
        type: Char,
        data: ByteArray,
        mode: Int,
        linkName: String = "",
        prefix: String = "",
        corruptChecksum: Boolean = false,
    ): TarBuilder {
        val header = ByteArray(BLOCK)
        put(header, 0, name, 100)
        put(header, 100, octal(mode.toLong(), 7), 8)
        put(header, 108, octal(0, 7), 8)
        put(header, 116, octal(0, 7), 8)
        put(header, 124, octal(data.size.toLong(), 11), 12)
        put(header, 136, octal(1_700_000_000, 11), 12)
        header[156] = type.code.toByte()
        put(header, 157, linkName, 100)
        put(header, 257, "ustar\u0000", 6)
        put(header, 263, "00", 2)
        put(header, 345, prefix, 155)
        for (i in 148 until 156) header[i] = ' '.code.toByte()
        var sum = header.sumOf { it.toInt() and 0xff }
        if (corruptChecksum) sum += 1
        put(header, 148, octal(sum.toLong(), 6) + "\u0000 ", 8)
        out.write(header)
        out.write(data)
        val padding = (BLOCK - data.size % BLOCK) % BLOCK
        out.write(ByteArray(padding))
        return this
    }

    /** The archive so far, ended as tar ends, and gzipped. */
    fun gz(): ByteArray = gzip(out.toByteArray() + ByteArray(2 * BLOCK))

    /** The archive so far, cut off without its end: a download that stopped part way. */
    fun truncatedGz(dropBytes: Int): ByteArray = out.toByteArray().let { gzip(it.copyOf(it.size - dropBytes)) }

    fun writeTo(file: File): File = file.also { it.writeBytes(gz()) }

    private fun gzip(bytes: ByteArray): ByteArray {
        val buffer = ByteArrayOutputStream()
        GZIPOutputStream(buffer).use { it.write(bytes) }
        return buffer.toByteArray()
    }

    private fun paxRecords(vararg records: Pair<String, String>): ByteArray {
        val text = StringBuilder()
        for ((key, value) in records) {
            val body = " $key=$value\n"
            var length = body.toByteArray().size + 1
            while ((length.toString() + body).toByteArray().size != length) length++
            text.append(length).append(body)
        }
        return text.toString().toByteArray()
    }

    private fun put(header: ByteArray, offset: Int, text: String, length: Int) {
        val bytes = text.toByteArray()
        require(bytes.size <= length) { "Field too long: $text" }
        bytes.copyInto(header, offset)
    }

    private fun octal(value: Long, digits: Int) = value.toString(8).padStart(digits, '0')

    private companion object {
        const val BLOCK = 512
    }
}
