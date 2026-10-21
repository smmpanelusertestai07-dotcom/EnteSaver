package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BitrateCalcTest {

    @Test
    fun bitrateTable1080p30() {
        // Where 1080p30 starts: 4.5 Mbps in HEVC, and H.264 asked for 1.45 times it.
        assertEquals(4_500_000, BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC))
        assertEquals(6_525_000, BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264))
    }

    @Test
    fun `smaller pictures get more bits per pixel`() {
        // 720p has 44% of 1080p's pixels and gets 54% of its rate.
        assertEquals(2_449_489, BitrateCalc.targetBps(1280, 720, 30f, VideoCodec.HEVC))
        // A WhatsApp 480p clip.
        assertEquals(1_327_078, BitrateCalc.targetBps(848, 480, 30f, VideoCodec.HEVC))
        // Slow motion keeps its frames: four times the frames, 2.8 times the rate.
        assertEquals(12_727_922, BitrateCalc.targetBps(1920, 1080, 120f, VideoCodec.HEVC))
        // 4K is kept at 4K, at 2.8 times 1080p's rate; 60 fps at 1.7 times.
        assertEquals(12_727_922, BitrateCalc.targetBps(3840, 2160, 30f, VideoCodec.HEVC))
        assertEquals(7_568_067, BitrateCalc.targetBps(1920, 1080, 60f, VideoCodec.HEVC))
        val hd = BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC).toDouble()
        val half = BitrateCalc.targetBps(1920, 540, 30f, VideoCodec.HEVC).toDouble()
        assertEquals(Math.pow(0.5, BitrateCalc.SCALE_EXPONENT), half / hd, 0.001)
    }

    @Test
    fun bitrateCapAndFloor() {
        // 8K at 120 fps in H.264 would be 148 Mbps -> capped at 80 Mbps.
        assertEquals(BitrateCalc.CAP_BPS, BitrateCalc.targetBps(7680, 4320, 120f, VideoCodec.H264))
        // 4K at 60 fps in fast motion stays under the cap.
        assertTrue(BitrateCalc.targetBps(3840, 2160, 60f, VideoCodec.H264) * VideoShare.MAX < BitrateCalc.CAP_BPS)
        // Tiny video -> floored.
        assertEquals(BitrateCalc.FLOOR_BPS, BitrateCalc.targetBps(160, 120, 15f, VideoCodec.H264))
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
    fun `a copy is as long as its original within two seconds`() {
        assertTrue(BitrateCalc.sameLength(60_000, 60_500))
        assertTrue(BitrateCalc.sameLength(60_000, 58_000))
        assertFalse(BitrateCalc.sameLength(60_000, 63_000))
        // An original that does not say how long it is cannot be told apart.
        assertTrue(BitrateCalc.sameLength(0, 12_345))
    }

    @Test
    fun `a copy may carry at most most of its source, and must weigh less than it`() {
        assertTrue(BitrateCalc.MAX_OF_SOURCE < 1.0)
        assertTrue(BitrateCalc.MAX_COPY_SHARE < 1.0)
    }
}
