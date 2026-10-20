package app.entesaver

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The app is called Ente Saver everywhere: on the phone, and in every file of
 * the repository. The old name survives only where it names something that
 * exists outside this app - the earlier app it replaces, and the folders and
 * files older versions left on phones.
 */
class BrandingTest {

    private val strings = File("src/main/res/values/strings.xml").readText()

    private val root = generateSequence(File("").absoluteFile) { it.parentFile }
        .first { File(it, ".github/workflows/build.yml").isFile }

    /** Every place the old name may stay, and why. */
    private val permanent = listOf(
        // The earlier app's application ID (until 12.2), by which this one finds it -
        // the id alone, never a component of this app under it.
        Regex("""\bapp\.cloudsaver\b(?!\.)"""),
        // Folders and files older versions wrote, still watched or read -
        // and, in tests, the look-alike folder names that must not match them.
        Regex("""(?i)\bpictures/cloudsaver\w*"""),
        Regex("""\bDocuments/CloudSaver\b"""),
        Regex("""\.cloudsaver\b"""),
        Regex("""\bcloudsaver_keep\b"""),
        // Old folder names as names.
        Regex(""""CloudSaver\w*""""),
    )

    @Test
    fun `the app's name is Ente Saver`() {
        assertTrue(Regex("""<string name="app_name"[^>]*>Ente Saver</string>""").containsMatchIn(strings))
    }

    @Test
    fun `the old name is left only where it is a permanent identifier`() {
        val tracked = runCatching {
            val git = ProcessBuilder("git", "ls-files", "-z")
                .directory(root).redirectErrorStream(true).start()
            val names = git.inputStream.bufferedReader().readText()
            if (git.waitFor() != 0) null else names.split('\u0000').filter { it.isNotEmpty() }
        }.getOrNull()
        assertTrue("git must be able to list the repository", tracked != null)
        val binary = setOf("png", "jpg", "webp", "jar", "jks", "keystore", "ttf", "otf", "so")
        val oldName = Regex("(?i)cloud\\s*saver")
        val offenders = tracked!!
            .filterNot { it.substringAfterLast('.').lowercase() in binary || it.endsWith("/BrandingTest.kt") }
            .flatMap { path ->
                val file = File(root, path)
                if (!file.isFile) return@flatMap emptyList()
                file.readLines().mapIndexedNotNull { i, line ->
                    val left = permanent.fold(line) { text, allowed -> allowed.replace(text, "") }
                    if (oldName.containsMatchIn(left)) "$path:${i + 1}: ${line.trim()}" else null
                }
            }
        assertEquals(emptyList<String>(), offenders)
    }

    @Test
    fun `the released file carries the new name`() {
        val workflow = File(root, ".github/workflows/build.yml").readText()
        assertTrue(workflow.contains("EnteSaver-v\$VERSION-release.apk"))
        assertTrue(workflow.contains("Ente Saver \$TAG"))
        val e2e = File(root, ".github/scripts/emulator-e2e.sh").readText()
        assertTrue(e2e.contains("install_apk \"\$LIVE_LOG\" -r -g EnteSaver-release.apk"))
    }
}
