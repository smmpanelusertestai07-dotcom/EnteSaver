package com.pocketide.linux

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption

/**
 * Google's gcloud lives in /opt/google-cloud-sdk-<version>, and /opt/google-cloud-sdk is a
 * relative link to the one in use. A new version is unpacked beside the current one, checked, and
 * switched to with one rename, so there is never a moment without a working gcloud, and switching
 * back is the same rename. gcloud's own updater keeps the one in use up to date after that.
 */
internal class GcloudSlot(
    private val rootfs: File,
    private val extractor: TarGzExtractor,
    private val runner: GuestRunner,
) {
    private fun opt(): Path =
        GuestRoot(rootfs).directory("/opt", create = true) ?: throw IOException("/opt inside Linux is not a folder")

    fun installed(): Boolean {
        val binary = GuestRoot(rootfs).existing("$LINK/bin/gcloud") ?: return false
        return GuestRoot.attributesOf(binary)?.isRegularFile == true
    }

    /** True when /opt/google-cloud-sdk-<version> was unpacked completely (it only appears by rename). */
    fun unpacked(version: String): Boolean = Files.isDirectory(opt().resolve(folder(version)))

    /** Unpacks the release archive into /opt/google-cloud-sdk-<version>, whole or not at all. */
    suspend fun unpack(version: String, archive: File, onProgress: (Float) -> Unit) {
        val target = opt().resolve(folder(version))
        val staging = opt().resolve(folder(version) + ".partial")
        Trees.delete(staging)
        // The release keeps everything under one top folder, google-cloud-sdk.
        extractor.extract(archive, staging.toFile(), stripComponents = 1, onProgress = onProgress)
        Trees.delete(target)
        Files.move(staging, target, StandardCopyOption.ATOMIC_MOVE)
    }

    /** True when the gcloud under [guestFolder] starts and reports [version] (any version when null). */
    suspend fun reports(guestFolder: String, version: String?): Boolean {
        var reported = false
        val code = try {
            withTimeout(CHECK_TIMEOUT_MS) {
                // "Google Cloud SDK 587.0.0", then its components' versions.
                runner.run(rootfs, listOf("$guestFolder/bin/gcloud", "--version")) { line ->
                    val said = line.trim()
                    if (said.startsWith("Google Cloud SDK ") && (version == null || said == "Google Cloud SDK $version")) reported = true
                }
            }
        } catch (expected: TimeoutCancellationException) {
            return false
        }
        return code == 0 && reported
    }

    /** Points /opt/google-cloud-sdk at [version]; returns the link's previous target, if there was one. */
    fun switchTo(version: String): String? = relink(folder(version))

    fun switchBack(previousTarget: String) {
        relink(previousTarget)
    }

    /** The version the link points at now. */
    fun current(): String? = runCatching { Files.readSymbolicLink(opt().resolve(NAME)).toString() }.getOrNull()
        ?.removePrefix("$NAME-")

    fun delete(version: String) = Trees.delete(opt().resolve(folder(version)))

    /** Removes every other version, and anything an interrupted unpack left behind. */
    fun prune(keep: String) {
        opt().toFile().listFiles { entry -> entry.name.startsWith("$NAME-") && entry.name != folder(keep) }
            ?.forEach { Trees.delete(it.toPath()) }
    }

    private fun relink(target: String): String? {
        val opt = opt()
        val link = opt.resolve(NAME)
        val attributes = GuestRoot.attributesOf(link)
        val previous = if (attributes?.isSymbolicLink == true) Files.readSymbolicLink(link).toString() else null
        // Anything that is not a link (a folder left by hand) gives way to the link.
        if (attributes != null && !attributes.isSymbolicLink) Trees.delete(link)
        val temporary = opt.resolve(".$NAME.link-${System.nanoTime()}")
        Files.createSymbolicLink(temporary, Paths.get(target))
        try {
            Files.move(temporary, link, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(temporary)
        }
        return previous
    }

    companion object {
        private const val NAME = "google-cloud-sdk"
        const val LINK = "/opt/google-cloud-sdk"
        private const val CHECK_TIMEOUT_MS = 120_000L

        fun folder(version: String) = "$NAME-$version"
    }
}
