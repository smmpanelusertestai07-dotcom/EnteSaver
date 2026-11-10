package com.pocketide.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class TreesTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun tree(): Pair<File, File> {
        val outside = temp.newFolder("outside").also { File(it, "keep").writeText("12345") }
        val root = temp.newFolder("rootfs")
        File(root, "usr/bin").mkdirs()
        File(root, "usr/bin/tool").writeText("1234567890")
        Files.createSymbolicLink(File(root, "escape").toPath(), outside.toPath())
        Files.createSymbolicLink(File(root, "usr/bin/keep-link").toPath(), File(outside, "keep").toPath())
        File(root, "sealed").mkdirs()
        File(root, "sealed/inside").writeText("x")
        FileModes.set(File(root, "sealed").toPath(), 0b101_101_101)
        return root to outside
    }

    @Test
    fun deleteNeverFollowsALinkOut() {
        val (root, outside) = tree()
        Trees.delete(root.toPath())
        assertFalse(root.exists())
        assertEquals("12345", File(outside, "keep").readText())
    }

    @Test
    fun bytesCountsOnlyRegularFilesInside() {
        val (root, _) = tree()
        assertEquals(11L, Trees.bytes(root.toPath()))
    }

    @Test
    fun discardMovesAsideFirstAndSweepRemovesLeftovers() {
        val (root, outside) = tree()
        Trees.discard(root)
        assertFalse(root.exists())
        val leftover = File(root.parentFile, "rootfs.trash-1").apply { mkdirs() }
        File(leftover, "x").writeText("x")
        Trees.sweep(root)
        assertFalse(leftover.exists())
        assertTrue(File(outside, "keep").exists())
    }
}
