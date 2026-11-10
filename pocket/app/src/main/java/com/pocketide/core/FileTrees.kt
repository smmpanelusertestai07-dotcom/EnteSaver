package com.pocketide.core

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes

/**
 * Deletes folders the way `rm -rf` does, without following links: a link is removed, what it
 * points to stays. Older versions kept a Linux file tree in the app's storage, whose links point
 * anywhere (`/proc`, the phone's shared storage) and whose folders can be read-only. Best effort:
 * whatever cannot be deleted is left, and everything else still goes.
 */
internal object FileTrees {
    /** Deletes everything in [dir] except the names [keep] accepts; true when nothing else is left. */
    fun deleteContents(dir: File, keep: (String) -> Boolean = { false }): Boolean {
        val entries = dir.listFiles() ?: return true
        return entries.filterNot { keep(it.name) }.map(::delete).all { it }
    }

    /** The bytes in [target] and under it; a link counts as itself, never what it points to. */
    fun size(target: File): Long {
        var total = 0L
        try {
            Files.walkFileTree(
                target.toPath(),
                object : SimpleFileVisitor<Path>() {
                    override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                        if (attrs.isRegularFile) total += attrs.size()
                        return FileVisitResult.CONTINUE
                    }

                    override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult = FileVisitResult.CONTINUE
                },
            )
        } catch (_: IOException) {
            // What could not be read is not counted.
        }
        return total
    }

    /** Deletes [target] and, if it is a real folder, everything in it; true when it is gone. */
    fun delete(target: File): Boolean {
        val root = target.toPath()
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) return true
        try {
            Files.walkFileTree(root, Remover)
        } catch (_: IOException) {
            // Remover handles its own errors; whatever is left is reported below.
        }
        return !Files.exists(root, LinkOption.NOFOLLOW_LINKS)
    }

    /** Walks without following links, so a link is only ever visited, and deleted, as itself. */
    private object Remover : SimpleFileVisitor<Path>() {
        override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
            // A read-only folder's entries cannot be removed until it is writable again.
            dir.toFile().setWritable(true, true)
            return FileVisitResult.CONTINUE
        }

        override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
            deleteQuietly(file)
            return FileVisitResult.CONTINUE
        }

        override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
            // A folder that could not be opened for want of read or search permission: open it up
            // and walk it once more. A second failure is not retried, so this cannot loop.
            val folder = file.toFile()
            val locked = Files.isDirectory(file, LinkOption.NOFOLLOW_LINKS) && !(folder.canRead() && folder.canExecute())
            if (locked && folder.setReadable(true, true) && folder.setExecutable(true, true)) {
                try {
                    Files.walkFileTree(file, this)
                } catch (_: IOException) {
                    // Left in place; the caller sees the folder still there.
                }
            } else {
                deleteQuietly(file)
            }
            return FileVisitResult.CONTINUE
        }

        override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
            deleteQuietly(dir)
            return FileVisitResult.CONTINUE
        }

        private fun deleteQuietly(path: Path) {
            try {
                Files.deleteIfExists(path)
            } catch (_: IOException) {
                // Left in place; the caller sees it still there.
            }
        }
    }
}
