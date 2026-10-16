package app.entesaver.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proves the palette is readable, rather than asserting that it is.
 *
 * Contrast is arithmetic on the colour values, so it can be checked here
 * instead of by squinting at a screenshot - and checked for both themes at
 * once, which is the part that gets missed. A colour pair that fails this is
 * a colour pair somebody cannot read.
 *
 * Thresholds are WCAG AA: 4.5:1 for body text, 3:1 for large text and icons.
 */
class ContrastTest {

    private fun channel(component: Float): Double {
        val c = component.toDouble()
        return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    }

    private fun luminance(color: Color): Double =
        0.2126 * channel(color.red) +
            0.7152 * channel(color.green) +
            0.0722 * channel(color.blue)

    private fun ratio(foreground: Color, background: Color): Double {
        val a = luminance(foreground)
        val b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private fun assertReadable(
        label: String,
        foreground: Color,
        background: Color,
        minimum: Double
    ) {
        val actual = ratio(foreground, background)
        assertTrue(
            "$label needs $minimum:1 but is %.2f:1".format(actual),
            actual >= minimum
        )
    }

    /** Body text: the pairs a reader spends the most time on. */
    private fun checkBodyText(name: String, scheme: ColorScheme) {
        assertReadable("$name onBackground", scheme.onBackground, scheme.background, 4.5)
        assertReadable("$name onSurface", scheme.onSurface, scheme.surface, 4.5)
        assertReadable(
            "$name onSurfaceVariant on surface",
            scheme.onSurfaceVariant,
            scheme.surface,
            4.5
        )
        assertReadable(
            "$name onSurfaceVariant on card",
            scheme.onSurfaceVariant,
            scheme.surfaceContainer,
            4.5
        )
        // The muted state badge on a file row: small type on a tinted pill.
        assertReadable(
            "$name onSurfaceVariant on a muted badge",
            scheme.onSurfaceVariant,
            scheme.surfaceContainerHigh,
            4.5
        )
        assertReadable("$name onPrimary", scheme.onPrimary, scheme.primary, 4.5)
        assertReadable("$name onError", scheme.onError, scheme.error, 4.5)
        assertReadable(
            "$name onErrorContainer",
            scheme.onErrorContainer,
            scheme.errorContainer,
            4.5
        )
        assertReadable(
            "$name onPrimaryContainer",
            scheme.onPrimaryContainer,
            scheme.primaryContainer,
            4.5
        )
        assertReadable(
            "$name onSecondaryContainer",
            scheme.onSecondaryContainer,
            scheme.secondaryContainer,
            4.5
        )
        // The warning card, which exists to be read before someone deletes.
        assertReadable(
            "$name onTertiaryContainer",
            scheme.onTertiaryContainer,
            scheme.tertiaryContainer,
            4.5
        )
    }

    /** Large text and icons, including the accent used for figures. */
    private fun checkLargeAndIcons(name: String, scheme: ColorScheme) {
        assertReadable("$name primary on surface", scheme.primary, scheme.surface, 3.0)
        assertReadable("$name primary on card", scheme.primary, scheme.surfaceContainer, 3.0)
        assertReadable("$name error on surface", scheme.error, scheme.surface, 3.0)
        assertReadable("$name outline on surface", scheme.outline, scheme.surface, 3.0)
    }

    @Test
    fun `light theme body text is readable`() {
        checkBodyText("light", LightScheme)
    }

    @Test
    fun `dark theme body text is readable`() {
        checkBodyText("dark", DarkScheme)
    }

    @Test
    fun `light theme large text and icons are readable`() {
        checkLargeAndIcons("light", LightScheme)
    }

    @Test
    fun `dark theme large text and icons are readable`() {
        checkLargeAndIcons("dark", DarkScheme)
    }

    @Test
    fun `the done badge is readable in both themes`() {
        assertReadable("light done badge", OnSuccessContainerLight, SuccessContainerLight, 4.5)
        assertReadable("dark done badge", OnSuccessContainerDark, SuccessContainerDark, 4.5)
    }

    @Test
    fun `text on the brand gradient is readable`() {
        // The hero card paints its own background, so the scheme's pairings do
        // not cover it. Both ends of the gradient have to work.
        for ((name, background) in listOf("indigo" to BrandIndigo, "deep violet" to BrandIndigoDeep)) {
            assertReadable("OnBrand over $name", OnBrand, background, 4.5)
            // The muted variant carries supporting lines, not body copy.
            assertReadable("OnBrandMuted over $name", OnBrandMuted, background, 3.0)
        }
    }

    @Test
    fun `small text on the brand gradient is readable as it is actually drawn`() {
        // The muted white and the tile fills are see-through, so what reaches
        // the eye is the blend, not the colour as written. Read as opaque, the
        // check above passed a label that was really 4.45:1 on the lighter end
        // of the banner, and white tiles that took the figures on them under
        // 4:1. Small text needs 4.5:1 at both ends of the gradient.
        for ((name, background) in listOf("indigo" to BrandIndigo, "deep violet" to BrandIndigoDeep)) {
            assertReadable(
                "OnBrandMuted blended over $name",
                OnBrandMuted.compositeOver(background),
                background,
                4.5
            )
            val tile = BrandTile.compositeOver(background)
            assertReadable("OnBrand on a tile over $name", OnBrand, tile, 4.5)
            assertReadable(
                "OnBrandMuted on a tile over $name",
                OnBrandMuted.compositeOver(tile),
                tile,
                4.5
            )
        }
    }
}
