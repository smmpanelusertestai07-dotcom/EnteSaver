package com.pocketide.linux

import kotlinx.coroutines.flow.StateFlow

/** The Linux computer's life cycle, as the screens show it. */
sealed interface ComputerState {
    data object NotInstalled : ComputerState

    /** [step] is a short sentence; [fraction] is 0..1 or null when unknown. */
    data class Installing(val step: String, val fraction: Float?, val bytesDone: Long, val bytesTotal: Long) : ComputerState

    data object Ready : ComputerState

    data class Updating(val what: String) : ComputerState

    /** Something is wrong; [fix] says what the owner can do, in their words. */
    data class Broken(val why: String, val fix: String) : ComputerState
}

/**
 * A directory made visible inside one PRoot session.
 *
 * PRoot has no read-only binds, so [readOnly] cannot be honoured: a command that asks for one is
 * refused rather than started with a folder it could write to after all.
 */
data class Bind(val hostPath: String, val guestPath: String, val readOnly: Boolean = false)

/**
 * One program to run inside Linux. The environment is exactly [env] plus the fixed basics (HOME,
 * USER, LOGNAME, SHELL, PATH, TERM, LANG, TZ, TMPDIR): PRoot runs `env -i`, so nothing from
 * Android leaks in. [env] names must look like `[A-Z_][A-Z0-9_]*`; a name that repeats a basic
 * replaces it. [env] never appears on a command line (other processes can read those): it reaches
 * the program through a private file that is deleted once read. [argv] is visible to every process
 * inside Linux, so a secret belongs in [env] or in a file, never there.
 */
data class LinuxCommand(
    val argv: List<String>,
    val binds: List<Bind> = emptyList(),
    val env: Map<String, String> = emptyMap(),
    val workDir: String = LinuxDirs.GUEST_HOME,
    /** Merge stderr into stdout. */
    val mergeErrors: Boolean = true,
    /**
     * As PRoot's faked root (what packages expect). False runs it as the app's own Linux user,
     * which ssh's shared connection needs: its control socket admits only a client with the same
     * user id as its own, and a faked root id is only known inside one PRoot run.
     */
    val asRoot: Boolean = true,
)

/** What the Computer screen shows. */
data class ComputerInfo(
    val cpu: String,
    val cores: Int,
    val android: String,
    val ubuntu: String?,
    val gcloud: String?,
    /** Ubuntu, Python, OpenSSH and gcloud; Reset rebuilds all of it. */
    val systemBytes: Long,
    /** The connection's home: gcloud's sign-in and settings; Reset keeps it. */
    val homeBytes: Long,
    val freeBytes: Long,
    /** When Ubuntu's updates last finished (UTC epoch ms), or null. */
    val updatedAt: Long?,
)

/** What an update of one part of the computer did, in words the owner can read. */
sealed interface UpdateOutcome {
    data object UpToDate : UpdateOutcome
    data class Updated(val detail: String) : UpdateOutcome

    /** Not now (no connection, not set up yet); it is tried again later. */
    data class Waiting(val why: String) : UpdateOutcome
    data class Failed(val why: String) : UpdateOutcome
}

/** How one item of a Repair turned out. */
enum class RepairStatus {
    /** Already right; nothing changed. */
    OK,

    /** Was missing or broken, and is now in place. */
    NEW,

    /** Could not be put right; [RepairItem.detail] says what to do. */
    WARN,

    /** Worth knowing; nothing to do. */
    NOTE,
}

/** One line of the Repair report. */
data class RepairItem(val what: String, val status: RepairStatus, val detail: String)

/** What "Reset" deletes and what it keeps, in the words of its confirm sheet. */
data class ResetPlan(val removes: List<String>, val keeps: List<String>) {
    companion object {
        val STANDARD = ResetPlan(
            removes = listOf(
                "Ubuntu, Python, OpenSSH and Google's gcloud on this phone",
                "Downloads kept for set-up",
            ),
            keeps = listOf(
                "gcloud's sign-in on this phone",
                "Everything in your Cloud Shell: projects, agents, their sign-ins and chats",
            ),
        )
    }
}

/**
 * PocketIDE's connection to Cloud Shell, inside the app: Ubuntu under PRoot (no root, no virtual
 * machine) with Python, OpenSSH and Google's gcloud. Pinned, checksum-verified downloads; rebuilt
 * identically by [reset]; an empty environment every time. The agents do not run here.
 */
interface Computer {
    val state: StateFlow<ComputerState>

    /** The processor the computer is built for; null when this APK carries no PRoot for this phone. */
    val arch: Arch?

    /** Sets up what is missing (about 130 MB to download): the owner starts it. */
    suspend fun install()

    /** Deletes and rebuilds Ubuntu. The home (gcloud's sign-in) is kept. */
    suspend fun reset()

    /** Deletes the whole connection, gcloud's sign-in included. */
    suspend fun remove()

    /** Starts a process inside Linux. The caller owns it and must [stop] it. */
    fun start(command: LinuxCommand): Process

    /** Runs to completion, passing each output line on; returns the exit code. */
    suspend fun run(command: LinuxCommand, onLine: (String) -> Unit = {}): Int

    /** Ends a PRoot and everything it traces (SIGQUIT, then kill). */
    fun stop(process: Process)

    /** Ends every Linux program and waits for them. Files and gcloud's sign-in stay. */
    suspend fun stopAll()

    suspend fun info(): ComputerInfo

    /** Ubuntu's updates (security fixes included), a set-up script an app update changed, and gcloud's own updater. */
    suspend fun updateBase(): UpdateOutcome

    /**
     * gcloud again from the version this app pins, after an update of gcloud PocketIDE cannot use;
     * gcloud's own updates then wait for the next app version. True when it starts.
     */
    suspend fun reinstallGcloud(): Boolean

    /** gcloud's own updates wait for the next app version: its last update changed what PocketIDE needs, and was undone. */
    suspend fun holdGcloudUpdates()

    /** The set-up again, safe to repeat: installs what is missing and reports each item. */
    suspend fun repair(): List<RepairItem>

    /** Linux processes this app runs right now (PRoot and everything under it). */
    fun liveProcesses(): Int

    fun resetPlan(): ResetPlan = ResetPlan.STANDARD
}
