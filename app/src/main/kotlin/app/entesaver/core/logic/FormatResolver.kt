package app.entesaver.core.logic

/**
 * The format a photo is written in: its own. A JPEG stays a JPEG, a HEIC a
 * HEIC, a WebP a WebP and a PNG a PNG, so nothing that opens the original
 * has to learn a new format, and the name never changes.
 *
 * What can be done without losing anything that matters:
 *
 *  - An Ultra HDR JPEG carries a gain map that Android 14 writes back; older
 *    versions cannot, and the photo is kept as it is rather than lose its HDR.
 *  - HEIC is written only where this phone has passed a real HEIC encode on
 *    its own hardware. A software encode on a budget phone takes many
 *    seconds a photo and heats it up; without the hardware, a HEIC is kept.
 *  - Every other format - GIF, RAW, SVG and the rest - is kept as it is.
 */
object FormatResolver {

    /** What to do with one photo. */
    sealed interface Decision {
        data class Encode(val format: PhotoFormat) : Decision
        /** Copied byte for byte; [reason] is shown in the file's details. */
        data class AsIs(val reason: String) : Decision
    }

    const val ULTRA_HDR_MIN_API = 34

    /** The format a photo file is in, by its name; null for one kept as it is. */
    fun sourceFormat(name: String): PhotoFormat? = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg", "jpe", "jfif" -> PhotoFormat.JPEG
        "heic", "heif" -> PhotoFormat.HEIC
        "webp" -> PhotoFormat.WEBP
        "png" -> PhotoFormat.PNG
        else -> null
    }

    fun resolve(source: PhotoFormat, heicWorks: Boolean, isUltraHdr: Boolean, sdkInt: Int): Decision {
        if (isUltraHdr) {
            return if (source == PhotoFormat.JPEG && sdkInt >= ULTRA_HDR_MIN_API) {
                Decision.Encode(PhotoFormat.JPEG)
            } else {
                Decision.AsIs("ultra_hdr_kept")
            }
        }
        return if (source == PhotoFormat.HEIC && !heicWorks) Decision.AsIs("format_as_is") else Decision.Encode(source)
    }

    /**
     * Whether a decoded photo whose colour space is or is not sRGB can be
     * written as [format] without its colours changing. The HEIC encoder
     * takes the pixel values as they are and labels them sRGB, so a Display
     * P3 photo would come out paler; it is kept as it is instead.
     */
    fun keepsColour(format: PhotoFormat, srgb: Boolean): Boolean = srgb || format != PhotoFormat.HEIC

    /** Whether [format] has see-through pixels; JPEG and HEIC have none. */
    fun carriesTransparency(format: PhotoFormat): Boolean = format == PhotoFormat.PNG || format == PhotoFormat.WEBP

    /**
     * True when any of the first [count] ARGB pixels is less than fully
     * opaque. JPEG and HEIC have no alpha, so such a picture would be
     * flattened onto black; it is copied as it is instead.
     */
    fun anyTransparent(argb: IntArray, count: Int = argb.size): Boolean {
        for (i in 0 until count) {
            if ((argb[i] ushr 24) != 0xFF) return true
        }
        return false
    }

    /**
     * Whether a WebP's head says it is the lossless kind: its first image
     * chunk is VP8L rather than VP8 (an extended file names its chunks
     * after a VP8X header, a colour profile perhaps, and an alpha chunk).
     */
    fun webpIsLossless(head: ByteArray): Boolean {
        if (head.size < 16 || String(head, 0, 4, Charsets.US_ASCII) != "RIFF" ||
            String(head, 8, 4, Charsets.US_ASCII) != "WEBP"
        ) {
            return false
        }
        var at = 12
        while (at + 8 <= head.size) {
            val fourCc = String(head, at, 4, Charsets.US_ASCII)
            if (fourCc == "VP8L") return true
            if (fourCc == "VP8 ") return false
            val size = (head[at + 4].toInt() and 0xFF) or ((head[at + 5].toInt() and 0xFF) shl 8) or
                ((head[at + 6].toInt() and 0xFF) shl 16) or ((head[at + 7].toInt() and 0xFF) shl 24)
            if (size < 0) return false
            at += 8 + size + (size and 1)
        }
        return false
    }

    /** The file extension a format is written with when the name gives none. */
    fun extensionOf(format: PhotoFormat): String = when (format) {
        PhotoFormat.HEIC -> "heic"
        PhotoFormat.WEBP -> "webp"
        PhotoFormat.PNG -> "png"
        PhotoFormat.JPEG -> "jpg"
    }

    /**
     * The MIME type of a file with this name, for every format this app
     * writes or copies. MediaProvider makes a file's extension agree with the
     * type it is given, so a HEIC copy declared as JPEG lands as
     * "name.heic.jpg" - a name nothing that looks for the copy afterwards
     * recognises. One table for every insert, so no writer falls behind the
     * encoders.
     */
    fun mimeOf(name: String, fallback: String): String =
        when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg", "jpe", "jfif" -> "image/jpeg"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "heic", "heif" -> "image/heic"
            "dng" -> "image/x-adobe-dng"
            else -> fallback
        }
}
