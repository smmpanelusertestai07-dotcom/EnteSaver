package app.entesaver.core.logic

import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * The place a video was filmed, put back into its copy as the original wrote it.
 *
 * A phone's camera writes the place as ISO 6709 text in the index's own
 * notes (moov/udta/©xyz): Android writes "+28.6139+077.2090/". Media3 writes
 * the same place as "+28.6139+77.2090/", without an altitude the camera
 * added: the same point to a gallery, but not the same text. The original's
 * own box goes into the copy instead.
 *
 * The index grows or shrinks by the difference. When Media3 wrote it at the
 * front, the free box Media3 leaves after it gives or takes those bytes.
 * When Media3 wrote it at the end, the file grows or shrinks instead. The
 * picture and sound stay where they are, so nothing the index points at
 * moves.
 */
object PlaceBox {

    private const val HEADER = 8

    /** The type of the box a place is written in: "©xyz". */
    const val XYZ = "©xyz"

    private class Box(val type: String, val at: Long, val size: Long)

    /**
     * Writes [xyz] - a whole ©xyz box, as the original holds it - into the
     * file's index. False, with the file as it was, when the file is not laid
     * out as Media3 writes one, its index is over [maxIndexBytes], or there is
     * no room.
     */
    fun restore(ch: FileChannel, xyz: ByteArray, maxIndexBytes: Int): Boolean {
        if (!isXyz(xyz)) return false
        val top = topLevel(ch) ?: return false
        val i = top.indexOfFirst { it.type == "moov" }
        if (i < 0) return false
        val moov = top[i]
        // Media3 writes its XMP box straight after the index; it moves along.
        var j = i + 1
        while (j < top.size && top[j].type == "uuid") j++
        val free = top.getOrNull(j)
        if (free != null && free.type != "free") return false
        val end = free?.at ?: ch.size()
        if (end - moov.at > maxIndexBytes) return false
        val old = read(ch, moov.at, moov.size.toInt())
        val after = read(ch, moov.at + moov.size, (end - moov.at - moov.size).toInt())
        val new = withPlace(old, xyz) ?: return false
        if (new.contentEquals(old)) return true
        val grows = new.size - old.size
        val left = free?.let { it.size - grows }
        if (left != null && left != 0L && left < HEADER) return false
        write(ch, moov.at, new)
        write(ch, moov.at + new.size, after)
        when {
            left == null -> ch.truncate(moov.at + new.size + after.size)
            left > 0 -> write(ch, moov.at + new.size + after.size, header(left, "free"))
        }
        return true
    }

    /**
     * [moov] with the ©xyz box in its udta replaced by [xyz] - or added, in a
     * new udta after the movie header, when it has none. Null when [moov] is
     * not an index this reads: a 64-bit size, or a box that runs past its parent.
     */
    fun withPlace(moov: ByteArray, xyz: ByteArray): ByteArray? {
        if (!isXyz(xyz) || moov.size < HEADER || typeAt(moov, 0) != "moov" || sizeAt(moov, 0) != moov.size.toLong()) {
            return null
        }
        val kids = children(moov, HEADER, moov.size) ?: return null
        val udta = kids.firstOrNull { typeAt(moov, it.first) == "udta" }
        val parts = mutableListOf<ByteArray>()
        if (udta == null) {
            val newUdta = box("udta", listOf(xyz))
            val mvhd = kids.indexOfFirst { typeAt(moov, it.first) == "mvhd" }
            kids.forEachIndexed { k, (at, size) ->
                if (k == 0 && mvhd < 0) parts += newUdta
                parts += moov.copyOfRange(at, at + size)
                if (k == mvhd) parts += newUdta
            }
            if (kids.isEmpty()) parts += newUdta
        } else {
            val (uAt, uSize) = udta
            val inner = children(moov, uAt + HEADER, uAt + uSize) ?: return null
            val notes = mutableListOf<ByteArray>()
            var placed = false
            for ((at, size) in inner) {
                if (typeAt(moov, at) == XYZ) {
                    if (!placed) notes += xyz
                    placed = true
                } else {
                    notes += moov.copyOfRange(at, at + size)
                }
            }
            if (!placed) notes += xyz
            for ((at, size) in kids) {
                parts += if (at == uAt) box("udta", notes) else moov.copyOfRange(at, at + size)
            }
        }
        return box("moov", parts)
    }

    private fun isXyz(xyz: ByteArray): Boolean =
        xyz.size >= HEADER && sizeAt(xyz, 0) == xyz.size.toLong() && typeAt(xyz, 0) == XYZ

    /** The boxes of a file's top level; null when one runs past the end. */
    private fun topLevel(ch: FileChannel): List<Box>? {
        val boxes = mutableListOf<Box>()
        val length = ch.size()
        var pos = 0L
        while (pos + HEADER <= length) {
            val h = ByteBuffer.wrap(read(ch, pos, minOf(16L, length - pos).toInt()))
            var size = h.getInt(0).toLong() and 0xFFFFFFFFL
            val type = String(ByteArray(4) { h.get(4 + it) }, Charsets.ISO_8859_1)
            when (size) {
                1L -> size = if (h.limit() >= 16) h.getLong(8) else return null
                0L -> size = length - pos
            }
            if (size < HEADER || pos + size > length) return null
            boxes += Box(type, pos, size)
            pos += size
        }
        return boxes
    }

    /** The boxes from [from] to [to] in [b], as (offset, size); null when one runs past [to]. */
    private fun children(b: ByteArray, from: Int, to: Int): List<Pair<Int, Int>>? {
        val out = mutableListOf<Pair<Int, Int>>()
        var pos = from
        while (pos < to) {
            if (pos + HEADER > to) return null
            val size = sizeAt(b, pos)
            if (size < HEADER || pos + size > to) return null
            out += pos to size.toInt()
            pos += size.toInt()
        }
        return out
    }

    private fun sizeAt(b: ByteArray, at: Int): Long = ByteBuffer.wrap(b, at, 4).int.toLong() and 0xFFFFFFFFL

    private fun typeAt(b: ByteArray, at: Int): String = String(b, at + 4, 4, Charsets.ISO_8859_1)

    private fun box(type: String, parts: List<ByteArray>): ByteArray {
        val size = HEADER + parts.sumOf { it.size }
        val out = ByteBuffer.allocate(size).put(header(size.toLong(), type))
        parts.forEach { out.put(it) }
        return out.array()
    }

    private fun header(size: Long, type: String): ByteArray =
        ByteBuffer.allocate(HEADER).putInt(size.toInt()).put(type.toByteArray(Charsets.ISO_8859_1)).array()

    private fun read(ch: FileChannel, at: Long, n: Int): ByteArray {
        val buf = ByteBuffer.allocate(n)
        while (buf.hasRemaining()) {
            if (ch.read(buf, at + buf.position()) < 0) break
        }
        return buf.array()
    }

    private fun write(ch: FileChannel, at: Long, bytes: ByteArray) {
        val buf = ByteBuffer.wrap(bytes)
        while (buf.hasRemaining()) ch.write(buf, at + buf.position())
    }
}
