package com.pocketide.linux

import java.io.File
import java.io.IOException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes

/**
 * Paths inside a Linux root, resolved the way a process chrooted there would see them: an
 * absolute symbolic link starts again at the root, and ".." never climbs above it.
 *
 * Everything the app reads from or writes into a rootfs goes through here, so a link that an
 * agent (or an archive) leaves behind can never lead the app to a file outside the rootfs,
 * such as its own settings or its sealed secrets.
 */
internal class GuestRoot(rootDir: File) {
    val root: Path = rootDir.toPath().toAbsolutePath().normalize()

    /**
     * proot's link2symlink writes absolute host paths into the links it makes, so a target
     * under the rootfs's own host path is read as the guest path it stands for.
     */
    private val hostPrefixes: List<String> = listOfNotNull(
        root.toString(),
        runCatching { rootDir.canonicalPath }.getOrNull(),
    ).distinct()

    /** The directory at [guestPath], created when [create] and missing; null when something else is in the way. */
    fun directory(guestPath: String, create: Boolean = false): Path? {
        val resolved = walk(components(guestPath), create) ?: return null
        return resolved.takeIf { Files.isDirectory(it, LinkOption.NOFOLLOW_LINKS) }
    }

    /** What [guestPath] names, following links inside the root; null when it does not exist. */
    fun existing(guestPath: String): Path? = walk(components(guestPath), create = false)

    /**
     * Where an entry named [guestPath] lives: its directory resolved (and created), its own
     * name kept as it is, so a link already there is replaced rather than followed.
     */
    fun entry(guestPath: String): Path {
        val names = components(guestPath)
        require(names.isNotEmpty() && names.last() != "..") { "Not an entry name: $guestPath" }
        val parent = walk(names.dropLast(1), create = true)
            ?.takeIf { Files.isDirectory(it, LinkOption.NOFOLLOW_LINKS) }
            ?: throw IOException("Not a folder inside Linux: ${names.dropLast(1).joinToString("/", "/")}")
        return parent.resolve(names.last())
    }

    /** The text of the small regular file at [guestPath], or null. */
    fun readText(guestPath: String, limit: Long = 64 * 1024): String? {
        val file = runCatching { existing(guestPath) }.getOrNull() ?: return null
        val attributes = attributesOf(file) ?: return null
        if (!attributes.isRegularFile || attributes.size() > limit) return null
        return runCatching { String(Files.readAllBytes(file), Charsets.UTF_8) }.getOrNull()
    }

    /**
     * Replaces [guestPath] with [bytes] through a temporary file and a rename, so whatever was
     * there (a file, or a link to anywhere) is replaced and never written through. False when
     * the file already held exactly [bytes].
     */
    fun write(guestPath: String, bytes: ByteArray, mode: Int = 0b110_100_100): Boolean {
        val target = entry(guestPath)
        if (sameContent(target, bytes)) return false
        val temporary = Files.createTempFile(target.parent, ".pocketide-", ".tmp")
        try {
            Files.write(temporary, bytes)
            FileModes.set(temporary, mode)
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(temporary)
        }
        return true
    }

    private fun walk(names: List<String>, create: Boolean): Path? {
        var current = root
        val pending = ArrayDeque(names)
        var links = 0
        while (pending.isNotEmpty()) {
            val name = pending.removeFirst()
            if (name == "..") {
                if (current != root) current = current.parent
                continue
            }
            val next = current.resolve(name)
            val attributes = attributesOf(next)
            when {
                attributes == null -> {
                    if (!create) return null
                    createDirectory(next)
                    current = next
                }
                attributes.isSymbolicLink -> {
                    if (++links > MAX_LINKS) throw IOException("Too many symbolic links under ${root.fileName}")
                    val target = guestTarget(Files.readSymbolicLink(next).toString())
                    if (target.startsWith("/")) current = root
                    components(target).asReversed().forEach(pending::addFirst)
                }
                attributes.isDirectory -> current = next
                pending.isEmpty() -> current = next
                else -> return null
            }
        }
        return current
    }

    private fun guestTarget(target: String): String {
        for (prefix in hostPrefixes) {
            if (target == prefix) return "/"
            if (target.startsWith("$prefix/")) return target.substring(prefix.length)
        }
        return target
    }

    private fun createDirectory(path: Path) {
        try {
            Files.createDirectory(path)
        } catch (raced: FileAlreadyExistsException) {
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) throw raced
        }
    }

    private fun sameContent(target: Path, bytes: ByteArray): Boolean {
        val attributes = attributesOf(target) ?: return false
        if (!attributes.isRegularFile || attributes.size() != bytes.size.toLong()) return false
        return runCatching { Files.readAllBytes(target).contentEquals(bytes) }.getOrDefault(false)
    }

    companion object {
        private const val MAX_LINKS = 40

        fun components(guestPath: String): List<String> =
            guestPath.split('/').filter { it.isNotEmpty() && it != "." }

        fun attributesOf(path: Path): BasicFileAttributes? = try {
            Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        } catch (missing: IOException) {
            null
        }
    }
}
