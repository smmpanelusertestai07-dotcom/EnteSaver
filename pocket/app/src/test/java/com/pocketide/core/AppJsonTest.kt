package com.pocketide.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppJsonTest {
    @Test
    fun `settings an older version saved still load, keeping what still means something`() {
        // 5.x wrote the phone computer's fields (key bar, project, updates), which 6.0 no longer has.
        val saved = """
            {"theme":"DARK","appLock":true,"onboardingDone":true,"termsAccepted":5,"keyBar":false,"project":"app",
             "updatesOnMobileData":true,"lastUpdate":1759000000000,"cloudAccount":"dev@example.com"}
        """.trimIndent()
        val settings = AppJson.decodeFromString(Settings.serializer(), saved)
        assertEquals(ThemeMode.DARK, settings.theme)
        assertTrue(settings.appLock)
        assertTrue(settings.onboardingDone)
        assertEquals(5, settings.termsAccepted)
        assertEquals("dev@example.com", settings.cloudAccount)
        assertEquals("not set up yet", 0L, settings.cloudSetUpAt)
    }

    @Test
    fun `deleting everything puts every choice back`() {
        val used = Settings(theme = ThemeMode.DARK, appLock = true, cloudAccount = "dev@example.com", cloudSetUpAt = 1, cloudOpenedAt = 2)
        val after = used.afterDeleteEverything()
        assertEquals(Settings(), after)
        assertFalse(after.onboardingDone)
    }

    @Test
    fun `the safe choices are the defaults`() {
        val defaults = Settings()
        assertFalse("screenshots are never blocked; App lock is the owner's choice", defaults.appLock)
        assertEquals("no Google account until the owner picks one", "", defaults.cloudAccount)
    }
}
