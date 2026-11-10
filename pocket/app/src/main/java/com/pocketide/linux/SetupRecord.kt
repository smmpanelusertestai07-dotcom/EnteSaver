package com.pocketide.linux

import com.pocketide.core.AppJson
import kotlinx.serialization.Serializable
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * How far PocketIDE's connection has been built, kept outside the rootfs so nothing inside Linux can
 * change what the app believes about it. Each step is written as soon as it is done, which is
 * what lets a set-up killed by a flat battery continue where it stopped.
 */
@Serializable
internal data class SetupRecord(
    /** The processor the rootfs was built for ([Arch.name]). */
    val arch: String? = null,
    /** Ubuntu version and SHA-256 of the base image the rootfs was unpacked from. */
    val ubuntu: String? = null,
    val base: String? = null,
    /** SHA-256 of the bootstrap.sh that last finished inside it. */
    val bootstrap: String? = null,
    /** The gcloud first unpacked at /opt/google-cloud-sdk, and the SHA-256 of its archive (it updates itself after). */
    val gcloud: String? = null,
    val gcloudSha256: String? = null,
    /** The app version that put the pinned gcloud back after an update it could not use: until it changes, gcloud does not update. */
    val gcloudHeld: String? = null,
    /** When set-up finished (UTC epoch ms); null while it is still under way. */
    val readyAt: Long? = null,
    /** When Ubuntu's updates last finished (UTC epoch ms). */
    val updatedAt: Long? = null,
)

internal class RecordStore(private val file: File) {
    fun load(): SetupRecord =
        runCatching { AppJson.decodeFromString(SetupRecord.serializer(), file.readText()) }.getOrDefault(SetupRecord())

    /** Written in full and synced before it replaces the old record, so a kill leaves one or the other. */
    fun save(record: SetupRecord) {
        file.parentFile?.let { Files.createDirectories(it.toPath()) }
        val temporary = File(file.parentFile, file.name + ".tmp")
        FileOutputStream(temporary).use { output ->
            output.write(AppJson.encodeToString(SetupRecord.serializer(), record).toByteArray())
            output.fd.sync()
        }
        Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    fun clear() {
        Files.deleteIfExists(file.toPath())
    }
}
