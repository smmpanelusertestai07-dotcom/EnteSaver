package com.pocketide.linux

import com.pocketide.core.AppJson
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** The processor, in the words a phone's spec sheet uses, read from /proc/cpuinfo. */
internal object CpuFacts {
    private const val ARM = 0x41
    private const val QUALCOMM = 0x51

    /** CPU part numbers, as Linux's arch/arm64/include/asm/cputype.h names them. */
    private val armCores = mapOf(
        0xd03 to "Cortex-A53", 0xd04 to "Cortex-A35", 0xd05 to "Cortex-A55", 0xd07 to "Cortex-A57",
        0xd08 to "Cortex-A72", 0xd09 to "Cortex-A73", 0xd0a to "Cortex-A75", 0xd0b to "Cortex-A76",
        0xd0d to "Cortex-A77", 0xd41 to "Cortex-A78", 0xd44 to "Cortex-X1", 0xd46 to "Cortex-A510",
        0xd47 to "Cortex-A710", 0xd48 to "Cortex-X2", 0xd4b to "Cortex-A78C", 0xd4c to "Cortex-X1C",
        0xd4d to "Cortex-A715", 0xd4e to "Cortex-X3", 0xd80 to "Cortex-A520", 0xd81 to "Cortex-A720",
        0xd82 to "Cortex-X4", 0xd85 to "Cortex-X925", 0xd87 to "Cortex-A725", 0xd8a to "C1-Nano",
        0xd8b to "C1-Pro", 0xd8c to "C1-Ultra", 0xd90 to "C1-Premium",
    )
    private val qualcommCores = mapOf(
        0x800 to "Kryo 2xx Gold", 0x801 to "Kryo 2xx Silver", 0x802 to "Kryo 3xx Gold",
        0x803 to "Kryo 3xx Silver", 0x804 to "Kryo 4xx Gold", 0x805 to "Kryo 4xx Silver",
    )

    /**
     * "MediaTek MT6769Z · 6× Cortex-A55 + 2× Cortex-A75": the chip's name ([soc] from Android,
     * else the "Hardware" or "model name" line), then its cores by CPU part.
     */
    fun describe(cpuinfo: String?, soc: String?): String {
        val fields = cpuinfo.orEmpty().lineSequence()
            .mapNotNull { line -> line.split(':', limit = 2).takeIf { it.size == 2 }?.let { it[0].trim() to it[1].trim() } }
            .toList()
        val name = soc?.takeIf { it.isNotBlank() }
            ?: fields.firstOrNull { it.first == "Hardware" }?.second?.takeIf { it.isNotBlank() }
            ?: fields.firstOrNull { it.first == "model name" }?.second?.takeIf { it.isNotBlank() }
        val cores = coreNames(fields)
            .groupingBy { it }.eachCount()
            .map { (core, count) -> "$count× $core" }
            .joinToString(" + ")
            .ifEmpty { null }
        return listOfNotNull(name, cores).joinToString(" · ").ifEmpty { "Unknown processor" }
    }

    /** "0-7" or "0-3,6-7" from /sys/devices/system/cpu/possible, as a count. */
    fun cores(possible: String?): Int? {
        val ranges = possible?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        var count = 0
        for (range in ranges.split(',')) {
            val bounds = range.split('-').map { it.trim().toIntOrNull() ?: return null }
            count += when (bounds.size) {
                1 -> 1
                2 -> (bounds[1] - bounds[0] + 1).takeIf { it > 0 } ?: return null
                else -> return null
            }
        }
        return count.takeIf { it > 0 }
    }

    private fun coreNames(fields: List<Pair<String, String>>): List<String> {
        val names = mutableListOf<String>()
        var implementer: Int? = null
        for ((key, value) in fields) {
            when (key) {
                "CPU implementer" -> implementer = hex(value)
                "CPU part" -> {
                    val part = hex(value) ?: continue
                    val table = when (implementer) {
                        ARM -> armCores
                        QUALCOMM -> qualcommCores
                        else -> emptyMap()
                    }
                    table[part]?.let(names::add)
                }
            }
        }
        return names
    }

    private fun hex(value: String): Int? = value.removePrefix("0x").toIntOrNull(16)
}

/** Versions read from files inside Linux. */
internal object GuestFacts {
    private val VERSION = Regex("""\d+\.\d+(\.\d+)*([-+.][0-9A-Za-z.-]+)?""")

    /** PRETTY_NAME from /etc/os-release, e.g. "Ubuntu 26.04.1 LTS". */
    fun prettyName(osRelease: String?): String? = osRelease?.lineSequence()
        ?.firstOrNull { it.startsWith("PRETTY_NAME=") }
        ?.removePrefix("PRETTY_NAME=")?.trim()?.removeSurrounding("\"")
        ?.takeIf { it.isNotBlank() && it.length <= MAX_SHOWN }

    /** "version" from a package.json. */
    fun packageVersion(json: String?): String? = runCatching {
        AppJson.parseToJsonElement(json ?: return null).jsonObject["version"]?.jsonPrimitive?.contentOrNull
    }.getOrNull()?.let(::version)

    /** The version number in what a program printed, e.g. "1.2.10" from "agy 1.2.10". */
    fun version(text: String?): String? = text?.let { VERSION.find(it)?.value }?.takeIf { it.length <= MAX_SHOWN }

    private const val MAX_SHOWN = 64
}
