package app.entesaver.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/*
 * Ente Saver palette: "Saver Indigo" #4253C4 (HCT hue 280, chroma 60, tone 40)
 * as the primary - the colour of the app's buttons, links, selection and the
 * hero card - with a quiet grey-indigo secondary, a muted mauve tertiary and
 * near-neutral surfaces from the same hue, so the indigo is an accent rather
 * than a wash. Built with Material's colour tools (material-color-utilities):
 * primary (280, 60), secondary (280, 16), tertiary (340, 24), neutral
 * (280, 6), neutral variant (280, 8). Full Material 3 role set, so every
 * component gets its contrast in both themes without per-widget alpha.
 *
 * Why not green: the launcher icon is Ente's green, and the app used to paint
 * the same green on every button, card and outline, which made the screens
 * read as one loud colour. Indigo sits 136 degrees from Ente's green: clearly
 * its own colour beside the icon, calm, and the colour people expect of
 * storage and privacy tools. Ente's own green stays only where it stands for
 * Ente itself - Ente's tile, and the icons.
 *
 * Measured contrast (WCAG 2.2): white on primary 6.4:1, primary on the light
 * surface 6.1:1, dark primary and its text 7.8:1, every on-container role
 * above 7:1; the outline is 4.3:1, over the 3:1 a control's edge needs.
 */

/**
 * Content colours for the hero card.
 *
 * The hero is the one surface whose colour does not change with the theme, so
 * its foreground cannot come from the colour scheme. These live here rather
 * than as Color.White literals inside screens, so the app has exactly one file
 * that names a colour.
 *
 * The muted white carries small supporting lines, so it has to clear 4.5:1
 * once it is blended over the lighter end of the gradient: at 94% it is 6.0:1
 * on #4253C4. The faint one is for icons only, which need 3:1.
 */
val OnBrand = Color(0xFFFFFFFF)
val OnBrandMuted = Color(0xF0FFFFFF)
val OnBrandFaint = Color(0xBFFFFFFF)

/**
 * The fill behind a tile or a badge inside the hero card.
 *
 * Darker than the card, not lighter. A white wash lifts the colour under the
 * figures towards the white text on it, and the pair loses contrast; a light
 * shade of black deepens it instead, so the white words on the tile read
 * better than the ones beside it rather than worse.
 */
val BrandTile = Color(0x26000000)

/**
 * Ente's own green, for Ente's tile while Ente is not on the phone - once it
 * is, its real icon is drawn instead. A brand looks the same in both themes,
 * so this does not come from the scheme; [OnBrand] is drawn on it.
 */
val EnteGreen = Color(0xFF08C225)

/**
 * The "done" badge: a light copy that is safely in Ente, an original freed.
 *
 * Success reads as green the world over, and every role of the scheme is
 * indigo now - the done badge drawn from it looked like the "in progress" one
 * beside it. So the one state that means "finished and safe" keeps a green of
 * its own, from Ente's family (HCT hue 150, chroma 30): tone 90 with tone 30
 * text in the light theme, the reverse in the dark one, 7.2:1 in both.
 */
val SuccessContainerLight = Color(0xFFC1EEC0)
val OnSuccessContainerLight = Color(0xFF284F2E)
val SuccessContainerDark = Color(0xFF284F2E)
val OnSuccessContainerDark = Color(0xFFC1EEC0)

// The two ends of the hero card's gradient: Saver Indigo into a deep violet.
// White text is 6.4:1 on the lighter end and 9.4:1 on the darker, and never
// less between them. Nothing soft-edged is drawn from them - a blurred glow
// reads on a dark screen as a stain over whatever it falls behind, which is
// why the page has no glows at all.
val BrandIndigo = Color(0xFF4253C4)
val BrandIndigoDeep = Color(0xFF522CA2)

val LightScheme = lightColorScheme(
    primary = Color(0xFF4253C4),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFDFE0FF),
    onPrimaryContainer = Color(0xFF2738AB),
    inversePrimary = Color(0xFFBCC3FF),

    // The secondary family is a quiet grey-indigo from the same hue, not another
    // colour: chips and the selected segment of a choice draw from it, and they
    // have to belong with the indigo beside them.
    secondary = Color(0xFF5B5D72),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE0E1F9),
    onSecondaryContainer = Color(0xFF434559),

    tertiary = Color(0xFF77536C),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFD7F0),
    onTertiaryContainer = Color(0xFF5D3C54),

    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF93000A),

    background = Color(0xFFFBF8FF),
    onBackground = Color(0xFF1B1B21),
    surface = Color(0xFFFBF8FF),
    onSurface = Color(0xFF1B1B21),
    surfaceVariant = Color(0xFFE3E1EC),
    onSurfaceVariant = Color(0xFF46464F),
    surfaceTint = Color(0xFF4253C4),

    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF5F2FA),
    surfaceContainer = Color(0xFFEFEDF4),
    surfaceContainerHigh = Color(0xFFE9E7EF),
    surfaceContainerHighest = Color(0xFFE4E1E9),

    outline = Color(0xFF777680),
    outlineVariant = Color(0xFFC7C5D0),
    scrim = Color(0xFF000000),
    inverseSurface = Color(0xFF303036),
    inverseOnSurface = Color(0xFFF2EFF7)
)

val DarkScheme = darkColorScheme(
    // Tone 80 of the same indigo: bright enough on a dark screen (10.9:1 on the
    // surface) without the glare of the full-strength colour.
    primary = Color(0xFFBCC3FF),
    onPrimary = Color(0xFF031B95),
    primaryContainer = Color(0xFF2738AB),
    onPrimaryContainer = Color(0xFFDFE0FF),
    inversePrimary = Color(0xFF4253C4),

    secondary = Color(0xFFC4C5DD),
    onSecondary = Color(0xFF2D2F42),
    secondaryContainer = Color(0xFF434559),
    onSecondaryContainer = Color(0xFFE0E1F9),

    tertiary = Color(0xFFE6BAD7),
    onTertiary = Color(0xFF45263D),
    tertiaryContainer = Color(0xFF5D3C54),
    onTertiaryContainer = Color(0xFFFFD7F0),

    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),

    background = Color(0xFF131318),
    onBackground = Color(0xFFE4E1E9),
    surface = Color(0xFF131318),
    onSurface = Color(0xFFE4E1E9),
    surfaceVariant = Color(0xFF46464F),
    onSurfaceVariant = Color(0xFFC7C5D0),
    surfaceTint = Color(0xFFBCC3FF),

    surfaceContainerLowest = Color(0xFF0D0E13),
    surfaceContainerLow = Color(0xFF1B1B21),
    surfaceContainer = Color(0xFF1F1F25),
    surfaceContainerHigh = Color(0xFF29292F),
    surfaceContainerHighest = Color(0xFF34343A),

    outline = Color(0xFF90909A),
    outlineVariant = Color(0xFF46464F),
    scrim = Color(0xFF000000),
    inverseSurface = Color(0xFFE4E1E9),
    inverseOnSurface = Color(0xFF303036)
)
