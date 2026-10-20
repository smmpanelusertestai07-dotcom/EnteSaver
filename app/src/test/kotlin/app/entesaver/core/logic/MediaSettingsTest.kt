package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * There is one way to optimise: photos at Storage saver's size limit, videos
 * at their own size and frame rate, each file at the quality it needs. These
 * pin the limits and the keys results are grouped under, which files made by
 * earlier versions still carry.
 */
class MediaSettingsTest {

    @Test
    fun `photos keep Storage saver's limit, videos their own size and frame rate`() {
        assertEquals(16, MediaSettings.PHOTO.maxMp)
        assertEquals(16_000_000L, MediaSettings.PHOTO.maxPixels)
        assertEquals(0, MediaSettings.VIDEO.longSide)
        assertEquals(Int.MAX_VALUE, MediaSettings.VIDEO.longSideLimit)
        assertEquals(0, MediaSettings.VIDEO.fpsCap)
        for (fps in listOf(24f, 30f, 60f, 120f, 240f)) {
            assertNull("$fps fps is written as filmed", MediaSettings.outputFps(fps, MediaSettings.VIDEO.fpsCap))
        }
    }

    @Test
    fun `full size and same resolution keep everything`() {
        assertEquals(Long.MAX_VALUE, PhotoSpec(0).maxPixels)
        assertEquals(Int.MAX_VALUE, VideoSpec(longSide = 0, fpsCap = 30).longSideLimit)
    }

    @Test
    fun `an ordinary high frame rate is capped, slow motion never is`() {
        assertEquals(30f, MediaSettings.outputFps(60f, 30))
        assertEquals(30f, MediaSettings.outputFps(59.94f, 30))
        assertNull("already at the cap", MediaSettings.outputFps(30f, 30))
        assertNull("a hair over the cap is the same rate", MediaSettings.outputFps(30.2f, 30))
        assertNull("slow motion keeps every frame", MediaSettings.outputFps(120f, 30))
        assertNull("slow motion keeps every frame", MediaSettings.outputFps(240f, 30))
        assertNull("no cap asked for", MediaSettings.outputFps(60f, 0))
        assertNull(MediaSettings.outputFps(Float.NaN, 30))
    }

    @Test
    fun `keys group results by how the file was made and read back for the details`() {
        assertEquals("heic-16", MediaSettings.photoKey(PhotoFormat.HEIC))
        assertEquals(MediaSettings.PhotoKey(PhotoFormat.HEIC, 16), MediaSettings.parsePhotoKey("heic-16"))
        assertEquals("hevc-0", MediaSettings.videoKey(VideoCodec.HEVC))
        assertEquals("h264-0", MediaSettings.videoKey(VideoCodec.H264))
        assertEquals(MediaSettings.VideoKey(VideoCodec.HEVC, 0), MediaSettings.parseVideoKey("hevc-0"))
        // Every video handled the way new ones are, in either codec or left
        // as it was, counts in an estimate; a video left as it was names no codec.
        assertEquals(listOf("h264-0", "hevc-0", "asis-0"), MediaSettings.videoKeys())
        assertNull(MediaSettings.parseVideoKey(MediaSettings.videoKeyAsIs()))
        // Earlier versions made videos HEVC at 1080p; their key still reads.
        assertEquals(MediaSettings.VideoKey(VideoCodec.HEVC, 1920), MediaSettings.parseVideoKey("hevc-1920"))
        // Keys written by versions with quality presets still read.
        assertEquals(MediaSettings.PhotoKey(PhotoFormat.JPEG, 16), MediaSettings.parsePhotoKey("jpeg-16-82"))
        assertEquals(MediaSettings.VideoKey(VideoCodec.H264, 2560), MediaSettings.parseVideoKey("h264-2560-std"))
        assertNull(MediaSettings.parsePhotoKey("STORAGE_SAVER"))
        assertNull(MediaSettings.parsePhotoKey("auto-16-82"))
        assertNull(MediaSettings.parseVideoKey("garbage"))
    }

    @Test
    fun `HEVC needs fewer bits than H264 for the same look`() {
        assertEquals(1.0, BitrateCalc.codecFactor(VideoCodec.HEVC), 0.0)
        assertEquals(BitrateCalc.H264_FACTOR, BitrateCalc.codecFactor(VideoCodec.H264), 0.0)
        assertTrue(BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.HEVC) < BitrateCalc.targetBps(1920, 1080, 30f, VideoCodec.H264))
    }
}
