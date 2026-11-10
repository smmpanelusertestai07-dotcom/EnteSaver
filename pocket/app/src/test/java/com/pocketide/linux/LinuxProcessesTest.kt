package com.pocketide.linux

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.TimeUnit

class LinuxProcessesTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @After
    fun tearDown() = scope.cancel()

    /** A /proc with the given processes: pid to (parent, uid, name). */
    private fun proc(vararg processes: Triple<Int, Int, Pair<Int, String>>): File {
        val proc = temp.newFolder("proc")
        for ((pid, parent, owner) in processes) {
            val (uid, name) = owner
            val dir = File(proc, pid.toString()).apply { mkdirs() }
            File(dir, "stat").writeText("$pid ($name) S $parent 1 1 0 -1\n")
            File(dir, "status").writeText("Name:\t$name\nUid:\t$uid\t$uid\t$uid\t$uid\n")
        }
        File(proc, "self").mkdirs()
        File(proc, "meminfo").writeText("MemTotal: 1 kB\n")
        return proc
    }

    @Test
    fun descendantsComeBeforeTheirParents() {
        val table = ProcTable(
            proc(
                Triple(100, 1, 10_123 to "app"),
                Triple(200, 100, 10_123 to "libproot.so"),
                Triple(300, 200, 10_123 to "node"),
                Triple(301, 300, 10_123 to "bash (weird) name"),
                Triple(400, 100, 10_123 to "libproot.so"),
                Triple(500, 1, 1000 to "system"),
            ),
        )
        assertEquals(listOf(301, 300), table.descendants(200))
        val all = table.descendants(100)
        assertEquals(setOf(200, 300, 301, 400), all.toSet())
        assertTrue(all.indexOf(301) < all.indexOf(300) && all.indexOf(300) < all.indexOf(200))
        assertEquals(4, table.countOwnedBy(10_123, selfPid = 100))
    }

    @Test
    fun stopSendsSigquitAndEndsWhatIsLeftAfterTheGracePeriod() {
        val signals = mutableListOf<Pair<Int, Int>>()
        val keeper = ProcessKeeper({ pid, signal -> signals += pid to signal }, ProcTable(temp.newFolder("empty")), scope, graceMs = 100)
        // SIGQUIT here is only recorded, so the program is still running when the grace period ends.
        val process = ProcessBuilder("sleep", "30").start()
        keeper.track(process)
        assertEquals(1, keeper.running())
        val pid = ProcessKeeper.pidOf(process)
        keeper.stop(process)
        assertEquals(listOf(pid to Signals.SIGQUIT), signals)
        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(0, keeper.running())
    }

    @Test
    fun stopAllAndWaitReturnsOnceEverythingEnded() {
        val keeper = ProcessKeeper(
            signals = { pid, signal -> ProcessBuilder("kill", "-$signal", pid.toString()).start().waitFor() },
            table = ProcTable(),
            scope = scope,
            graceMs = 2_000,
        )
        val first = ProcessBuilder("sleep", "30").start().also(keeper::track)
        val second = ProcessBuilder("sleep", "30").start().also(keeper::track)
        assertEquals(1, keeper.count(first))
        runBlocking { keeper.stopAllAndWait() }
        assertFalse(first.isAlive)
        assertFalse(second.isAlive)
        assertEquals(0, keeper.count(first))
    }

    @Test
    fun countIncludesChildren() {
        val keeper = ProcessKeeper({ _, _ -> }, ProcTable(), scope)
        val shell = ProcessBuilder("sh", "-c", "sleep 30 & sleep 30 & wait").start()
        keeper.track(shell)
        try {
            val deadline = System.currentTimeMillis() + 5_000
            while (keeper.count(shell) < 3 && System.currentTimeMillis() < deadline) Thread.sleep(50)
            assertEquals(3, keeper.count(shell))
        } finally {
            ProcTable().descendants(ProcessKeeper.pidOf(shell) ?: 0).forEach { ProcessBuilder("kill", "-9", it.toString()).start().waitFor() }
            shell.destroyForcibly()
        }
    }

    @Test
    fun drainPassesEveryLineAndTheExitCode() {
        val lines = mutableListOf<String>()
        val code = runBlocking {
            drain(ProcessBuilder("sh", "-c", "echo one; echo two >&2; exit 3").redirectErrorStream(true).start(), true, { lines += it }, { it.destroy() })
        }
        assertEquals(3, code)
        assertEquals(listOf("one", "two"), lines)
    }
}
