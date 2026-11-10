package com.pocketide.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Paths

class GuestRootTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var rootDir: File
    private lateinit var outside: File
    private lateinit var guest: GuestRoot

    @Before
    fun setUp() {
        rootDir = temp.newFolder("rootfs")
        outside = temp.newFolder("outside")
        File(outside, "token").writeText("ghp_secret")
        guest = GuestRoot(rootDir)
        File(rootDir, "etc").mkdirs()
        File(rootDir, "etc/os-release").writeText("PRETTY_NAME=\"Ubuntu 24.04.5 LTS\"\n")
    }

    private fun link(guestPath: String, target: String) {
        Files.createSymbolicLink(File(rootDir, guestPath.removePrefix("/")).toPath(), Paths.get(target))
    }

    @Test
    fun `the app's own user is added once, with root's home`() {
        File(rootDir, "etc/passwd").writeText("root:x:0:0:root:/root:/bin/bash")
        File(rootDir, "etc/group").writeText("root:x:0:\n")
        assertTrue(GuestConfig.ensureUser(guest, 10234, 10234))
        assertTrue(GuestConfig.ensureUser(guest, 10234, 10234))
        assertEquals("root:x:0:0:root:/root:/bin/bash\npocketide:x:10234:10234:PocketIDE:/root:/bin/bash\n", guest.readText("/etc/passwd"))
        assertEquals("root:x:0:\npocketide:x:10234:\n", guest.readText("/etc/group"))
    }

    @Test
    fun absoluteLinksStartAgainAtTheRoot() {
        link("/os", "/etc/os-release")
        assertEquals("PRETTY_NAME=\"Ubuntu 24.04.5 LTS\"\n", guest.readText("/os"))
    }

    @Test
    fun aLinkNeverLeadsOutOfTheRoot() {
        link("/up", "../../../../${outside.name}/token")
        link("/host", outside.absolutePath + "/token")
        link("/dots", "/../../..")
        assertNull(guest.readText("/up"))
        assertNull(guest.readText("/host"))
        assertEquals(guest.root, guest.existing("/dots"))
    }

    @Test
    fun linksWrittenByProotWithTheRootsHostPathAreReadAsGuestPaths() {
        // proot's link2symlink stores absolute host paths.
        link("/l2s", rootDir.absolutePath + "/etc/os-release")
        assertEquals("PRETTY_NAME=\"Ubuntu 24.04.5 LTS\"\n", guest.readText("/l2s"))
    }

    @Test
    fun writeReplacesALinkInsteadOfWritingThroughIt() {
        link("/etc/resolv.conf", outside.absolutePath + "/token")
        assertTrue(guest.write("/etc/resolv.conf", "nameserver 1.1.1.1\n".toByteArray()))
        assertEquals("ghp_secret", File(outside, "token").readText())
        assertFalse(Files.isSymbolicLink(File(rootDir, "etc/resolv.conf").toPath()))
        assertEquals("nameserver 1.1.1.1\n", File(rootDir, "etc/resolv.conf").readText())
        assertFalse(guest.write("/etc/resolv.conf", "nameserver 1.1.1.1\n".toByteArray()))
    }

    @Test
    fun writeCreatesFoldersThroughLinksInsideTheRoot() {
        File(rootDir, "usr/lib").mkdirs()
        link("/lib", "usr/lib")
        guest.write("/lib/pocketide/x", "1".toByteArray())
        assertEquals("1", File(rootDir, "usr/lib/pocketide/x").readText())
    }

    @Test
    fun aFileInTheWayOfAFolderIsAnError() {
        File(rootDir, "opt").writeText("not a folder")
        assertThrows(IOException::class.java) { guest.write("/opt/pocketide/launch.pl", "x".toByteArray()) }
        assertNull(guest.directory("/opt"))
    }

    @Test
    fun aLinkLoopEnds() {
        link("/a", "/b")
        link("/b", "/a")
        assertThrows(IOException::class.java) { guest.existing("/a") }
        assertNull(guest.readText("/a"))
    }

    @Test
    fun readTextRefusesBigFilesAndFolders() {
        File(rootDir, "big").writeBytes(ByteArray(70 * 1024))
        assertNull(guest.readText("/big"))
        assertNull(guest.readText("/etc"))
        assertNull(guest.readText("/missing"))
    }
}
