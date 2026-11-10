package com.pocketide.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ProotCommandTest {
    private val host = ProotHost(File("/data/app/pocketide/lib/arm64"), File("/data/data/pocketide/files/proot-tmp"))
    private val root = File("/data/data/pocketide/files/rootfs")
    private val standIns = linkedMapOf(
        "/proc/loadavg" to "/data/data/pocketide/files/proc-fakes/loadavg",
        "/proc/stat" to "/data/data/pocketide/files/proc-fakes/stat",
    )

    private fun build(command: LinuxCommand, variables: File? = null) =
        ProotCommand.build(host, root, standIns, "Asia/Kolkata", command, variables)

    @Test
    fun `a command as the app's own user runs without PRoot's faked root`() {
        val argv = build(LinuxCommand(listOf("/usr/bin/ssh", "-O", "check", "x"), asRoot = false)).argv
        assertFalse(argv.contains("-0"))
        assertTrue(build(LinuxCommand(listOf("/usr/bin/ssh"))).argv.contains("-0"))
    }

    @Test
    fun goldenCommandLine() {
        val command = LinuxCommand(
            argv = listOf("git", "status"),
            binds = listOf(
                Bind("/data/data/pocketide/files/rooms/claude/home", "/root"),
                Bind("/data/data/pocketide/files/repos", "/repos"),
            ),
            workDir = "/work/demo",
        )
        assertEquals(
            listOf(
                "/data/app/pocketide/lib/arm64/libproot.so", "--link2symlink", "--kill-on-exit", "-0",
                "-r", "/data/data/pocketide/files/rootfs",
                "-b", "/dev", "-b", "/proc", "-b", "/sys",
                "-b", "/data/data/pocketide/files/proc-fakes/loadavg:/proc/loadavg",
                "-b", "/data/data/pocketide/files/proc-fakes/stat:/proc/stat",
                "-b", "/data/data/pocketide/files/rooms/claude/home:/root",
                "-b", "/data/data/pocketide/files/repos:/repos",
                "-w", "/work/demo",
                "/usr/bin/env", "-i",
                "HOME=/root", "USER=root", "LOGNAME=root", "SHELL=/bin/bash",
                "PATH=${ProotCommand.GUEST_PATH}", "TERM=xterm-256color", "LANG=C.UTF-8", "TZ=Asia/Kolkata", "TMPDIR=/tmp",
                "git", "status",
            ),
            build(command).argv,
        )
    }

    @Test
    fun aCommandWithoutItsOwnSharedMemoryGetsTheDefaultRightAfterTheSystemFolders() {
        val argv = ProotCommand.build(
            host, root, standIns, "UTC", LinuxCommand(listOf("python3")), sharedMemory = File(root, "tmp"),
        ).argv
        val at = argv.indexOf("${root.path}/tmp:/dev/shm")
        assertEquals("-b", argv[at - 1])
        assertEquals("/sys", argv[at - 2])
    }

    @Test
    fun aCommandsOwnSharedMemoryWins() {
        val command = LinuxCommand(listOf("python3"), binds = listOf(Bind("/data/data/pocketide/files/rooms/claude/shm", "/dev/shm")))
        val argv = ProotCommand.build(host, root, standIns, "UTC", command, sharedMemory = File(root, "tmp")).argv
        assertEquals(listOf("/data/data/pocketide/files/rooms/claude/shm:/dev/shm"), argv.filter { it.endsWith(":/dev/shm") })
    }

    @Test
    fun prootGetsOnlyItsOwnEnvironment() {
        assertEquals(
            mapOf(
                "PROOT_TMP_DIR" to "/data/data/pocketide/files/proot-tmp",
                "PROOT_LOADER" to "/data/app/pocketide/lib/arm64/libproot-loader.so",
                "PROOT_NO_SECCOMP" to "1",
                "PROOT_NO_MOUNTINFO" to "1",
                "LD_LIBRARY_PATH" to "/data/app/pocketide/lib/arm64",
            ),
            build(LinuxCommand(listOf("true"))).environment,
        )
    }

    @Test
    fun nothingFromTheAppsOwnEnvironmentReachesLinux() {
        val argv = build(LinuxCommand(listOf("env"))).argv
        val guestWords = argv.subList(argv.indexOf("-i") + 1, argv.size)
        val basics = setOf("HOME", "USER", "LOGNAME", "SHELL", "PATH", "TERM", "LANG", "TZ", "TMPDIR")
        for ((name, value) in System.getenv()) {
            if (name in basics) continue
            assertFalse("$name leaked", guestWords.any { it == "$name=$value" })
        }
        assertTrue(guestWords.none { it.startsWith("PROOT_") || it.startsWith("LD_") || it.startsWith("ANDROID_") })
    }

    @Test
    fun theStandInsComeAfterProcAndBeforeTheCommandsFolders() {
        val argv = build(LinuxCommand(listOf("true"), binds = listOf(Bind("/host/proc-like", "/proc/cpuinfo")))).argv
        val binds = argv.withIndex().filter { it.index > 0 && argv[it.index - 1] == "-b" }.map { it.value }
        assertEquals(
            listOf(
                "/dev", "/proc", "/sys",
                "/data/data/pocketide/files/proc-fakes/loadavg:/proc/loadavg",
                "/data/data/pocketide/files/proc-fakes/stat:/proc/stat",
                "/host/proc-like:/proc/cpuinfo",
            ),
            binds,
        )
    }

    @Test
    fun variablesTravelInAFileNeverOnTheCommandLine() {
        val file = File("/data/data/pocketide/files/proot-tmp/variables/1234")
        val command = LinuxCommand(
            listOf("code-server", "--bind-addr", "127.0.0.1:41234"),
            binds = listOf(Bind("/data/data/pocketide/files/rooms/claude/home", "/root")),
            env = mapOf("PASSWORD" to "per-launch-secret", "GIT_AUTHOR_NAME" to "Asha", "PATH" to "/custom/bin"),
        )
        val argv = build(command, file).argv
        assertTrue(argv.none { it.contains("per-launch-secret") || it.contains("Asha") || it.contains("/custom/bin") })
        val tail = argv.subList(argv.indexOf("TMPDIR=/tmp") + 1, argv.size)
        assertEquals(
            listOf("/usr/bin/perl", ProotCommand.LAUNCHER, ProotCommand.GUEST_VARIABLES, "code-server", "--bind-addr", "127.0.0.1:41234"),
            tail,
        )
        // Bound after the command's own folders, so no folder of the command can cover it.
        val lastBind = argv.lastIndexOf("-b")
        assertEquals("${file.absolutePath}:${ProotCommand.GUEST_VARIABLES}", argv[lastBind + 1])
        assertEquals(
            "GIT_AUTHOR_NAME=Asha\u0000PASSWORD=per-launch-secret\u0000PATH=/custom/bin\u0000",
            ProotCommand.variables(command).toString(Charsets.UTF_8),
        )
    }

    @Test
    fun aVariableRepeatingABasicReplacesIt() {
        val environment = ProotCommand.environment("UTC", mapOf("HOME" to "/root/work", "ZED" to "1"))
        assertEquals("/root/work", environment["HOME"])
        assertEquals("1", environment["ZED"])
        assertEquals("UTC", environment["TZ"])
    }

    @Test
    fun theVariablesFileGoesWithVariablesOnly() {
        assertThrows(IllegalArgumentException::class.java) { build(LinuxCommand(listOf("true"), env = mapOf("A" to "1"))) }
        assertThrows(IllegalArgumentException::class.java) { build(LinuxCommand(listOf("true")), File("/tmp/v")) }
    }

    @Test
    fun refusesWhatCouldBreakOutOfTheCommandLine() {
        val refused = listOf(
            LinuxCommand(emptyList()),
            LinuxCommand(listOf("")),
            LinuxCommand(listOf("-u")),
            LinuxCommand(listOf("A=1")),
            LinuxCommand(listOf("ls", "a\u0000b")),
            LinuxCommand(listOf("ls"), workDir = "relative"),
            LinuxCommand(listOf("ls"), workDir = "/work/../etc"),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host", "/guest", readOnly = true))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host:/etc", "/guest"))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host", "/guest:x"))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("relative", "/guest"))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host", "/"))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host", "/root/../etc"))),
            LinuxCommand(listOf("ls"), binds = listOf(Bind("/host", ProotCommand.GUEST_VARIABLES))),
        )
        for (command in refused) {
            assertThrows(command.toString(), IllegalArgumentException::class.java) { build(command) }
        }
        for (name in listOf("lower", "1A", "A-B", "A B", "", "Ä")) {
            val command = LinuxCommand(listOf("ls"), env = mapOf(name to "x"))
            assertThrows(name, IllegalArgumentException::class.java) { build(command, File("/tmp/v")) }
        }
        val nul = LinuxCommand(listOf("ls"), env = mapOf("A" to "x\u0000y"))
        assertThrows(IllegalArgumentException::class.java) { build(nul, File("/tmp/v")) }
    }

    @Test
    fun acceptsOrdinaryNames() {
        for (name in listOf("A", "_", "GIT_DIR", "X1", "_PRIVATE_2")) {
            build(LinuxCommand(listOf("ls"), env = mapOf(name to "value with spaces\nand lines")), File("/tmp/v"))
        }
    }
}
