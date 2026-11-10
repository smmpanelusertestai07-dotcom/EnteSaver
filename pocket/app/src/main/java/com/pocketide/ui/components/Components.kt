package com.pocketide.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.FlowRowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.DialogProperties
import com.pocketide.ui.theme.LocalStatusColors
import kotlin.math.max

enum class Tone { OK, WARN, ERROR, NEUTRAL }

@Composable
fun toneColor(tone: Tone): Color = when (tone) {
    Tone.OK -> LocalStatusColors.current.ok
    Tone.WARN -> LocalStatusColors.current.warn
    Tone.ERROR -> LocalStatusColors.current.error
    Tone.NEUTRAL -> LocalStatusColors.current.neutral
}

/** A titled group of rows. */
@Composable
fun SectionCard(title: String?, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (title != null) Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

/**
 * The text slot of a dialog. Material's AlertDialog clips that slot when its window is shorter
 * than the content, which is what the keyboard or a large font size does on a small phone, so
 * every dialog with a field or more than a line or two scrolls instead.
 */
@Composable
fun DialogBody(modifier: Modifier = Modifier, spacing: Dp = 12.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(spacing), content = content)
}

/**
 * For a dialog that holds typed input: a tap beside it, often meant to hide the keyboard, does
 * not close it and throw the text away. Back and its Cancel button still close it.
 */
val KeepTypedInput = DialogProperties(dismissOnClickOutside = false)

/**
 * A group of buttons side by side that wraps: a button that does not fit moves to the next line
 * whole, instead of being squeezed into a narrow pill of one word per line on a small phone or
 * at a large font size.
 */
@Composable
fun ActionRow(modifier: Modifier = Modifier, content: @Composable FlowRowScope.() -> Unit) {
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        itemVerticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** A label on the left, a value on the right. */
@Composable
fun InfoRow(label: String, value: String, modifier: Modifier = Modifier) {
    LabelValueRow(
        label = { Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        value = { Text(value, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End, maxLines = 3, overflow = TextOverflow.Ellipsis) },
        modifier = modifier,
    )
}

/**
 * A label and a value side by side, sharing the width fairly (see [RowSplit]): a long value
 * never squeezes its label into a column of letters, and the other way round.
 */
@Composable
fun LabelValueRow(label: @Composable () -> Unit, value: @Composable () -> Unit, modifier: Modifier = Modifier, gap: Dp = 12.dp) {
    Layout(content = { label(); value() }, modifier = modifier.fillMaxWidth()) { measurables, constraints ->
        val (labelPart, valuePart) = measurables
        val gapPx = gap.roundToPx()
        val labelWants = labelPart.maxIntrinsicWidth(Constraints.Infinity)
        val valueWants = valuePart.maxIntrinsicWidth(Constraints.Infinity)
        val available = if (constraints.hasBoundedWidth) (constraints.maxWidth - gapPx).coerceAtLeast(0) else labelWants + valueWants
        val valueWidth = RowSplit.valueWidth(available, labelWants, valueWants)
        val placedLabel = labelPart.measure(Constraints(maxWidth = available - valueWidth))
        val placedValue = valuePart.measure(Constraints(maxWidth = valueWidth))
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else available + gapPx
        val height = max(placedLabel.height, placedValue.height).coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(width, height) {
            placedLabel.place(0, (height - placedLabel.height) / 2)
            placedValue.place(width - placedValue.width, (height - placedValue.height) / 2)
        }
    }
}

/** How a row's width is shared between a label and its value. */
object RowSplit {
    /**
     * The value's width out of [available]: all it wants when both fit; otherwise the value may
     * take what the label leaves, but never less than half when it needs that much. So the one
     * that is short keeps its natural width and the long one wraps; when both are long, each
     * gets half.
     */
    fun valueWidth(available: Int, labelWants: Int, valueWants: Int): Int =
        minOf(valueWants, maxOf(available / 2, available - labelWants)).coerceIn(0, available)
}

/** How strongly a status chip is tinted with its own colour. */
const val STATUS_CHIP_TINT = 0.14f

/** A small coloured status label. */
@Composable
fun StatusChip(text: String, tone: Tone, modifier: Modifier = Modifier) {
    val color = toneColor(tone)
    Surface(modifier = modifier, color = color.copy(alpha = STATUS_CHIP_TINT), shape = MaterialTheme.shapes.small) {
        Text(text, color = color, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp))
    }
}

/**
 * Long text the owner may want to copy or share: a platform TextView with native selection,
 * so Android's own toolbar offers Copy, Select all, Share and Translate. No copy buttons.
 */
@Composable
fun SelectableText(text: CharSequence, modifier: Modifier = Modifier, sizeSp: Float = 15f) {
    val color = MaterialTheme.colorScheme.onSurface
    val argb = android.graphics.Color.argb(
        (color.alpha * 255).toInt(), (color.red * 255).toInt(), (color.green * 255).toInt(), (color.blue * 255).toInt(),
    )
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            android.widget.TextView(ctx).apply {
                setTextIsSelectable(true)
                textSize = sizeSp
                setLineSpacing(0f, 1.2f)
            }
        },
        update = {
            it.text = text
            it.setTextColor(argb)
        },
    )
}

/** Temporary body for a screen whose module has not landed yet. */
@Composable
fun PendingScreen(name: String) {
    Column(Modifier.fillMaxWidth().padding(24.dp)) { Text(name, style = MaterialTheme.typography.titleLarge) }
}
