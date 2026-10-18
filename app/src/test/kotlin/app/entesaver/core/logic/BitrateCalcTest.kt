package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BitrateCalcTest {

    @Test
    fun bitrateTable1080p30() {
        // The reference: 1080p30 in HEVC, and H.264 asked for 1.45 times it.
        assertEquals(950_000, BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC))
        assertEquals(1_377_500, BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264))
    }

    @Test
    fun `smaller pictures get more bits per pixel`() {
        // 720p has 44% of 1080p's pixels and gets 54% of its rate.
        assertEquals(517_114, BitrateCalc.targetBps(1280, 720, 30f, VideoCodec.HEVC))
        // A WhatsApp 480p clip.
        assertEquals(280_161, BitrateCalc.targetBps(848, 480, 30f, VideoCodec.HEVC))
        // Slow motion keeps its frames: four times the frames, 2.8 times the rate.
        assertEquals(2_687_005, BitrateCalc.targetBps(1920, 1080, 120f, VideoCodec.HEVC))
        val hd = BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC).toDouble()
        val half = BitrateCalc.targetBps(1920, 540, 30f, VideoCodec.HEVC).toDouble()
        assertEquals(Math.pow(0.5, BitrateCalc.SCALE_EXPONENT), half / hd, 0.001)
    }

    @Test
    fun bitrateCapAndFloor() {
        // 4K at 120 fps in H.264 would be 15 Mbps -> capped at 8 Mbps.
        assertEquals(BitrateCalc.CAP_BPS, BitrateCalc.targetBps(3840, 2160, 120f, VideoCodec.H264))
        // Tiny video -> floored.
        assertEquals(BitrateCalc.FLOOR_BPS, BitrateCalc.targetBps(320, 240, 15f, VideoCodec.H264))
    }

    @Test
    fun invalidFpsFallsBackTo30() {
        assertEquals(
            BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264),
            BitrateCalc.targetBps(1920, 1080, Float.NaN, VideoCodec.H264)
        )
        assertEquals(
            BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264),
            BitrateCalc.targetBps(1920, 1080, 0f, VideoCodec.H264)
        )
    }

    @Test
    fun outputDimsKeepAspectAndEven() {
        // 4K -> long side 1920.
        assertEquals(1920 to 1080, BitrateCalc.outputDims(3840, 2160, 1920))
        // Portrait swaps too.
        assertEquals(1080 to 1920, BitrateCalc.outputDims(2160, 3840, 1920))
        // Under the limit: unchanged (evened).
        assertEquals(1280 to 720, BitrateCalc.outputDims(1280, 720, 1920))
        // Odd source becomes even.
        val (w, h) = BitrateCalc.outputDims(1281, 721, 1920)
        assertTrue(w % 2 == 0 && h % 2 == 0)
    }

    @Test
    fun copyAsIsRule() {
        val target = BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264)
        // Small and efficient in mp4 -> copy.
        assertTrue(
            BitrateCalc.shouldCopyAsIs(1920, 1920, (target * 1.10).toLong(), target, true)
        )
        // Bitrate too high -> no copy.
        assertFalse(
            BitrateCalc.shouldCopyAsIs(1920, 1920, (target * 1.30).toLong(), target, true)
        )
        // Larger than preset -> no copy.
        assertFalse(BitrateCalc.shouldCopyAsIs(3840, 1920, target.toLong(), target, true))
        // Weird container -> no copy.
        assertFalse(BitrateCalc.shouldCopyAsIs(1920, 1920, target.toLong(), target, false))
        // Unknown source bitrate -> no copy (re-encode instead).
        assertFalse(BitrateCalc.shouldCopyAsIs(1920, 1920, 0, target, true))
    }

    @Test
    fun resultCheckCatchesEncoderMisbehaviour() {
        val target = 6_000_000
        // Good result.
        assertTrue(BitrateCalc.resultAcceptable(100_000_000, 40_000_000, 6_000_000, target, 60_000, 60_500))
        // Output not smaller than source -> reject.
        assertFalse(BitrateCalc.resultAcceptable(100, 100, 6_000_000, target, 60_000, 60_000))
        // Encoder ignored bitrate (>1.3x) -> reject.
        assertFalse(
            BitrateCalc.resultAcceptable(100_000_000, 90_000_000, 8_000_000, target, 60_000, 60_000)
        )
        // Duration drifted more than 2 s -> reject.
        assertFalse(
            BitrateCalc.resultAcceptable(100_000_000, 40_000_000, 6_000_000, target, 60_000, 63_000)
        )
        // Empty output -> reject.
        assertFalse(BitrateCalc.resultAcceptable(100, 0, 0, target, 60_000, 60_000))
    }

    @Test
    fun sampleSizeSelection() {
        // 8000x6000 = 48 MP; budget 16 MP -> sample 2 gives 12 MP.
        assertEquals(2, BitrateCalc.sampleSizeFor(8000, 6000, 16_000_000))
        // Already within budget -> 1.
        assertEquals(1, BitrateCalc.sampleSizeFor(4000, 3000, 16_000_000))
        // Very large -> powers of two only.
        val s = BitrateCalc.sampleSizeFor(16000, 12000, 8_000_000)
        assertTrue(s > 0 && (s and (s - 1)) == 0)
        assertTrue((16000L / s) * (12000L / s) <= 8_000_000L * 4)
    }

    @Test
    fun `a copy that overshot every target is kept only when it is a real saving`() {
        // Half the size of the original, the right length: kept.
        assertTrue(BitrateCalc.worthKeeping(2_659_080, 1_260_989, 2_000, 1_966))
        // A tenth or less saved is not worth a re-encoded copy.
        assertFalse(BitrateCalc.worthKeeping(1_000_000, 950_000, 2_000, 2_000))
        // Never larger, never empty.
        assertFalse(BitrateCalc.worthKeeping(1_000_000, 1_200_000, 2_000, 2_000))
        assertFalse(BitrateCalc.worthKeeping(1_000_000, 0, 2_000, 2_000))
        // A clip that came out the wrong length is broken, however small.
        assertFalse(BitrateCalc.worthKeeping(10_000_000, 2_000_000, 60_000, 50_000))
    }

    /** The source cap for a copy at the source's own size and frame rate, unless given. */
    private fun cap(
        bps: Long,
        mime: String?,
        w: Int,
        h: Int,
        fps: Float,
        codec: VideoCodec = VideoCodec.HEVC,
        out: Triple<Int, Int, Float> = Triple(w, h, fps)
    ) = BitrateCalc.sourceCapBps(bps, mime, w, h, fps, out.first, out.second, out.third, codec)

    @Test
    fun `a copy is asked for at most a part of what its source's picture holds`() {
        val share = BitrateCalc.SOURCE_SHARE
        // A Telegram episode: 720p H.264 at 980 kbps holds what HEVC keeps at
        // 980 / 1.45 = 676 kbps; an H.264 copy of it, the same 980.
        assertEquals((980_000 / 1.45 * share).toInt(), cap(980_000, "video/avc", 1280, 720, 30f))
        assertEquals((980_000 * share).toInt(), cap(980_000, "video/avc", 1280, 720, 30f, VideoCodec.H264))
        // An HEVC source holds its own rate in HEVC.
        assertEquals((900_000 * share).toInt(), cap(900_000, "video/hevc", 1280, 536, 24f))
        // Made smaller, a picture holds less: 4K30 at 20 Mbps down to 1080p30
        // holds a quarter of the pixels, to the power 0.75.
        val fourK = cap(20_000_000, "video/avc", 3840, 2160, 30f, out = Triple(1920, 1080, 30f))!!
        assertEquals(20_000_000 * Math.pow(0.25, 0.75) / 1.45 * share, fourK.toDouble(), 1.0)
        // A camera original is far above what the app asks for: the cap does not bind.
        val camera = cap(20_000_000, "video/avc", 1920, 1080, 30f)!!
        assertTrue(camera > BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC) * VideoShare.MAX)
        // Whatever the source, a copy at the cap is a real saving.
        assertTrue(share <= 0.7)
    }

    @Test
    fun `the cap stays inside the floor and the ceiling, and needs a known source`() {
        assertEquals(BitrateCalc.FLOOR_BPS, cap(50_000, "video/avc", 480, 270, 25f))
        assertEquals(BitrateCalc.CAP_BPS, cap(90_000_000, "video/hevc", 1920, 1080, 30f))
        assertEquals(null, cap(980_000, null, 1280, 720, 30f))
        assertEquals(null, cap(980_000, "video/x-unknown", 1280, 720, 30f))
        assertEquals(null, cap(0, "video/avc", 1280, 720, 30f))
    }
}
