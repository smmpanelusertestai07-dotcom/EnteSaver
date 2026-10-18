package app.entesaver.media

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
import android.media.MediaCodecList
import android.media.MediaFormat
import app.entesaver.BuildConfig
import app.entesaver.core.logic.MediaSettings

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
            runCatching { info.isHardwareAccelerated && !info.isSoftwareOnly }.getOrDefault(false)
    }

    /**
     * The savings benchmark only, on an emulator, which has no hardware
     * encoder at all: let its software HEVC encoder stand in for a phone's
     * chip, so the HEVC path phones take is the one measured. A release
     * build ignores it entirely.
     */
    @Volatile
    var softwareHevcForBenchmark: Boolean = false

    private fun encoders(mime: String): List<MediaCodecInfo> =
        if (BuildConfig.DEBUG && softwareHevcForBenchmark) {
            codecs.filter { info -> info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
        } else {
            hardwareEncoders(mime)
        }

    /**
     * True when a hardware HEVC encoder takes a video of this size and frame
     * rate. Either orientation is accepted: encoders often state limits for
     * landscape only and rotate a portrait frame themselves.
     */
    fun hevcFits(width: Int, height: Int, fps: Float): Boolean =
        encoders(MIME_HEVC).any { info ->
            runCatching {
                val video = info.getCapabilitiesForType(MIME_HEVC).videoCapabilities
                val rate = fps.toDouble().coerceAtLeast(1.0)
                video.areSizeAndRateSupported(width, height, rate) ||
                    video.areSizeAndRateSupported(height, width, rate)
            }.getOrDefault(false)
        }

    /**
     * Whether a video [width] x [height] at [fps] is made at 1080p instead:
     * above 1080p only where a hardware encoder takes the size - a budget
     * chip that stops at 1080p would otherwise encode in software, for hours
     * - and never on the smallest phones ([smallestPhone]). The one rule the
     * compressor applies and Settings and About describe.
     */
    fun holdsToFullHd(width: Int, height: Int, fps: Float, smallestPhone: Boolean): Boolean =
        maxOf(width, height) > MediaSettings.FULL_HD && (smallestPhone || !anyHardwareFits(width, height, fps))

    /**
     * True when some hardware video encoder - H.264 or HEVC - takes this size
     * and frame rate. A budget phone's chip often stops at 1080p; asking it
     * for more ends in a software encode or a failed one.
     */
    fun anyHardwareFits(width: Int, height: Int, fps: Float): Boolean =
        listOf(MediaFormat.MIMETYPE_VIDEO_AVC, MIME_HEVC).any { mime ->
            hardwareEncoders(mime).any { info ->
                runCatching {
                    val video = info.getCapabilitiesForType(mime).videoCapabilities
                    val rate = fps.toDouble().coerceAtLeast(1.0)
                    video.areSizeAndRateSupported(width, height, rate) ||
                        video.areSizeAndRateSupported(height, width, rate)
                }.getOrDefault(false)
            }
        }

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

    /** A hardware encoder HEIC can be written with: a HEIC one, or HEVC. */
    fun hasHardwareHeic(): Boolean =
        hardwareEncoders(MIME_HEIC).isNotEmpty() || hardwareEncoders(MIME_HEVC).isNotEmpty()
}
