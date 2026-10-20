package app.entesaver.core.logic

import java.util.Locale

/**
 * Whether a codec is a software one, judged by its name - on Android 9,
 * which cannot be asked.
 *
 * Android 10 added MediaCodecInfo.isHardwareAccelerated and isSoftwareOnly.
 * Before them the name is all there is, and Android filled those flags in
 * from the name itself: its own codecs are "OMX.google." and "c2.android.",
 * and a codec that is not "OMX." or "c2." at all is software too. A few
 * vendors ship software codecs under their own name, marked ".sw." or
 * "software", and ffmpeg ports call themselves "OMX.ffmpeg". Reading a
 * software encoder as a chip is the mistake to avoid: on a budget phone it
 * runs for hours and runs the phone hot.
 */
object CodecNames {

    fun looksSoftware(name: String): Boolean {
        val n = name.lowercase(Locale.ROOT)
        return n.startsWith("omx.google.") ||
            n.startsWith("c2.android.") ||
            n.startsWith("omx.ffmpeg") ||
            n.contains(".sw.") ||
            n.endsWith(".sw") ||
            n.contains("software") ||
            !(n.startsWith("omx.") || n.startsWith("c2."))
    }
}
