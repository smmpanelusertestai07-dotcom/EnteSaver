package com.pocketide.linux

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermission

/** Unix permission bits, set the same way on Android and on a test machine. */
internal object FileModes {
    /** rw-r--r-- */
    const val PLAIN = 0b110_100_100

    /** rwxr-xr-x */
    const val EXECUTABLE = 0b111_101_101

    private const val OWNER_READ_WRITE = 0b110_000_000
    private const val OWNER_ALL = 0b111_000_000

    /**
     * The app is not root, so it must keep its own access to everything it unpacks, or it could
     * neither write into a folder nor delete it later. Inside Linux proot's faked root reads
     * these owner bits as it likes.
     */
    fun forFile(mode: Int) = (mode and 0b111_111_111_111) or OWNER_READ_WRITE

    fun forDirectory(mode: Int) = (mode and 0b111_111_111_111) or OWNER_ALL

    fun set(path: Path, mode: Int) {
        try {
            // Keeps setuid, setgid and sticky bits where the platform supports it.
            Files.setAttribute(path, "unix:mode", mode)
        } catch (unsupported: UnsupportedOperationException) {
            Files.setPosixFilePermissions(path, permissions(mode))
        } catch (unsupported: IllegalArgumentException) {
            Files.setPosixFilePermissions(path, permissions(mode))
        }
    }

    private fun permissions(mode: Int): Set<PosixFilePermission> {
        val order = listOf(
            PosixFilePermission.OTHERS_EXECUTE, PosixFilePermission.OTHERS_WRITE, PosixFilePermission.OTHERS_READ,
            PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.GROUP_WRITE, PosixFilePermission.GROUP_READ,
            PosixFilePermission.OWNER_EXECUTE, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_READ,
        )
        return order.filterIndexed { bit, _ -> mode and (1 shl bit) != 0 }.toSet()
    }
}

/**
 * Whole-tree operations that never follow a link. A link inside Linux can name anything the
 * app can reach, and a walk that followed one out of the rootfs would measure, or delete,
 * whatever it pointed at.
 */
internal object Trees {
    /** Deletes [path] and everything under it; links are deleted as links. */
    fun delete(path: Path) {
        if (GuestRoot.attributesOf(path) == null) return
        Files.walkFileTree(
            path,
            object : SimpleFileVisitor<Path>() {
                override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                    // A folder Linux made read-only must become writable again before it can be emptied.
                    if (!Files.isWritable(dir)) FileModes.set(dir, FileModes.forDirectory(0))
                    return FileVisitResult.CONTINUE
                }

                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.deleteIfExists(file)
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                    if (exc !is NoSuchFileException) Files.deleteIfExists(file)
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                    Files.deleteIfExists(dir)
                    return FileVisitResult.CONTINUE
                }
            },
        )
    }

    /**
     * Deletes a big tree without leaving it half-deleted in place: it is renamed out of the way
     * first (one step), then emptied. A kill in between leaves only a "trash" folder, which
     * [sweep] removes later.
     */
    fun discard(dir: File) {
        val path = dir.toPath()
        if (GuestRoot.attributesOf(path) == null) return
        val trash = path.resolveSibling("${dir.name}$TRASH${System.nanoTime()}")
        Files.move(path, trash, StandardCopyOption.ATOMIC_MOVE)
        delete(trash)
    }

    /** Removes what an interrupted [discard] of [dir] left behind. */
    fun sweep(dir: File) {
        dir.parentFile?.listFiles { file -> file.name.startsWith("${dir.name}$TRASH") }
            ?.forEach { runCatching { delete(it.toPath()) } }
    }

    /** Bytes of the regular files under [path]; a link counts as nothing. */
    fun bytes(path: Path): Long {
        if (GuestRoot.attributesOf(path) == null) return 0
        var total = 0L
        Files.walkFileTree(
            path,
            object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    if (attrs.isRegularFile) total += attrs.size()
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, exc: IOException) = FileVisitResult.CONTINUE
            },
        )
        return total
    }

    fun isLinkOrMissing(path: Path) =
        !Files.exists(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)

    private const val TRASH = ".trash-"
}
