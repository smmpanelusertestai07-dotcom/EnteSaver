package app.entesaver.ui.components

import android.net.Uri
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Science
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.entesaver.R
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.TabularFigures
import app.entesaver.util.Formats
import app.entesaver.util.Thumbnails
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * "Try it on a few photos first", in one place so setup and Home cannot drift.
 *
 * It lives on Home as well as in setup because skipping it during setup used
 * to lose it for good, and the trial is the cheapest possible answer to "what
 * will this actually do to my photos". It stops being offered once there are
 * real results to look at instead: at that point the Files screen shows every
 * before-and-after there is, and a trial would be proving something already
 * proven.
 *
 * [size] is how many photos are genuinely waiting, capped at the trial size.
 * The button used to promise three whatever was there.
 *
 * [albumsChosen] decides which of three things the card says, and the same
 * rule holds in setup and on Home. During setup nothing has been scanned yet,
 * so [size] is zero there for a perfectly healthy phone: the card used to read
 * "no photos are waiting" and hide its own button, which made the trial look
 * broken exactly where it is most useful. The run scans the chosen albums
 * itself, so the offer only depends on an album being ticked.
 */
@Composable
fun TrialCard(
    size: Int,
    running: Boolean,
    results: List<AppViewModel.TestItem>?,
    onRun: () -> Unit,
    modifier: Modifier = Modifier,
    albumsChosen: Boolean = true,
    onChooseAlbums: (() -> Unit)? = null,
    accessFull: Boolean = true,
    /** Tapping a result opens the before-and-after of that photo. */
    onOpen: ((AppViewModel.TestItem) -> Unit)? = null,
    /** Throws the trial's copies away and puts the photos back in the queue. */
    onDiscard: (() -> Unit)? = null,
    /** The last tap found a run making a copy, so nothing was tried. */
    busy: Boolean = false
) {
    AppCard(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Outlined.Science,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp)
            )
            Spacer(Modifier.width(10.dp))
            Text(
                stringResource(R.string.trial_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
        }
        Text(
            when {
                // The run refuses under partial access, so offering the button
                // there would be a button that does nothing - the one thing a
                // screen must never do.
                !accessFull -> stringResource(R.string.trial_needs_access)
                !albumsChosen -> stringResource(R.string.trial_needs_albums)
                size > 0 -> pluralStringResource(R.plurals.trial_body, size, size)
                else -> stringResource(R.string.trial_ready)
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp)
        )
        if (!accessFull) {
            // Nothing to offer: Home already carries the card that fixes this.
        } else if (!albumsChosen) {
            onChooseAlbums?.let { choose ->
                TextButton(onClick = choose, modifier = Modifier.padding(top = 4.dp)) {
                    Text(stringResource(R.string.trial_choose_albums))
                }
            }
        } else if (results.isNullOrEmpty()) {
            // Gone once there are results: a second trial picked three more
            // photos and left the first three copies with no way to remove
            // them. Remove the copies below to try again.
            OutlinedButton(
                enabled = !running,
                onClick = onRun,
                modifier = Modifier.padding(top = 10.dp)
            ) {
                if (running) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.onb6_running))
                } else if (size > 0) {
                    Text(pluralStringResource(R.plurals.trial_action, size, size))
                } else {
                    Text(stringResource(R.string.trial_run))
                }
            }
            // Said, not waited out: a run can be on one video for minutes.
            if (busy && !running) {
                Text(
                    stringResource(R.string.trial_busy),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
        }
        results?.takeIf { it.isNotEmpty() }?.let { list ->
            Column(Modifier.padding(top = 10.dp)) {
                Text(
                    stringResource(R.string.trial_done),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary
                )
                for (item in list) {
                    TrialRow(item, onOpen?.let { open -> { open(item) } })
                }
                // What the trial is really for: the quality that survived it.
                val before = list.sumOf { it.before }
                val after = list.sumOf { it.after }
                if (before > 0) {
                    Text(
                        stringResource(
                            R.string.trial_kept,
                            Formats.bytes(before - after),
                            Formats.percentOf(before - after, before)
                        ),
                        style = MaterialTheme.typography.bodyMedium.merge(TabularFigures),
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
                // The pixels the encoder really kept on these very files. It
                // replaces a sentence that used to promise they "still look
                // the same", which was a claim nobody could check.
                val measured = list.mapNotNull { it.keptPercent }
                if (measured.isNotEmpty()) {
                    Text(
                        stringResource(R.string.trial_kept_detail, measured.average().toInt()),
                        style = MaterialTheme.typography.bodyMedium.merge(TabularFigures),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
                // The trial makes the copies but does not publish them: that
                // is the release step, which is paced. Without this line the
                // app reports three optimised photos and the gallery shows no
                // Ente Saver album, which reads as the trial having failed.
                Text(
                    stringResource(R.string.trial_next),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
                // When this card leaves, and how to be rid of the copies now.
                Text(
                    stringResource(R.string.trial_goes_away),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp)
                )
                onDiscard?.let { discard ->
                    TextButton(onClick = discard, modifier = Modifier.padding(top = 2.dp)) {
                        Text(stringResource(R.string.trial_discard))
                    }
                }
            }
        }
    }
}

/**
 * One trial result: the photo, its name on one line, and the saving.
 *
 * The card used to print each file name in full - a screenshot's name is
 * sixty characters and wrapped over five lines - beside the sizes, with
 * nothing to look at and nothing to tap. Now the row is the photo's own
 * thumbnail, the name cut in the middle (the start and the extension are the
 * parts that identify a file), and the whole row opens the before-and-after.
 */
@Composable
private fun TrialRow(item: AppViewModel.TestItem, onOpen: (() -> Unit)?) {
    val thumb = trialThumb(item.row?.contentUri)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = Dimens.TouchTarget)
            .clip(RoundedCornerShape(10.dp))
            .let { if (onOpen != null) it.clickable(onClick = onOpen) else it }
            .padding(vertical = 6.dp)
    ) {
        Box(
            Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
        ) {
            if (thumb != null) {
                Image(
                    bitmap = thumb,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(48.dp)
                )
            } else {
                Icon(
                    Icons.Outlined.Image,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .size(22.dp)
                        .align(Alignment.Center)
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                item.name,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis
            )
            Text(
                stringResource(
                    R.string.files_size_saving,
                    Formats.bytes(item.before),
                    Formats.bytes(item.after),
                    Formats.percentOf((item.before - item.after).coerceAtLeast(0), item.before)
                ),
                style = MaterialTheme.typography.bodySmall.merge(TabularFigures),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (onOpen != null) {
                Text(
                    stringResource(R.string.trial_tap_compare),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary
                )
            }
        }
    }
}

/** The original's thumbnail through MediaStore, off the main thread; null is the placeholder. */
@Composable
private fun trialThumb(uri: String?): ImageBitmap? {
    if (uri == null) return null
    val resolver = LocalContext.current.contentResolver
    val bitmap by produceState<ImageBitmap?>(initialValue = null, uri) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                Thumbnails.load(resolver, Uri.parse(uri), Size(192, 192)).asImageBitmap()
            }.getOrNull()
        }
    }
    return bitmap
}
