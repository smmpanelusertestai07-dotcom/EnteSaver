package app.entesaver.util

import android.content.Context
import android.media.MediaFormat
import android.os.Build
import app.entesaver.R
import app.entesaver.media.EncoderCaps
import app.entesaver.media.HeicSupport

/**
 * What limits Ente Saver on this phone, one plain line each, and only the
 * ones that apply: the About page's "This phone" card. Nothing here stops
 * the app; each line says what it does instead. Facts that are not limits
 * for this app (screen size, processor type, memory page size) are left out.
 */
object PhoneLimits {

    fun lines(context: Context, minFreeBytes: Long, storageVolume: String): List<String> {
        val out = mutableListOf<String>()
        val tier = DeviceTier.tier(context)
        val total = DeviceTier.totalMemBytes(context)
        val memory = Formats.bytes(total)
        val base = DeviceTier.baseCeilingMp(tier)
        when (tier) {
            DeviceTier.Tier.VERY_LOW -> out += context.getString(R.string.limit_memory_small, memory, base)
            DeviceTier.Tier.LOW -> out += context.getString(R.string.limit_memory, memory, base)
            DeviceTier.Tier.NORMAL -> Unit
        }
        val learned = DeviceTier.learnedCeilingMp(context)
        if (learned in 1 until base) out += context.getString(R.string.limit_learned, learned)
        if (EncoderCaps.hardwareEncoders(EncoderCaps.MIME_HEVC).isEmpty()) {
            out += context.getString(R.string.limit_no_hevc)
        }
        if (tier != DeviceTier.Tier.VERY_LOW && !writesFourK(context)) {
            out += context.getString(R.string.limit_video_chip)
        }
        if (HeicSupport.state(context) == HeicSupport.State.FAIL) out += context.getString(R.string.limit_heic_fail)
        if (Build.VERSION.SDK_INT >= 31 && !Permissions.isIgnoringBatteryOptimizations(context)) {
            out += context.getString(R.string.limit_battery)
        }
        val free = Storage.freeBytes(context, storageVolume)
        if (free < minFreeBytes) {
            out += context.getString(R.string.limit_space, Formats.bytes(free), Formats.bytes(minFreeBytes))
        }
        return out
    }

    /**
     * Whether this phone's chip writes a 4K video in its own codec: H.264,
     * the codec a phone films 4K in. Without it, 4K videos stay as they are
     * - and on the smallest phones too, whose memory a 4K encode would not fit.
     */
    fun writesFourK(context: Context): Boolean =
        DeviceTier.tier(context) != DeviceTier.Tier.VERY_LOW &&
            EncoderCaps.hardwareFits(MediaFormat.MIMETYPE_VIDEO_AVC, 3840, 2160, 30f)
}
