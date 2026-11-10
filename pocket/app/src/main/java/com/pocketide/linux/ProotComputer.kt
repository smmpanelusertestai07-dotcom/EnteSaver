package com.pocketide.linux

import android.content.Context
import android.os.Build
import android.os.storage.StorageManager
import com.pocketide.BuildConfig
import com.pocketide.core.Clock
import com.pocketide.core.Http
import com.pocketide.core.LogBackgroundFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * PocketIDE's connection to Cloud Shell on the phone: Ubuntu under PRoot, rooted at
 * [LinuxDirs.rootfs], with gcloud's home at /root.
 *
 * Set-up, reset, repair and updates run one at a time in the computer's own scope, so leaving a
 * screen never stops dpkg half way; the caller only stops waiting. Every program starts through
 * [ProotCommand] with an empty environment.
 *
 * [beforeFirstWrite] runs before set-up touches the disk: the start-up housekeeping that deletes
 * what older versions left, which must be finished first.
 */
internal class ProotComputer(
    private val context: Context,
    private val dirs: LinuxDirs,
    private val clock: Clock,
    private val beforeFirstWrite: suspend () -> Unit = {},
) : Computer {
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.IO + LogBackgroundFailure)
    private val oneAtATime = Mutex()
    private val nativeLibraries = File(context.applicationInfo.nativeLibraryDir)
    private val host = ProotHost(nativeLibraries, dirs.prootTmp)
    private val variablesDir = File(dirs.prootTmp, VARIABLES_DIR)
    private val table = ProcTable()
    private val processes = ProcessKeeper(
        signals = { pid, signal -> android.os.Process.sendSignal(pid, signal) },
        table = table,
        scope = work,
    )
    private val dns = PhoneDns(context)
    private val cores = CpuFacts.cores(readHostFile("/sys/devices/system/cpu/possible"))
        ?: Runtime.getRuntime().availableProcessors()
    private val standIns = ProcStandIns(dirs.procFakes, cores)

    override val arch: Arch? = Arch.of(nativeLibraries)?.takeIf { host.proot.isFile && host.loader.isFile }

    /** New programs may not start while this holds a reason (a rebuild, or a code-server switch). */
    private val gate = ReentrantReadWriteLock()
    private var closedBecause: String? = null

    private val storage = context.getSystemService(StorageManager::class.java)

    private val phone = object : SetupHost {
        override fun dnsServers(): List<InetAddress> = dns.servers()

        // What can be written, cached files Android would clear for it included.
        override fun freeBytes(): Long = storageUuid()?.let { runCatching { storage.getAllocatableBytes(it) }.getOrNull() }
            ?: dirs.base.parentFile?.freeSpace
            ?: 0

        // Has Android clear those cached files now, before the downloads need the room.
        override fun makeRoom(bytes: Long) {
            storageUuid()?.let { uuid -> runCatching { storage.allocateBytes(uuid, bytes) } }
        }
    }

    private fun storageUuid(): UUID? = runCatching { storage.getUuidForPath(context.filesDir) }.getOrNull()

    private val mutableState = MutableStateFlow<ComputerState>(ComputerState.NotInstalled)
    override val state: StateFlow<ComputerState> = mutableState.asStateFlow()

    private val setup: ComputerSetup? = arch?.let { arch ->
        ComputerSetup(
            places = SetupPlaces(rootfs = dirs.rootfs, downloads = dirs.downloads, record = dirs.record),
            host = phone,
            fetcher = Downloader(Http.downloads),
            runner = { root, argv, onLine -> drain(launch(root, LinuxCommand(argv)), true, onLine, processes::stop) },
            assets = AndroidLinuxAssets(context.assets),
            clock = clock,
            publish = { mutableState.value = it },
            arch = arch,
            appVersion = BuildConfig.VERSION_NAME,
        )
    }

    private val sizes = SizeCache()

    init {
        mutableState.value = setup?.stateOnDisk() ?: ComputerState.Broken(
            "This phone's processor is not one PocketIDE's connection runs on.",
            "PocketIDE needs a 64-bit ARM phone (arm64-v8a).",
        )
        // Variables files a killed app could not delete.
        variablesDir.listFiles()?.forEach { it.delete() }
        // A long set-up or a day of work crosses from Wi-Fi to mobile data; Linux follows.
        dns.watch { servers -> runCatching { GuestConfig.writeResolver(GuestRoot(dirs.rootfs), servers) } }
    }

    override suspend fun install() {
        val setup = setup ?: return
        exclusively {
            beforeFirstWrite()
            Files.createDirectories(dirs.home.toPath())
            setup.install()
        }
    }

    override suspend fun reset() {
        val setup = setup ?: return
        exclusively {
            close("PocketIDE's connection is being rebuilt.")
            try {
                processes.stopAllAndWait()
                mutableState.value = ComputerState.Installing("Removing the old Ubuntu…", null, 0, 0)
                if (removeQuietly(setup) == null) setup.install()
            } finally {
                reopen()
            }
        }
    }

    override suspend fun remove() {
        exclusively {
            close("PocketIDE's connection is being deleted.")
            try {
                processes.stopAllAndWait()
                setup?.let { removeQuietly(it) }
                Trees.discard(dirs.home)
                Trees.sweep(dirs.home)
                Trees.delete(dirs.prootTmp.toPath())
                Trees.delete(dirs.procFakes.toPath())
            } finally {
                reopen()
            }
        }
    }

    override suspend fun stopAll() = processes.stopAllAndWait()

    override suspend fun repair(): List<RepairItem> {
        val setup = setup ?: return emptyList()
        return exclusively { hostItems() + setup.repair() }
    }

    override fun start(command: LinuxCommand): Process = gate.read {
        closedBecause?.let { throw IllegalStateException(it) }
        val current = state.value
        check(current is ComputerState.Ready || current is ComputerState.Updating) { "PocketIDE's connection is not set up yet." }
        runCatching { GuestConfig.writeBasics(GuestRoot(dirs.rootfs), onlyMissing = true) }
        if (!command.asRoot) {
            val uid = android.os.Process.myUid()
            runCatching { GuestConfig.ensureUser(GuestRoot(dirs.rootfs), uid, uid) }
        }
        launch(dirs.rootfs, command)
    }

    override suspend fun run(command: LinuxCommand, onLine: (String) -> Unit): Int {
        val process = withContext(Dispatchers.IO) { start(command) }
        return drain(process, command.mergeErrors, onLine, processes::stop)
    }

    override fun stop(process: Process) = processes.stop(process)

    override suspend fun reinstallGcloud(): Boolean {
        val setup = setup ?: return false
        return exclusively { setup.reinstallGcloud(BuildConfig.VERSION_NAME) }
    }

    override suspend fun holdGcloudUpdates() {
        val setup = setup ?: return
        exclusively { setup.holdGcloudUpdates(BuildConfig.VERSION_NAME) }
    }

    override suspend fun updateBase(): UpdateOutcome {
        val setup = setup ?: return UpdateOutcome.Waiting(NOT_SUPPORTED)
        return exclusively { setup.updateBase() }
    }

    override fun liveProcesses(): Int = table.countOwnedBy(android.os.Process.myUid(), android.os.Process.myPid())

    override suspend fun info(): ComputerInfo = withContext(Dispatchers.IO) {
        val guest = GuestRoot(dirs.rootfs)
        val record = setup?.record()
        ComputerInfo(
            cpu = CpuFacts.describe(readHostFile("/proc/cpuinfo"), socName()),
            cores = cores,
            android = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            ubuntu = GuestFacts.prettyName(guest.readText("/etc/os-release")),
            gcloud = guest.readText("${GcloudSlot.LINK}/VERSION")?.trim()?.ifEmpty { null },
            systemBytes = sizes.get(SYSTEM, clock.now()) { Trees.bytes(dirs.rootfs.toPath()) },
            homeBytes = sizes.get(HOME, clock.now()) { Trees.bytes(dirs.home.toPath()) },
            freeBytes = phone.freeBytes(),
            updatedAt = record?.updatedAt,
        )
    }

    /** Starts PRoot on [root]; the programs of set-up use the rootfs being built. */
    private fun launch(root: File, command: LinuxCommand): Process {
        val binds = standardBinds(command) + command.binds
        for (bind in binds) {
            if (!File(bind.hostPath).exists()) throw IOException("A folder this command needs is missing: ${bind.guestPath}")
        }
        Files.createDirectories(host.tmpDir.toPath())
        // Android gives a container no resolver; the phone's servers of the moment are written each time.
        runCatching { GuestConfig.writeResolver(GuestRoot(root), dns.servers()) }
        val withBinds = command.copy(binds = binds)
        val variables = withBinds.env.takeIf { it.isNotEmpty() }?.let { writeVariables(withBinds) }
        try {
            // Every program shares the computer's own /tmp as its /dev/shm.
            val shm = File(root, "tmp").takeIf { it.isDirectory }
            val call = ProotCommand.build(host, root, standIns.binds(), TimeZone.getDefault().id, withBinds, variables, shm)
            val builder = ProcessBuilder(call.argv).redirectErrorStream(command.mergeErrors)
            builder.environment().run {
                clear()
                putAll(call.environment)
            }
            return builder.start().also(processes::track)
        } finally {
            // launch.pl deletes the file once it has read it; this catches a start that failed first.
            variables?.let { file -> work.launch { delay(VARIABLES_LIFETIME_MS); file.delete() } }
        }
    }

    /** The owner's home at /root, for every program, unless the command brings its own. */
    private fun standardBinds(command: LinuxCommand): List<Bind> {
        if (command.binds.any { it.guestPath == LinuxDirs.GUEST_HOME }) return emptyList()
        Files.createDirectories(dirs.home.toPath())
        return listOf(Bind(dirs.home.absolutePath, LinuxDirs.GUEST_HOME))
    }

    /** The command's variables, in a file only the app can read, under a name no one can guess. */
    private fun writeVariables(command: LinuxCommand): File {
        Files.createDirectories(variablesDir.toPath())
        val file = File(variablesDir, UUID.randomUUID().toString())
        val path = Files.createFile(file.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        Files.write(path, ProotCommand.variables(command))
        return file
    }

    private suspend fun removeQuietly(setup: ComputerSetup): ComputerState.Broken? = try {
        setup.remove()
        null
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: IOException) {
        ComputerState.Broken("The old Ubuntu could not be deleted completely.", "Restart the phone, then set up the connection again.")
            .also { mutableState.value = it }
    }

    /** The parts of a repair that live outside Linux. */
    private fun hostItems(): List<RepairItem> = buildList {
        add(
            if (host.proot.isFile && host.loader.isFile) {
                RepairItem("PRoot", RepairStatus.OK, "Present in the app.")
            } else {
                RepairItem("PRoot", RepairStatus.WARN, "Missing from the app. Install PocketIDE again from its release page.")
            },
        )
        val free = phone.freeBytes()
        add(
            if (free >= LOW_SPACE) {
                RepairItem("Free space", RepairStatus.OK, "${free / BYTES_PER_GB} GB free.")
            } else {
                RepairItem("Free space", RepairStatus.WARN, "Only ${free / BYTES_PER_MB} MB free. Free some space on the phone.")
            },
        )
        val standing = runCatching { standIns.binds().keys }.getOrDefault(emptySet())
        if (standing.isNotEmpty()) {
            add(RepairItem("Hidden system files", RepairStatus.NOTE, "Android hides ${standing.joinToString()}; Linux sees placeholders."))
        }
    }

    private fun socName(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL)
            .filter { it.isNotBlank() && it != Build.UNKNOWN }
            .joinToString(" ")
            .ifBlank { null }
    }

    /** Runs [block] after any other set-up, reset or update, in the computer's own scope. */
    private suspend fun <T> exclusively(block: suspend () -> T): T {
        val result = work.async { oneAtATime.withLock { block() } }.await()
        sizes.forget()
        return result
    }

    private fun close(reason: String) = gate.write { closedBecause = reason }

    private fun reopen() = gate.write { closedBecause = null }

    /** Sizes walk every file, so each is measured at most once a minute. */
    private class SizeCache {
        private val measured = HashMap<String, Pair<Long, Long>>()

        @Synchronized
        fun get(what: String, now: Long, measure: () -> Long): Long {
            measured[what]?.let { (at, bytes) -> if (now - at in 0 until FRESH_MS) return bytes }
            return measure().also { measured[what] = now to it }
        }

        @Synchronized
        fun forget() = measured.clear()

        private companion object {
            const val FRESH_MS = 60_000L
        }
    }

    private companion object {
        const val VARIABLES_DIR = "variables"
        const val VARIABLES_LIFETIME_MS = 60_000L
        const val LOW_SPACE = 2_000_000_000L
        const val BYTES_PER_GB = 1_000_000_000L
        const val BYTES_PER_MB = 1_000_000L
        const val SYSTEM = "system"
        const val HOME = "home"
        const val NOT_SUPPORTED = "This phone's processor is not supported."

        fun readHostFile(path: String): String? = runCatching { File(path).readText() }.getOrNull()
    }
}
