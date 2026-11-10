package com.pocketide.linux

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions

class TarGzExtractorTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var destination: File

    /** A sibling of the destination: nothing an archive holds may ever reach it. */
    private lateinit var outside: File

    @Before
    fun setUp() {
        destination = temp.newFolder("root")
        outside = temp.newFolder("outside")
    }

    private fun extract(tar: TarBuilder, strip: Int = 0): Int = runBlocking {
        TarGzExtractor().extract(tar.writeTo(temp.newFile()), destination, stripComponents = strip)
    }

    private fun permissions(file: File) =
        PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath(), LinkOption.NOFOLLOW_LINKS))

    @Test
    fun unpacksFoldersFilesAndModes() {
        val count = extract(
            TarBuilder()
                .dir("usr/")
                .dir("usr/bin/")
                .file("usr/bin/tool", "#!/bin/sh\n", mode = 0b111_101_101)
                .file("etc/shadow", "secret\n", mode = 0b110_100_000)
                .dir("root/", mode = 0b111_000_000)
                .dir("sealed/", mode = 0b101_101_101),
        )
        assertEquals(6, count)
        assertEquals("#!/bin/sh\n", File(destination, "usr/bin/tool").readText())
        assertEquals("rwxr-xr-x", permissions(File(destination, "usr/bin/tool")))
        assertEquals("rw-r-----", permissions(File(destination, "etc/shadow")))
        assertEquals("rwx------", permissions(File(destination, "root")))
        // The app keeps its own write access, or it could never update or delete the folder.
        assertEquals("rwxr-xr-x", permissions(File(destination, "sealed")))
    }

    @Test
    fun symbolicLinksKeepTheirTargetAsWritten() {
        extract(TarBuilder().file("usr/bin/bash", "elf").symlink("bin", "usr/bin").symlink("sh", "/usr/bin/bash"))
        assertEquals(Paths.get("usr/bin"), Files.readSymbolicLink(File(destination, "bin").toPath()))
        assertEquals(Paths.get("/usr/bin/bash"), Files.readSymbolicLink(File(destination, "sh").toPath()))
    }

    @Test
    fun aLinkThatClimbsOutIsFollowedOnlyAsAChrootWould() {
        extract(
            TarBuilder()
                .symlink("escape", "../../../${outside.name}")
                .file("escape/pwned", "x")
                .symlink("absolute", outside.absolutePath)
                .file("absolute/pwned", "y"),
        )
        assertTrue(outside.list().isNullOrEmpty())
        assertEquals("x", File(destination, outside.name + "/pwned").readText())
        assertEquals("y", File(destination, outside.absolutePath.removePrefix("/") + "/pwned").readText())
    }

    @Test
    fun anEntryReplacesALinkStandingInItsPlace() {
        val victim = File(outside, "victim").apply { writeText("keep") }
        Files.createSymbolicLink(File(destination, "file").toPath(), victim.toPath())
        extract(TarBuilder().file("file", "new"))
        assertEquals("keep", victim.readText())
        assertFalse(Files.isSymbolicLink(File(destination, "file").toPath()))
        assertEquals("new", File(destination, "file").readText())
    }

    @Test
    fun pathTraversalAndAbsoluteNamesFailTheWholeArchive() {
        assertThrows(UnsafeArchive::class.java) { extract(TarBuilder().file("../evil", "x")) }
        assertThrows(UnsafeArchive::class.java) { extract(TarBuilder().file("a/../../evil", "x")) }
        assertThrows(UnsafeArchive::class.java) { extract(TarBuilder().file("/etc/evil", "x")) }
        assertThrows(UnsafeArchive::class.java) { extract(TarBuilder().paxFile("../../evil", "x")) }
        assertThrows(UnsafeArchive::class.java) { extract(TarBuilder().file("x", "1").hardlink("y", "../x")) }
        assertTrue(outside.list().isNullOrEmpty())
        assertFalse(File(temp.root, "evil").exists())
    }

    @Test
    fun hardLinksBecomeIndependentCopies() {
        extract(TarBuilder().file("usr/bin/perl", "perl", mode = 0b111_101_101).hardlink("usr/bin/perl5.38.2", "usr/bin/perl"))
        val copy = File(destination, "usr/bin/perl5.38.2")
        assertEquals("perl", copy.readText())
        assertFalse(Files.isSymbolicLink(copy.toPath()))
        File(destination, "usr/bin/perl").writeText("changed")
        assertEquals("perl", copy.readText())
    }

    @Test
    fun aHardLinkNeverCopiesAFileFromOutside() {
        File(outside, "passwd").writeText("host secret")
        val tar = TarBuilder().symlink("link", outside.absolutePath + "/passwd").hardlink("stolen", "link")
        assertThrows(IOException::class.java) { extract(tar) }
        assertFalse(File(destination, "stolen").exists())
    }

    @Test
    fun aHardLinkToAMissingFileIsADamagedArchive() {
        assertThrows(IOException::class.java) { extract(TarBuilder().hardlink("b", "a")) }
    }

    @Test
    fun longNamesFromGnuRecordsPaxHeadersAndTheUstarPrefix() {
        val gnu = "deep/" + "g".repeat(140) + "/file.txt"
        val pax = "pax/" + "p".repeat(200) + "/file.txt"
        val prefix = "q".repeat(120)
        extract(
            TarBuilder()
                .gnuLongFile(gnu, "gnu")
                .paxFile(pax, "pax")
                .prefixedFile(prefix, "name.txt", "prefix")
                .paxSymlink("links/long-link", "t".repeat(150)),
        )
        assertEquals("gnu", File(destination, gnu).readText())
        assertEquals("pax", File(destination, pax).readText())
        assertEquals("prefix", File(destination, "$prefix/name.txt").readText())
        assertEquals(Paths.get("t".repeat(150)), Files.readSymbolicLink(File(destination, "links/long-link").toPath()))
        // A pax header applies to the next entry only.
        assertFalse(File(destination, "short-name").exists())
    }

    @Test
    fun stripsLeadingFolders() {
        extract(TarBuilder().dir("code-server-1.0-linux-arm64/").file("code-server-1.0-linux-arm64/bin/code-server", "run"), strip = 1)
        assertEquals("run", File(destination, "bin/code-server").readText())
        assertFalse(File(destination, "code-server-1.0-linux-arm64").exists())
    }

    @Test
    fun devicesAndFifosAreSkipped() {
        extract(TarBuilder().entry("dev/null", '3', ByteArray(0), 0b110_110_110).entry("fifo", '6', ByteArray(0), 0b110_100_100).file("after", "ok"))
        assertFalse(File(destination, "dev/null").exists())
        assertEquals("ok", File(destination, "after").readText())
    }

    @Test
    fun aDamagedHeaderOrAShortArchiveFails() {
        assertThrows(IOException::class.java) {
            extract(TarBuilder().entry("bad", '0', "x".toByteArray(), 0b110_100_100, corruptChecksum = true))
        }
        val archive = temp.newFile().apply { writeBytes(TarBuilder().file("big", "y".repeat(5000)).truncatedGz(2000)) }
        assertThrows(IOException::class.java) { runBlocking { TarGzExtractor().extract(archive, destination) } }
    }

    @Test
    fun reportsProgressUpToTheWholeArchive() {
        val tar = TarBuilder()
        repeat(200) { tar.file("f$it", "x".repeat(it)) }
        val seen = mutableListOf<Float>()
        runBlocking { TarGzExtractor().extract(tar.writeTo(temp.newFile()), destination, onProgress = { seen += it }) }
        assertTrue(seen.isNotEmpty())
        assertTrue(seen.all { it in 0f..1f })
        assertEquals(seen.sorted(), seen)
    }
}
