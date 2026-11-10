package com.pocketide.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class OldVersionFilesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `an update from 3_0 deletes the old computer and keeps version 5's computer and the settings`() {
        val folders = folders()
        // What 3.0.0 kept: the Linux, a project copy, an agent's sign-in, its sealed tokens, the Google account's name.
        val old = listOf(
            put(folders.files, "rootfs/usr/bin/node"),
            put(folders.files, "rooms/claude/home/.claude/.credentials.json"),
            put(folders.files, "work/claude/owner__app/s1/main.kt"),
            put(folders.files, "secure/github"),
            put(folders.noBackup, "git-gate/state"),
            put(folders.noBackup, "androidx.work.workdb"),
            put(folders.cache, "downloads/media-staging/shot.png"),
            put(folders.data, "databases/old.db"),
            put(folders.data, "shared_prefs/pocketide.google.xml"),
            put(folders.data, "shared_prefs/WebViewChromiumPrefs.xml"),
            put(folders.data, "app_webview/Default/Cookies"),
        )
        val kept = listOf(
            put(folders.files, "computer/home/projects/app/main.kt"),
            put(folders.data, "shared_prefs/pocketide.settings.xml"),
            put(folders.data, "shared_prefs/pocketide.settings.xml.bak"),
        )

        assertTrue(OldVersionFiles.removeOnce(folders))

        old.forEach { assertFalse("$it should be gone", it.exists()) }
        kept.forEach { assertTrue("$it should stay", it.exists()) }
        assertEquals(listOf("computer"), folders.files.list()?.toList())
    }

    @Test
    fun `an update from 5_x deletes the sealed keys and the agent page's storage, and keeps the phone computer`() {
        val folders = folders()
        put(folders.noBackup, "old-versions-removed")
        put(folders.noBackup, "v5-removed")
        val gone = listOf(
            put(folders.noBackup, "secure/keys.bin"),
            put(folders.noBackup, "secure/github.token"),
            put(folders.data, "app_webview/Default/Local Storage/leveldb/000003.log"),
            put(folders.cache, "WebView/Default/HTTP Cache/index"),
            put(folders.cache, "org.chromium.android_webview/state"),
            put(folders.data, "shared_prefs/WebViewChromiumPrefs.xml"),
        )
        val kept = listOf(
            put(folders.files, "computer/home/projects/app/main.kt"),
            put(folders.cache, "agent-icons/claude.png"),
            put(folders.data, "shared_prefs/pocketide.settings.xml"),
        )

        assertTrue(OldVersionFiles.removeOnce(folders))

        gone.forEach { assertFalse("$it should be gone", it.exists()) }
        kept.forEach { assertTrue("$it should stay", it.exists()) }
        assertFalse("runs once", OldVersionFiles.removeOnce(folders))
    }

    @Test
    fun `it runs once, so later files are left alone`() {
        val folders = folders()
        put(folders.files, "rootfs/etc/os-release")
        OldVersionFiles.removeOnce(folders)

        val later = put(folders.files, "profileinstaller_profileWrittenFor_lastUpdateTime.dat")
        OldVersionFiles.removeOnce(folders)

        assertTrue(later.exists())
    }

    @Test
    fun `deleting the phone's data takes the phone computer too, and keeps only the settings`() {
        val folders = folders()
        OldVersionFiles.removeOnce(folders)
        val gone = listOf(
            put(folders.files, "computer/home/projects/app/main.kt"),
            put(folders.cache, "agent-icons/claude.png"),
            put(folders.noBackup, "last-stop.txt"),
        )
        val settings = put(folders.data, "shared_prefs/pocketide.settings.xml")

        assertTrue(OldVersionFiles.remove(folders))

        gone.forEach { assertFalse("$it should be gone", it.exists()) }
        assertTrue(settings.exists())
    }

    private fun folders(): AppFolders {
        val data = tmp.newFolder("data")
        return AppFolders(
            files = File(data, "files").apply { mkdirs() },
            noBackup = File(data, "no_backup").apply { mkdirs() },
            cache = File(data, "cache").apply { mkdirs() },
            data = data,
        )
    }

    private fun put(dir: File, path: String): File = File(dir, path).apply {
        parentFile?.mkdirs()
        writeText(path)
    }
}
