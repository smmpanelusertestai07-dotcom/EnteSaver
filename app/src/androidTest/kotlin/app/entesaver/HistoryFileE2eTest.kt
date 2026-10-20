package app.entesaver

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import app.entesaver.core.logic.Defaults
import app.entesaver.data.db.AppDb
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.SnapshotStore
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The daily history file on a real Android: one file, found again on the next
 * pass and written over rather than beside, readable back - and the hidden
 * folders older versions filled, one file per pass, emptied of what this app
 * put there.
 *
 * Android 9 records no owner for a file, so there the suite looks at the
 * folders themselves: the history file is still one file, and what is in the
 * old hidden folders - which no build that ran on Android 9 ever wrote - is
 * not the app's to remove, and stays.
 */
@RunWith(AndroidJUnit4::class)
class HistoryFileE2eTest {

    /** Android 9 writes the history file with storage access. */
    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(*TestPermissions.forSharedFiles())

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val repo: OptionsRepo get() = OptionsRepo.get(context)
    private val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private var onboardingWas = false

    private fun store() = SnapshotStore(context, AppDb.get(context), repo)

    /** This install's files in [dir], by name; on Android 9 every file there. */
    private fun own(dir: String): List<Pair<Uri, String>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return folder(dir).listFiles().orEmpty()
                .filter { it.isFile && !it.name.startsWith(".") }
                .map { Uri.fromFile(it) to it.name }
        }
        val out = mutableListOf<Pair<Uri, String>>()
        context.contentResolver.query(
            files,
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME),
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?",
            arrayOf("$dir/", context.packageName),
            null
        )?.use { c ->
            while (c.moveToNext()) {
                out += Uri.withAppendedPath(files, c.getLong(0).toString()) to c.getString(1)
            }
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun folder(dir: String) = File(Environment.getExternalStorageDirectory(), dir)

    private val historyDirs = Defaults.SNAPSHOT_TARGETS.map { it.first }

    private fun removeAll() {
        for (dir in historyDirs + Defaults.PREVIOUS_SNAPSHOT_DIRS) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                folder(dir).listFiles()?.forEach { it.delete() }
                continue
            }
            for ((uri, _) in own(dir)) runCatching { context.contentResolver.delete(uri, null, null) }
        }
    }

    /** A file the way a build before 12.0 left it; false where this Android refuses the place. */
    private fun leaveOldFile(dir: String, name: String): Boolean = runCatching {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            folder(dir).mkdirs()
            File(folder(dir), name).writeBytes("{}".toByteArray())
            return@runCatching true
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/")
        }
        val collection = if (dir.startsWith("${Environment.DIRECTORY_DOWNLOADS}/")) {
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            files
        }
        val uri = context.contentResolver.insert(collection, values)!!
        context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write("{}".toByteArray()) }
        true
    }.getOrDefault(false)

    @Before
    fun setUp(): Unit = runBlocking {
        AppDb.get(context).clearAllTables()
        onboardingWas = repo.current().onboardingDone
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
        removeAll()
    }

    @After
    fun tearDown(): Unit = runBlocking {
        removeAll()
        repo.setBool(OptionsRepo.K.ONBOARDING_DONE, onboardingWas)
        // A restore is watched for a week; the tests after this one are not
        // about that (an old date, not none: an unset one is a restore made
        // by an earlier version, watched from its first pass).
        repo.setLong(OptionsRepo.K.RESTORED_AT, 1L)
    }

    @Test
    fun theHistoryIsOneFileWrittenOverEachTime(): Unit = runBlocking {
        assertTrue("the first write must land", store().writeSafetySnapshot())
        assertTrue("the second write must land", store().writeSafetySnapshot())
        assertTrue("and the third", store().writeSafetySnapshot())

        val written = historyDirs.flatMap { own(it) }
        assertEquals("one history file, not one per pass: $written", 1, written.size)
        assertEquals(Defaults.HISTORY_NAME, written.single().second)
        assertTrue("the next pass knows it is there", store().sharedTargetsPresent())
        assertNotNull("and it reads back", store().readBestSnapshot())
    }

    @Test
    fun whatOlderVersionsLeftInTheirHiddenFoldersIsRemoved(): Unit = runBlocking {
        val left = Defaults.PREVIOUS_SNAPSHOT_DIRS
            .filter { it.substringAfter('/').startsWith("_") }
            .filter { dir -> leaveOldFile(dir, "state.json") && leaveOldFile(dir, "state (1).json") }
        assertTrue("there must be somewhere to leave an old file", left.isNotEmpty())
        for (dir in left) assertEquals(2, own(dir).size)

        assertTrue(store().writeSafetySnapshot())

        for (dir in left) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                assertEquals("$dir is not this app's to empty on Android 9", 2, own(dir).size)
            } else {
                assertEquals("$dir must be emptied of this app's files", emptyList<Pair<Uri, String>>(), own(dir))
            }
        }
        assertEquals(1, historyDirs.flatMap { own(it) }.size)
    }
}
