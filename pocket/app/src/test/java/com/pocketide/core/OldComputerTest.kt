package com.pocketide.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipInputStream

class OldComputerTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `the zip holds the projects and the chats, never a sign-in or what a project downloads again`() {
        val computer = OldComputer(tmp.newFolder("computer"))
        val home = File(computer.base, "home")
        val saved = listOf(
            "projects/app/main.kt",
            "projects/app/.git/HEAD",
            // The owner's own code is kept whole, whatever its name.
            "projects/app/tokenizer.py",
            ".claude/projects/-root-projects-app/chat.jsonl",
            ".codex/sessions/2026/09/rollout.jsonl",
            ".gemini/antigravity/conversations/one.pb",
        )
        val left = listOf(
            "projects/app/node_modules/left-pad/index.js",
            "projects/app/.venv/bin/python",
            ".claude/.credentials.json",
            ".claude/projects/-root-projects-app/oauth-token.json",
            ".codex/auth.json",
            ".gemini/antigravity/oauth_token.json",
            ".npm/_cacache/index",
            "rootfs-like/etc/passwd",
        )
        (saved + left).forEach { put(home, it) }
        // A link out of the home folder is never followed.
        val outside = File(tmp.root, "outside").apply { mkdirs() }
        put(outside, "secret.txt")
        Files.createSymbolicLink(File(home, "projects/app/link").toPath(), outside.toPath())

        val out = ByteArrayOutputStream()
        val count = computer.saveTo(out)

        val names = ZipInputStream(out.toByteArray().inputStream()).use { zip ->
            generateSequence { zip.nextEntry }.map { it.name }.toList()
        }
        assertEquals(saved.sorted(), names.sorted())
        assertEquals(saved.size, count)
    }

    @Test
    fun `its size counts what is there, and deleting it removes all of it`() {
        val computer = OldComputer(tmp.newFolder("computer"))
        put(File(computer.base, "home"), "projects/app/main.kt")
        put(computer.base, "rootfs/usr/bin/tool")
        assertTrue(computer.exists())
        assertTrue(computer.size() > 0)

        assertTrue(computer.delete())

        assertFalse(computer.exists())
    }

    @Test
    fun `sign-in files are recognised by their names`() {
        listOf(".credentials.json", "auth.json", "oauth_creds.json", "token.json", "id.pem", "key.key").forEach {
            assertTrue(it, OldComputer.isSignIn(it))
        }
        listOf("main.kt", "chat.jsonl", "README.txt").forEach { assertFalse(it, OldComputer.isSignIn(it)) }
    }

    private fun put(dir: File, path: String): File = File(dir, path).apply {
        parentFile?.mkdirs()
        writeText(path)
    }
}
