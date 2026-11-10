package com.pocketide.downloads

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FileOfferTest {
    private val key = "0123456789abcdef0123456789abcdef"
    private fun door(port: Int, path: String) = "http://$port-$key.localhost:40123$path"

    @Test
    fun `PocketIDE's own Download buttons start at once`() {
        val apk = FileOffer.of(
            door(6081, "/f/codex/app/build/outputs/apk/debug/app-debug.apk?download"),
            "attachment; filename=\"app-debug.apk\"; filename*=UTF-8''app-debug.apk",
            "application/vnd.android.package-archive",
            5_168_447,
            fromVsCode = false,
        )!!
        assertTrue(apk.decided)
        assertTrue(apk.isApk)
        assertEquals("app-debug.apk", apk.name)
        assertEquals(5_168_447L, apk.size)
        val zip = FileOffer.of(door(6081, "/f/codex/out?zip"), "attachment; filename=\"out.zip\"", "application/zip", -1, fromVsCode = false)!!
        assertTrue(zip.decided)
        assertEquals(-1L, zip.size)
    }

    @Test
    fun `a file any other page hands over is shown first, and nothing is saved before the owner says so`() {
        // An agent's own server (python -m http.server) linking a file directly: the WebView cannot show it.
        val offer = FileOffer.of(door(8000, "/app/build/outputs/apk/release/app-release.apk"), null, "application/octet-stream", 1234, fromVsCode = false)!!
        assertFalse(offer.decided)
        assertEquals("app-release.apk", offer.name)
        assertEquals(FileKinds.APK, offer.mime)
        // files.py's own page links that are no download (an image opened in full) are not saved at once either.
        assertFalse(FileOffer.of(door(6081, "/r/codex/report.pdf"), null, "application/pdf", 10, fromVsCode = false)!!.decided)
    }

    @Test
    fun `VS Code's own Download keeps the file's name, from its path`() {
        val offer = FileOffer.of(
            door(8081, "/vscode-remote-resource?path=%2Fhome%2Fme%2Fprojects%2Fcodex%2Fmy%20notes.txt&tkn=abc"),
            null,
            "text/plain",
            12,
            fromVsCode = true,
        )!!
        assertTrue(offer.decided)
        assertEquals("my notes.txt", offer.name)
        assertEquals("text/plain", offer.mime)
    }

    @Test
    fun `only Cloud Shell's files, through PocketIDE's door`() {
        assertNull(FileOffer.of("blob:http://8081-$key.localhost:40123/5d2e", null, "image/png", 10, fromVsCode = true))
        assertNull(FileOffer.of("https://example.com/app.apk", null, null, 10, fromVsCode = false))
        assertNull("not this app's key", FileOffer.of("http://6081-other.localhost:40123/f/a?download", null, null, 1, fromVsCode = false))
        assertNull(FileOffer.of("http://localhost:6081/f/a?download", null, null, 1, fromVsCode = false))
    }

    @Test
    fun `names come whole, in any language, and never as a path`() {
        val hindi = "%E0%A4%B0%E0%A4%BF%E0%A4%AA%E0%A5%8B%E0%A4%B0%E0%A5%8D%E0%A4%9F"
        assertEquals("रिपोर्ट final.pdf", FileKinds.name("attachment; filename=\"_______ final.pdf\"; filename*=UTF-8''$hindi%20final.pdf", "http://x/f", null))
        assertEquals("a b.txt", FileKinds.name("attachment; filename=\"a b.txt\"", "http://x/y", null))
        assertEquals("plain.txt", FileKinds.name("attachment; filename=plain.txt", "http://x/y", null))
        assertEquals("passwd", FileKinds.name("attachment; filename=\"../../etc/passwd\"", "http://x/y", null))
        assertEquals("from url.zip", FileKinds.name(null, "http://x/f/codex/from%20url.zip?download", null))
        assertEquals("download.pdf", FileKinds.name(null, "http://x/", "application/pdf"))
        val long = "a".repeat(300) + ".apk"
        assertTrue(FileKinds.name("attachment; filename=\"$long\"", "http://x/", null).let { it.length <= 120 && it.endsWith(".apk") })
    }

    @Test
    fun `the type it is saved as`() {
        assertEquals(FileKinds.APK, FileKinds.mime("a.apk", "application/octet-stream"))
        assertEquals(FileKinds.APK, FileKinds.mime("a.apk", "application/zip"))
        assertEquals("image/png", FileKinds.mime("shot", "image/png; charset=binary"))
        assertEquals("application/pdf", FileKinds.mime("r.pdf", "application/octet-stream"))
        assertEquals("application/octet-stream", FileKinds.mime("data.bin", null))
        assertEquals(FileKinds.Kind.APP, FileKinds.kind("a.apk", "application/octet-stream"))
        assertEquals(FileKinds.Kind.VIDEO, FileKinds.kind("v.webm", "video/webm"))
        assertEquals(FileKinds.Kind.ARCHIVE, FileKinds.kind("logs.tgz", "application/gzip"))
        assertEquals(FileKinds.Kind.TEXT, FileKinds.kind("a.json", "application/json"))
    }

    @Test
    fun `sizes read as Android's Files app says them`() {
        assertEquals("0 bytes", FileKinds.sizeText(0))
        assertEquals("1023 bytes", FileKinds.sizeText(1023))
        assertEquals("2 KB", FileKinds.sizeText(2048))
        assertEquals("4.9 MB", FileKinds.sizeText(5_168_447))
        assertEquals("1.5 GB", FileKinds.sizeText(1_610_612_736))
        assertEquals("", FileKinds.sizeText(-1))
    }
}
