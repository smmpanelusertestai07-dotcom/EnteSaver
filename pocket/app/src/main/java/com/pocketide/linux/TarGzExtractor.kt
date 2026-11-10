package com.pocketide.linux

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardOpenOption
import java.util.zip.GZIPInputStream

/** An archive entry that would land outside the folder it is unpacked into. */
internal class UnsafeArchive(message: String) : IOException(message)

/**
 * Unpacks a .tar.gz in one streaming pass: ustar, pax and GNU long names, symbolic links,
 * modes, and hard links as copies (Android app storage refuses real hard links on many phones).
 *
 * Nothing lands outside the destination. An absolute name or a ".." fails the whole archive;
 * links already unpacked are followed only the way a chroot would; and an entry replaces a
 * link standing in its place instead of writing through it.
 */
internal class TarGzExtractor {

    /** Unpacks [archive] into [destination], dropping [stripComponents] leading names. Returns the entry count. */
    suspend fun extract(
        archive: File,
        destination: File,
        stripComponents: Int = 0,
        onProgress: (Float) -> Unit = {},
    ): Int {
        Files.createDirectories(destination.toPath())
        val compressedBytes = archive.length().coerceAtLeast(1)
        CountingInputStream(FileInputStream(archive)).use { counted ->
            GZIPInputStream(BufferedInputStream(counted, BUFFER), BUFFER).use { input ->
                val unpacker = Unpacker(TarStream(input), GuestRoot(destination), stripComponents) {
                    onProgress((counted.count.toFloat() / compressedBytes).coerceIn(0f, 1f))
                }
                return unpacker.run()
            }
        }
    }

    private class Unpacker(
        private val tar: TarStream,
        private val guest: GuestRoot,
        private val strip: Int,
        private val tick: () -> Unit,
    ) {
        suspend fun run(): Int {
            var entries = 0
            while (true) {
                currentCoroutineContext().ensureActive()
                val header = tar.next() ?: return entries
                val names = inside(header.name)
                if (names == null) {
                    tar.skip(header.size)
                } else {
                    unpack(header, names.joinToString("/"))
                }
                tar.skipPadding(header.size)
                entries++
                if (entries % 64 == 0) tick()
            }
        }

        private suspend fun unpack(header: TarHeader, name: String) {
            val path = guest.entry(name)
            when (header.type) {
                // Old archives mark a folder only by the "/" at the end of its name.
                TYPE_FILE, TYPE_OLD_FILE, TYPE_CONTIGUOUS -> if (header.name.endsWith("/")) {
                    makeDirectory(path, header.mode)
                    tar.skip(header.size)
                } else {
                    writeFile(path, header)
                }
                TYPE_DIRECTORY -> {
                    makeDirectory(path, header.mode)
                    tar.skip(header.size)
                }
                TYPE_SYMLINK -> {
                    makeLink(path, header)
                    tar.skip(header.size)
                }
                TYPE_HARDLINK -> {
                    copyHardLink(path, header)
                    tar.skip(header.size)
                }
                // Devices and FIFOs cannot be made without root; proot binds the real /dev.
                else -> tar.skip(header.size)
            }
        }

        private suspend fun writeFile(path: Path, header: TarHeader) {
            clearForEntry(path, header.name)
            Files.newOutputStream(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                tar.copy(header.size, output, tick)
            }
            FileModes.set(path, FileModes.forFile(header.mode.ifZero(FileModes.PLAIN)))
        }

        private fun makeDirectory(path: Path, mode: Int) {
            val attributes = GuestRoot.attributesOf(path)
            if (attributes == null || !attributes.isDirectory) {
                if (attributes != null) Files.delete(path)
                Files.createDirectory(path)
            }
            FileModes.set(path, FileModes.forDirectory(mode.ifZero(FileModes.EXECUTABLE)))
        }

        private fun makeLink(path: Path, header: TarHeader) {
            val target = header.linkName
            if (target.isEmpty()) throw UnsafeArchive("A link without a target: ${header.name}")
            clearForEntry(path, header.name)
            Files.createSymbolicLink(path, Paths.get(target))
        }

        /** A hard link names a file earlier in the same archive; anything else is a damaged archive. */
        private fun copyHardLink(path: Path, header: TarHeader) {
            val sourceNames = inside(header.linkName) ?: return
            val source = guest.existing(sourceNames.joinToString("/"))
            val attributes = source?.let(GuestRoot::attributesOf)
            if (source == null || attributes == null || !attributes.isRegularFile) {
                throw IOException("A hard link to a file that is not in the archive: ${header.name}")
            }
            if (source == path) return
            clearForEntry(path, header.name)
            Files.copy(source, path)
            FileModes.set(path, FileModes.forFile(header.mode.ifZero(FileModes.PLAIN)))
        }

        /** Removes a file or link standing where a new entry goes; never writes through it. */
        private fun clearForEntry(path: Path, name: String) {
            val attributes = GuestRoot.attributesOf(path) ?: return
            if (attributes.isDirectory) throw IOException("A file and a folder share the name $name")
            Files.delete(path)
        }

        private fun inside(raw: String): List<String>? {
            if (raw.startsWith("/")) throw UnsafeArchive("An absolute path in the archive: $raw")
            val names = GuestRoot.components(raw)
            if (names.any { it == ".." }) throw UnsafeArchive("A path that leaves the folder: $raw")
            return names.drop(strip).ifEmpty { null }
        }

        private fun Int.ifZero(fallback: Int) = if (this == 0) fallback else this
    }

    private class TarHeader(val name: String, val linkName: String, val type: Char, val size: Long, val mode: Int)

    /** The tar layer: headers with their long-name and pax records applied, and entry data. */
    private class TarStream(private val input: InputStream) {
        private val block = ByteArray(BLOCK)

        fun next(): TarHeader? {
            var longName: String? = null
            var longLink: String? = null
            val pax = HashMap<String, String>()
            while (true) {
                if (!readBlock()) return null
                if (block.all { it.toInt() == 0 }) return null
                verifyChecksum()
                val type = (block[156].toInt() and 0xff).toChar()
                val size = number(124, 12)
                when (type) {
                    TYPE_GNU_LONG_NAME -> longName = cString(readMeta(size))
                    TYPE_GNU_LONG_LINK -> longLink = cString(readMeta(size))
                    TYPE_PAX -> pax.putAll(parsePax(readMeta(size)))
                    TYPE_PAX_GLOBAL -> readMeta(size)
                    else -> return TarHeader(
                        name = pax["path"] ?: longName ?: headerName(),
                        linkName = pax["linkpath"] ?: longLink ?: field(157, 100),
                        type = type,
                        size = pax["size"]?.toLongOrNull() ?: size,
                        mode = (number(100, 8) and 0b111_111_111_111L).toInt(),
                    )
                }
            }
        }

        suspend fun copy(size: Long, output: OutputStream, tick: () -> Unit) {
            val buffer = ByteArray(BUFFER)
            var remaining = size
            var sinceTick = 0L
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) throw IOException("The archive ends in the middle of a file")
                output.write(buffer, 0, read)
                remaining -= read
                sinceTick += read
                if (sinceTick >= TICK_BYTES) {
                    sinceTick = 0
                    currentCoroutineContext().ensureActive()
                    tick()
                }
            }
        }

        fun skip(size: Long) {
            val buffer = ByteArray(BUFFER)
            var remaining = size
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) throw IOException("The archive ends in the middle of an entry")
                remaining -= read
            }
        }

        fun skipPadding(size: Long) = skip((BLOCK - size % BLOCK) % BLOCK)

        private fun readBlock(): Boolean {
            val read = readFully(block)
            if (read == 0) return false
            if (read != BLOCK) throw IOException("The archive ends in the middle of a header")
            return true
        }

        private fun readMeta(size: Long): ByteArray {
            if (size !in 0..MAX_META) throw IOException("An archive header record is too large")
            val data = ByteArray(size.toInt())
            if (readFully(data) != data.size) throw IOException("The archive ends in the middle of a header")
            skipPadding(size)
            return data
        }

        private fun readFully(target: ByteArray): Int {
            var total = 0
            while (total < target.size) {
                val read = input.read(target, total, target.size - total)
                if (read < 0) break
                total += read
            }
            return total
        }

        /** ustar keeps long paths in a prefix field; GNU headers use those bytes for other things. */
        private fun headerName(): String {
            val name = field(0, 100)
            val ustar = block.copyOfRange(257, 263).contentEquals(USTAR_MAGIC)
            val prefix = if (ustar) field(345, 155) else ""
            return if (prefix.isEmpty()) name else "$prefix/$name"
        }

        private fun verifyChecksum() {
            val stored = number(148, 8)
            var unsigned = 0L
            var signed = 0L
            for (i in block.indices) {
                val inChecksum = i in 148 until 156
                unsigned += if (inChecksum) 32 else block[i].toInt() and 0xff
                signed += if (inChecksum) 32 else block[i].toInt()
            }
            if (stored != unsigned && stored != signed) throw IOException("The archive is damaged (header checksum)")
        }

        private fun number(offset: Int, length: Int): Long {
            val first = block[offset].toInt() and 0xff
            if (first and 0x80 != 0) {
                if (first == 0xff) throw IOException("The archive has a negative number")
                var value = (first and 0x7f).toLong()
                for (i in offset + 1 until offset + length) value = (value shl 8) or (block[i].toLong() and 0xff)
                return value
            }
            var value = 0L
            var digits = false
            for (i in offset until offset + length) {
                val c = block[i].toInt() and 0xff
                if (c == 0 || c == ' '.code) {
                    if (digits) break
                    continue
                }
                if (c !in '0'.code..'7'.code) throw IOException("The archive has a malformed number")
                digits = true
                value = (value shl 3) + (c - '0'.code)
            }
            return value
        }

        private fun field(offset: Int, length: Int): String {
            var end = offset
            while (end < offset + length && block[end].toInt() != 0) end++
            return String(block, offset, end - offset, Charsets.UTF_8)
        }

        private fun cString(data: ByteArray): String {
            var end = data.size
            while (end > 0 && (data[end - 1].toInt() == 0 || data[end - 1] == '\n'.code.toByte())) end--
            return String(data, 0, end, Charsets.UTF_8)
        }

        /** Records are "<length> <key>=<value>\n", the length counted in bytes. */
        private fun parsePax(data: ByteArray): Map<String, String> {
            val values = HashMap<String, String>()
            var position = 0
            while (position < data.size) {
                var space = position
                while (space < data.size && data[space] != ' '.code.toByte()) space++
                if (space >= data.size) break
                val length = String(data, position, space - position, Charsets.US_ASCII).toIntOrNull() ?: break
                if (length <= space - position + 2 || position + length > data.size) break
                val record = String(data, space + 1, position + length - space - 2, Charsets.UTF_8)
                val equals = record.indexOf('=')
                if (equals > 0) values[record.substring(0, equals)] = record.substring(equals + 1)
                position += length
            }
            return values
        }
    }

    private class CountingInputStream(input: InputStream) : FilterInputStream(input) {
        var count = 0L
            private set

        override fun read(): Int = super.read().also { if (it >= 0) count++ }

        override fun read(b: ByteArray, off: Int, len: Int): Int =
            super.read(b, off, len).also { if (it > 0) count += it }

        override fun skip(n: Long): Long = super.skip(n).also { count += it }
    }

    private companion object {
        const val BLOCK = 512
        const val BUFFER = 128 * 1024
        const val TICK_BYTES = 4L * 1024 * 1024
        const val MAX_META = 1L * 1024 * 1024
        val USTAR_MAGIC = byteArrayOf('u'.code.toByte(), 's'.code.toByte(), 't'.code.toByte(), 'a'.code.toByte(), 'r'.code.toByte(), 0)

        const val TYPE_FILE = '0'
        const val TYPE_OLD_FILE = '\u0000'
        const val TYPE_HARDLINK = '1'
        const val TYPE_SYMLINK = '2'
        const val TYPE_DIRECTORY = '5'
        const val TYPE_CONTIGUOUS = '7'
        const val TYPE_PAX = 'x'
        const val TYPE_PAX_GLOBAL = 'g'
        const val TYPE_GNU_LONG_NAME = 'L'
        const val TYPE_GNU_LONG_LINK = 'K'
    }
}
