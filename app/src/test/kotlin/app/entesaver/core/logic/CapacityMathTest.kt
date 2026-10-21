package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CapacityMathTest {

    private val defaultRatios = CapacityMath.ratios(emptyList(), emptyList(), VideoCodec.H264)

    @Test
    fun coldStartUsesDefaults() {
        val r = defaultRatios
        assertEquals(2.5 / 3.5, r.photoRatio, 1e-9)
        assertEquals(60.0 / 122.0, r.videoRatio, 1e-9)
        assertEquals(60.0, r.videoOutMBperMin, 1e-9)
        assertEquals(2_500_000.0, r.avgPhotoOutBytes, 1e-3)
        assertFalse(r.photoMeasured)
        assertFalse(r.videoMeasured)
    }

    @Test
    fun hevcDefaultsAreSmaller() {
        val r = CapacityMath.ratios(emptyList(), emptyList(), VideoCodec.HEVC)
        assertEquals(28.0, r.videoOutMBperMin, 1e-9)
        assertTrue(r.videoRatio < defaultRatios.videoRatio)
    }

    @Test
    fun measuredRatiosAreByteWeightedAndClamped() {
        // 20 identical photos: 4 MB -> 2 MB (ratio 0.5).
        val photos = List(20) { CapacityMath.Sample(4_000_000, 2_000_000) }
        val r = CapacityMath.ratios(photos, emptyList(), VideoCodec.H264)
        assertTrue(r.photoMeasured)
        assertEquals(0.5, r.photoRatio, 1e-9)
        assertEquals(2_000_000.0, r.avgPhotoOutBytes, 1e-3)
    }

    @Test
    fun outlierItemsAreClamped() {
        // One absurd item claims 1000x compression; clamp holds it at 0.05.
        val photos = List(19) { CapacityMath.Sample(4_000_000, 4_000_000) } +
            CapacityMath.Sample(4_000_000, 4_000)
        val r = CapacityMath.ratios(photos, emptyList(), VideoCodec.H264)
        assertTrue(r.photoRatio >= 0.05)
        assertTrue(r.photoRatio > 0.9) // 19 of 20 items had ratio 1.0
    }

    @Test
    fun clampRatioBounds() {
        assertEquals(0.05, CapacityMath.clampRatio(0.0001), 1e-9)
        assertEquals(1.0, CapacityMath.clampRatio(3.0), 1e-9)
        assertEquals(1.0, CapacityMath.clampRatio(Double.NaN), 1e-9)
        assertEquals(0.5, CapacityMath.clampRatio(0.5), 1e-9)
    }

    @Test
    fun videoMbPerMinuteFromSamples() {
        // 20 videos, 2 min each, 60 MB output each -> 30 MB/min.
        val videos = List(20) { CapacityMath.Sample(200_000_000, 60_000_000, durationMin = 2.0) }
        val r = CapacityMath.ratios(emptyList(), videos, VideoCodec.H264)
        assertTrue(r.videoMeasured)
        assertEquals(30.0, r.videoOutMBperMin, 1e-6)
        assertEquals(0.3, r.videoRatio, 1e-9)
    }

    @Test
    fun photosOnlyCapacity() {
        // 10 GB cloud, avg photo out 2.5 MB -> 4000 photos.
        val g = CapacityMath.Gallery(0, 0, 0.0, 0, 0)
        val e = CapacityMath.estimate(10.0, CapacityMath.CalcMode.PHOTOS, 0.5, g, defaultRatios)
        assertEquals(4000L, e.photoCount)
        assertEquals(0.0, e.videoHours, 1e-9)
        // Y = 10 / (2.5/3.5) = 14 GB of originals.
        assertEquals(14.0, e.originalsGB, 1e-6)
    }

    @Test
    fun videosOnlyCapacity() {
        // 10 GB cloud at 60 MB/min -> 10e9/(60e6*60) hours = 2.78 h.
        val g = CapacityMath.Gallery(0, 0, 0.0, 0, 0)
        val e = CapacityMath.estimate(10.0, CapacityMath.CalcMode.VIDEOS, 0.5, g, defaultRatios)
        assertEquals(0L, e.photoCount)
        assertEquals(10.0e9 / (60.0e6 * 60), e.videoHours, 1e-6)
    }

    @Test
    fun mixSplitsTheSpace() {
        val g = CapacityMath.Gallery(0, 0, 0.0, 0, 0)
        val e = CapacityMath.estimate(10.0, CapacityMath.CalcMode.BOTH, 0.5, g, defaultRatios)
        assertEquals(2000L, e.photoCount) // half the space for photos
        assertTrue(e.videoHours > 0)
    }

    @Test
    fun backlogFitsAndNeedsMore() {
        // Gallery: 20 GB photos originals, ratio 0.5 (measured below) -> 10 GB compressed.
        val photos = List(20) { CapacityMath.Sample(4_000_000, 2_000_000) }
        val r = CapacityMath.ratios(photos, emptyList(), VideoCodec.H264)
        val g = CapacityMath.Gallery(20_000_000_000, 0, 0.0, 0, 0)
        val fitting = CapacityMath.estimate(15.0, CapacityMath.CalcMode.PHOTOS, 1.0, g, r)
        assertTrue(fitting.fits)
        assertEquals(10.0, fitting.backlogGB, 1e-6)
        val tight = CapacityMath.estimate(4.0, CapacityMath.CalcMode.PHOTOS, 1.0, g, r)
        assertFalse(tight.fits)
        assertEquals(6.0, tight.needMoreGB, 1e-6)
        assertTrue(tight.monthsLeft < 0)
    }

    @Test
    fun paceMonths() {
        val photos = List(20) { CapacityMath.Sample(4_000_000, 2_000_000) }
        val r = CapacityMath.ratios(photos, emptyList(), VideoCodec.H264)
        // Backlog 5 GB compressed; 1 GB compressed new per month; 10 GB cloud.
        val g = CapacityMath.Gallery(10_000_000_000, 0, 0.0, 2_000_000_000, 0)
        val e = CapacityMath.estimate(10.0, CapacityMath.CalcMode.PHOTOS, 1.0, g, r)
        assertTrue(e.fits)
        assertEquals(5.0, e.monthsLeft, 1e-6)
    }

    @Test
    fun noPaceMeansNoMonths() {
        val g = CapacityMath.Gallery(0, 0, 0.0, 0, 0)
        val e = CapacityMath.estimate(10.0, CapacityMath.CalcMode.PHOTOS, 1.0, g, defaultRatios)
        assertTrue(e.monthsLeft < 0)
    }

    @Test
    fun defaultMixShareFollowsGalleryBytes() {
        assertEquals(
            0.25,
            CapacityMath.defaultMixShare(CapacityMath.Gallery(25, 75, 0.0, 0, 0)),
            1e-9
        )
        assertEquals(0.5, CapacityMath.defaultMixShare(CapacityMath.Gallery(0, 0, 0.0, 0, 0)), 1e-9)
    }

    @Test
    fun typicalBadgeFollowsModeRelevantTypes() {
        val photos = List(20) { CapacityMath.Sample(4_000_000, 2_000_000) }
        val r = CapacityMath.ratios(photos, emptyList(), VideoCodec.H264)
        val g = CapacityMath.Gallery(0, 0, 0.0, 0, 0)
        // Photos measured -> photos-only is not "typical".
        assertFalse(CapacityMath.estimate(10.0, CapacityMath.CalcMode.PHOTOS, 1.0, g, r).typicalEstimate)
        // Video unmeasured -> both-mode still "typical".
        assertTrue(CapacityMath.estimate(10.0, CapacityMath.CalcMode.BOTH, 0.5, g, r).typicalEstimate)
    }

    @Test
    fun roundTwoSignificantFigures() {
        assertEquals(120.0, CapacityMath.round2sf(123.4), 1e-9)
        assertEquals(1.3, CapacityMath.round2sf(1.26), 1e-9)
        assertEquals(0.056, CapacityMath.round2sf(0.0561), 1e-9)
        assertEquals(2400.0, CapacityMath.round2sf(2449.0), 1e-9)
        assertEquals(0.0, CapacityMath.round2sf(0.0), 1e-9)
    }

    // ---- E2: the two guards on "measured" -----------------------------------

    private fun samples(n: Int, origBytes: Long, ratio: Double = 0.5) =
        List(n) { CapacityMath.Sample(origBytes, (origBytes * ratio).toLong(), 1.0) }

    @Test
    fun `too few files means typical, however good they look`() {
        val r = CapacityMath.ratios(
            photo = samples(CapacityMath.MIN_SAMPLES - 1, 4_000_000),
            video = emptyList(),
            codec = VideoCodec.H264,
            galleryPhotoMedian = 4_000_000
        )
        assertFalse(r.photoMeasured)
    }

    @Test
    fun `a pile of screenshots does not get to speak for the gallery`() {
        // 40 KB thumbnails against a gallery of 4 MB photographs: enough of
        // them by count, nothing like them in size.
        val r = CapacityMath.ratios(
            photo = samples(50, 40_000),
            video = emptyList(),
            codec = VideoCodec.H264,
            galleryPhotoMedian = 4_000_000
        )
        assertFalse("unrepresentative sample must not be trusted", r.photoMeasured)
    }

    @Test
    fun `a representative sample is used`() {
        val r = CapacityMath.ratios(
            photo = samples(50, 3_500_000),
            video = emptyList(),
            codec = VideoCodec.H264,
            galleryPhotoMedian = 4_000_000
        )
        assertTrue(r.photoMeasured)
    }

    @Test
    fun `asking for typical always gets typical`() {
        val r = CapacityMath.ratios(
            photo = samples(500, 4_000_000),
            video = samples(500, 100_000_000),
            codec = VideoCodec.H264,
            source = CapacityMath.Source.TYPICAL,
            galleryPhotoMedian = 4_000_000,
            galleryVideoMedian = 100_000_000
        )
        assertFalse(r.photoMeasured)
        assertFalse(r.videoMeasured)
        assertEquals(
            CapacityMath.DEF_PHOTO_OUT_MB / CapacityMath.DEF_PHOTO_ORIG_MB,
            r.photoRatio,
            1e-9
        )
    }

    @Test
    fun `with no gallery median to compare against, size is not held against the sample`() {
        // A fresh install has no totals yet; refusing every sample then would
        // mean the calculator never leaves "typical".
        val r = CapacityMath.ratios(
            photo = samples(50, 40_000),
            video = emptyList(),
            codec = VideoCodec.H264,
            galleryPhotoMedian = 0
        )
        assertTrue(r.photoMeasured)
    }

    @Test
    fun `median handles both odd and even counts`() {
        assertEquals(3L, CapacityMath.median(listOf(5L, 1L, 3L)))
        assertEquals(3L, CapacityMath.median(listOf(4L, 2L)))
        assertEquals(0L, CapacityMath.median(emptyList()))
    }
}
