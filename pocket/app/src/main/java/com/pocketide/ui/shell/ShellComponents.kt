package com.pocketide.ui.shell

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pocketide.R
import com.pocketide.ui.components.StatusChip
import com.pocketide.ui.components.Tone
import com.pocketide.ui.components.toneColor
import com.pocketide.ui.theme.Brand

/** Readable line length on wide screens and in landscape. */
val ContentMaxWidth = 600.dp

/**
 * The height of the frosted bottom bar the page scrolls behind (0 where there is none): a page
 * ends with this much room, so its last line can be scrolled clear of the bar.
 */
val LocalBottomBarPadding = compositionLocalOf { 0.dp }

/**
 * The body of every full-page shell screen: edge-to-edge background, content inside the safe
 * area, scrolls when large fonts or landscape make it taller than the screen. A [Surface], so text
 * takes the theme's colour wherever the page is shown, the lock and first-run screens included.
 */
@Composable
fun ShellPage(
    modifier: Modifier = Modifier,
    centered: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val bar = LocalBottomBarPadding.current
    // Under the bottom bar, the bar itself keeps clear of the phone's navigation area.
    val insets = if (bar > 0.dp) WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal) else WindowInsets.safeDrawing
    Surface(modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize().windowInsetsPadding(insets), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier
                    .widthIn(max = ContentMaxWidth)
                    .fillMaxWidth()
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 20.dp),
                verticalArrangement = if (centered) Arrangement.Center else Arrangement.Top,
                horizontalAlignment = if (centered) Alignment.CenterHorizontally else Alignment.Start,
            ) {
                content()
                if (bar > 0.dp) Spacer(Modifier.height(bar))
            }
        }
    }
}

/** The app's own mark on its violet tile, as on the launcher. */
@Composable
fun BrandMark(size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(Brush.verticalGradient(listOf(Brand.TileTop, Brand.TileBottom)))
            .clearAndSetSemantics { contentDescription = "PocketIDE" },
        contentAlignment = Alignment.Center,
    ) {
        // The vector sits on the 108 dp adaptive canvas; the visible tile is its middle 72 dp.
        Image(painterResource(R.drawable.splash_mark), contentDescription = null, modifier = Modifier.requiredSize(size * 1.5f))
    }
}

/** An icon tile and a large title with one or two lines under it. */
@Composable
fun ScreenTitle(icon: ImageVector, title: String, subtitle: String?, modifier: Modifier = Modifier, tone: Tone? = null) {
    Column(modifier.fillMaxWidth()) {
        IconTile(icon, tone)
        Spacer(Modifier.height(20.dp))
        Text(
            title,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() },
        )
        if (subtitle != null) {
            Spacer(Modifier.height(8.dp))
            Text(subtitle, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A centred version of [ScreenTitle], for lock screens. */
@Composable
fun CenteredTitle(icon: ImageVector, title: String, subtitle: String?, tone: Tone? = null) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        IconTile(icon, tone, size = 64.dp)
        Spacer(Modifier.height(20.dp))
        Text(
            title,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        if (subtitle != null) {
            Spacer(Modifier.height(10.dp))
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
fun IconTile(icon: ImageVector, tone: Tone? = null, size: Dp = 56.dp) {
    val container = if (tone == null) MaterialTheme.colorScheme.primaryContainer else toneColor(tone).copy(alpha = 0.16f)
    val content = if (tone == null) MaterialTheme.colorScheme.onPrimaryContainer else toneColor(tone)
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * 0.3f)).background(container),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(size * 0.5f))
    }
}

/** A small uppercase label above a group, read as a heading by TalkBack. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(top = 20.dp, bottom = 8.dp).semantics { heading() },
    )
}

/**
 * One row of a [CheckCard]: [good] true shows a tick, false a cross, null the given icon.
 * [spoken] is what TalkBack says for the icon, when it carries a state.
 */
data class CheckItem(
    val title: String,
    val subtitle: String? = null,
    val good: Boolean? = true,
    val icon: ImageVector? = null,
    val spoken: String? = null,
)

/** A rounded card of rows separated by hairlines, as in the set-up mockups. */
@Composable
fun CheckCard(items: List<CheckItem>, modifier: Modifier = Modifier) {
    OutlinedCard(modifier) {
        items.forEachIndexed { index, item ->
            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            CheckRow(item)
        }
    }
}

@Composable
private fun CheckRow(item: CheckItem) {
    val tone = when (item.good) {
        true -> Tone.OK
        false -> Tone.ERROR
        null -> null
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp)
            .semantics(mergeDescendants = true) { item.spoken?.let { stateDescription = it } },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val color = if (tone != null) toneColor(tone) else MaterialTheme.colorScheme.primary
        val icon = item.icon ?: if (item.good == false) Icons.Outlined.Close else Icons.Outlined.Check
        Box(Modifier.size(32.dp).clip(CircleShape).background(color.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(item.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            if (item.subtitle != null) {
                Text(item.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** A plain outlined container matching the mockups' cards. */
@Composable
fun OutlinedCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape),
        content = content,
    )
}

/** Label on the left, a coloured status on the right, an optional detail line. */
@Composable
fun StatusLine(title: String, detail: String?, status: String, tone: Tone) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.width(12.dp))
        Text(status, style = MaterialTheme.typography.labelLarge, color = toneColor(tone), fontWeight = FontWeight.SemiBold)
    }
}

/** A tinted note: information, a warning, or an error the owner can act on. */
@Composable
fun NoticeCard(text: String, tone: Tone = Tone.NEUTRAL, modifier: Modifier = Modifier, title: String? = null) {
    val color = if (tone == Tone.NEUTRAL) MaterialTheme.colorScheme.primary else toneColor(tone)
    val icon = when (tone) {
        Tone.ERROR -> Icons.Outlined.ErrorOutline
        Tone.WARN -> Icons.Outlined.WarningAmber
        else -> Icons.Outlined.Info
    }
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = color.copy(alpha = 0.10f)) {
        Row(Modifier.padding(16.dp).semantics(mergeDescendants = true) {}) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(12.dp))
            Column {
                if (title != null) Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

/** The one main action of a page: full width, tall enough for a thumb, a spinner while busy. */
@Composable
fun PrimaryAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, busy: Boolean = false) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        modifier = modifier.fillMaxWidth().heightIn(min = 56.dp),
        shape = RoundedCornerShape(18.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = LocalContentColor.current)
            Spacer(Modifier.width(12.dp))
        }
        Text(text, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
    }
}

@Composable
fun SecondaryAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
        shape = RoundedCornerShape(18.dp),
    ) {
        Text(text, style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center)
    }
}

@Composable
fun QuietAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(onClick = onClick, modifier = modifier.fillMaxWidth().heightIn(min = 48.dp)) {
        Text(text, style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center)
    }
}

/** Small print under the main action. */
@Composable
fun FinePrint(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = modifier.fillMaxWidth().padding(top = 12.dp),
    )
}

@Composable
fun Gap(height: Dp = 16.dp) = Spacer(Modifier.height(height))
