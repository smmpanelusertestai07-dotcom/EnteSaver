package app.entesaver.core.logic

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * Cloud calculator math (13.C). Pure Kotlin, fully unit-tested.
 * GB is decimal (1 GB = 1000 MB = 1e9 bytes), like cloud providers count.
 * Every output is an ESTIMATE and is rounded to 2 significant figures for
 * humans - never show false precision.
 */
object CapacityMath {

    const val GB = 1_000_000_000.0

    /** Measured ratios need at least this many processed items of a type. */
    const val MIN_SAMPLES = 20

    /**
     * A sample must also look like the gallery it is meant to describe.
     *
     * The first files a phone processes are often screenshots and thumbnails,
     * which compress almost not at all and are a fraction of the size of a
     * real photo. Twenty of those would otherwise "measure" the whole library
     * and the estimate would be wildly wrong in the direction people notice.
     * So the sample's median size has to be at least this share of the
     * gallery's median for that type before it is trusted.
     */
    const val MIN_MEDIAN_SHARE = 0.10

    /** Where the numbers come from. The badge always says which is in use. */
    enum class Source { MEASURED, TYPICAL }

    /** Outlier guard for per-item compression ratios. */
    const val CLAMP_MIN = 0.05
    const val CLAMP_MAX = 1.0

    // Cold-start defaults (typical phone media).
    const val DEF_PHOTO_ORIG_MB = 3.5
    const val DEF_PHOTO_OUT_MB = 2.5
    const val DEF_VIDEO_ORIG_MB_PER_MIN = 122.0
    // About half: what the savings benchmark's 1080p camera videos came
    // down to, each copy kept only where it still looked like its original.
    const val DEF_VIDEO_OUT_MB_PER_MIN_H264 = 60.0
    const val DEF_VIDEO_OUT_MB_PER_MIN_HEVC = 28.0

    enum class CalcMode { PHOTOS, VIDEOS, BOTH }

    /** One processed item (as-is copies included - they are real outcomes). */
    data class Sample(val origBytes: Long, val outBytes: Long, val durationMin: Double = 0.0)

    data class Ratios(
        val photoRatio: Double,
        val videoRatio: Double,
        val videoOutMBperMin: Double,
        val avgPhotoOutBytes: Double,
        val photoSamples: Int,
        val videoSamples: Int,
        /** False when the sample was rejected as unrepresentative. */
        val photoMeasured: Boolean = photoSamples >= MIN_SAMPLES,
        val videoMeasured: Boolean = videoSamples >= MIN_SAMPLES
    )

    /**
     * Whether a sample may speak for the gallery: enough of it, and not a
     * pile of screenshots standing in for photographs.
     */
    fun sampleIsRepresentative(
        sampleSizes: List<Long>,
        galleryMedianBytes: Long
    ): Boolean {
        if (sampleSizes.size < MIN_SAMPLES) return false
        if (galleryMedianBytes <= 0) return true
        return median(sampleSizes) >= galleryMedianBytes * MIN_MEDIAN_SHARE
    }

    fun median(values: List<Long>): Long {
        if (values.isEmpty()) return 0
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) {
            sorted[mid]
        } else {
            (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    fun clampRatio(r: Double): Double = when {
        r.isNaN() || r.isInfinite() -> CLAMP_MAX
        else -> r.coerceIn(CLAMP_MIN, CLAMP_MAX)
    }

    /**
     * Byte-weighted ratios from this phone's processed items (last 500 per type,
     * the caller limits). Types with fewer than [MIN_SAMPLES] items fall back to
     * the defaults for the given codec.
     *
     * @param source MEASURED uses this phone's own results where the sample
     *   passes both guards; TYPICAL always answers with the published-style
     *   defaults, so the user can compare the two.
     * @param galleryPhotoMedian / [galleryVideoMedian] median file size of the
     *   whole gallery for that type; 0 disables the representativeness guard.
     */
    fun ratios(
        photo: List<Sample>,
        video: List<Sample>,
        codec: VideoCodec,
        source: Source = Source.MEASURED,
        galleryPhotoMedian: Long = 0,
        galleryVideoMedian: Long = 0
    ): Ratios {
        val defVideoOut = if (codec == VideoCodec.H264) {
            DEF_VIDEO_OUT_MB_PER_MIN_H264
        } else {
            DEF_VIDEO_OUT_MB_PER_MIN_HEVC
        }
        val defaults = Ratios(
            photoRatio = DEF_PHOTO_OUT_MB / DEF_PHOTO_ORIG_MB,
            videoRatio = defVideoOut / DEF_VIDEO_ORIG_MB_PER_MIN,
            videoOutMBperMin = defVideoOut,
            avgPhotoOutBytes = DEF_PHOTO_OUT_MB * 1e6,
            photoSamples = photo.size,
            videoSamples = video.size
        )

        val usePhoto = source == Source.MEASURED &&
            sampleIsRepresentative(photo.map { it.origBytes }, galleryPhotoMedian)
        val useVideo = source == Source.MEASURED &&
            sampleIsRepresentative(video.map { it.origBytes }, galleryVideoMedian)

        var photoRatio = defaults.photoRatio
        var avgPhotoOut = defaults.avgPhotoOutBytes
        if (usePhoto) {
            val origSum = photo.sumOf { it.origBytes.toDouble() }
            if (origSum > 0) {
                val weighted = photo.sumOf {
                    it.origBytes.toDouble() * clampRatio(it.outBytes.toDouble() / it.origBytes)
                }
                photoRatio = clampRatio(weighted / origSum)
            }
            avgPhotoOut = photo.sumOf { it.outBytes.toDouble() } / photo.size
            if (avgPhotoOut <= 0) avgPhotoOut = defaults.avgPhotoOutBytes
        }

        var videoRatio = defaults.videoRatio
        var videoOutMBperMin = defaults.videoOutMBperMin
        if (useVideo) {
            val origSum = video.sumOf { it.origBytes.toDouble() }
            if (origSum > 0) {
                val weighted = video.sumOf {
                    it.origBytes.toDouble() * clampRatio(it.outBytes.toDouble() / it.origBytes)
                }
                videoRatio = clampRatio(weighted / origSum)
            }
            val withDuration = video.filter { it.durationMin > 0 }
            val minutes = withDuration.sumOf { it.durationMin }
            if (minutes > 0.5) {
                videoOutMBperMin = withDuration.sumOf { it.outBytes.toDouble() } / 1e6 / minutes
            }
        }

        return Ratios(
            photoRatio = photoRatio,
            videoRatio = videoRatio,
            videoOutMBperMin = videoOutMBperMin,
            avgPhotoOutBytes = avgPhotoOut,
            photoSamples = photo.size,
            videoSamples = video.size,
            photoMeasured = usePhoto,
            videoMeasured = useVideo
        )
    }

    /** Gallery totals for the selected mode's folder rules (bytes, minutes). */
    data class Gallery(
        val photoBytes: Long,
        val videoBytes: Long,
        val videoMinutes: Double,
        val monthlyPhotoBytes: Long,
        val monthlyVideoBytes: Long,
        /** Needed to turn hours of capacity into a number of clips. */
        val videoCount: Int = 0
    ) {
        /** How long this phone's videos actually are, on average. */
        val meanVideoMinutes: Double
            get() = if (videoCount > 0 && videoMinutes > 0) videoMinutes / videoCount else 0.0
    }

    /** Default mix slider position: this phone's actual photo:video byte share. */
    fun defaultMixShare(g: Gallery): Double {
        val total = g.photoBytes + g.videoBytes
        if (total <= 0) return 0.5
        return g.photoBytes.toDouble() / total
    }

    data class Estimate(
        /** "X GB cloud ~ Y GB of originals". */
        val originalsGB: Double,
        /** "~N photos" capacity for the photo share. */
        val photoCount: Long,
        /** "~H hours of video" capacity for the video share. */
        val videoHours: Double,
        /**
         * The same capacity said as a number of clips, using this phone's own
         * average clip length. Zero when there are no videos to average, in
         * which case the screen shows hours alone rather than a made-up count.
         */
        val videoCount: Long,
        /** Predicted compressed size of the current gallery backlog (GB). */
        val backlogGB: Double,
        val fits: Boolean,
        /** "needs C GB more" when the backlog does not fit. */
        val needMoreGB: Double,
        /** "lasts ~M more months"; negative = cannot say (no pace / does not fit). */
        val monthsLeft: Double,
        /** True while defaults are used for a type this mode needs. */
        val typicalEstimate: Boolean,
        /** Number of this phone's files the ratios are based on. */
        val sampleCount: Int
    )

    fun estimate(
        cloudFreeGB: Double,
        mode: CalcMode,
        photoShare: Double,
        g: Gallery,
        r: Ratios
    ): Estimate {
        val x = max(0.0, cloudFreeGB) * GB
        val share = when (mode) {
            CalcMode.PHOTOS -> 1.0
            CalcMode.VIDEOS -> 0.0
            CalcMode.BOTH -> photoShare.coerceIn(0.0, 1.0)
        }
        val xPhoto = x * share
        val xVideo = x * (1 - share)

        val originalsBytes = xPhoto / r.photoRatio + xVideo / r.videoRatio
        val photoCount = if (share > 0 && r.avgPhotoOutBytes > 0) {
            floor(xPhoto / r.avgPhotoOutBytes).toLong()
        } else {
            0L
        }
        val videoHours = if (share < 1 && r.videoOutMBperMin > 0) {
            xVideo / (r.videoOutMBperMin * 1e6 * 60.0)
        } else {
            0.0
        }

        val videoCount = if (videoHours > 0 && g.meanVideoMinutes > 0) {
            floor(videoHours * 60.0 / g.meanVideoMinutes).toLong()
        } else {
            0L
        }

        val usePhotos = mode != CalcMode.VIDEOS
        val useVideos = mode != CalcMode.PHOTOS
        val backlogBytes =
            (if (usePhotos) g.photoBytes * r.photoRatio else 0.0) +
                (if (useVideos) g.videoBytes * r.videoRatio else 0.0)
        val fits = backlogBytes <= x
        val needMoreGB = max(0.0, backlogBytes - x) / GB

        val monthlyCompressed =
            (if (usePhotos) g.monthlyPhotoBytes * r.photoRatio else 0.0) +
                (if (useVideos) g.monthlyVideoBytes * r.videoRatio else 0.0)
        val monthsLeft = when {
            !fits -> -1.0
            monthlyCompressed <= 0 -> -1.0
            else -> (x - backlogBytes) / monthlyCompressed
        }

        val typical = (usePhotos && !r.photoMeasured) || (useVideos && !r.videoMeasured)
        val samples = (if (usePhotos) r.photoSamples else 0) + (if (useVideos) r.videoSamples else 0)

        return Estimate(
            originalsGB = originalsBytes / GB,
            photoCount = photoCount,
            videoHours = videoHours,
            videoCount = videoCount,
            backlogGB = backlogBytes / GB,
            fits = fits,
            needMoreGB = needMoreGB,
            monthsLeft = monthsLeft,
            typicalEstimate = typical,
            sampleCount = samples
        )
    }

    /** Round to 2 significant figures - human numbers, no false precision. */
    fun round2sf(v: Double): Double {
        if (v == 0.0 || v.isNaN() || v.isInfinite()) return 0.0
        val magnitude = floor(log10(abs(v)))
        val factor = 10.0.pow(magnitude - 1)
        return (v / factor).roundToLong() * factor
    }
}
