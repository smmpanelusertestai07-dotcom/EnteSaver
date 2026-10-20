package app.entesaver.core.logic

/**
 * The codec a video is actually encoded with on this phone.
 *
 * HEVC makes a file about a third smaller than H.264 at the same look, but
 * only a hardware encoder makes it at a sensible speed and temperature; in
 * software a budget phone takes many times the clip's own length and runs
 * hot. So HEVC is used only where the phone has a hardware HEVC encoder that
 * takes this video's size and frame rate. H.264 is the codec every phone
 * encodes in hardware.
 */
object VideoCodecResolver {

    data class Hardware(
        /** A hardware HEVC encoder exists and takes this size and frame rate. */
        val hevcFits: Boolean
    )

    fun resolve(hardware: Hardware): VideoCodec = if (hardware.hevcFits) VideoCodec.HEVC else VideoCodec.H264
}
