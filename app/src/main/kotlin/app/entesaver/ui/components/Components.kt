package app.entesaver.ui.components

import android.content.ClipData
import android.os.Build
import android.widget.Toast
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.entesaver.ui.theme.BrandIndigo
import app.entesaver.ui.theme.BrandIndigoDeep
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.LocalIsDarkTheme
import app.entesaver.ui.theme.MetricTextStyle
import app.entesaver.ui.theme.OnBrand
import app.entesaver.ui.theme.OnSuccessContainerDark
import app.entesaver.ui.theme.OnSuccessContainerLight
import app.entesaver.ui.theme.SuccessContainerDark
import app.entesaver.ui.theme.SuccessContainerLight
import kotlinx.coroutines.launch

/*
 * The shared design system: one card style, one tile style, one selector.
 * Everything animates with the same spring so the app feels like one piece.
 */

/**
 * The one card outline in the app.
 *
 * No longer private to this file. A row that adds its own press gesture has to
 * clip itself to this shape before it adds one, or the ripple is painted as a
 * square that overhangs the rounded corner - visible on every tap of a file
 * row, and the sort of thing that makes an app look unfinished without anyone
 * being able to say why. The shape has to be reachable from the files those
 * rows live in, rather than copied there as a second 24 dp that can drift.
 */
internal val CardShape = RoundedCornerShape(24.dp)

/**
 * The text size at which two things stop being able to share one line.
 *
 * Above it a row of words beside a control is drawn as the words with the
 * control underneath, because at 150% and up on a narrow phone the two halves
 * each get a few words' width and both become unreadable - the label worst of
 * all, since it is the half that says what the control does. Below it nothing
 * changes at all, so an ordinary phone at an ordinary text size is drawn the
 * way it has always been drawn.
 *
 * It is shared rather than judged per component: rows that stack at different
 * moments make one screen look like two.
 */
internal const val StackedTextScale = 1.5f

/**
 * A file row's chrome: the parts that hold their dp size whatever the text
 * does, and so eat the width the name and the size have to share.
 */
internal val ThumbnailWidth = 56.dp
internal val CheckboxWidth = 52.dp
internal val OverflowWidth = 48.dp

/**
 * How much room the name and the size need before they can sit side by side.
 *
 * The two share what the chrome leaves in a 1 to 0.45 split, so the size gets
 * under a third of it and the name barely two thirds. At 320 dp that made the
 * size 42 dp - it broke into "643" over "KB", a column twice as tall as its
 * own text, holding width the name was being cut for. Raising it only far
 * enough to stop that wrap still leaves the name a prefix on an ordinary
 * phone, and a file row whose name reads "tour_photo..." on a screen where
 * every file starts "tour_photo" has told the reader nothing. So the floor is
 * the width at which BOTH still work; under it the size goes beneath the name
 * and takes the whole row, which is what selection mode has always done, and
 * side by side is left to the widths that genuinely have room - a tablet, or
 * a phone turned sideways.
 */
internal val SideBySideMinWidth = 240.dp

/** Shrinks slightly while pressed - cheap, universal touch feedback. */
@Composable
private fun Modifier.pressScale(interaction: MutableInteractionSource): Modifier {
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "pressScale"
    )
    return this.scale(scale)
}

/**
 * App-wide background: the theme's own surface, plain.
 *
 * There used to be two blurred brand glows behind every page. They read on a
 * dark screen as a stain over whatever they fell behind, and a plain surface
 * is what Ente itself draws - so the page is flat, and the accent colour is
 * kept for what the person can tap.
 *
 * It also provides LocalContentColor. Material 3 leaves that to Surface, not
 * to MaterialTheme, so a plain Box root leaves every Text that does not name
 * its own colour painting in the default black - invisible on a dark
 * background, and correct-looking in light mode purely by accident.
 */
@Composable
fun AppBackground(content: @Composable () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    CompositionLocalProvider(
        LocalContentColor provides scheme.onBackground
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(scheme.background)
        ) {
            content()
        }
    }
}

/** Standard content card. */
@Composable
fun AppCard(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    tonal: Boolean = false,
    content: @Composable ColumnScope.() -> Unit
) {
    val scheme = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    var box = modifier
        .fillMaxWidth()
        .let { if (onClick != null) it.pressScale(interaction) else it }
        .clip(CardShape)
        .background(if (tonal) scheme.primaryContainer else scheme.surfaceContainer)
        .border(1.dp, scheme.outlineVariant.copy(alpha = 0.5f), CardShape)
    if (onClick != null) {
        box = box.clickable(interactionSource = interaction, indication = null, onClick = onClick)
    }
    Column(modifier = box.padding(18.dp), content = content)
}

/**
 * Brand gradient card used for the dashboard hero. Its content is white, so
 * both ends of the gradient have to carry white text: Saver Indigo is 6.4:1
 * and the deep violet 9.4:1, while the icon's own bright green would be 2.4:1.
 */
@Composable
fun HeroCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    // The banner keeps its colours in both themes, so it hands its own
    // content colour down rather than letting screens name white themselves.
    CompositionLocalProvider(LocalContentColor provides OnBrand) {
        Column(
            modifier = modifier
                .fillMaxWidth()
                .clip(CardShape)
                .background(Brush.linearGradient(listOf(BrandIndigo, BrandIndigoDeep)))
                .padding(20.dp),
            content = content
        )
    }
}

/** A number that counts up when it changes. */
@Composable
fun AnimatedNumber(
    value: String,
    modifier: Modifier = Modifier,
    style: TextStyle = MetricTextStyle,
    color: Color = MaterialTheme.colorScheme.onSurface
) {
    // Always one Text, always fully opaque, never moved.
    //
    // This used to cross-fade two of them: mid-transition the old and new
    // counts overlapped at partial alpha, which on a tile read as a faded
    // number smeared behind its own label - and on a slow count it never
    // settled. Only the digits change now; the text block does not.
    Text(
        value,
        style = style,
        color = color,
        maxLines = 1,
        softWrap = false,
        // Without this the default is TextOverflow.Clip, so a number too wide
        // for its cell simply lost its end - and half a number is worse than
        // an obviously shortened one.
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
    )
}

/**
 * One count in the progress grid: big number, small caption.
 *
 * Fixed height and a fixed-width figure style, because these tiles sit in a
 * 2x2 grid and a count going from 9 to 10 used to make its tile - and then
 * the whole grid - jump. A number that reflows while it counts reads as a
 * glitch, not as progress. Tapping explains what the count means.
 */
@Composable
fun MetricTile(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
    highlight: Boolean = false,
    onClick: (() -> Unit)? = null,
    icon: ImageVector? = null
) {
    val scheme = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    // The floor grows with the text, because what has to fit inside a tile is
    // text - the same reasoning, and the same 200% cap, as the width floor the
    // grid below uses to decide how many tiles share a row. A bare 126 dp
    // stops meaning anything at a large font: the number and its label both
    // grow past it, the tile grows with them, and every tile in the row ends
    // up at whatever height its own label happened to need, which is the
    // ragged grid the floor exists to prevent.
    val floor = TileHeight * LocalDensity.current.fontScale.coerceIn(1f, 2f)
    var box = modifier
        // A minimum, not a fixed height. The reason the height was pinned -
        // a count going 9 to 10 must not make the grid jump - is already
        // handled by the tabular figures on the number below, and pinning it
        // meant the label was cut off instead: at a large font the two lines
        // of "In upload folder" need more than the 126 dp box and the clip on
        // the next line sliced the second one away. The label is the half
        // that says what the number counts.
        .heightIn(min = floor)
        .clip(RoundedCornerShape(20.dp))
        .background(if (highlight) scheme.secondaryContainer else scheme.surfaceContainer)
        .border(
            1.dp,
            scheme.outlineVariant.copy(alpha = 0.5f),
            RoundedCornerShape(20.dp)
        )
    if (onClick != null) {
        box = box.clickable(interactionSource = interaction, indication = null, onClick = onClick)
    }
    Column(
        modifier = box
            .padding(vertical = 14.dp, horizontal = 12.dp)
            .clearAndSetSemantics {
                contentDescription = "$label: $value"
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // The icon says what the number counts before the label is read. It
        // is decorative in the accessibility tree because the tile already
        // announces itself as "label: value".
        icon?.let {
            Icon(
                it,
                contentDescription = null,
                tint = if (highlight) {
                    scheme.onSecondaryContainer.copy(alpha = 0.8f)
                } else {
                    scheme.onSurfaceVariant
                },
                modifier = Modifier.size(18.dp).padding(bottom = 2.dp)
            )
        }
        AnimatedNumber(
            value = value,
            style = tileFigureStyle(),
            color = if (highlight) scheme.onSecondaryContainer else scheme.primary
        )
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            textAlign = TextAlign.Center,
            // One line for a single word, which has nowhere to wrap and would
            // otherwise be broken in half; two for a label that can wrap.
            maxLines = if (label.trim().contains(' ')) 2 else 1,
            overflow = TextOverflow.Ellipsis,
            // A long label must shrink rather than push the number out of
            // the fixed cell.
            autoSize = TextAutoSize.StepBased(
                minFontSize = 9.sp,
                maxFontSize = MaterialTheme.typography.labelMedium.fontSize,
                stepSize = 0.5.sp
            ),
            color = if (highlight) {
                scheme.onSecondaryContainer.copy(alpha = 0.8f)
            } else {
                scheme.onSurfaceVariant
            },
            modifier = Modifier.padding(top = 6.dp)
        )
    }
}

/**
 * The size of the count inside a progress tile.
 *
 * The number is drawn on one line by design - it must not reflow as it counts
 * up - which leaves it the one piece of the tile with nowhere to go when the
 * reader turns their font up. Two tiles across a 320 dp phone give each about
 * 150 dp, and at the largest accessibility size a five-figure count needs more
 * than that: it came out as "99,9..." on the very tile whose whole job is to
 * say how many. A shortened number says nothing at all.
 *
 * So the figure still grows with the reader's setting, just not past the point
 * where it stops fitting in its own cell - the same trade, and the same 140%
 * threshold, as the one big figure in the hero banner on Home. The label under
 * it wraps and scales in full, as everything else on the tile does.
 */
@Composable
private fun tileFigureStyle(): TextStyle {
    val base = MaterialTheme.typography.headlineSmall.copy(
        // Tabular figures: every digit the same width, so 9 becoming 10
        // changes the number without moving the grid.
        fontFeatureSettings = "tnum",
        fontWeight = FontWeight.SemiBold
    )
    val cap = 1.4f
    val scale = LocalDensity.current.fontScale
    if (scale <= cap) return base
    val factor = cap / scale
    return base.copy(
        fontSize = base.fontSize * factor,
        lineHeight = base.lineHeight * factor
    )
}

/**
 * The progress grid.
 *
 * Every tile is the same cell whatever the row holds: three tiles are three
 * equal thirds, not two-and-a-stretched-one, and a single remaining tile is
 * centred at that same width rather than spanning the screen. A grid whose
 * cells resize as counts appear and disappear reads as a glitch.
 *
 * How many cells fit on a row is measured rather than assumed. Two columns is
 * the shape this was drawn as and is still exactly what comes out on any
 * ordinary phone at an ordinary text size. But a tile carries a five-figure
 * number and a two-word label, and both of those grow with the text size while
 * the glass does not: at 200% on a 320 dp phone two columns leave a tile too
 * little to print its number in, and the number is the whole point of the
 * tile. So the row gives up a column and the grid grows downwards, which is
 * the one direction it is free to grow in.
 */
@Composable
fun MetricGrid(tiles: List<@Composable (Modifier) -> Unit>) {
    if (tiles.isEmpty()) return
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // The floor grows with the text, because what has to fit inside a tile
        // is text. Capped at 200%, which is as far as Android's own setting
        // goes, so an OEM slider beyond it cannot drive this to one column of
        // nothing.
        val floor = TileMinWidth * LocalDensity.current.fontScale.coerceIn(1f, 2f)
        val fits = if (constraints.hasBoundedWidth) {
            ((maxWidth + TileGap) / (floor + TileGap)).toInt()
        } else {
            tiles.size
        }
        // Never wider than the grid was drawn, never narrower than one column.
        val perRow = minOf(if (tiles.size <= 3) tiles.size else 2, fits).coerceAtLeast(1)
        Column(Modifier.fillMaxWidth()) {
            for (row in tiles.chunked(perRow)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        // IntrinsicSize.Min so a tile that had to grow for its
                        // label lifts the others with it. Without this the
                        // tiles are all still the same width but no longer the
                        // same height, which is the ragged grid the fixed
                        // height was there to prevent.
                        .height(IntrinsicSize.Min)
                        .padding(bottom = TileGap),
                    horizontalArrangement = Arrangement.spacedBy(TileGap)
                ) {
                    for (tile in row) tile(Modifier.weight(1f).fillMaxHeight())
                    // Keep the last row's cells the same width as every other
                    // row's.
                    repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/**
 * The narrowest a progress tile may be drawn before its row drops a column,
 * and the gap between two of them.
 *
 * Deliberately low: it is a cliff edge, not a target. Every layout that works
 * today is left exactly as it is - three tiles across a 320 dp phone still
 * measure about 77 dp each and stay on one row - and the reflow only happens
 * where the tiles genuinely cannot hold their own contents.
 */
private val TileMinWidth = 72.dp
private val TileGap = 10.dp

/**
 * The height every progress tile starts at, and never goes below, at an
 * ordinary text size.
 *
 * A floor rather than a fixed size. It is generous enough for a big number
 * and two lines of label at ordinary font sizes, so the grid is even in the
 * normal case; when a label genuinely needs more - a long one at a large font
 * scale - the tile grows and takes its row with it, rather than clipping the
 * line that says what the number counts.
 *
 * The tile scales this by the reader's font setting, capped at 200%, so the
 * floor keeps meaning the same thing - "room for a number and two lines of
 * label" - at every text size rather than only at the default one.
 */
val TileHeight = 126.dp




/**
 * How wide a status pill's words may get before the end of them is shortened.
 *
 * A cliff edge rather than a target, and it grows with the text size so it
 * holds roughly the same number of characters however large the reader's font
 * is - the same rule the filter chips on the list screens follow. Inside a
 * row that wraps, the words simply wrap and this never comes into play; it is
 * here for the row that does not, where an unbounded label is one long chip
 * that pushes every other chip off the side of the phone.
 */
private val StatusChipLabelMax = 200.dp

/** Tappable status pill (needs attention). */
@Composable
fun StatusChip(text: String, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    val labelMax = StatusChipLabelMax * LocalDensity.current.fontScale.coerceIn(1f, 2f)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .pressScale(interaction)
            .clip(CircleShape)
            .background(scheme.tertiaryContainer)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            // These are the taps that lead to the fix for whatever is wrong,
            // and they were about 32 dp tall - under the 48 dp a thumb can
            // reliably hit. The pill still LOOKS the same size; the target
            // around it is the one that grew.
            .heightIn(min = Dimens.TouchTarget)
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Box(
            Modifier
                .size(7.dp)
                .background(scheme.tertiary, CircleShape)
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium,
            color = scheme.onTertiaryContainer,
            // Two lines and then an ellipsis. These chips say what is wrong -
            // "Cloud app not set up", "Battery restricted" - and with no limit
            // at all a long one in another language ran down the card as a
            // column of single words; with a limit and no overflow it would be
            // cut mid-letter instead, which is worse than saying less.
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .padding(start = 8.dp)
                .widthIn(max = labelMax)
        )
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .padding(start = 4.dp, top = 8.dp, bottom = 6.dp)
            // A heading to a screen reader as well as to the eye, so someone
            // using TalkBack can jump from group to group instead of reading
            // every row of a long settings page to find the one they want.
            .semantics { heading() }
    )
}

@Composable
fun KeyValueRow(key: String, value: String) {
    LabelValueRow(key, value, Modifier.padding(vertical = 4.dp), FontWeight.Medium)
}

/**
 * A label and its value, as one line when the line holds both whole.
 *
 * Two weighted columns split the line whether or not either half fits, so a
 * value such as "Photos and videos, from 2 of your 5 albums" was wrapped into
 * a narrow column pushed against the end - two lines of ragged text beside a
 * label with room to spare, on an ordinary phone at an ordinary font. Laid
 * out by [TrailingOrBelow] the pair shares a line only when both fit on it
 * unbroken, and otherwise the value goes under its label with the whole
 * width to itself. Read as one item by a screen reader.
 */
@Composable
fun LabelValueRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    valueWeight: FontWeight = FontWeight.SemiBold
) {
    TrailingOrBelow(modifier.semantics(mergeDescendants = true) {}) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = valueWeight
        )
    }
}

/**
 * Two pieces of [content] - something and what goes with it - on one line,
 * the second against the end, when the line holds both unbroken; otherwise
 * the second under the first, from the start, with the whole width to
 * itself. Measured, not guessed from the text size, so it holds at any
 * screen width and any font scale, and it mirrors for right-to-left.
 */
@Composable
fun TrailingOrBelow(
    modifier: Modifier = Modifier,
    gap: Dp = 12.dp,
    lineGap: Dp = 2.dp,
    content: @Composable () -> Unit
) {
    Layout(content = content, modifier = modifier.fillMaxWidth()) { measurables, constraints ->
        require(measurables.size == 2) { "TrailingOrBelow lays out exactly two pieces" }
        val (first, second) = measurables
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val gapPx = gap.roundToPx()
        val oneLine = !constraints.hasBoundedWidth ||
            first.maxIntrinsicWidth(constraints.maxHeight) + gapPx +
            second.maxIntrinsicWidth(constraints.maxHeight) <= constraints.maxWidth
        val a = first.measure(loose)
        val b = second.measure(loose)
        if (oneLine) {
            val width = if (constraints.hasBoundedWidth) constraints.maxWidth else a.width + gapPx + b.width
            val height = maxOf(a.height, b.height)
            layout(width, height) {
                a.placeRelative(0, (height - a.height) / 2)
                b.placeRelative(width - b.width, (height - b.height) / 2)
            }
        } else {
            val under = lineGap.roundToPx()
            layout(constraints.maxWidth, a.height + under + b.height) {
                a.placeRelative(0, 0)
                b.placeRelative(0, a.height + under)
            }
        }
    }
}

/**
 * Segmented selector with an animated, filled selection.
 *
 * The options share the width equally, and how many of them share one line is
 * measured rather than fixed. On any phone at an ordinary text size that is
 * still all of them, exactly as before. Where they genuinely cannot fit -
 * five choices on a 320 dp screen, or three of them at 200% text - the
 * selector takes a second line rather than shrinking every label towards
 * illegible: the whole job of this control is to say what the choices are.
 * Every segment stays the same size as every other, on whichever line it
 * lands, so the group still reads as one control.
 */
@Composable
fun SegmentedChoice(
    options: List<Pair<String, String>>, // value to label
    selected: String,
    onSelect: (String) -> Unit
) {
    if (options.isEmpty()) return
    val scheme = MaterialTheme.colorScheme
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .padding(top = 10.dp)
    ) {
        // What one option needs, which grows with the text inside it. Capped
        // at 200%, the largest size Android's own setting offers.
        val floor = SegmentMinWidth * LocalDensity.current.fontScale.coerceIn(1f, 2f)
        val inner = maxWidth - SegmentGap * 2
        val fits = if (constraints.hasBoundedWidth) {
            ((inner + SegmentGap) / (floor + SegmentGap)).toInt()
        } else {
            options.size
        }
        val perLine = minOf(options.size, fits).coerceAtLeast(1)
        // Even lines rather than a full one and a remainder: five options over
        // two lines are three and two, not four and a lonely one.
        val lines = (options.size + perLine - 1) / perLine
        val across = (options.size + lines - 1) / lines
        Column(
            Modifier
                .fillMaxWidth()
                // A circle is the right outline for one line of pills and the
                // wrong one for two, where it bows the sides in around them.
                .clip(if (lines > 1) RoundedCornerShape(Dimens.CardCorner) else CircleShape)
                .background(scheme.surfaceContainerHighest)
                .padding(SegmentGap),
            verticalArrangement = Arrangement.spacedBy(SegmentGap)
        ) {
            for (line in options.chunked(across)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        // One line's segments are as tall as its tallest label,
                        // so a wrapped label lifts its neighbours with it
                        // instead of leaving gaps in the strip.
                        .height(IntrinsicSize.Min),
                    horizontalArrangement = Arrangement.spacedBy(SegmentGap)
                ) {
                    for ((value, label) in line) {
                        Segment(
                            label = label,
                            active = value == selected,
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            onClick = { onSelect(value) }
                        )
                    }
                    // Keeps the last line's segments the width of every other
                    // line's, rather than stretching two across the whole row.
                    repeat(across - line.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/** One option in a [SegmentedChoice]. */
@Composable
private fun Segment(
    label: String,
    active: Boolean,
    modifier: Modifier,
    onClick: () -> Unit
) {
    val scheme = MaterialTheme.colorScheme
    val alpha by animateFloatAsState(
        targetValue = if (active) 1f else 0f,
        animationSpec = tween(200),
        label = "segment"
    )
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            // A segment is a button, and a button smaller than a finger is a
            // button people miss.
            .heightIn(min = Dimens.TouchTarget)
            .clip(CircleShape)
            .background(scheme.primary.copy(alpha = alpha))
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick
            )
            // Which option is on was carried by fill colour and nothing else,
            // so a screen reader read the whole row as identical buttons and
            // announced no selection at all. Colour is never the only carrier
            // of meaning.
            .semantics {
                role = Role.RadioButton
                selected = active
            }
            .padding(vertical = 10.dp, horizontal = 6.dp),
        contentAlignment = Alignment.Center
    ) {
        // A clipped option is a broken option: "Unlimited" showing as
        // "Unlimi" tells the user nothing. Shrinking alone was not
        // enough - "Photos and videos" across a third of the row still
        // ran out of space at the smallest size allowed and came out
        // as "Photos and vide" - so a label that will not fit on one
        // line wraps onto a second instead of losing its end.
        //
        // Only where there is a space to wrap at, though. Given two
        // lines to fill, the shrinking stops as soon as the text fits
        // across both, and a single long word simply breaks in half:
        // four options across a phone turned "Unlimited" into
        // "Unlimit" above "ed". A one-word label gets one line and has
        // to shrink until it really fits.
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = if (active) scheme.onPrimary else scheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            maxLines = if (label.trim().contains(' ')) 2 else 1,
            overflow = TextOverflow.Ellipsis,
            autoSize = TextAutoSize.StepBased(
                minFontSize = 9.sp,
                maxFontSize = MaterialTheme.typography.labelLarge.fontSize,
                stepSize = 0.5.sp
            )
        )
    }
}

/**
 * The narrowest one option may be drawn before the selector takes a second
 * line, and the gap between two of them.
 *
 * Low on purpose, like the tile floor above it: four options across a 320 dp
 * phone still measure 75 dp each and stay on one line, so nothing that works
 * today moves. It is only the genuinely impossible case that reflows.
 */
private val SegmentMinWidth = 64.dp
private val SegmentGap = 4.dp

/**
 * Rounded capacity bar that animates to its new value. [fraction] is how full
 * the volume is, so the filled part is what is already used.
 */
@Composable
fun MeterBar(
    fraction: Float,
    modifier: Modifier = Modifier,
    warn: Boolean = false
) {
    val scheme = MaterialTheme.colorScheme
    val target = fraction.coerceIn(0f, 1f)
    val animated by animateFloatAsState(
        targetValue = target,
        animationSpec = spring(stiffness = Spring.StiffnessLow),
        label = "meter"
    )
    val fill = if (warn) scheme.error else scheme.primary
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(10.dp)
            .clip(CircleShape)
            .background(scheme.surfaceContainerHighest)
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(animated)
                .clip(CircleShape)
                .background(
                    Brush.horizontalGradient(
                        listOf(fill.copy(alpha = 0.75f), fill)
                    )
                )
        )
    }
}

/** Severity a status badge should read as. */
enum class BadgeTone { NEUTRAL, PROGRESS, SUCCESS, MUTED }

/** Small filled pill that carries an item's state at a glance. */
@Composable
fun StateBadge(text: String, tone: BadgeTone, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val (background, foreground) = when (tone) {
        BadgeTone.NEUTRAL -> scheme.surfaceContainerHighest to scheme.onSurfaceVariant
        BadgeTone.PROGRESS -> scheme.primaryContainer to scheme.onPrimaryContainer
        BadgeTone.SUCCESS -> if (LocalIsDarkTheme.current) {
            SuccessContainerDark to OnSuccessContainerDark
        } else {
            SuccessContainerLight to OnSuccessContainerLight
        }
        // The outline colour is a rule's colour, not a word's: on this fill it
        // was 3.7:1, under what text this small needs. Muted is said by the
        // paler pill; the words on it stay readable.
        BadgeTone.MUTED -> scheme.surfaceContainerHigh to scheme.onSurfaceVariant
    }
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = foreground,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .clip(CircleShape)
            .background(background)
            .padding(horizontal = 10.dp, vertical = 4.dp)
    )
}

/** Inline note used for warnings under an option. */
@Composable
fun WarningNote(text: String) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(scheme.tertiaryContainer.copy(alpha = 0.6f))
            .padding(horizontal = 12.dp, vertical = 8.dp)
    ) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onTertiaryContainer
        )
    }
}

/**
 * How much a launcher enlarges an adaptive icon's layers: the artwork is
 * drawn on a 108 unit canvas of which only the middle 72 are guaranteed to
 * survive the mask, so every launcher scales by 108/72 and crops. A layer
 * drawn at its natural size instead keeps that safe-zone padding as visible
 * empty space, which is exactly why the mark inside the app looked smaller
 * than the same icon on the home screen.
 */
private const val AdaptiveIconScale = 1.5f

/**
 * The app's own mark, composed the way the launcher composes it.
 *
 * It used to be a separate flat PNG - a pre-baked tile with transparent
 * margin around it and the glyph sitting small in the middle, drifting from
 * the real icon every time either was touched. Now the two adaptive layers
 * the launcher itself uses are drawn here, scaled by the launcher's own
 * factor and clipped to a rounded tile, so the icon in the app and the icon
 * on the home screen are one object with one source of truth. The corner
 * radius is a share of the size rather than a fixed dp, so the shape reads
 * the same at 34 dp on Home as it does at 64 dp in an empty state.
 */
@Composable
fun BrandMark(size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(percent = AdaptiveIconCornerPercent))
    ) {
        Image(
            painter = painterResource(app.entesaver.R.drawable.ic_launcher_background),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .matchParentSize()
                .scale(AdaptiveIconScale)
        )
        Image(
            painter = painterResource(app.entesaver.R.drawable.ic_launcher_foreground),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .matchParentSize()
                .scale(AdaptiveIconScale)
        )
    }
}

/**
 * The corner of the tile, as a percentage of its own size.
 *
 * Android's own icon mask is a squircle with roughly a quarter of the width
 * taken off each corner. A rounded rectangle at the same share sits in the
 * same family without shipping a second mask to keep in step.
 */
private const val AdaptiveIconCornerPercent = 24

/** Friendly empty state instead of a blank screen. */

@Composable
fun EmptyState(title: String, body: String, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        // A share of the room rather than a flat 40 dp above and below.
        //
        // Forty was chosen against a phone held upright with plenty of screen
        // left over. Sideways, or on a small phone at a large font, the same
        // eighty dp of nothing is most of what the empty state has to work
        // with, and it pushes the sentence explaining what to do next below
        // the fold of a screen that has nothing else on it at all.
        //
        // Where the height is known this takes a proportion of it, so the
        // breathing space stays in proportion to the screen it is drawn on.
        // Every caller today puts this inside something that scrolls, which
        // measures its children with no height limit at all, so there is
        // nothing to take a share of - those fall back to the app's ordinary
        // gap between groups, which is what this space is: a gap, not a
        // feature.
        val pad = (if (constraints.hasBoundedHeight) maxHeight * 0.08f else Dimens.GroupGap)
            .coerceIn(Dimens.CardGap, Dimens.GroupGap)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = pad, horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BrandMark(size = 64.dp)
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                color = LocalContentColor.current,
                modifier = Modifier.padding(top = 16.dp)
            )
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
    }
}

/**
 * Puts a folder path on the clipboard, and says so where the system does not.
 *
 * Returned as a callback so the two places that print a path - the setup
 * summary and the Storage screen - copy it identically.
 */
@Composable
fun rememberPathCopier(): (String) -> Unit {
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val copied = androidx.compose.ui.res.stringResource(app.entesaver.R.string.path_copied)
    return { path ->
        scope.launch {
            clipboard.setClipEntry(
                ClipEntry(
                    ClipData.newPlainText(copied, path)
                )
            )
            // Android 13 and up shows its own clipboard confirmation; a second
            // toast on top of it is noise.
            if (Build.VERSION.SDK_INT < 33) {
                val toast = Toast.makeText(
                    context, copied, Toast.LENGTH_SHORT
                )
                toast.show()
            }
        }
    }
}

/**
 * A folder path, with a one-tap copy.
 *
 * Paths are shown so they can be typed into a cloud app's folder picker, and
 * a path typed slightly wrong backs up nothing while looking correct. They are
 * set in the normal text face rather than monospace: a column of monospace
 * paths on a settings screen reads as a log file.
 */
@Composable
fun PathLine(path: String, modifier: Modifier = Modifier) {
    val copyPath = rememberPathCopier()
    val copyLabel = androidx.compose.ui.res.stringResource(app.entesaver.R.string.copy_path_action)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth()
    ) {
        Text(
            path,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            // No line limit on purpose. This path is here to be read and typed
            // into a cloud app's folder picker, and a path cut short still
            // looks like a path - so the user adds it, and the half that was
            // never shown is never backed up. Nothing bounds this row's
            // height, so it simply wraps.
            modifier = Modifier.weight(1f)
        )
        IconButton(
            onClick = { copyPath(path) },
            // A finger, not an icon: at 32 dp this was the smallest tap target
            // in the app, on the one control that has to work first time -
            // a path typed out by hand instead is a path typed slightly wrong.
            modifier = Modifier.size(Dimens.TouchTarget)
        ) {
            Icon(
                Icons.Outlined.ContentCopy,
                contentDescription = copyLabel,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

/**
 * A short warning under the control it belongs to.
 *
 * Shared rather than re-declared per screen: an inconsistent warning colour
 * is how "this matters" quietly stops meaning anything.
 */
@Composable
fun WarningText(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.error,
        modifier = Modifier.padding(top = 4.dp)
    )
}
