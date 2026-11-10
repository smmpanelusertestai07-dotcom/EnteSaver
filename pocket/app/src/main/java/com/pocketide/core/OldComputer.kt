package com.pocketide.core

import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * The computer PocketIDE 5 kept on this phone: Ubuntu, with the owner's projects and the agents'
 * chats in its home folder. Version 6 works in Google Cloud Shell and cannot open it, so it stays
 * only until the owner has saved what they want from it and deleted it (Settings > Your data).
 */
internal class OldComputer(val base: File) {
    private val home = File(base, "home")

    fun exists(): Boolean = base.isDirectory

    /** Its size on the phone. */
    fun size(): Long = FileTrees.size(base)

    /**
     * Writes the projects and each agent's chats as a zip to [out], and closes it. The agents'
     * sign-ins, and what a project fetches again by itself (node_modules and the like), are left out;
     * links are never followed. Returns how many files it holds.
     */
    fun saveTo(out: OutputStream): Int {
        var count = 0
        ZipOutputStream(out.buffered()).use { zip ->
            SAVED.map { File(home, it).toPath() }.filter { Files.isDirectory(it, LinkOption.NOFOLLOW_LINKS) }.forEach { start ->
                // A project is the owner's own code, kept whole; an agent's folder also holds its sign-in.
                val agentFolder = start != File(home, PROJECTS).toPath()
                Files.walkFileTree(
                    start,
                    object : SimpleFileVisitor<Path>() {
                        override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult =
                            if (dir != start && dir.fileName.toString() in SKIPPED) FileVisitResult.SKIP_SUBTREE else FileVisitResult.CONTINUE

                        override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                            if (attrs.isRegularFile && !(agentFolder && isSignIn(file.fileName.toString()))) {
                                val entry = ZipEntry(home.toPath().relativize(file).joinToString("/"))
                                entry.lastModifiedTime = attrs.lastModifiedTime()
                                zip.putNextEntry(entry)
                                Files.copy(file, zip)
                                zip.closeEntry()
                                count++
                            }
                            return FileVisitResult.CONTINUE
                        }

                        override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult = FileVisitResult.CONTINUE
                    },
                )
            }
        }
        return count
    }

    fun delete(): Boolean = FileTrees.delete(base)

    companion object {
        const val FOLDER = "computer"

        private const val PROJECTS = "projects"

        /** In the old home folder: the projects, and where each agent kept its chats. */
        val SAVED = listOf(PROJECTS, ".claude/projects", ".codex/sessions", ".gemini/antigravity")

        /** Folders a project fills again by itself. */
        val SKIPPED = setOf("node_modules", ".venv", "venv", "__pycache__", ".gradle", ".next", ".cache")

        private val SIGN_IN = Regex("(?i).*(credential|token|oauth|secret|auth\\.json|\\.pem$|\\.key$).*")

        /** A file that looks like a sign-in or a key: it never goes into the zip. */
        fun isSignIn(name: String): Boolean = SIGN_IN.matches(name)
    }
}
