package com.pocketide.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

class FileTreesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `a link is deleted, never what it points to`() {
        val outside = tmp.newFolder("outside")
        val kept = File(outside, "photo.jpg").apply { writeText("owner's") }
        val tree = tmp.newFolder("rootfs")
        File(tree, "usr/lib").mkdirs()
        link(File(tree, "lib"), File("usr/lib"))
        link(File(tree, "home-phone"), outside)
        link(File(tree, "photo"), kept)
        link(File(tree, "dangling"), File(tmp.root, "gone"))

        assertTrue(FileTrees.delete(tree))

        assertFalse(tree.exists())
        assertEquals("owner's", kept.readText())
    }

    @Test
    fun `read-only and closed folders are opened up and deleted`() {
        val tree = tmp.newFolder("rootfs")
        val readOnly = File(tree, "proc").apply { mkdirs() }
        File(readOnly, "stat").writeText("1")
        readOnly.setWritable(false, false)
        val closed = File(tree, "root").apply { mkdirs() }
        File(closed, ".credentials.json").writeText("{}")
        closed.setReadable(false, false)
        closed.setExecutable(false, false)

        assertTrue(FileTrees.delete(tree))
        assertFalse(tree.exists())
    }

    @Test
    fun `contents go, the folder and what keep accepts stay`() {
        val dir = tmp.newFolder("no_backup")
        File(dir, "secure").mkdirs()
        File(dir, "secure/github").writeText("sealed")
        File(dir, "git-gate/state").apply { parentFile?.mkdirs() }.writeText("old")
        File(dir, "androidx.work.workdb").writeText("old")

        assertTrue(FileTrees.deleteContents(dir) { it == "secure" })

        assertEquals(listOf("secure"), dir.list()?.toList())
        assertEquals("sealed", File(dir, "secure/github").readText())
    }

    @Test
    fun `what is not there counts as deleted`() {
        assertTrue(FileTrees.delete(File(tmp.root, "never-made")))
        assertTrue(FileTrees.deleteContents(File(tmp.root, "never-made")))
    }

    private fun link(link: File, target: File) {
        Files.createSymbolicLink(link.toPath(), target.toPath())
        assertTrue(Files.isSymbolicLink(link.toPath()) && Files.exists(link.toPath(), LinkOption.NOFOLLOW_LINKS))
    }
}
