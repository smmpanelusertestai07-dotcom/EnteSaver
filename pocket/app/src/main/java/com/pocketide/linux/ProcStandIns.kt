package com.pocketide.linux

import java.io.File
import java.io.FileInputStream
import java.io.IOException

/**
 * Stand-ins for the few /proc files Android hides from apps but ordinary Linux programs read
 * (Node, Python and top among them). This is what proot-distro does too.
 *
 * Each path is checked on the phone at every start and gets a stand-in only when it really
 * cannot be read, so a phone that allows the real file keeps its real values. The stand-ins
 * are placeholders, never resource figures anyone should act on.
 */
internal class ProcStandIns(
    private val directory: File,
    private val cores: Int,
    private val readable: (String) -> Boolean = ::hasContents,
) {
    /** Guest path to the host file bound over it, in a stable order. */
    fun binds(): Map<String, String> {
        val binds = LinkedHashMap<String, String>()
        for ((guestPath, contents) in contents()) {
            if (readable(guestPath)) continue
            val file = File(directory, guestPath.substringAfterLast('/'))
            write(file, contents)
            binds[guestPath] = file.absolutePath
        }
        return binds
    }

    private fun write(file: File, contents: String) {
        val bytes = contents.toByteArray()
        if (file.isFile && file.length() == bytes.size.toLong() && file.readBytes().contentEquals(bytes)) return
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Could not create the /proc stand-ins folder")
        file.writeBytes(bytes)
    }

    private fun contents(): Map<String, String> {
        val cpus = cores.coerceAtLeast(1)
        val stat = buildString {
            append("cpu  100000 0 50000 900000 0 0 0 0 0 0\n")
            repeat(cpus) { append("cpu").append(it).append(" 12500 0 6250 112500 0 0 0 0 0 0\n") }
            append("intr 0\nctxt 100000\nbtime 1700000000\nprocesses 4096\n")
            append("procs_running 1\nprocs_blocked 0\nsoftirq 0\n")
        }
        val vmstat = listOf(
            "nr_free_pages", "nr_zone_inactive_anon", "nr_zone_active_anon", "nr_zone_inactive_file",
            "nr_zone_active_file", "nr_dirty", "nr_writeback", "pgpgin", "pgpgout", "pswpin", "pswpout",
            "pgfault", "pgmajfault",
        ).joinToString("") { "$it 0\n" }
        return linkedMapOf(
            "/proc/loadavg" to "0.32 0.28 0.24 1/512 4096\n",
            "/proc/uptime" to "1234.56 4321.00\n",
            "/proc/version" to "Linux version 6.2.1 (pocketide@localhost) (gcc 13.2.0) #1 SMP PREEMPT\n",
            "/proc/sys/kernel/cap_last_cap" to "40\n",
            "/proc/sys/fs/inotify/max_user_watches" to "524288\n",
            "/proc/stat" to stat,
            "/proc/vmstat" to vmstat,
        )
    }

    companion object {
        /**
         * Reads one byte: procfs reports a length of zero for readable files, and SELinux can
         * refuse the read even after an access check says yes.
         */
        fun hasContents(path: String): Boolean = try {
            FileInputStream(path).use { it.read() != -1 }
        } catch (unreadable: IOException) {
            false
        } catch (unreadable: SecurityException) {
            false
        }
    }
}
