package com.pocketide.linux

import java.io.File

/** Where proot and its loader are installed, and where proot keeps its own temporary files. */
internal class ProotHost(val nativeLibraryDir: File, val tmpDir: File) {
    val proot: File get() = File(nativeLibraryDir, "libproot.so")
    val loader: File get() = File(nativeLibraryDir, "libproot-loader.so")
}

/** One proot run, ready for ProcessBuilder: its arguments and its whole environment. */
internal data class ProotCall(val argv: List<String>, val environment: Map<String, String>)

/**
 * Builds the PRoot command line. The flags are PocketIDE 2.6.0's, each proven on a real phone:
 *  - `--link2symlink`: Android refuses hard links in app storage, and dpkg relies on them.
 *  - `--kill-on-exit`: nothing keeps running untraced after the command ends.
 *  - `-0`: packages expect root; proot fakes it (except for a command that runs as the app's own
 *    user, [LinuxCommand.asRoot]).
 *  - /dev, /proc and /sys come from the phone, then stand-ins for the /proc files Android hides
 *    (they must come after /proc to win), then the command's own folders.
 *  - /dev/shm: Android has none, and glibc keeps POSIX semaphores and shared memory there, so a
 *    writable folder is always bound over it: the command's own when it binds one,
 *    else [sharedMemory].
 *
 * The program runs under `env -i` with a fixed set of basics, so nothing of Android's
 * environment (and nothing secret the app holds) reaches Linux. The command's own variables
 * stay off the command line, where any process could read them in /proc/<pid>/cmdline: they
 * travel in a private file bound in for this one run, which launch.pl reads, deletes and turns
 * into the program's environment.
 */
internal object ProotCommand {
    /** The owner's own tools first (~/.local/bin, where pipx and official installers put them), then PocketIDE's commands. */
    const val GUEST_PATH = "/root/.local/bin:/opt/pocketide/bin:/opt/code-server/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /** Where a command's variables file appears inside Linux, and the script that reads it. */
    const val GUEST_VARIABLES = "/run/pocketide-variables"
    const val LAUNCHER = "/opt/pocketide/launch.pl"
    const val GUEST_SHM = "/dev/shm"

    private val VARIABLE_NAME = Regex("[A-Z_][A-Z0-9_]*")

    /**
     * [variablesFile] holds [variables] of [command]; it is given exactly when the command has variables.
     * [sharedMemory] is the /dev/shm of a command that binds none of its own.
     */
    fun build(
        host: ProotHost,
        root: File,
        procStandIns: Map<String, String>,
        timeZone: String,
        command: LinuxCommand,
        variablesFile: File? = null,
        sharedMemory: File? = null,
    ): ProotCall {
        validate(command)
        require((variablesFile != null) == command.env.isNotEmpty()) { "A variables file goes with variables, and only with them." }
        require(variablesFile == null || !variablesFile.absolutePath.contains(':')) { "Not a usable file: $variablesFile" }
        require(sharedMemory == null || !sharedMemory.absolutePath.contains(':')) { "Not a usable folder: $sharedMemory" }
        val defaultShm = sharedMemory?.takeIf { command.binds.none { it.guestPath == GUEST_SHM } }
        val argv = buildList {
            add(host.proot.absolutePath)
            add("--link2symlink")
            add("--kill-on-exit")
            if (command.asRoot) add("-0")
            add("-r")
            add(root.absolutePath)
            for (system in listOf("/dev", "/proc", "/sys")) {
                add("-b")
                add(system)
            }
            if (defaultShm != null) {
                add("-b")
                add("${defaultShm.absolutePath}:$GUEST_SHM")
            }
            for ((guest, file) in procStandIns) {
                add("-b")
                add("$file:$guest")
            }
            for (bind in command.binds) {
                add("-b")
                add("${bind.hostPath}:${bind.guestPath}")
            }
            if (variablesFile != null) {
                add("-b")
                add("${variablesFile.absolutePath}:$GUEST_VARIABLES")
            }
            add("-w")
            add(command.workDir)
            add("/usr/bin/env")
            add("-i")
            basics(timeZone).forEach { (name, value) -> add("$name=$value") }
            if (variablesFile != null) {
                add("/usr/bin/perl")
                add(LAUNCHER)
                add(GUEST_VARIABLES)
            }
            addAll(command.argv)
        }
        return ProotCall(argv, prootEnvironment(host))
    }

    /**
     * The variables file: "NAME=value" pairs sorted by name, each ended by a NUL, so a value may
     * hold any other character, newlines included. launch.pl sets them over the basics, so a
     * name that repeats a basic replaces it.
     */
    fun variables(command: LinuxCommand): ByteArray = buildString {
        command.env.toSortedMap().forEach { (name, value) -> append(name).append('=').append(value).append('\u0000') }
    }.toByteArray(Charsets.UTF_8)

    /** The environment the program starts with: the basics, then the command's variables. */
    fun environment(timeZone: String, variables: Map<String, String>): Map<String, String> =
        basics(timeZone).apply { variables.toSortedMap().forEach { (name, value) -> put(name, value) } }

    private fun basics(timeZone: String) = linkedMapOf(
        "HOME" to "/root",
        "USER" to "root",
        "LOGNAME" to "root",
        "SHELL" to "/bin/bash",
        "PATH" to GUEST_PATH,
        "TERM" to "xterm-256color",
        "LANG" to "C.UTF-8",
        "TZ" to timeZone,
        "TMPDIR" to "/tmp",
    )

    /** proot's own environment: exactly this, never the app's. */
    private fun prootEnvironment(host: ProotHost) = linkedMapOf(
        "PROOT_TMP_DIR" to host.tmpDir.absolutePath,
        "PROOT_LOADER" to host.loader.absolutePath,
        // Slower without the seccomp accelerator, but it always starts, and a failed start
        // costs far more than the speed. 2.6.0 also ran every phone without the mountinfo rewrite.
        "PROOT_NO_SECCOMP" to "1",
        "PROOT_NO_MOUNTINFO" to "1",
        "LD_LIBRARY_PATH" to host.nativeLibraryDir.absolutePath,
    )

    private fun validate(command: LinuxCommand) {
        val program = command.argv.firstOrNull()
        require(!program.isNullOrBlank()) { "A command needs a program to run." }
        // env would read a first word with "=" as a variable, and one starting with "-" as an option.
        require(!program.startsWith("-") && !program.contains('=')) { "Not a program name: $program" }
        require(command.argv.none { it.contains('\u0000') }) { "A command argument contains a NUL character." }
        require(isGuestPath(command.workDir)) { "The working folder must be an absolute path: ${command.workDir}" }
        for ((name, value) in command.env) {
            require(VARIABLE_NAME.matches(name)) { "Not a variable name: $name" }
            require(!value.contains('\u0000')) { "The value of $name contains a NUL character." }
        }
        for (bind in command.binds) {
            require(!bind.readOnly) { "proot cannot make ${bind.guestPath} read-only." }
            // proot splits "-b host:guest" at the first colon.
            require(isGuestPath(bind.hostPath) && !bind.hostPath.contains(':')) { "Not a usable folder: ${bind.hostPath}" }
            require(isGuestPath(bind.guestPath) && !bind.guestPath.contains(':')) { "Not a usable Linux path: ${bind.guestPath}" }
            require(GuestRoot.components(bind.guestPath).isNotEmpty()) { "A folder cannot replace the whole of Linux." }
            require(bind.guestPath != GUEST_VARIABLES) { "$GUEST_VARIABLES is kept for the command's variables." }
        }
    }

    private fun isGuestPath(path: String) =
        path.startsWith("/") && !path.contains('\u0000') && GuestRoot.components(path).none { it == ".." }
}
