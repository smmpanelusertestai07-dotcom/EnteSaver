package app.entesaver

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The workflows must keep running on GitHub's runners without anyone
 * watching them.
 *
 * GitHub removes the Node 20 runtime from its runners on 23 September 2026.
 * Every JavaScript action pinned to a major that still says `using: node20`
 * stops loading that day, and a workflow that cannot load its checkout step
 * cannot even begin - CI goes red on a repository nobody changed. The
 * majors below are the first of each action to declare `node24`, read from
 * each action.yml at its tag; anything older is a pin that expires.
 */
class CiRuntimeTest {

    /** Unit tests run from app/; the workflows live beside it, one level up. */
    private fun repoRoot(): File? {
        var dir: File? = File(System.getProperty("user.dir").orEmpty()).absoluteFile
        while (dir != null) {
            if (File(dir, ".github/workflows").isDirectory) return dir
            dir = dir.parentFile
        }
        return null
    }

    private val workflows = File(repoRoot() ?: File("."), ".github/workflows")

    /** Action -> the lowest major whose action.yml runs on Node 24. */
    private val nodeTwentyFour = mapOf(
        "actions/checkout" to 5,
        "actions/setup-java" to 5,
        "actions/upload-artifact" to 6,
        "actions/download-artifact" to 7,
        "gradle/actions/setup-gradle" to 5,
        "reactivecircus/android-emulator-runner" to 2
    )

    @Test
    fun `the Gradle the wrapper downloads is the Gradle that was tested`() {
        // Every CI job starts on a fresh runner and downloads Gradle from the
        // URL below; without a checksum the wrapper runs whatever those bytes
        // turn out to be, and the release APK - whose hash and signing
        // fingerprint the release notes ask people to verify - is built by a
        // toolchain nobody verified. The value is the one services.gradle.org
        // publishes beside the distribution, confirmed against a download.
        val root = repoRoot()
        assertTrue("repository root not found from app/", root != null)
        val props = File(root, "gradle/wrapper/gradle-wrapper.properties").readLines()
        val url = props.firstOrNull { it.startsWith("distributionUrl=") }
        assertTrue("the wrapper must name its distribution", url != null)
        val sum = props.firstOrNull { it.startsWith("distributionSha256Sum=") }
            ?.substringAfter("=")
        assertTrue(
            "the wrapper must pin the SHA-256 of $url",
            sum != null && Regex("[0-9a-f]{64}").matches(sum)
        )
    }

    @Test
    fun `no action is pinned to a major that loses its runtime`() {
        assertTrue("the workflows directory must be found from app/", workflows.isDirectory)
        // A tag, or a commit with the tag it is written next to.
        val uses = Regex("""uses:\s*([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-/]+)@(?:[0-9a-f]{40}\s+#\s*)?v(\d+)""")
        val expiring = mutableListOf<String>()
        val unknown = mutableListOf<String>()
        for (file in workflows.listFiles { f -> f.extension == "yml" || f.extension == "yaml" }.orEmpty()) {
            file.readLines().forEachIndexed { idx, line ->
                val m = uses.find(line) ?: return@forEachIndexed
                val (action, major) = m.destructured
                val floor = nodeTwentyFour[action]
                if (floor == null) {
                    unknown += "${file.name}:${idx + 1} $action"
                } else if (major.toInt() < floor) {
                    expiring += "${file.name}:${idx + 1} $action@v$major (needs v$floor)"
                }
            }
        }
        assertTrue(
            "these actions are pinned below the first Node 24 major and stop " +
                "loading on 2026-09-23: $expiring",
            expiring.isEmpty()
        )
        assertTrue(
            "new actions must be added to the Node 24 table with the major " +
                "whose action.yml says `using: node24`: $unknown",
            unknown.isEmpty()
        )
    }

    @Test
    fun `the emulator harness hides system error dialogs before the suite`() {
        // A loaded runner can hang the emulator's launcher, and the "isn't
        // responding" dialog Android then shows takes window focus: taps and
        // back presses stop reaching the app under test and a leg goes red
        // with Ente Saver untouched (run 373 lost nine API 35 tests to the
        // Pixel Launcher's dialog). The harness turns those dialogs off
        // before the suite starts; the crash buffer and the process checks
        // it keeps still report every failure that is the app's.
        val root = repoRoot()
        assertTrue("repository root not found from app/", root != null)
        val script = File(root, ".github/scripts/emulator-e2e.sh").readText()
        val hide = script.indexOf("settings put global hide_error_dialogs 1")
        val suite = script.indexOf("connectedDebugAndroidTest")
        assertTrue("the emulator harness must hide the system's error dialogs", hide >= 0)
        assertTrue("and must do so before the instrumented suite starts", suite > hide)
    }

    @Test
    fun `the emulator harness closes an error dialog raised before it hid them`() {
        // Hiding stops only the dialogs raised after it. Run 550 lost nine
        // API 35 tests to a Pixel Launcher dialog raised while the emulator
        // booted, before the harness ran: the runner's unlock key took 6.6 s
        // where it takes 0.1 s. The harness now ends the app any dialog
        // already on screen is about, and Android takes the dialog down with
        // the app's process. The full logcat is kept, because the "ANR in"
        // line that names such an app is in no test's own log.
        val root = repoRoot()
        assertTrue("repository root not found from app/", root != null)
        val script = File(root, ".github/scripts/emulator-e2e.sh").readText()
        val hide = script.indexOf("settings put global hide_error_dialogs 1")
        val find = script.indexOf("Application (Not Responding|Error)")
        val close = script.indexOf("am force-stop", find)
        val suite = script.indexOf("connectedDebugAndroidTest")
        assertTrue("the harness must look for error dialogs already on screen", find > hide)
        assertTrue("and end the app each one is about", close > find)
        assertTrue("before the instrumented suite starts", suite > close)
        val workflow = File(root, ".github/workflows/build.yml").readText()
        assertTrue(
            "each leg's full logcat must be uploaded with its screenshots",
            workflow.contains("artifacts/logcat.txt")
        )
    }

    @Test
    fun `a release is tagged at the commit its APK was built from`() {
        // Without --target GitHub creates a missing tag at the branch head at
        // the moment of the call. The release job waits for every emulator
        // leg, so a push that lands meanwhile got the tag and the source
        // archive while the APK and its hash came from the commit before.
        val root = repoRoot()
        assertTrue("repository root not found from app/", root != null)
        val workflow = File(root, ".github/workflows/build.yml").readText()
        val create = workflow.substringAfter("gh release create", "").substringBefore("--repo")
        assertTrue("the workflow must publish its release with gh release create", create.isNotEmpty())
        assertTrue(
            "the release tag must name the commit this run built",
            create.contains("--target \"\$GITHUB_SHA\"")
        )
    }

    @Test
    fun `the release APK walk finishes setup and reaches every tab`() {
        // A fresh install opens on setup, which has no tab bar. The walk used
        // to tap where the tabs would be, landed on setup every time and
        // passed, so no screen past launch was ever drawn from R8 code.
        val root = repoRoot()
        assertTrue("repository root not found from app/", root != null)
        val script = File(root, ".github/scripts/emulator-e2e.sh").readText()
        // The install the walk runs on, in its own group: the update checks
        // before it install the same file and then remove it again.
        val group = script.indexOf("::group::Install the signed release APK and launch it")
        val install = script.indexOf("adb install -r -g EnteSaver-release.apk", group)
        val walk = script.indexOf("python3 .github/scripts/release-tab-walk.py")
        val promises = script.indexOf("android.permission.INTERNET")
        assertTrue("the release install must have its own group", group >= 0)
        assertTrue("the release APK must be installed with its permissions granted", install > group)
        assertTrue("the release walk must run after the install", walk > install)
        assertTrue("and before the installed package's promises are read", promises > walk)
        assertFalse("tabs are found by their labels, not by screen fraction", script.contains("TAB_Y"))

        // Every label the walk looks for has to be one the app still shows:
        // a renamed button would leave it swiping at setup until it fails.
        val walker = File(root, ".github/scripts/release-tab-walk.py").readText()
        val strings = File(root, "app/src/main/res/values/strings.xml").readText()
        for (list in listOf("FORWARD", "TABS")) {
            val names = Regex("""^$list = \[(.*)]$""", RegexOption.MULTILINE).find(walker)
                ?.groupValues?.get(1)
                ?.let { Regex(""""(\w+)"""").findAll(it).map { m -> m.groupValues[1] }.toList() }
            assertTrue("the walk must list its $list labels", !names.isNullOrEmpty())
            for (name in names!!) {
                assertTrue("strings.xml has no \"$name\" for the walk", strings.contains("name=\"$name\""))
            }
        }
        assertTrue(
            "the walk must fail when the tabs never appear",
            walker.contains("never reached its tabs") && walker.contains("sys.exit(1)")
        )
        assertTrue("and when a tab does not open", walker.contains("tab never opened"))
    }

    /**
     * An action outside GitHub's own runs with the build's files in reach,
     * and a tag is a pointer its owner can move. A moved tag in the build
     * job could change the APK before it is signed, so every action that is
     * not GitHub's is pinned to the commit that was reviewed.
     */
    @Test
    fun `an action from outside GitHub is pinned to a commit`() {
        val uses = Regex("""uses:\s*([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-/]+)@(\S+)""")
        val loose = mutableListOf<String>()
        for (file in workflows.listFiles { f -> f.extension == "yml" || f.extension == "yaml" }.orEmpty()) {
            file.readLines().forEachIndexed { idx, line ->
                val m = uses.find(line) ?: return@forEachIndexed
                val (owner, _, ref) = m.destructured
                if (owner != "actions" && !Regex("[0-9a-f]{40}").matches(ref)) loose += "${file.name}:${idx + 1} ${m.value}"
            }
        }
        assertTrue("pin these to a commit SHA, with the tag as a comment: $loose", loose.isEmpty())
    }

    /**
     * The signing key and its passwords reach one step, and only that one.
     * They used to be written into the job's environment before the build,
     * where Gradle, every plugin and every dependency could read them, with
     * the keystore beside the sources and a write token in .git/config.
     */
    @Test
    fun `the release key reaches only the signing step, and the token only reads`() {
        val build = File(workflows, "build.yml").readText()
        assertTrue("read-only by default", build.contains("permissions:\n  contents: read"))
        val releaseJob = build.substringAfter("\n  release:\n")
        assertTrue("the release job alone may write", releaseJob.contains("permissions:\n      contents: write"))
        assertFalse("no other job may write", build.substringBefore("\n  release:\n").contains("contents: write"))
        val checkouts = Regex("""uses: actions/checkout@\S+\n\s+with:\n\s+(?:#.*\n\s+)*persist-credentials: false""")
        assertTrue(
            "every checkout leaves no token behind",
            checkouts.findAll(build).count() == Regex("uses: actions/checkout@").findAll(build).count()
        )
        // Each secret is named exactly once in the file's steps: in the env of the signing step.
        val steps = build.split("\n      - name: ")
        for (secret in listOf("KEYSTORE_B64", "KEYSTORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD")) {
            val using = steps.filter { it.contains("secrets.$secret }}") }
            assertTrue(
                "$secret may be read by the signing step only, not by ${using.map { it.lineSequence().first() }}",
                using.size == 1 && using.single().startsWith("Sign APK")
            )
        }
        assertFalse("no password goes into the job's environment", Regex("""echo "(KEYSTORE_PASSWORD|KEY_PASSWORD)=""").containsMatchIn(build))
        assertTrue("the key is written outside the checkout", build.contains("KS=\"\$RUNNER_TEMP/release.p12\""))
        assertTrue("and removed after signing", build.contains("trap 'rm -f \"\$KS\""))
    }

    /**
     * The step that holds the key runs on a runner the build never touched.
     * Gradle, its plugins and every dependency run as the same user as any
     * later step of their job, and could leave a changed script, tool or
     * environment line behind for the step that has the key in reach.
     */
    @Test
    fun `the release key is opened on a runner that never ran the build`() {
        val build = File(workflows, "build.yml").readText()
        val buildJob = build.substringAfter("\n  build:\n").substringBefore("\n  sign:\n")
        val signJob = build.substringAfter("\n  sign:\n").substringBefore("\n  emulator:\n")
        assertTrue("there is a sign job after the build", signJob.contains("needs: build"))
        assertTrue("the sign job signs", signJob.contains("- name: Sign APK"))
        assertFalse("the build job signs nothing", buildJob.contains("- name: Sign APK"))
        assertFalse("the build job opens no key", buildJob.contains("keytool"))
        assertFalse("the sign job runs no Gradle", signJob.contains("gradlew") || signJob.contains("setup-gradle"))
        assertTrue("the emulator legs test the signed APK", build.contains("needs: [build, sign]"))
        assertTrue("and the release publishes it", build.contains("needs: [build, sign, emulator]"))
    }

    @Test
    fun `a run's artifacts expire`() {
        for (file in workflows.listFiles { f -> f.extension == "yml" || f.extension == "yaml" }.orEmpty()) {
            val text = file.readText()
            val uploads = Regex("uses: actions/upload-artifact@").findAll(text).count()
            val expiring = Regex("retention-days: \\d+").findAll(text).count()
            assertTrue("${file.name}: every upload needs retention-days", uploads == expiring)
        }
    }
}
