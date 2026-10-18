package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoShareTest {

    @Test
    fun `a still scene gets the least, fast motion the most`() {
        // A talking head (TI about 4) and a still YouTube talk.
        assertEquals(0.7, VideoShare.of(3.2, 120.0, screenRecording = false), 1e-9)
        // A daylight pan (TI about 14).
        assertEquals(1.125, VideoShare.of(14.0, 120.0, screenRecording = false), 1e-9)
        // Children running, a festival (TI 30 and over).
        assertEquals(2.4, VideoShare.of(30.0, 120.0, screenRecording = false), 1e-9)
        assertEquals(2.4, VideoShare.of(55.0, 120.0, screenRecording = false), 1e-9)
    }

    @Test
    fun `the share rises with motion, never falling`() {
        var last = 0.0
        var ti = 0.0
        while (ti <= 40.0) {
            val s = VideoShare.of(ti, 120.0, screenRecording = false)
            assertTrue("share at TI $ti fell to $s", s >= last)
            last = s
            ti += 0.5
        }
    }

    @Test
    fun `a dark scene gets enough for its noise and shadows, whatever it does`() {
        assertEquals(VideoShare.DARK_SHARE, VideoShare.of(9.5, 40.0, screenRecording = false), 1e-9)
        // Dark and fast stays fast.
        assertEquals(2.4, VideoShare.of(32.0, 40.0, screenRecording = false), 1e-9)
    }

    @Test
    fun `a screen recording keeps its text sharp`() {
        assertEquals(VideoShare.SCREEN_SHARE, VideoShare.of(13.0, 200.0, screenRecording = true), 1e-9)
        assertEquals(2.4, VideoShare.of(31.0, 120.0, screenRecording = true), 1e-9)
    }

    @Test
    fun `a video whose frames could not be read gets the standard rate`() {
        assertEquals(1.0, VideoShare.of(null, null, screenRecording = false), 1e-9)
        assertEquals(1.0, VideoShare.of(Double.NaN, 100.0, screenRecording = false), 1e-9)
        assertEquals(VideoShare.SCREEN_SHARE, VideoShare.of(null, null, screenRecording = true), 1e-9)
    }

    @Test
    fun `every share is inside the range`() {
        for (ti in listOf(-5.0, 0.0, 7.0, 15.0, 25.0, 100.0)) {
            for (luma in listOf(10.0, 69.9, 70.0, 250.0)) {
                for (screen in listOf(false, true)) {
                    val s = VideoShare.of(ti, luma, screen)
                    assertTrue("$ti $luma $screen -> $s", s in VideoShare.MIN..VideoShare.MAX)
                }
            }
        }
    }

    @Test
    fun `screen recordings are known by the names phones give them`() {
        assertTrue(VideoShare.isScreenRecording("Screen_Recording_20241106_150533.mp4", "Screenshots"))
        assertTrue(VideoShare.isScreenRecording("screen-20250101-101010.mp4", "Screen recordings"))
        assertTrue(VideoShare.isScreenRecording("Screenrecorder-2025-07-11.mp4", "ScreenRecorder"))
        assertTrue(VideoShare.isScreenRecording("video.mp4", "Screenshots"))
        assertFalse(VideoShare.isScreenRecording("VID20250807061026.mp4", "Camera"))
        assertFalse(VideoShare.isScreenRecording("VID-20231029-WA5294.mp4", "WhatsApp Video"))
        assertFalse(VideoShare.isScreenRecording("Movie 7914 (2025) 720p HEVC.mp4", null))
    }
}
