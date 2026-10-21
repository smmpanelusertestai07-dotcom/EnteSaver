package app.entesaver.core.logic

/**
 * The codec a copy is written in: its original's own. H.264 stays H.264 and
 * HEVC stays HEVC, so a copy plays everywhere its original did, and nothing
 * about the file changes but how many bits its picture is given.
 *
 * Only the two codecs a phone's video chip writes can be kept. A video in any
 * other - an old phone's MPEG-4 or H.263, a VP9 or AV1 download, a Dolby
 * Vision clip - is left exactly as it is, since a copy would change its codec.
 */
object VideoCodecResolver {

    /** The codec a picture of [mime] is kept in; null when no phone writes it. */
    fun keptCodec(mime: String?): VideoCodec? = when (mime?.lowercase()) {
        "video/avc" -> VideoCodec.H264
        "video/hevc" -> VideoCodec.HEVC
        else -> null
    }
}
