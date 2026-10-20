package app.entesaver.core.logic

/**
 * Android's minimum quality floor for video encoding.
 *
 * From Android 12, on a phone or tablet - a touchscreen, and not a TV, a
 * watch or a car - MediaCodec reshapes every VBR encode of a picture above
 * 320x240 and up to 1920x1088 before the encoder sees it: a bitrate below the
 * framework's own table for that size is raised to it, and then by a fifth
 * again on an encoder that takes no QP bounds, which is most phone chips.
 * The table aims at VMAF 70 for a camera's real-time encode: 3.1 Mbps for
 * 1080p HEVC, 1.7 for 720p, 0.9 for 480p, and more again for H.264. Every
 * rate BitrateCalc gives is below it, so a VBR copy comes out at the floor
 * whatever was asked - three or four times the size the app chose. CBR is
 * left alone, which is why the compressor writes in CBR where the floor
 * would apply and the chip has it.
 *
 * The numbers are AOSP's (frameworks/av, libmediaformatshaper: CodecSeeding
 * and VQApply). A phone maker can tune them per chip; these are the ones a
 * phone has unless it does.
 */
object QualityFloor {

    /** Android 12, where the floor began. */
    const val FIRST_SDK = 31

    /** At or below this many pixels, a picture is not reshaped. */
    const val MIN_PIXELS = 320 * 240

    /** Above this many pixels, a picture is not reshaped. */
    const val MAX_PIXELS = 1920 * 1088

    /** The floor in bits per second per pixel, by the size it is set for, smallest first. */
    private val HEVC = listOf(854 * 480 to 2.30, 960 * 540 to 2.10, 1280 * 720 to 1.80, 1920 * 1080 to 1.50)
    private val H264 = listOf(854 * 480 to 3.00, 960 * 540 to 2.65, 1280 * 720 to 2.25, 1920 * 1080 to 1.90)

    /** How much more an encoder without QP bounds is given, and the most the floor ever asks for. */
    const val MISSING_QP_BOOST = 0.20
    const val PHASE_OUT = 1.75

    /** Whether Android reshapes a VBR encode of [width] x [height] on this phone. */
    fun applies(sdkInt: Int, handheld: Boolean, width: Int, height: Int): Boolean {
        val pixels = width.toLong() * height
        return sdkInt >= FIRST_SDK && handheld && pixels > MIN_PIXELS && pixels <= MAX_PIXELS
    }

    /**
     * What a VBR encode asked for [requestedBps] at [width] x [height] is held
     * to where the floor applies, on an encoder without QP bounds.
     */
    fun vbrBps(requestedBps: Int, width: Int, height: Int, codec: VideoCodec): Int {
        val pixels = width.toLong() * height
        // The first size at least as big as the picture sets its floor; a
        // picture bigger than all of them - 1920x1088 - has none.
        val bpp = (if (codec == VideoCodec.HEVC) HEVC else H264).firstOrNull { it.first >= pixels }?.second
            ?: return requestedBps
        val floor = pixels * bpp
        val ceiling = floor * PHASE_OUT
        if (requestedBps >= ceiling) return requestedBps
        val raised = maxOf(requestedBps.toDouble(), floor) * (1 + MISSING_QP_BOOST)
        return minOf(raised, ceiling).toInt()
    }
}
