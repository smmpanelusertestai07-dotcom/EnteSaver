package app.entesaver.media

import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.PhotoFormat
import app.entesaver.core.logic.VideoCodec
import app.entesaver.core.logic.VideoCodecResolver

/**
 * What optimising turns into on this phone, before any file is looked at:
 * the codec an ordinary 1080p video gets.
 *
 * Encode results are grouped under it, so an estimate only ever quotes files
 * that were made the way new ones will be. One file may still come out
 * differently - a clip too large for the HEVC chip goes H.264 - and its own
 * details say so. Photos keep their own format, so their key is that of the
 * format nearly every phone photo is in.
 */
object PlannedEncode {

    /** The codec an ordinary 1080p30 clip gets on this phone. */
    fun videoCodec(): VideoCodec = VideoCodecResolver.resolve(
        VideoCodecResolver.Hardware(hevcFits = EncoderCaps.hevcFits(MediaSettings.FULL_HD, 1080, 30f))
    )

    fun photoKey(): String = MediaSettings.photoKey(PhotoFormat.JPEG)

    fun videoKey(): String = MediaSettings.videoKey(videoCodec())
}
