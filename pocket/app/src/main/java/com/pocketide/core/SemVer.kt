package com.pocketide.core

/**
 * A semantic version: major.minor.patch with an optional pre-release ("1.2.3-beta.1"). Missing
 * parts read as 0 ("1.2" is 1.2.0), a leading "v" is allowed, and build metadata after "+" is
 * ignored, as semver 2.0 says. Precedence follows semver 2.0 §11.
 */
data class SemVer(
    val major: Long,
    val minor: Long,
    val patch: Long,
    val preRelease: List<String> = emptyList(),
) : Comparable<SemVer> {

    val isPreRelease: Boolean get() = preRelease.isNotEmpty()

    /** The same version without its pre-release part. */
    fun core(): SemVer = if (isPreRelease) copy(preRelease = emptyList()) else this

    override fun compareTo(other: SemVer): Int {
        compareValues(major, other.major).let { if (it != 0) return it }
        compareValues(minor, other.minor).let { if (it != 0) return it }
        compareValues(patch, other.patch).let { if (it != 0) return it }
        return comparePreRelease(preRelease, other.preRelease)
    }

    override fun toString(): String =
        "$major.$minor.$patch" + if (isPreRelease) preRelease.joinToString(".", prefix = "-") else ""

    companion object {
        private val NUMBER = Regex("0|[1-9][0-9]{0,17}")
        private val IDENTIFIER = Regex("[0-9A-Za-z-]+")

        /** Null when [text] is not a version. */
        fun parse(text: String): SemVer? {
            val trimmed = text.trim().removePrefix("v").removePrefix("V")
            val withoutBuild = trimmed.substringBefore('+')
            val core = withoutBuild.substringBefore('-')
            val pre = if (withoutBuild.contains('-')) withoutBuild.substringAfter('-') else null
            val parts = core.split('.')
            if (parts.size !in 1..3 || parts.any { !NUMBER.matches(it) }) return null
            val identifiers = pre?.split('.') ?: emptyList()
            if (identifiers.any { !IDENTIFIER.matches(it) }) return null
            val numbers = parts.map { it.toLong() }
            return SemVer(numbers[0], numbers.getOrElse(1) { 0 }, numbers.getOrElse(2) { 0 }, identifiers)
        }

        private fun comparePreRelease(a: List<String>, b: List<String>): Int {
            // A release outranks every pre-release of the same version.
            if (a.isEmpty() || b.isEmpty()) return compareValues(a.isEmpty(), b.isEmpty())
            for (i in 0 until minOf(a.size, b.size)) {
                val order = compareIdentifiers(a[i], b[i])
                if (order != 0) return order
            }
            return compareValues(a.size, b.size)
        }

        private fun compareIdentifiers(a: String, b: String): Int {
            val x = a.toLongOrNull()?.takeIf { a.all(Char::isDigit) }
            val y = b.toLongOrNull()?.takeIf { b.all(Char::isDigit) }
            return when {
                x != null && y != null -> compareValues(x, y)
                x != null -> -1
                y != null -> 1
                else -> a.compareTo(b)
            }
        }
    }
}
