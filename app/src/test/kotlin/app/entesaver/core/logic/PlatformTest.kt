package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformTest {

    @Test
    fun `Android 9 and 10 are supported, but without undo`() {
        // The distinction this whole class exists for: the app runs there,
        // and a removal there cannot be taken back.
        for (sdk in listOf(28, 29)) {
            assertEquals("API $sdk", Platform.Support.NO_UNDO, Platform.supportFor(sdk))
            assertFalse(Platform.canTrash(sdk))
            assertFalse(Platform.canBatchDelete(sdk))
        }
    }

    @Test
    fun `Android 11 onwards gets everything`() {
        for (sdk in 30..40) {
            assertEquals("API $sdk", Platform.Support.FULL, Platform.supportFor(sdk))
            assertTrue(Platform.canTrash(sdk))
        }
    }

    @Test
    fun `the trash boundary is exactly Android 11`() {
        assertFalse(Platform.canTrash(Platform.TRASH_SDK - 1))
        assertTrue(Platform.canTrash(Platform.TRASH_SDK))
        assertEquals(30, Platform.TRASH_SDK)
    }

    @Test
    fun `the stated minimum matches what the app is built for`() {
        assertEquals(28, Platform.MIN_SDK)
        assertEquals(36, Platform.TARGET_SDK)
        assertTrue(Platform.TARGET_SDK > Platform.MIN_SDK)
    }

    @Test
    fun `every supported level has a name people recognise`() {
        assertEquals("9", Platform.releaseName(28))
        assertEquals("10", Platform.releaseName(29))
        assertEquals("11", Platform.releaseName(30))
        assertEquals("12L", Platform.releaseName(32))
        assertEquals("16", Platform.releaseName(36))
        for (sdk in Platform.MIN_SDK..Platform.TARGET_SDK) {
            assertFalse(
                "API $sdk should have a release name",
                Platform.releaseName(sdk).startsWith("API ")
            )
        }
    }

    @Test
    fun `an unknown future version says the number rather than guessing`() {
        assertEquals("API 99", Platform.releaseName(99))
        // The phone's own version string, when it has one.
        assertEquals("18", Platform.releaseName(38, "18"))
        assertEquals("17", Platform.releaseName(37))
    }
}
