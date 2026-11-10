package com.pocketide.ui.screens.help

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BulletSpan
import android.text.style.StyleSpan
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.pocketide.docs.DocBlock
import com.pocketide.docs.DocsContent
import com.pocketide.ui.components.SelectableText
import com.pocketide.ui.components.Tone
import com.pocketide.ui.components.toneColor
import com.pocketide.ui.web.Browser

/**
 * Renders one doc block. All text uses the platform's own selection (Copy, Select all, Share,
 * Translate). A link to another Help page ("help:<id>") opens in the app; a web link, in Chrome.
 */
@Composable
fun DocBlockView(block: DocBlock, onOpen: (String) -> Unit) {
    when (block) {
        is DocBlock.Paragraph -> SelectableText(block.text, Modifier.fillMaxWidth())
        is DocBlock.Bullets -> SelectableText(bullets(block.items), Modifier.fillMaxWidth())
        is DocBlock.Steps -> SelectableText(steps(block.items), Modifier.fillMaxWidth())
        is DocBlock.Table -> TableBlock(block)
        is DocBlock.Note -> NoteBlock(block)
        is DocBlock.Link -> LinkRow(block.label, block.url, onOpen)
    }
}

@Composable
private fun bullets(items: List<String>): CharSequence {
    val density = LocalDensity.current
    val gap = with(density) { 10.dp.roundToPx() }
    val radius = with(density) { 2.5.dp.roundToPx() }
    val color = MaterialTheme.colorScheme.primary.toArgb()
    val out = SpannableStringBuilder()
    items.forEachIndexed { index, item ->
        val start = out.length
        out.append(item)
        if (index < items.lastIndex) out.append('\n')
        out.setSpan(BulletSpan(gap, color, radius), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    return out
}

private fun steps(items: List<String>): CharSequence {
    val out = SpannableStringBuilder()
    items.forEachIndexed { index, item ->
        val start = out.length
        out.append("${index + 1}.  ")
        out.setSpan(StyleSpan(Typeface.BOLD), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        out.append(item)
        if (index < items.lastIndex) out.append("\n\n")
    }
    return out
}

/** Below this width a table's columns do not fit at a readable text size. */
private val WideTable = 600.dp

/**
 * On a phone a table becomes one card per row: the first cell as the card's title and every
 * other cell under its column name. On a wide screen it stays a table.
 */
@Composable
private fun TableBlock(table: DocBlock.Table) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        if (maxWidth >= WideTable && table.header.isNotEmpty()) WideTableView(table) else StackedTable(table)
    }
}

@Composable
private fun StackedTable(table: DocBlock.Table) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (row in table.rows) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
            ) {
                SelectableText(tableRow(table.header, row), Modifier.fillMaxWidth().padding(14.dp))
            }
        }
    }
}

@Composable
private fun WideTableView(table: DocBlock.Table) {
    val columns = table.header.size
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
            TableLine(table.header, columns, header = true)
            table.rows.forEach { row ->
                HorizontalDivider()
                TableLine(row, columns, header = false)
            }
        }
    }
}

@Composable
private fun TableLine(cells: List<String>, columns: Int, header: Boolean) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for (i in 0 until columns) {
            val text = cells.getOrNull(i).orEmpty()
            SelectableText(if (header) bold(text) else text, Modifier.weight(1f))
        }
    }
}

private fun bold(text: String): CharSequence = SpannableStringBuilder(text).apply {
    setSpan(StyleSpan(Typeface.BOLD), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
}

internal fun tableRow(header: List<String>, row: List<String>): CharSequence {
    val out = SpannableStringBuilder()
    val title = row.firstOrNull().orEmpty()
    if (title.isNotBlank()) {
        out.append(title)
        out.setSpan(StyleSpan(Typeface.BOLD), 0, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    for (i in 1 until row.size) {
        val cell = row[i]
        if (cell.isBlank()) continue
        if (out.isNotEmpty()) out.append('\n')
        val label = header.getOrNull(i)?.takeIf { it.isNotBlank() }
        if (label != null) {
            val start = out.length
            out.append(label).append(": ")
            out.setSpan(StyleSpan(Typeface.BOLD), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        out.append(cell)
    }
    return out
}

/** How a note is labelled, so its meaning does not depend on colour alone. */
internal fun noteLabel(tone: String): String = when (tone.lowercase()) {
    "warn" -> "Warning"
    "tip" -> "Good to know"
    else -> "Note"
}

@Composable
private fun NoteBlock(note: DocBlock.Note) {
    val (tone, icon) = when (note.tone.lowercase()) {
        "warn" -> Tone.WARN to Icons.Outlined.WarningAmber
        "tip" -> Tone.OK to Icons.Outlined.Lightbulb
        else -> Tone.NEUTRAL to Icons.Outlined.Info
    }
    val color = if (tone == Tone.NEUTRAL) MaterialTheme.colorScheme.primary else toneColor(tone)
    Surface(color = color.copy(alpha = 0.10f), shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.Top) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(noteLabel(note.tone), style = MaterialTheme.typography.labelLarge, color = color)
                SelectableText(note.text, Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun LinkRow(label: String, url: String, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    val openPlace = LocalOpenPlace.current
    val (icon, open) = when {
        url.startsWith(DocsContent.HELP_SCHEME) -> Icons.AutoMirrored.Outlined.MenuBook to { onOpen(url.removePrefix(DocsContent.HELP_SCHEME)) }
        url.startsWith(DocsContent.APP_SCHEME) -> Icons.AutoMirrored.Outlined.ArrowForward to { openPlace(url.removePrefix(DocsContent.APP_SCHEME)) }
        else -> Icons.AutoMirrored.Outlined.OpenInNew to { Browser.open(context, url) }
    }
    TextButton(onClick = open) {
        Icon(icon, contentDescription = null)
        Spacer(Modifier.width(8.dp))
        Text(label)
    }
}

/** Opens a place in the app by its id (`app:keys` opens Settings > Keys); the app's navigation provides it. */
val LocalOpenPlace = staticCompositionLocalOf<(String) -> Unit> { {} }
