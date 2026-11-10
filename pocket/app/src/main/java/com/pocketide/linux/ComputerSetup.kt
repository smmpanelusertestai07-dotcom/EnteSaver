package com.pocketide.linux

import com.pocketide.core.Clock
import com.pocketide.core.SemVer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** What set-up needs from the phone, kept small so the steps can run off the phone in tests. */
internal interface SetupHost {
    fun dnsServers(): List<InetAddress>

    /** Bytes the computer may still use, cached files Android can clear included. */
    fun freeBytes(): Long

    /** Asks Android to clear cached files until [bytes] fit, after [freeBytes] said they would. */
    fun makeRoom(bytes: Long)
}

/** Where set-up keeps things: the rootfs, the one being unpacked beside it, downloads, and its record. */
internal class SetupPlaces(val rootfs: File, val downloads: File, val record: File) {
    val staging = File(rootfs.parentFile, rootfs.name + ".partial")
}

/** An expected stop, already in the owner's words. */
internal class SetupStop(val why: String, val fix: String) : Exception(why)

/**
 * Builds, repairs, updates and removes PocketIDE's connection to Cloud Shell: Ubuntu under PRoot
 * with Python and OpenSSH, and Google's gcloud. Every step checks what is already done (the
 * [SetupRecord], the files themselves), so running it again after a kill continues where it
 * stopped, and running it on a finished one only refreshes what the phone provides.
 *
 * Callers run one operation at a time.
 */
@Suppress("LongParameterList") // Each part is replaced in tests: the downloads, the runner, the pins.
internal class ComputerSetup(
    private val places: SetupPlaces,
    private val host: SetupHost,
    private val fetcher: Fetcher,
    runner: GuestRunner,
    assets: LinuxAssets,
    private val clock: Clock,
    private val publish: (ComputerState) -> Unit,
    private val arch: Arch,
    private val ubuntu: PinnedDownload = LinuxPins.ubuntuBase(arch),
    private val ubuntuVersion: String = LinuxPins.UBUNTU_VERSION,
    private val gcloud: GcloudPin = LinuxPins.gcloud(arch),
    private val extractor: TarGzExtractor = TarGzExtractor(),
    private val appVersion: String = "",
) {
    private val records = RecordStore(places.record)
    private val scripts = GuestScripts(assets, runner)
    private val runner = runner
    private val slot = GcloudSlot(places.rootfs, extractor, runner)

    /** What the files on disk say, for when the app starts. */
    fun stateOnDisk(): ComputerState {
        val record = records.load()
        return when {
            record.readyAt == null -> ComputerState.NotInstalled
            healthy(record) -> ComputerState.Ready
            else -> ComputerState.Broken("Part of PocketIDE's connection is missing.", FIX_SET_UP_AGAIN)
        }
    }

    fun record(): SetupRecord = records.load()

    /** Sets up what is missing; returns (and has published) where the computer ended up. */
    suspend fun install(): ComputerState = withContext(Dispatchers.IO) {
        val end = try {
            Trees.sweep(places.rootfs)
            val record = records.load()
            if (record.readyAt != null && healthy(record)) {
                refreshGuest(places.rootfs)
            } else {
                build(record.copy(readyAt = null))
            }
            ComputerState.Ready
        } catch (cancelled: CancellationException) {
            publish(stateOnDisk())
            throw cancelled
        } catch (stop: SetupStop) {
            ComputerState.Broken(stop.why, stop.fix)
        } catch (failure: Exception) {
            broken(failure)
        }
        publish(end)
        end
    }

    /**
     * A computer that is not whole is set up again from where it stopped; a whole one has each
     * part checked and, where it can be, put right. Files the owner may have changed are only
     * ever written when missing.
     */
    suspend fun repair(): List<RepairItem> = withContext(Dispatchers.IO) {
        val record = records.load()
        if (record.readyAt == null || !healthy(record)) {
            return@withContext when (val end = install()) {
                ComputerState.Ready -> listOf(RepairItem(WHOLE, RepairStatus.NEW, "The parts that were missing are set up again."))
                is ComputerState.Broken -> listOf(RepairItem(WHOLE, RepairStatus.WARN, "${end.why} ${end.fix}"))
                else -> listOf(RepairItem(WHOLE, RepairStatus.WARN, "Set-up did not finish. Try again."))
            }
        }
        publish(ComputerState.Updating("Repair"))
        try {
            guestFiles() + listOf(tools(), gcloudItem()) + listOfNotNull(supportEnded(record))
        } finally {
            publish(stateOnDisk())
        }
    }

    private fun guestFiles(): List<RepairItem> {
        val guest = GuestRoot(places.rootfs)
        val restored = GuestConfig.writeBasics(guest, onlyMissing = true)
        val basics = if (restored.isEmpty()) {
            RepairItem(NETWORK_FILES, RepairStatus.OK, "Present; left as they are.")
        } else {
            RepairItem(NETWORK_FILES, RepairStatus.NEW, "Written again: ${restored.joinToString()}.")
        }
        val resolver = if (GuestConfig.writeResolver(guest, host.dnsServers())) {
            RepairItem("DNS", RepairStatus.OK, "Linux uses the phone's DNS servers.")
        } else {
            RepairItem("DNS", RepairStatus.WARN, "The phone reported no DNS servers. Check the connection, then repair again.")
        }
        val replaced = scripts.install(places.rootfs)
        val own = if (replaced == 0) {
            RepairItem(SCRIPTS, RepairStatus.OK, "Up to date.")
        } else {
            RepairItem(SCRIPTS, RepairStatus.NEW, "Replaced $replaced with the app's own copies.")
        }
        return listOf(basics, resolver, own)
    }

    /** bootstrap.sh again: it installs only the tools that are missing and resets the settings it owns. */
    private suspend fun tools(): RepairItem {
        var installed = 0
        val result = scripts.run(places.rootfs, GuestScripts.BOOTSTRAP) { line ->
            if (line is GuestLine.Installed) installed = line.count
        }
        if (result.exitCode != 0) {
            return RepairItem(TOOLS, RepairStatus.WARN, "Stopped: ${stoppedBecause(result)}. Try again on a steady connection.")
        }
        records.save(records.load().copy(bootstrap = scripts.bootstrapVersion()))
        return when (installed) {
            0 -> RepairItem(TOOLS, RepairStatus.OK, "Everything is installed.")
            1 -> RepairItem(TOOLS, RepairStatus.NEW, "Installed 1 missing tool.")
            else -> RepairItem(TOOLS, RepairStatus.NEW, "Installed $installed missing tools.")
        }
    }

    /** Ubuntu past the end of its security fixes, which only a computer built on the next LTS gets again. */
    private fun supportEnded(record: SetupRecord): RepairItem? {
        if (clock.now() < LinuxPins.UBUNTU_SUPPORT_ENDS || record.ubuntu != ubuntuVersion) return null
        val release = ubuntuVersion.split('.').take(2).joinToString(".")
        return RepairItem(SUPPORT, RepairStatus.WARN, "Ubuntu $release no longer gets security fixes. $FIX_NEXT_LTS")
    }

    /** gcloud is checked by starting it; one that does not start is unpacked again from the pinned release. */
    private suspend fun gcloudItem(): RepairItem {
        if (slot.installed() && slot.reports(GcloudSlot.LINK, null)) {
            return RepairItem(GCLOUD, RepairStatus.OK, "Google's gcloud starts.")
        }
        val pin = gcloud
        val archive = fetcher.fetch(pin.download(), File(places.downloads, pin.download().fileName)) {}
        slot.unpack(pin.version, archive) {}
        val previous = slot.switchTo(pin.version)
        if (!slot.reports(GcloudSlot.LINK, pin.version)) {
            previous?.takeIf { it != GcloudSlot.folder(pin.version) }?.let(slot::switchBack)
            return RepairItem(GCLOUD, RepairStatus.WARN, "It does not start, even unpacked again. $FIX_RESET")
        }
        records.save(records.load().copy(gcloud = pin.version, gcloudSha256 = pin.sha256))
        slot.prune(keep = pin.version)
        Files.deleteIfExists(archive.toPath())
        return RepairItem(GCLOUD, RepairStatus.NEW, "Unpacked gcloud ${pin.version} again; it starts.")
    }

    private fun stoppedBecause(result: ScriptResult) = result.lastWords?.removeSuffix(".") ?: "exit code ${result.exitCode}"

    /** Deletes Ubuntu and what set-up downloaded; the record goes first, so a kill never leaves "ready". */
    suspend fun remove() = withContext(Dispatchers.IO) {
        records.clear()
        Trees.discard(places.staging)
        Trees.discard(places.rootfs)
        Trees.sweep(places.staging)
        Trees.sweep(places.rootfs)
        Trees.delete(places.downloads.toPath())
        publish(ComputerState.NotInstalled)
    }

    /** Ubuntu's updates (after a bootstrap an app update changed), then gcloud's own updater. */
    suspend fun updateBase(): UpdateOutcome = withContext(Dispatchers.IO) {
        val record = records.load()
        if (record.readyAt == null || !healthy(record)) return@withContext UpdateOutcome.Waiting(NOT_SET_UP)
        publish(ComputerState.Updating("Ubuntu's updates"))
        try {
            refreshGuest(places.rootfs)
            val refreshed = record.bootstrap != scripts.bootstrapVersion()
            if (refreshed) {
                val result = scripts.run(places.rootfs, GuestScripts.BOOTSTRAP) {}
                if (result.exitCode != 0) {
                    return@withContext UpdateOutcome.Failed("Refreshing Ubuntu stopped: ${stoppedBecause(result)}.")
                }
                records.save(records.load().copy(bootstrap = scripts.bootstrapVersion()))
            }
            var updated = 0
            val result = scripts.run(places.rootfs, GuestScripts.UPDATE) { line ->
                if (line is GuestLine.Fixed) updated = line.count
            }
            if (result.exitCode != 0) {
                return@withContext UpdateOutcome.Failed("Ubuntu's updates stopped: ${stoppedBecause(result)}.")
            }
            val gcloudUpdated = updateGcloud()
            records.save(records.load().copy(updatedAt = clock.now()))
            baseOutcome(refreshed, updated, gcloudUpdated)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            UpdateOutcome.Failed(broken(failure).why)
        } finally {
            publish(stateOnDisk())
        }
    }

    /** gcloud's own updater (components it checks against Google's list); true when it installed something. */
    private suspend fun updateGcloud(): Boolean {
        // Held back after an update PocketIDE could not use, until the next app version (reinstallGcloud).
        if (records.load().gcloudHeld == appVersion) return false
        var changed = false
        val code = runner.run(places.rootfs, listOf(GCLOUD_COMMAND, "components", "update", "--quiet")) { line ->
            if (line.contains("Performing update") || line.contains("Update done")) changed = true
        }
        return code == 0 && changed
    }

    /**
     * gcloud from the version this app pins, unpacked over the one in place (after an update whose
     * tunnel PocketIDE cannot keep private); gcloud's updates then wait for the next app version.
     */
    suspend fun reinstallGcloud(heldFor: String): Boolean = withContext(Dispatchers.IO) {
        val record = records.load()
        if (record.readyAt == null || !healthy(record)) return@withContext false
        publish(ComputerState.Updating("Google's gcloud"))
        try {
            val pin = gcloud
            val archive = fetcher.fetch(pin.download(), File(places.downloads, pin.download().fileName)) {}
            slot.unpack(pin.version, archive) {}
            slot.switchTo(pin.version)
            val starts = slot.reports(GcloudSlot.LINK, pin.version)
            if (starts) {
                records.save(records.load().copy(gcloud = pin.version, gcloudSha256 = pin.sha256, gcloudHeld = heldFor))
                slot.prune(keep = pin.version)
            }
            Files.deleteIfExists(archive.toPath())
            starts
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (expected: Exception) {
            false
        } finally {
            publish(stateOnDisk())
        }
    }

    /** gcloud's own updater waits until the app version is no longer [heldFor]. */
    fun holdGcloudUpdates(heldFor: String) {
        records.save(records.load().copy(gcloudHeld = heldFor))
    }

    private suspend fun build(start: SetupRecord) = coroutineScope {
        records.save(start)
        var record = start
        val baseInPlace = record.base != null && GuestRoot(places.rootfs).existing("/etc/os-release") != null
        val toolsDone = baseInPlace && record.bootstrap == scripts.bootstrapVersion() &&
            GuestRoot(places.rootfs).existing(GuestScripts.STAMP) != null
        val gcloudDone = baseInPlace && record.gcloud != null && slot.installed()
        checkRoom(baseInPlace, toolsDone, gcloudDone)
        val bar = Bar(
            stages = buildSet {
                if (!baseInPlace) addAll(listOf(Stage.DOWNLOAD_UBUNTU, Stage.UNPACK_UBUNTU))
                if (!toolsDone) add(Stage.TOOLS)
                if (!gcloudDone) addAll(listOf(Stage.DOWNLOAD_GCLOUD, Stage.UNPACK_GCLOUD, Stage.CHECK))
            },
            bytesTotal = (if (baseInPlace) 0 else ubuntu.bytes) + (if (gcloudDone) 0 else gcloud.bytes),
            publish = publish,
        )
        // gcloud's archive downloads while Ubuntu is set up: neither needs the other. A failed download
        // is reported when its turn comes, so it never stops apt half way.
        val gcloudArchive = if (gcloudDone) {
            null
        } else {
            async { runCatching { fetcher.fetch(gcloud.download(), File(places.downloads, gcloud.download().fileName)) { bar.aside(it) } } }
        }
        if (!baseInPlace) record = placeUbuntu(bar)
        refreshGuest(places.rootfs)
        if (!toolsDone) record = runBootstrap(record, bar)
        if (gcloudArchive != null) record = placeGcloud(record, bar, gcloudArchive)
        records.save(record.copy(readyAt = clock.now(), updatedAt = clock.now()))
        publish(ComputerState.Ready)
    }

    /** Free space, checked for what this run still has to fetch and unpack. */
    private fun checkRoom(baseInPlace: Boolean, toolsDone: Boolean, gcloudDone: Boolean) {
        val space = (if (baseInPlace) 0 else UBUNTU_SPACE) +
            (if (toolsDone) 0 else TOOLS_SPACE) +
            (if (gcloudDone) 0 else GCLOUD_SPACE)
        if (space > 0 && host.freeBytes() < space + SPARE_SPACE) {
            val needed = (space + SPARE_SPACE) / BYTES_PER_GB
            throw SetupStop(
                "There is not enough free space for PocketIDE's connection.",
                "Free about ${"%.1f".format(needed)} GB on the phone, then tap Set up again. It continues where it stopped.",
            )
        }
        if (space > 0) host.makeRoom(space + SPARE_SPACE)
    }

    private suspend fun placeUbuntu(bar: Bar): SetupRecord {
        bar.enter(Stage.DOWNLOAD_UBUNTU, "Downloading Ubuntu $ubuntuVersion…")
        val archive = fetcher.fetch(ubuntu, File(places.downloads, ubuntu.fileName)) { bar.downloaded(it, ubuntu.bytes) }
        bar.downloadFinished(ubuntu.bytes)
        bar.enter(Stage.UNPACK_UBUNTU, "Unpacking Ubuntu…")
        Trees.delete(places.staging.toPath())
        extractor.extract(archive, places.staging) { bar.within(it) }
        val guest = GuestRoot(places.staging)
        GuestConfig.writeBasics(guest, onlyMissing = false)
        GuestConfig.writeResolver(guest, host.dnsServers())
        scripts.install(places.staging)
        // PRoot's link2symlink writes absolute host paths into the links it makes, so the tree must
        // be in its final place before anything runs inside it; moved later, those links would
        // point at a folder that no longer exists.
        Trees.discard(places.rootfs)
        Files.move(places.staging.toPath(), places.rootfs.toPath(), StandardCopyOption.ATOMIC_MOVE)
        val record = SetupRecord(arch = arch.name, ubuntu = ubuntuVersion, base = ubuntu.sha256)
        records.save(record)
        Files.deleteIfExists(archive.toPath())
        return record
    }

    private suspend fun runBootstrap(record: SetupRecord, bar: Bar): SetupRecord {
        bar.enter(Stage.TOOLS, "Installing Python and OpenSSH…")
        val progress = ToolsProgress(bar)
        val result = scripts.run(places.rootfs, GuestScripts.BOOTSTRAP) { line -> progress.show(line) }
        if (result.exitCode != 0) {
            throw SetupStop("Setting up Ubuntu stopped: ${stoppedBecause(result)}.", FIX_TRY_AGAIN)
        }
        return record.copy(bootstrap = scripts.bootstrapVersion()).also(records::save)
    }

    private suspend fun placeGcloud(record: SetupRecord, bar: Bar, download: Deferred<Result<File>>): SetupRecord {
        val pin = gcloud
        bar.enter(Stage.DOWNLOAD_GCLOUD, "Downloading Google's gcloud ${pin.version}…")
        val archive = download.await().getOrThrow()
        bar.asideFinished(pin.bytes)
        bar.enter(Stage.UNPACK_GCLOUD, "Unpacking gcloud…")
        slot.unpack(pin.version, archive) { bar.within(it) }
        slot.switchTo(pin.version)
        bar.enter(Stage.CHECK, "Checking that gcloud starts…")
        if (!slot.reports(GcloudSlot.LINK, pin.version)) throw SetupStop("gcloud did not start.", FIX_RESET)
        slot.prune(keep = pin.version)
        val updated = record.copy(gcloud = pin.version, gcloudSha256 = pin.sha256)
        records.save(updated)
        Files.deleteIfExists(archive.toPath())
        return updated
    }

    /** What the phone provides and an app update may change: DNS, host names, the scripts. */
    private fun refreshGuest(rootfs: File) {
        val guest = GuestRoot(rootfs)
        GuestConfig.writeBasics(guest, onlyMissing = true)
        GuestConfig.writeResolver(guest, host.dnsServers())
        scripts.install(rootfs)
    }

    private fun healthy(record: SetupRecord): Boolean =
        record.base != null && record.gcloud != null &&
            GuestRoot(places.rootfs).existing("/etc/os-release") != null && slot.installed()

    private fun baseOutcome(refreshed: Boolean, updated: Int, gcloudUpdated: Boolean): UpdateOutcome {
        val parts = buildList {
            if (refreshed) add("refreshed Ubuntu's set-up")
            if (updated > 0) add(if (updated == 1) "updated 1 package" else "updated $updated packages")
            if (gcloudUpdated) add("updated gcloud")
        }
        return if (parts.isEmpty()) UpdateOutcome.UpToDate else UpdateOutcome.Updated(parts.joinToString(", ").replaceFirstChar { it.uppercase() } + ".")
    }

    /** An unexpected failure, in the owner's words. */
    private fun broken(failure: Exception): ComputerState.Broken = when {
        failure is ChecksumMismatch ->
            ComputerState.Broken("The download of ${failure.fileName} did not match its published checksum, so it was deleted.", FIX_TRY_AGAIN)
        failure is DownloadFailed -> ComputerState.Broken("${failure.message}.", FIX_CONNECTION)
        failure is UnsafeArchive -> ComputerState.Broken("A downloaded archive was not safe to unpack.", FIX_TRY_AGAIN)
        Downloader.outOfSpace(failure) -> ComputerState.Broken("The phone ran out of space.", "Free some space on the phone, then tap Set up again.")
        failure is FileSystemException -> ComputerState.Broken("Set-up could not write its files.", FIX_RESET)
        failure is IOException -> ComputerState.Broken("Set-up stopped: ${failure.message ?: "a file could not be read or written"}.", FIX_TRY_AGAIN)
        else -> ComputerState.Broken("Set-up stopped unexpectedly.", FIX_RESET)
    }

    private enum class Stage(val weight: Int) {
        DOWNLOAD_UBUNTU(8),
        UNPACK_UBUNTU(8),
        TOOLS(40),
        DOWNLOAD_GCLOUD(16),
        UNPACK_GCLOUD(20),
        CHECK(8),
    }

    /** One bar across the stages this run still has to do; it never moves backwards. */
    private class Bar(stages: Set<Stage>, private val bytesTotal: Long, private val publish: (ComputerState) -> Unit) {
        private val total = stages.sumOf { it.weight }.coerceAtLeast(1)
        private var finished = 0
        private var current: Stage? = null
        private var within = 0f
        private var step = ""
        private var bytesBefore = 0L
        private var bytes = 0L

        /** Bytes of the download that runs beside the stages (gcloud's, while Ubuntu is set up). */
        private var aside = 0L

        @Synchronized
        fun aside(done: Long) {
            aside = done
            show()
        }

        @Synchronized
        fun asideFinished(size: Long) {
            bytesBefore += size
            bytes = bytesBefore
            aside = 0
            within(1f)
        }

        @Synchronized
        fun enter(stage: Stage, text: String) {
            current?.let { finished += it.weight }
            current = stage
            within = 0f
            step = text
            show()
        }

        @Synchronized
        fun step(text: String) {
            step = text
            show()
        }

        @Synchronized
        fun within(fraction: Float) {
            within = maxOf(within, fraction.coerceIn(0f, 1f))
            show()
        }

        @Synchronized
        fun downloaded(done: Long, size: Long) {
            bytes = bytesBefore + done
            within(done.toFloat() / size.coerceAtLeast(1))
        }

        @Synchronized
        fun downloadFinished(size: Long) {
            bytesBefore += size
            bytes = bytesBefore
        }

        private fun show() {
            val weight = current?.weight ?: 0
            val fraction = ((finished + weight * within) / total).coerceIn(0f, 1f)
            publish(ComputerState.Installing(step, fraction, bytes + aside, bytesTotal))
        }
    }

    /** Turns bootstrap.sh's markers and apt's status lines into the bar's position and step. */
    private class ToolsProgress(private val bar: Bar) {
        private var phase = 0
        private var label = "Preparing Ubuntu"

        fun show(line: GuestLine) {
            when (line) {
                is GuestLine.Progress -> {
                    phase = line.percent
                    bar.within(line.percent / 100f)
                }
                is GuestLine.Apt -> {
                    val part = line.percent / 100f
                    val position = when {
                        phase < APT_LISTS_DONE -> 10 + 20 * part
                        !line.installing -> 30 + 25 * part
                        else -> 55 + 35 * part
                    }
                    bar.step("$label: ${line.text}")
                    bar.within(position / 100f)
                }
                // Only the script's own steps name the bar: apt and dpkg print warnings too.
                is GuestLine.Step -> {
                    label = line.text.removeSuffix("…")
                    bar.step(line.text)
                }
                is GuestLine.Text, is GuestLine.Fetched, is GuestLine.Fixed, is GuestLine.Installed -> Unit
            }
        }

        private companion object {
            const val APT_LISTS_DONE = 30
        }
    }

    internal companion object {
        /** Unpacked sizes, with the archive still on disk while it unpacks. */
        private const val UBUNTU_SPACE = 150_000_000L
        private const val TOOLS_SPACE = 200_000_000L
        private const val GCLOUD_SPACE = 600_000_000L

        /** Left free for the rest of the phone. */
        private const val SPARE_SPACE = 500_000_000L
        private const val BYTES_PER_GB = 1e9

        /** The items of a Repair report. */
        private const val WHOLE = "The computer"
        private const val NETWORK_FILES = "Host name and network files"
        private const val SCRIPTS = "PocketIDE's scripts"
        private const val TOOLS = "Tools and settings"
        private const val GCLOUD = "Google's gcloud"
        private const val SUPPORT = "Ubuntu's support"
        private const val NOT_SET_UP = "PocketIDE's connection is not set up yet."
        const val GCLOUD_COMMAND = "${GcloudSlot.LINK}/bin/gcloud"
        private const val FIX_CONNECTION = "Check the connection and tap Set up again. It continues where it stopped."
        private const val FIX_TRY_AGAIN = "Tap Set up again. If it keeps stopping, set up the connection again from Settings."
        private const val FIX_RESET = "Set up the connection again from Settings. Your Cloud Shell is not touched."
        private const val FIX_NEXT_LTS =
            "Update PocketIDE: once an update brings the next Ubuntu, set up the connection again to move to it."
        private const val FIX_SET_UP_AGAIN = "Tap Set up. Your Cloud Shell is not touched."
    }
}
