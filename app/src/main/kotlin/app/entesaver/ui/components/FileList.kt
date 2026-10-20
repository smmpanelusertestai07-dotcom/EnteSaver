package app.entesaver.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.entesaver.R
import app.entesaver.ui.theme.TabularFigures

/*
 * The parts every "find space" list shares.
 *
 * Duplicates, biggest files and reclaim all answer the same question and used
 * to answer it three different ways - three row layouts, three ideas of what
 * a size looks like, and only one of them able to do anything. They now use
 * these pieces, so a person who learns one list has learned all three.
 */

/** Search box: name or album, with a clear button once there is something in it. */
@Composable
fun ListSearchField(
    query: String,
    onQuery: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: String = stringResource(R.string.list_search)
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQuery,
        singleLine = true,
        label = { Text(label) },
        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) {
                    Icon(
                        Icons.Outlined.Close,
                        contentDescription = stringResource(R.string.list_clear_search)
                    )
                }
            }
        },
        modifier = modifier.fillMaxWidth()
    )
}

/**
 * One file in a find-space list.
 *
 * Thumbnail, name ellipsised at the end so the extension survives, one line of
 * context, the size on the right, and the actions behind an overflow. Actions
 * are not full-width buttons inside the row: two of those per row turned a
 * list of files into a wall of controls with the files squeezed between them.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FileRow(
    name: String,
    context: String,
    size: String,
    proof: String?,
    thumbnail: @Composable () -> Unit,
    actions: List<Pair<String, () -> Unit>>,
    modifier: Modifier = Modifier,
    selected: Boolean? = null,
    onSelectedChange: ((Boolean) -> Unit)? = null,
    trailingNote: String? = null,
    onClick: (() -> Unit)? = null,
    onLongPress: (() -> Unit)? = null
) {
    var menuOpen by remember { mutableStateOf(false) }
    // Where the size and the saving note go. Beside the name normally; under
    // it once the text is large enough that the two columns would each be a
    // few characters wide. A checkbox, a thumbnail and an overflow button all
    // hold their dp size whatever the text does, so at 200% on a 320 dp phone
    // there is barely a third of the row left for the two of them to share.
    // A visible checkbox costs the same width as a font jump, and on a real
    // phone the combination cut the name to one word and the duration to
    // "1 m..." - so selection mode stacks at every font size.
    val selectable = selected != null && onSelectedChange != null
    // Long-press starts a selection, exactly as it does on Files. Without it
    // a screen can show a checkbox once a selection exists but offer no way to
    // create one, which leaves "Select all" and the action bar unreachable.
    // Named, so a screen reader offers "double-tap and hold to select" rather
    // than an unexplained long-press action.
    val selectLabel = stringResource(R.string.list_select)
    val card = if (onLongPress != null) {
        modifier
            .padding(vertical = 4.dp)
            // Clipped to the card's own outline before the gesture is added,
            // not after. The press ripple is drawn by whatever added the
            // gesture, so applied first it painted a square of colour that
            // overhung all four rounded corners - on every tap of every file,
            // on the screen people spend the most time on. AppCard clips
            // itself, but that happens further down the chain and so cannot
            // reach a ripple that was already put above it.
            .clip(CardShape)
            .combinedClickable(
                onClick = { onClick?.invoke() },
                onLongClickLabel = selectLabel,
                onLongClick = onLongPress
            )
    } else {
        modifier.padding(vertical = 4.dp)
    }
    AppCard(modifier = card, onClick = if (onLongPress != null) null else onClick) {
        // The row asks the row how wide it is. Font scale alone was not enough:
        // at ordinary text size on a 320 dp phone, a Largest files row spends
        // its width on a thumbnail, an overflow button and the card's own
        // padding, and what is left splits 1 to 0.45 - so the size column got
        // about 42 dp, too narrow to hold "643 KB" on one line, and wrapped
        // into a thin two-line stack while the name it had displaced was cut to
        // "tour_photo...". Both columns lost. Below the width the two of them
        // need, the value goes under the name and takes the full row instead.
        BoxWithConstraints {
            val chrome = ThumbnailWidth + 12.dp +
                (if (selectable) CheckboxWidth else 0.dp) +
                (if (actions.isNotEmpty()) OverflowWidth else 0.dp)
            // A note under the size ("about 459 KB after") is a phrase, and
            // beside the name it had a share of the row that wrapped it into
            // a ragged column against the edge: with one, the value always
            // goes under the name.
            val stacked = selectable || trailingNote != null ||
                LocalDensity.current.fontScale >= StackedTextScale ||
                maxWidth - chrome < SideBySideMinWidth
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (selectable) {
                    // Named after the file it selects. An unlabeled checkbox
                    // in a list of them is announced as "checkbox, not ticked"
                    // over and over, with nothing to say which file it means.
                    Checkbox(
                        checked = selected,
                        onCheckedChange = onSelectedChange,
                        modifier = Modifier.semantics { contentDescription = name }
                    )
                    Spacer(Modifier.width(4.dp))
                }
                thumbnail()
                Column(
                    Modifier
                        .weight(1f)
                        .padding(start = 12.dp)
                ) {
                    Text(
                        name,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        context,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    proof?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                            // No line limit. This is the sentence the whole
                            // evidence feature rests on - "Your cloud app uploaded
                            // this much data right after we added the file" - and
                            // two lines cut it mid-word with no ellipsis on any
                            // phone. The row has no fixed height, so it wraps and
                            // the card grows, which is what Reclaim already does
                            // with the same text.
                        )
                    }
                    if (stacked) {
                        FileRowValue(
                            size = size,
                            trailingNote = trailingNote,
                            alignEnd = false,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 4.dp)
                        )
                    }
                }
                // A share of the row, not a fixed 120 dp. Bounding the note in dp
                // stopped it emptying the name off the row, but dp does not grow
                // with the font: at a large scale "about 459 KB after optimising"
                // was cut back to "about 459 KB af..." and lost the words that say
                // what the number means. A weight lets both sides scale together.
                if (!stacked) {
                    FileRowValue(
                        size = size,
                        trailingNote = trailingNote,
                        alignEnd = true,
                        modifier = Modifier.weight(0.45f, fill = false)
                    )
                }
                if (actions.isNotEmpty()) {
                    Box {
                        IconButton(onClick = { menuOpen = true }) {
                            Icon(
                                Icons.Outlined.MoreVert,
                                contentDescription = stringResource(R.string.list_more_actions)
                            )
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            for ((label, action) in actions) {
                                DropdownMenuItem(
                                    text = { Text(label) },
                                    onClick = {
                                        menuOpen = false
                                        action()
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * What a file weighs, and what it would weigh afterwards.
 *
 * One definition for both places the row can put it - to the right of the
 * name, or underneath it - so the two cannot drift into saying the same thing
 * two different ways.
 */
@Composable
private fun FileRowValue(
    size: String,
    trailingNote: String?,
    alignEnd: Boolean,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier,
        horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start
    ) {
        Text(
            size,
            style = MaterialTheme.typography.titleMedium.merge(TabularFigures)
        )
        trailingNote?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall.merge(TabularFigures),
                color = MaterialTheme.colorScheme.primary,
                textAlign = if (alignEnd) TextAlign.End else TextAlign.Start,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/**
 * The ordinary gap under the last row of a list.
 *
 * It used to be a taller gap, scaled with the text, for the selection bar to
 * float over - and however it was sized it was a guess at that bar's height.
 * A bar carrying a reason and a note above a button that had wrapped onto its
 * own line outgrew it, and sat over the last file in the list: the one row a
 * person scrolled all that way to reach. The bar is now laid out under the
 * list rather than on top of it, so there is nothing left here to make room
 * for.
 */
@Composable
fun ListTail() {
    Spacer(Modifier.height(24.dp))
}
