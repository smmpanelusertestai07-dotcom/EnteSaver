package app.entesaver.core.logic

/**
 * Where a gallery file sits, on Android 9.
 *
 * Android 10 gave every MediaStore row a RELATIVE_PATH - "Pictures/EnteSaver/"
 * - and everything in this app that judges a folder compares those: its own
 * output, the light copies album, the scanner's exclusions, the folder a
 * release has to have landed in. Android 9 has no such column, only the
 * file's full path (DATA). So there the path is turned into the very string
 * Android 10's MediaProvider derives from it: everything after the storage
 * volume's root, with the trailing slash, "/" for a file at the root itself,
 * and null for a path outside shared storage, which Android 10 gives no
 * relative path either. The same string means the same rules decide on both.
 */
object LegacyPaths {

    /** A volume's root, the way MediaProvider recognises it: /storage/emulated/0/ or /storage/1234-ABCD/. */
    private val VOLUME_ROOT = Regex("""(?i)^/storage/(?:emulated/[0-9]+/|[^/]+/)""")

    /**
     * The relative path of the file at [data], or null.
     *
     * [primaryRoot] is the phone's own storage as the app sees it. It is
     * tried first, for a phone that mounts shared storage somewhere other
     * than under /storage.
     */
    fun relativePathOf(data: String?, primaryRoot: String? = null): String? {
        if (data.isNullOrEmpty()) return null
        val root = primaryRoot?.trimEnd('/')?.takeIf { it.isNotEmpty() }
        val start = if (root != null && data.startsWith("$root/")) {
            root.length + 1
        } else {
            VOLUME_ROOT.find(data)?.let { it.range.last + 1 } ?: return null
        }
        val lastSlash = data.lastIndexOf('/')
        return if (lastSlash < start) "/" else data.substring(start, lastSlash + 1)
    }

    /**
     * A LIKE pattern on DATA, for ESCAPE '\', that holds every file inside
     * [folder] wherever its volume is mounted: "%/Pictures/EnteSaver/%". It is
     * wider than the folder - a folder of the same name deeper down matches
     * too - so a caller keeps only the rows whose [relativePathOf] really is
     * inside it.
     */
    fun dataLike(folder: String): String = "%/" + OutputRoots.escapeLike(OutputRoots.normalize(folder)) + "/%"
}
