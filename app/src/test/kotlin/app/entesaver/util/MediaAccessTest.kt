package app.entesaver.util

import app.entesaver.util.Permissions.MediaAccess
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BB1: the access-level decision, and the places that must obey it.
 *
 * Under Android 14's "Select photos", MediaStore answers every query as if
 * the handful the user picked were the whole gallery. The app used to treat
 * that grant as usable access and present the handful as fact. The decision
 * is now a three-way level, and everything that scans, counts or projects
 * asks for the level rather than the old boolean.
 */
class MediaAccessTest {

    private fun level(
        sdk: Int,
        images: Boolean = false,
        video: Boolean = false,
        selected: Boolean = false,
        legacy: Boolean = false,
        write: Boolean = false
    ) = Permissions.mediaAccessFor(sdk, images, video, selected, legacy, write)

    @Test
    fun `api 28 needs storage write as well as read`() {
        // Android 9 writes every copy into its folder as a file: reading the
        // gallery without that would queue work the app cannot finish.
        assertEquals(MediaAccess.FULL, level(sdk = 28, legacy = true, write = true))
        assertEquals(MediaAccess.NONE, level(sdk = 28, legacy = true))
        assertEquals(MediaAccess.NONE, level(sdk = 28, write = true))
        assertEquals(MediaAccess.NONE, level(sdk = 28, images = true, video = true, selected = true))
    }

    @Test
    fun `api 29 knows only full or none`() {
        assertEquals(MediaAccess.FULL, level(sdk = 29, legacy = true))
        // Write access is for Replace on this phone there, never for reading.
        assertEquals(MediaAccess.NONE, level(sdk = 29, write = true))
        assertEquals(MediaAccess.NONE, level(sdk = 29, legacy = false))
        // The user-selected grant does not exist there; even if some OEM
        // reported it, it must not count.
        assertEquals(MediaAccess.NONE, level(sdk = 29, selected = true))
    }

    @Test
    fun `api 33 wants both halves of the gallery before it says full`() {
        assertEquals(MediaAccess.FULL, level(sdk = 33, images = true, video = true))
        // Android 13 asks for photos and videos separately, so a phone can
        // easily end up with one of the two. Half a gallery is not a full
        // view of it: the missing half is invisible to every query, and
        // calling that FULL is how the counts came to leave videos out.
        assertEquals(MediaAccess.PARTIAL, level(sdk = 33, images = true))
        assertEquals(MediaAccess.PARTIAL, level(sdk = 33, video = true))
        assertEquals(MediaAccess.NONE, level(sdk = 33))
        // READ_MEDIA_VISUAL_USER_SELECTED is API 34; on 33 it means nothing.
        assertEquals(MediaAccess.NONE, level(sdk = 33, selected = true))
        // The legacy permission is ignored on 33 - it grants nothing there.
        assertEquals(MediaAccess.NONE, level(sdk = 33, legacy = true))
    }

    @Test
    fun `api 34 distinguishes full from the user-selected handful`() {
        assertEquals(MediaAccess.FULL, level(sdk = 34, images = true, video = true))
        assertEquals(MediaAccess.PARTIAL, level(sdk = 34, selected = true))
        // Photos without videos hides as much of the phone as the handful
        // does, so it reads the same way.
        assertEquals(MediaAccess.PARTIAL, level(sdk = 34, images = true))
        assertEquals(MediaAccess.PARTIAL, level(sdk = 34, video = true))
        assertEquals(MediaAccess.NONE, level(sdk = 34))
        // Full always wins when both are granted, which Android does report
        // during the "keep access" flow.
        assertEquals(
            MediaAccess.FULL,
            level(sdk = 34, images = true, video = true, selected = true)
        )
    }

    // ---- the callers that must ask for the level, verified in source -------

    private fun source(path: String): String {
        val file = File(path)
        assertTrue("$path must exist", file.isFile)
        return file.readText()
    }

    @Test
    fun `scanning refuses to run under partial access`() {
        val scanner = source("src/main/kotlin/app/entesaver/media/MediaScanner.kt")
        assertTrue(
            "MediaScanner.scan must check the access level itself, so no " +
                "caller can forget",
            scanner.contains("Permissions.mediaAccess(context) != Permissions.MediaAccess.FULL")
        )
        val worker = source("src/main/kotlin/app/entesaver/work/CompressWorker.kt")
        assertTrue(
            "the worker must stop under PARTIAL, not only under NONE",
            worker.contains("Permissions.mediaAccess(app) != Permissions.MediaAccess.FULL")
        )
    }

    @Test
    fun `home shows the card and files shows the chip`() {
        val home = source("src/main/kotlin/app/entesaver/ui/screens/HomeScreen.kt")
        assertTrue(
            "Home must surface the limited-access card",
            home.contains("AccessNotice.title(") && home.contains("AccessNotice.isLimited(")
        )
        val files = source("src/main/kotlin/app/entesaver/ui/screens/FilesScreen.kt")
        assertTrue(
            "Files must surface the limited-access chip",
            files.contains("AccessNotice.chip(") && files.contains("AccessNotice.isLimited(")
        )
    }

    @Test
    fun `storage and the calculator wait instead of showing numbers`() {
        for (screen in listOf("StorageScreen", "CalculatorScreen")) {
            val text = source("src/main/kotlin/app/entesaver/ui/screens/$screen.kt")
            assertTrue(
                "$screen must render the waiting text whenever access is short of " +
                    "full, never a total",
                text.contains("AccessNotice.waiting(") && text.contains("AccessNotice.isLimited(")
            )
        }
    }

    @Test
    fun `snapshots record the access level they were taken under`() {
        val codec = source("src/main/kotlin/app/entesaver/core/logic/SnapshotCodec.kt")
        assertTrue(
            "the snapshot payload must carry mediaAccess",
            codec.contains("\"mediaAccess\"")
        )
    }

    /**
     * There are two ways to lose sight of the gallery, and only one of them
     * used to have any words. A screen asking "is it partial?" says nothing
     * at all when the answer is "there is no access": Home went blank, the
     * Files list read as an empty gallery, and the calculator printed a total
     * from a database nothing was refreshing - a number about photographs the
     * app could no longer see.
     *
     * So screens ask whether access is full. The one place allowed to name
     * PARTIAL is where the words are chosen.
     */
    @Test
    fun `no screen asks whether access is partial`() {
        val offenders = mutableListOf<String>()
        for (file in File("src/main/kotlin/app/entesaver/ui").walkTopDown()) {
            if (!file.isFile || file.extension != "kt") continue
            val code = file.readLines()
                .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
                .joinToString("\n")
            // Naming PARTIAL is fine in a file that also answers for NONE -
            // the setup step chooses between all three, and AccessNotice is
            // where the wording for each is picked. What is not fine is a
            // screen that knows only about the middle case.
            if (code.contains("MediaAccess.NONE")) continue
            for (m in Regex("""[=!]=\s*(?:[A-Za-z.]*)MediaAccess\.PARTIAL""").findAll(code)) {
                offenders += "${file.name}: ${m.value.trim()}"
            }
        }
        assertTrue(
            "these branch on partial access, so they say nothing when access is " +
                "switched off entirely and the screen states something untrue: " +
                "$offenders",
            offenders.isEmpty()
        )
    }

    /** No-access must have its own words, not partial access's, in every slot. */
    @Test
    fun `losing access entirely is worded as itself`() {
        val notice = File("src/main/kotlin/app/entesaver/ui/components/AccessNotice.kt").readText()
        for (slot in listOf("title", "body", "action", "chip", "waiting")) {
            val fn = notice.substringAfter("fun $slot(", "").substringBefore("\n\n")
            assertTrue("AccessNotice.$slot is gone", fn.isNotEmpty())
            assertTrue(
                "AccessNotice.$slot hands no-access the partial-access wording, " +
                    "which tells someone they picked some photos when they picked none",
                fn.contains("R.string.no_access_")
            )
        }
    }
}
