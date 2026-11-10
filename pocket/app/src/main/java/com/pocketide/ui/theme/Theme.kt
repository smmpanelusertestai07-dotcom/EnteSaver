package com.pocketide.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.pocketide.core.ThemeMode

/** Brand colours, mirrored from branding/tokens.json (the brand gate checks they agree). */
object Brand {
    val TileTop = Color(0xFF7A3CD6)
    val TileBottom = Color(0xFF33146F)
    val TileFlat = Color(0xFF56289F)
    val Accent = Color(0xFF8B55E8)
    val AccentOnDark = Color(0xFFB79BF5)
    val Mark = Color(0xFFF7F3EB)
    val Running = Color(0xFF129150)
    val NeedsYou = Color(0xFFB87400)
    val Failed = Color(0xFFC7362B)
}

/** Colours for states, beyond Material's scheme. */
@Immutable
data class StatusColors(val ok: Color, val warn: Color, val error: Color, val neutral: Color)

/**
 * State colours for text and chips. They are darker (lighter in dark mode) than the brand's own
 * state colours, which stay for the icon: small text in each reads at 4.5:1 or more, alone and
 * on its chip's tint, on every card colour (StatusContrastTest).
 */
internal val LightStatus = StatusColors(
    ok = Color(0xFF0A6636),
    warn = Color(0xFF7F4F00),
    error = Color(0xFFA8231C),
    neutral = Color(0xFF5E5866),
)
internal val DarkStatus = StatusColors(
    ok = Color(0xFF6DD89A),
    warn = Color(0xFFF2C063),
    error = Color(0xFFFFB4AB),
    neutral = Color(0xFFADA6B1),
)

val LocalStatusColors = staticCompositionLocalOf { LightStatus }

internal val Light: ColorScheme = lightColorScheme(
    primary = Brand.TileFlat,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFEBDDFF),
    onPrimaryContainer = Color(0xFF25005A),
    secondary = Color(0xFF645A70),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFEBDDF7),
    onSecondaryContainer = Color(0xFF1F182A),
    tertiary = Color(0xFF7E525E),
    background = Color(0xFFFAF9F6),
    onBackground = Color(0xFF1C1B1E),
    surface = Color(0xFFFAF9F6),
    onSurface = Color(0xFF1C1B1E),
    surfaceVariant = Color(0xFFE8E0EB),
    onSurfaceVariant = Color(0xFF4A4550),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF5F2F5),
    surfaceContainer = Color(0xFFEFEBF0),
    surfaceContainerHigh = Color(0xFFE9E5EA),
    surfaceContainerHighest = Color(0xFFE3DFE4),
    outline = Color(0xFF7B7581),
    outlineVariant = Color(0xFFCCC4CF),
    error = Brand.Failed,
)

internal val Dark: ColorScheme = darkColorScheme(
    primary = Brand.AccentOnDark,
    onPrimary = Color(0xFF3B0F80),
    primaryContainer = Color(0xFF532A99),
    onPrimaryContainer = Color(0xFFEBDDFF),
    secondary = Color(0xFFCEC2DA),
    onSecondary = Color(0xFF352D40),
    secondaryContainer = Color(0xFF4C4357),
    onSecondaryContainer = Color(0xFFEBDDF7),
    tertiary = Color(0xFFF0B8C6),
    background = Color(0xFF171717),
    onBackground = Color(0xFFE6E1E6),
    surface = Color(0xFF171717),
    onSurface = Color(0xFFE6E1E6),
    surfaceVariant = Color(0xFF4A4550),
    onSurfaceVariant = Color(0xFFCCC4CF),
    surfaceContainerLowest = Color(0xFF111111),
    surfaceContainerLow = Color(0xFF1D1C1F),
    surfaceContainer = Color(0xFF221F25),
    surfaceContainerHigh = Color(0xFF2C292F),
    surfaceContainerHighest = Color(0xFF37343A),
    outline = Color(0xFF958E99),
    outlineVariant = Color(0xFF4A4550),
    error = Color(0xFFFFB4AB),
)

/** True when [mode] shows the dark theme right now. */
@Composable
fun isDark(mode: ThemeMode): Boolean = when (mode) {
    ThemeMode.SYSTEM -> isSystemInDarkTheme()
    ThemeMode.LIGHT -> false
    ThemeMode.DARK -> true
}

/**
 * PocketIDE's violet scheme, or with [dynamicColor] the wallpaper's colours (Android 12 and newer).
 * The state colours stay PocketIDE's own either way, so "running" and "stopped" read the same.
 */
@Composable
fun PocketTheme(mode: ThemeMode = ThemeMode.SYSTEM, dynamicColor: Boolean = false, content: @Composable () -> Unit) {
    val dark = isDark(mode)
    val context = LocalContext.current
    val scheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> Dark
        else -> Light
    }
    CompositionLocalProvider(LocalStatusColors provides if (dark) DarkStatus else LightStatus) {
        MaterialTheme(colorScheme = scheme, typography = Typography(), content = content)
    }
}
