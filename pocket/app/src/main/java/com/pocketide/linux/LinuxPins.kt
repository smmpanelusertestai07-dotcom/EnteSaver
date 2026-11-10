package com.pocketide.linux

import java.io.File

/** A file fetched only from [url] and kept only when it is [bytes] long with this [sha256]. */
data class PinnedDownload(val url: String, val sha256: String, val bytes: Long) {
    val fileName: String get() = url.substringAfterLast('/')
}

/** A release of Google's gcloud for this phone's processor, used only when its SHA-256 matches. */
data class GcloudPin(val version: String, val url: String, val sha256: String, val bytes: Long)

internal fun GcloudPin.download() = PinnedDownload(url, sha256, bytes)

/**
 * The processor the computer is built for, named the way each publisher names it. Phones are
 * arm64; x86-64 is for the Android emulator the end-to-end tests run on.
 */
enum class Arch(val ubuntu: String, val gcloud: String) {
    ARM64("arm64", "arm"),
    X86_64("amd64", "x86_64"),
    ;

    companion object {
        /**
         * The processor of the PRoot this APK installed: Android picks one ABI's native libraries
         * at install time and puts them in a folder named after it (lib/arm64, lib/x86_64).
         */
        fun of(nativeLibraryDir: File): Arch? = when (nativeLibraryDir.name) {
            "arm64", "arm64-v8a" -> ARM64
            "x86_64" -> X86_64
            else -> null
        }
    }
}

/**
 * What PocketIDE's connection to Cloud Shell is built from. Each checksum was taken from the
 * publisher's own source and matched against a fresh download: Ubuntu's from the SHA256SUMS file
 * signed by the Ubuntu CD image key (29 Sep 2026); gcloud's versioned archive from Google's download
 * server holds exactly the files of the archive whose SHA-256 Google publishes on its install page
 * (30 Sep 2026: the same tar, only the gzip header differs). tools/check-pins.py downloads each one
 * again in CI.
 */
object LinuxPins {
    const val UBUNTU_VERSION = "26.04.1"

    /** Ubuntu 26.04 LTS, "Resolute Raccoon": the codename apt's package sources use. */
    const val UBUNTU_CODENAME = "resolute"

    /**
     * When Canonical's standard security fixes for Ubuntu 26.04 end: after April 2031 (UTC epoch
     * ms of 1 June 2031). From then on the Computer screen says so, and an app update that pins the
     * next LTS moves the computer to it with Reset.
     */
    const val UBUNTU_SUPPORT_ENDS = 1_938_038_400_000L

    // The point release's own folder: the plain 26.04 one moves on to each newer point release.
    private const val UBUNTU_BASE = "https://cdimage.ubuntu.com/ubuntu-base/releases/$UBUNTU_VERSION/release"

    fun ubuntuBase(arch: Arch): PinnedDownload = when (arch) {
        Arch.ARM64 -> PinnedDownload(
            url = "$UBUNTU_BASE/ubuntu-base-26.04.1-base-arm64.tar.gz",
            sha256 = "5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd",
            bytes = 35_092_106,
        )
        Arch.X86_64 -> PinnedDownload(
            url = "$UBUNTU_BASE/ubuntu-base-26.04.1-base-amd64.tar.gz",
            sha256 = "a496a960472ce474a59590b8987d3a1135d3cbef1991f3b1abe8cacfea8bf85a",
            bytes = 34_931_253,
        )
    }

    const val GCLOUD_VERSION = "587.0.0"
    private const val GCLOUD_RELEASES = "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads"

    /** Google's gcloud, from Google's own download server; its own updater takes over once it is in place. */
    fun gcloud(arch: Arch): GcloudPin = when (arch) {
        Arch.ARM64 -> GcloudPin(
            version = GCLOUD_VERSION,
            url = "$GCLOUD_RELEASES/google-cloud-cli-$GCLOUD_VERSION-linux-arm.tar.gz",
            sha256 = "8349b151da42f07136294da0908624fe8ea16fea200cb2f4412ad081a86e890c",
            bytes = 53_905_571,
        )
        Arch.X86_64 -> GcloudPin(
            version = GCLOUD_VERSION,
            url = "$GCLOUD_RELEASES/google-cloud-cli-$GCLOUD_VERSION-linux-x86_64.tar.gz",
            sha256 = "57df2448d259c654796a3703af8e5b53a02d439715b2034d6bb811efc2d6dd7b",
            bytes = 88_004_933,
        )
    }
}
