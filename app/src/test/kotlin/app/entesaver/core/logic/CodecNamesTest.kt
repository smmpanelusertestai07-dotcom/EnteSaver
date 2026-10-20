package app.entesaver.core.logic

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** On Android 9 a codec's name is the only way to tell a chip from software. */
class CodecNamesTest {

    @Test
    fun `Android's own codecs and the vendors' software ones are software`() {
        for (name in listOf(
            "OMX.google.h264.encoder",
            "c2.android.hevc.encoder",
            "OMX.ffmpeg.h264.encoder",
            "OMX.SEC.avc.sw.enc",
            "OMX.vendor.video.encoder.avc.sw",
            "OMX.example.software.encoder",
            "AVCEncoder"
        )) {
            assertTrue(name, CodecNames.looksSoftware(name))
        }
    }

    @Test
    fun `a vendor's codec is hardware`() {
        for (name in listOf(
            "OMX.qcom.video.encoder.avc",
            "OMX.qcom.video.encoder.hevc",
            "OMX.Exynos.HEVC.Encoder",
            "OMX.MTK.VIDEO.ENCODER.AVC",
            "OMX.hisi.video.encoder.hevc",
            "c2.qti.avc.encoder"
        )) {
            assertFalse(name, CodecNames.looksSoftware(name))
        }
    }
}
