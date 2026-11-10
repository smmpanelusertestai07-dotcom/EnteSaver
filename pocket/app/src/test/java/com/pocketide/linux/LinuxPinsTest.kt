package com.pocketide.linux

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LinuxPinsTest {
    private val sha256 = Regex("[0-9a-f]{64}")

    private fun pins(): Map<String, PinnedDownload> = Arch.entries.flatMap { arch ->
        listOf(
            "ubuntuBase-${arch.ubuntu}" to LinuxPins.ubuntuBase(arch),
            "gcloud-${arch.gcloud}" to LinuxPins.gcloud(arch).download(),
        )
    }.toMap()

    @Test
    fun `every pin is a full https address of this version, with a checksum and a size`() {
        pins().forEach { (name, pin) ->
            assertTrue(name, pin.url.startsWith("https://"))
            assertTrue(name, sha256.matches(pin.sha256))
            assertTrue(name, pin.bytes > 0)
        }
        Arch.entries.forEach { arch ->
            val base = LinuxPins.ubuntuBase(arch)
            // The point release's own folder: the plain 26.04 one moves on to each newer point release.
            assertTrue(base.url, base.url.contains("/releases/${LinuxPins.UBUNTU_VERSION}/release/"))
            assertEquals("ubuntu-base-${LinuxPins.UBUNTU_VERSION}-base-${arch.ubuntu}.tar.gz", base.fileName)
            val gcloud = LinuxPins.gcloud(arch)
            // Google's own download server, the version in the name: never a "latest" that changes under the pin.
            assertTrue(gcloud.url, gcloud.url.startsWith("https://dl.google.com/"))
            assertEquals("google-cloud-cli-${LinuxPins.GCLOUD_VERSION}-linux-${arch.gcloud}.tar.gz", gcloud.download().fileName)
            assertEquals(LinuxPins.GCLOUD_VERSION, gcloud.version)
        }
    }

    /** What CI checks against the publishers, and builds the engine test from: the pins exactly as the app has them. */
    @Test
    fun `the pins are written for CI`() {
        val out = File("build/engine").apply { mkdirs() }
        val json = buildJsonObject {
            put("ubuntuVersion", LinuxPins.UBUNTU_VERSION)
            put("ubuntuCodename", LinuxPins.UBUNTU_CODENAME)
            put("gcloudVersion", LinuxPins.GCLOUD_VERSION)
            putJsonObject("pins") {
                pins().forEach { (name, pin) ->
                    putJsonObject(name) {
                        put("url", pin.url)
                        put("sha256", pin.sha256)
                        put("bytes", pin.bytes)
                    }
                }
            }
        }
        File(out, "pins.json").writeText(json.toString() + "\n")
        assertTrue(File(out, "pins.json").length() > 0)
    }
}
