package app.entesaver

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.Inflater
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The home screen's side of the app: Ente Saver's one icon and name, the icon
 * pack that dresses Ente up as a gallery, and the pictures both use.
 * Launchers read these by name, from outside the app, so nothing at build
 * time notices when one goes missing.
 */
class IconPackTest {

    private fun xml(path: String): Element =
        DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File(path)).documentElement

    private fun Element.children(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private val manifest = xml("src/main/AndroidManifest.xml")

    /** The application ID (package name). */
    private val appId = Regex("""applicationId = "([^"]+)"""")
        .find(File("build.gradle.kts").readText())!!.groupValues[1]

    private val activities = manifest.children("activity")
    private val aliases = manifest.children("activity-alias")

    private fun Element.isLauncher(): Boolean =
        children("category").any { it.getAttribute("android:name") == "android.intent.category.LAUNCHER" }

    @Test
    fun `the home screen has one icon, Ente Saver, under the name launchers keep`() {
        val entry = (activities + aliases).filter { it.isLauncher() }.single()
        // An alias, so the component launchers keep an icon and its
        // shortcuts by never depends on the activity class's name.
        assertEquals(".MainActivity", entry.getAttribute("android:name"))
        assertEquals(".HostActivity", entry.getAttribute("android:targetActivity"))
        assertTrue(entry.getAttribute("android:enabled") != "false")
        assertEquals("@string/app_name", entry.getAttribute("android:label"))
        assertEquals("@mipmap/ic_launcher", entry.getAttribute("android:icon"))
        assertEquals("@mipmap/ic_launcher_round", entry.getAttribute("android:roundIcon"))
        assertTrue(entry.children("meta-data").any { it.getAttribute("android:name") == "android.app.shortcuts" })
        // Nothing declared switched off, waiting to be switched on.
        assertTrue((activities + aliases).none { it.getAttribute("android:enabled") == "false" })
    }

    @Test
    fun `launchers can find the icon pack`() {
        val packs = (activities + aliases).filter { component ->
            component.children("action").any { it.getAttribute("android:name") == "org.adw.launcher.THEMES" }
        }
        // One component answers, or a launcher would list the pack twice.
        val pack = packs.single()
        assertEquals(".IconPackActivity", pack.getAttribute("android:name"))
        assertEquals("true", pack.getAttribute("android:exported"))
        assertEquals("@drawable/iconpack_photos", pack.getAttribute("android:icon"))
        assertEquals("@string/icon_pack_name", pack.getAttribute("android:label"))
        val actions = pack.children("action").map { it.getAttribute("android:name") }
        assertTrue(actions.containsAll(listOf("org.adw.launcher.THEMES", "com.novalauncher.THEME")))
    }

    @Test
    fun `the Photos shortcut opens through a screen of its own`() {
        val open = activities.single { it.getAttribute("android:name") == ".OpenEnteActivity" }
        assertEquals("true", open.getAttribute("android:noHistory"))
        assertTrue(!open.isLauncher())
    }

    @Test
    fun `the pack offers Ente exactly one icon, also on Realme and Oppo`() {
        val res = File("src/main/res/xml/appfilter.xml").readText()
        assertEquals("launchers read either copy", res, File("src/main/assets/appfilter.xml").readText())
        val components = xml("src/main/res/xml/appfilter.xml").children("item").map { it.getAttribute("component") }
        // Ente's launcher entry is its enabled alias (IconGreen by default);
        // release builds take the LAUNCHER category off MainActivity.
        assertEquals(listOf("ComponentInfo{io.ente.photos/io.ente.photos.IconGreen}"), components)

        // The ColorOS / Realme UI / OxygenOS 13-15 launcher's per-app editor
        // lists one icon per component key plus one per package, and drops the
        // last one. 18 entries once showed as 20 copies of the same picture.
        val keys = mutableSetOf<String>()
        for (c in components) {
            val inner = c.removePrefix("ComponentInfo{").removeSuffix("}").lowercase()
            keys += inner
            keys += inner.substringBefore('/')
        }
        assertEquals("Realme and Oppo show (keys - 1) icons: exactly one", 2, keys.size)
    }

    @Test
    fun `the pack restyles Ente Photos and no other app`() {
        val filter = xml("src/main/res/xml/appfilter.xml")
        // iconback, iconmask, iconupon and scale make a launcher restyle
        // every app the pack does not list. Plain items only, so applying the
        // pack touches Ente and nothing else - Ente Saver included.
        val tags = (0 until filter.childNodes.length).map { filter.childNodes.item(it) }
            .filterIsInstance<Element>().map { it.tagName }.toSet()
        assertEquals(setOf("item"), tags)
        assertTrue(filter.children("item").none { it.getAttribute("component").contains(appId) })
        // The pack is found through its own actions and is never a second
        // icon on the home screen.
        val pack = activities.single { it.getAttribute("android:name") == ".IconPackActivity" }
        assertTrue(!pack.isLauncher())
    }

    @Test
    fun `every picture the pack names exists and survives shrinking`() {
        val named = (
            xml("src/main/res/xml/appfilter.xml").children("item") +
                xml("src/main/res/xml/drawable.xml").children("item")
            ).map { it.getAttribute("drawable") }.toSet()
        assertEquals("one icon: Ente as the phone's Photos", setOf("iconpack_photos"), named)
        for (name in named) {
            assertTrue(name, File("src/main/res/drawable-nodpi/$name.png").isFile)
        }
        assertEquals(
            File("src/main/res/xml/drawable.xml").readText(),
            File("src/main/assets/drawable.xml").readText()
        )
    }

    @Test
    fun `the pack's Ente icon is round, at the size icon packs ship`() {
        // One PNG, unscaled (drawable-nodpi), 512 px square: twice the
        // largest launcher icon size, so a launcher only ever scales it down
        // and it never looks soft, even with the icon size turned up.
        val icon = Rgba.read(File("src/main/res/drawable-nodpi/iconpack_photos.png"))
        assertEquals(512, icon.width)
        assertEquals(512, icon.height)
        fun alpha(x: Int, y: Int) = icon.alpha(x, y)
        // Round: clear corners, a solid disc, edge to edge but for a thin margin.
        for ((x, y) in listOf(0 to 0, 511 to 0, 0 to 511, 511 to 511, 60 to 60, 450 to 450)) {
            assertEquals("corner ($x, $y) must be clear", 0, alpha(x, y))
        }
        for ((x, y) in listOf(256 to 256, 256 to 24, 24 to 256, 487 to 256, 256 to 487)) {
            assertEquals("disc ($x, $y) must be solid", 255, alpha(x, y))
        }
        val keep = File("src/main/res/raw/keep.xml").readText()
        assertTrue(keep.contains("@drawable/iconpack_*"))
        assertTrue(keep.contains("@xml/appfilter"))
        assertTrue(keep.contains("@xml/drawable"))
    }

    @Test
    fun `Ente Saver has one name and nothing in it changes its own icon`() {
        val strings = File("src/main/res/values/strings.xml").readText()
        assertTrue(strings.contains("""<string name="app_name" translatable="false">Ente Saver</string>"""))
        assertTrue("no other home-screen names", !Regex("""name="app_name_""").containsMatchIn(strings))
        val sources = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.map { it.readText() }.toList()
        // Nothing switches a component on or off: the one icon is always the
        // one in the manifest.
        assertTrue(sources.none { it.contains("setComponentEnabledSetting") })
        assertTrue(sources.none { it.contains("AppLooks") })
        assertTrue(File("src/main/res/mipmap-anydpi/ic_shortcut_photos.xml").isFile)
    }

    @Test
    fun `every icon is drawn to its platform size`() {
        fun vector(name: String) = xml("src/main/res/drawable/$name.xml")
        // Adaptive-icon layers: the 108 dp canvas the launcher masks.
        for (layer in listOf(
            "ic_launcher_background", "ic_launcher_foreground", "ic_launcher_monochrome",
            "shortcut_photos_background", "shortcut_photos_foreground", "shortcut_photos_monochrome",
            "shortcut_glyph_background", "shortcut_free_up_foreground", "shortcut_activity_foreground"
        )) {
            val v = vector(layer)
            assertEquals(layer, "108dp", v.getAttribute("android:width"))
            assertEquals(layer, "108dp", v.getAttribute("android:height"))
        }
        // The status-bar icon: 24 dp, in white for the system to tint.
        val stat = vector("ic_stat_saver")
        assertEquals("24dp", stat.getAttribute("android:width"))
        assertEquals("24dp", stat.getAttribute("android:height"))
        // Launcher icons, round ones included, and the long-press shortcuts
        // are adaptive, so each launcher gives them its own shape.
        for (icon in listOf("ic_launcher", "ic_launcher_round", "ic_shortcut_photos", "ic_shortcut_free_up", "ic_shortcut_activity")) {
            assertEquals(icon, "adaptive-icon", xml("src/main/res/mipmap-anydpi/$icon.xml").tagName)
        }
        val shortcuts = File("src/main/res/xml/shortcuts.xml").readText()
        assertTrue(shortcuts.contains("@mipmap/ic_shortcut_free_up"))
        assertTrue(shortcuts.contains("@mipmap/ic_shortcut_activity"))
    }
}

/**
 * Just enough PNG to read an 8-bit RGBA picture's transparency: the platform
 * image readers are not on a unit test's classpath.
 */
private class Rgba(val width: Int, val height: Int, private val pixels: ByteArray) {

    fun alpha(x: Int, y: Int): Int = pixels[(y * width + x) * 4 + 3].toInt() and 0xFF

    companion object {
        fun read(file: File): Rgba {
            val input = DataInputStream(file.inputStream().buffered())
            input.skipBytes(8)
            var width = 0
            var height = 0
            val data = ByteArrayOutputStream()
            while (true) {
                val length = input.readInt()
                val type = String(ByteArray(4).also { input.readFully(it) }, Charsets.US_ASCII)
                val body = ByteArray(length).also { input.readFully(it) }
                input.readInt()
                when (type) {
                    "IHDR" -> {
                        width = ByteBuffer.wrap(body, 0, 4).int
                        height = ByteBuffer.wrap(body, 4, 4).int
                        check(body[8].toInt() == 8 && body[9].toInt() == 6) { "8-bit RGBA expected" }
                    }
                    "IDAT" -> data.write(body)
                    "IEND" -> break
                }
            }
            val stride = width * 4
            val raw = ByteArray((stride + 1) * height)
            Inflater().apply { setInput(data.toByteArray()); inflate(raw); end() }
            val out = ByteArray(stride * height)
            for (y in 0 until height) {
                val filter = raw[y * (stride + 1)].toInt()
                for (i in 0 until stride) {
                    val x = raw[y * (stride + 1) + 1 + i].toInt() and 0xFF
                    val a = if (i >= 4) out[y * stride + i - 4].toInt() and 0xFF else 0
                    val b = if (y > 0) out[(y - 1) * stride + i].toInt() and 0xFF else 0
                    val c = if (i >= 4 && y > 0) out[(y - 1) * stride + i - 4].toInt() and 0xFF else 0
                    val value = when (filter) {
                        0 -> x
                        1 -> x + a
                        2 -> x + b
                        3 -> x + (a + b) / 2
                        else -> {
                            val p = a + b - c
                            val pa = Math.abs(p - a)
                            val pb = Math.abs(p - b)
                            val pc = Math.abs(p - c)
                            x + if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c
                        }
                    }
                    out[y * stride + i] = value.toByte()
                }
            }
            return Rgba(width, height, out)
        }
    }
}
