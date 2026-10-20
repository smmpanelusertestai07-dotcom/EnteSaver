package app.entesaver.media

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.ColorInfo
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EncoderUtil
import app.entesaver.BuildConfig
import app.entesaver.core.logic.CodecNames
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.QualityFloor

/**
 * What this phone's own encoder chips can do.
 *
 * Only hardware encoders count. A software encoder can produce the same file,
 * but on a budget phone it takes many times longer and runs the phone hot,
 * and this app's first promise is that nobody notices it working.
 */
object EncoderCaps {

    const val MIME_HEVC = MediaFormat.MIMETYPE_VIDEO_HEVC
    const val MIME_HEIC = MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC

    private val codecs: List<MediaCodecInfo> by lazy {
        runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.toList() }
            .getOrDefault(emptyList())
    }

    /** Hardware encoders for [mime], best first as the phone lists them. */
    fun hardwareEncoders(mime: String): List<MediaCodecInfo> = codecs.filter { info ->
        info.isEncoder &&
            info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
            runCatching { isHardware(info) }.getOrDefault(false)
    }

    /**
     * Whether [info] runs on a chip. From Android 10 the phone says so;
     * Android 9 cannot be asked, and there the codec's name decides, by the
     * rule Android itself filled those answers in with (CodecNames).
     */
    fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            info.isHardwareAccelerated && !info.isSoftwareOnly
        } else {
            !CodecNames.looksSoftware(info.name)
        }

    /** Whether [info] is a software codec, by the same reading as [isHardware]. */
    fun isSoftware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isSoftwareOnly else CodecNames.looksSoftware(info.name)

    /**
     * The savings benchmark only, on an emulator, which has no hardware
     * encoder at all: let its software encoders stand in for a phone's chip,
     * so the path phones take - each video in its own codec - is the one
     * measured. A release build ignores it entirely.
     */
    @Volatile
    var softwareForBenchmark: Boolean = false

    /**
     * The savings benchmark only: its emulator runs with Android's quality
     * floor switched off (debug.stagefright.enableshaping), and with this the
     * app judges its copies as a phone does whose encoder writes in CBR,
     * which the floor never touches. A release build ignores it entirely.
     */
    @Volatile
    var qualityFloorOffForBenchmark: Boolean = false

    /** Whether Android's quality floor holds up a VBR encode of this size on this phone (QualityFloor). */
    fun qualityFloorApplies(context: Context, width: Int, height: Int): Boolean =
        !(BuildConfig.DEBUG && qualityFloorOffForBenchmark) &&
            QualityFloor.applies(Build.VERSION.SDK_INT, handheld(context), width, height)

    private fun encoders(mime: String): List<MediaCodecInfo> =
        if (BuildConfig.DEBUG && softwareForBenchmark) {
            codecs.filter { info -> info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
        } else {
            hardwareEncoders(mime)
        }

    /** Software encoders for [mime]: Android's own, on every phone. */
    private fun softwareEncoders(mime: String): List<MediaCodecInfo> = codecs.filter { info ->
        info.isEncoder &&
            info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
            runCatching { isSoftware(info) }.getOrDefault(false)
    }

    /**
     * True when one of [infos] takes a video of this size and frame rate.
     * Either orientation is accepted: encoders often state limits for
     * landscape only and rotate a portrait frame themselves.
     */
    private fun anyTakes(infos: List<MediaCodecInfo>, mime: String, width: Int, height: Int, fps: Float): Boolean =
        infos.any { info ->
            runCatching {
                val video = info.getCapabilitiesForType(mime).videoCapabilities
                val rate = fps.toDouble().coerceAtLeast(1.0)
                video.areSizeAndRateSupported(width, height, rate) ||
                    video.areSizeAndRateSupported(height, width, rate)
            }.getOrDefault(false)
        }

    /** True when a hardware encoder for [mime] takes a video of this size and frame rate. */
    fun hardwareFits(mime: String, width: Int, height: Int, fps: Float): Boolean =
        anyTakes(encoders(mime), mime, width, height, fps)

    /**
     * True when Android's own software encoder for [mime] takes this size and
     * frame rate: H.264's last resort, for a clip no chip rung could write. Never
     * above 1080p, which in software would take hours on a budget phone.
     */
    fun softwareFits(mime: String, width: Int, height: Int, fps: Float): Boolean =
        maxOf(width, height) <= MediaSettings.FULL_HD && anyTakes(softwareEncoders(mime), mime, width, height, fps)

    /**
     * True when an encoder for [mime] takes a video of this size and frame
     * rate in CBR - the mode Android's quality floor (QualityFloor) leaves
     * alone. Many chips have it for HEVC and not for H.264.
     */
    fun cbrFits(mime: String, width: Int, height: Int, fps: Float): Boolean =
        encoders(mime).any { info ->
            runCatching {
                val caps = info.getCapabilitiesForType(mime)
                val video = caps.videoCapabilities
                val rate = fps.toDouble().coerceAtLeast(1.0)
                caps.encoderCapabilities.isBitrateModeSupported(BITRATE_MODE_CBR) &&
                    (video.areSizeAndRateSupported(width, height, rate) ||
                        video.areSizeAndRateSupported(height, width, rate))
            }.getOrDefault(false)
        }

    /**
     * Whether Android counts this as a handheld device, the kind its quality
     * floor is for: a touchscreen, and not a car, a TV or a watch - the test
     * MediaCodec itself makes.
     */
    fun handheld(context: Context): Boolean {
        val pm = context.packageManager
        val others = listOf(
            PackageManager.FEATURE_AUTOMOTIVE,
            "android.hardware.type.television",
            PackageManager.FEATURE_WATCH
        )
        return pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) && others.none { pm.hasSystemFeature(it) }
    }

    /**
     * Whether this phone writes a video of [colorInfo]'s HDR as HDR: Media3's
     * own test, an HEVC encoder Android counts as editing HDR (Android 13 and
     * up). Where it fails, Media3 would tone-map the copy to SDR without a
     * word, so a video that fails it stays as it is.
     */
    @OptIn(UnstableApi::class)
    fun writesHdr(colorInfo: ColorInfo?): Boolean =
        colorInfo != null && runCatching {
            EncoderUtil.getSupportedEncodersForHdrEditing(MimeTypes.VIDEO_H265, colorInfo).isNotEmpty()
        }.getOrDefault(false)

    /**
     * Whether the AAC encoder Media3 would write sound with is Android's own
     * Codec2 one, the only one whose start-up delay it allows for. With any
     * other the sound would come out a few hundredths of a second late.
     */
    @OptIn(UnstableApi::class)
    fun aacKeepsSync(): Boolean = runCatching {
        EncoderUtil.getSupportedEncoders(MimeTypes.AUDIO_AAC).firstOrNull()?.name == "c2.android.aac.encoder"
    }.getOrDefault(false)

    /** A hardware encoder HEIC can be written with: a HEIC one, or HEVC. */
    fun hasHardwareHeic(): Boolean =
        hardwareEncoders(MIME_HEIC).isNotEmpty() || hardwareEncoders(MIME_HEVC).isNotEmpty()
}
