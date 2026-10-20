package app.entesaver.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isFinite
import app.entesaver.R
import app.entesaver.core.logic.QualityKept
import app.entesaver.data.db.ItemRow
import app.entesaver.ui.components.KeyValueRow
import app.entesaver.util.Formats
import app.entesaver.util.Thumbnails
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Original against optimised copy, before anything is deleted.
 *
 * Nobody should have to take "about 90-95% quality" on faith when the next
 * button removes their photograph. Dragging the slider shows the two versions
 * of the same picture in the same frame, at the same size, which is the only
 * comparison that means anything.
 *
 * When the copy is already in the cloud and no longer on the phone there is
 * nothing to draw, so the sheet says so and shows the recorded sizes instead
 * of rendering the original twice and implying they matched.
 */
@Composable
fun CompareSheet(
    row: ItemRow,
    onDismiss: () -> Unit,
    onKeepThisOne: (() -> Unit)? = null
) {
    val context = LocalContext.current
    var split by remember { mutableFloatStateOf(0.5f) }

    // Null while a picture is still being read, and a Loaded - holding a
    // picture or nothing - once the read has answered. The two used to be one
    // null, so for the moment the thumbnails took to arrive the sheet said the
    // copy "is already in Ente and no longer on the phone", about a copy that
    // was sitting right there, and then swapped that for the pictures.
    val original by produceState<Loaded?>(null, row.contentUri) {
        value = Loaded(loadThumb(context, row.contentUri))
    }
    // A copy that is only staged - the trial's, or one waiting for its
    // pacing slot - has no gallery address yet; it is a file inside the app,
    // and the comparison reads it from there.
    val optimised by produceState<Loaded?>(null, row.outputUri, row.keptUri, row.stagePath) {
        value = Loaded(
            loadThumb(context, row.outputUri ?: row.keptUri)
                ?: loadFileThumb(row.stagePath)
        )
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.ok)) }
        },
        dismissButton = onKeepThisOne?.let {
            {
                TextButton(onClick = it) { Text(stringResource(R.string.compare_keep_this)) }
            }
        },
        title = {
            Text(
                row.displayName,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis
            )
        },
        text = {
            // Scrollable, because a dialog's text slot is not. On a
            // 320x568 screen at font scale 2.0 the bottom of this content
            // sits past the edge with no way to reach it, and the buttons
            // are pushed off with it.
            BoxWithConstraints {
                val slotHeight = maxHeight
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    // Read once into locals rather than through the delegates a
                    // second time: a null check on a state property proves nothing
                    // about the read after it, and the two !! that followed were
                    // the only thing standing between a thumbnail arriving late
                    // and a crash on the screen that is meant to reassure people.
                    val readBefore = original
                    val readAfter = optimised
                    val loading = readBefore == null || readAfter == null
                    val before = readBefore?.bitmap
                    val after = readAfter?.bitmap
                    // Never taller than about half of what the dialog has for its
                    // text, centred. On a phone turned sideways a full-width square
                    // was taller than the dialog itself, so the picture and the
                    // slider under it were never on screen together; held upright
                    // the dialog is narrower than that, and nothing changes.
                    val frameSize = Modifier
                        .align(Alignment.CenterHorizontally)
                        .widthIn(max = if (slotHeight.isFinite) slotHeight * 0.6f else Dp.Infinity)
                        .fillMaxWidth()
                        .aspectRatio(1f)
                    if (loading) {
                        // The frame the comparison will fill, so nothing jumps
                        // when it arrives, and a sign that it is on its way.
                        Box(
                            frameSize.background(MaterialTheme.colorScheme.surfaceContainerHighest),
                            contentAlignment = Alignment.Center
                        ) {
                            CircularProgressIndicator()
                        }
                    } else if (before != null && after != null) {
                        BoxWithConstraints(
                            frameSize
                                .clipToBounds()
                                .background(MaterialTheme.colorScheme.surfaceContainerHighest)
                        ) {
                            // Optimised underneath, original clipped over it: the
                            // slider is a wipe across one image, not two pictures
                            // side by side at different scales.
                            val frame = maxWidth
                            Image(
                                bitmap = after.asImageBitmap(),
                                contentDescription = stringResource(R.string.compare_optimised),
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize()
                            )
                            Box(
                                Modifier
                                    .fillMaxHeight()
                                    .width(frame * split)
                                    .clipToBounds()
                            ) {
                                // The original is laid out at the full width of the
                                // frame and then clipped by the box around it. Left
                                // to fill the narrow box it was cropped to that
                                // box's shape instead, so the half being compared
                                // was a different part of the picture at a
                                // different scale - which is exactly the comparison
                                // this sheet exists to avoid.
                                Image(
                                    bitmap = before.asImageBitmap(),
                                    contentDescription = stringResource(R.string.compare_original),
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier
                                        .requiredWidth(frame)
                                        .fillMaxHeight()
                                )
                            }
                        }
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(top = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            // Half the row each, so a long translation of either
                            // word wraps under itself instead of pushing the other
                            // one off the end of the dialog.
                            Text(
                                stringResource(R.string.compare_original),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                stringResource(R.string.compare_optimised),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.End,
                                modifier = Modifier
                                    .weight(1f)
                                    .padding(start = 8.dp)
                            )
                        }
                        Slider(value = split, onValueChange = { split = it })
                    } else {
                        // Only once both reads have answered, and one came back
                        // with nothing: then the copy really is not on the phone.
                        Text(
                            stringResource(R.string.compare_in_cloud),
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                    }
                    KeyValueRow(
                        stringResource(R.string.detail_original),
                        Formats.bytes(row.sizeBytes)
                    )
                    row.outputBytes?.let {
                        KeyValueRow(stringResource(R.string.detail_copy), Formats.bytes(it))
                        val saved = (row.sizeBytes - it).coerceAtLeast(0)
                        if (saved > 0) {
                            KeyValueRow(
                                stringResource(R.string.detail_saved),
                                stringResource(
                                    R.string.detail_saved_value,
                                    Formats.bytes(saved),
                                    Formats.percentOf(saved, row.sizeBytes)
                                )
                            )
                        }
                    }
                    // What the encoder really did to this file, not what the preset
                    // allows. Absent when the pixels were never recorded, because a
                    // blank is honest and an invented percentage is not.
                    QualityKept.measuredDetailKeptPercent(row.srcPixels, row.outPixels)?.let { kept ->
                        KeyValueRow(
                            stringResource(R.string.detail_kept),
                            if (kept >= 100) {
                                stringResource(R.string.detail_kept_all)
                            } else {
                                stringResource(R.string.detail_kept_value, kept)
                            }
                        )
                    }
                    Text(
                        stringResource(R.string.compare_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
            }
        }
    )
}

/** One thumbnail read that has finished, whether or not it found a picture. */
private class Loaded(val bitmap: Bitmap?)

/** A staged copy, decoded from the app's own file at roughly thumbnail size. */
private suspend fun loadFileThumb(path: String?): Bitmap? {
    if (path == null) return null
    return withContext(Dispatchers.IO) {
        runCatching {
            val file = File(path)
            if (!file.isFile) return@runCatching null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
            BitmapFactory.decodeFile(
                path, BitmapFactory.Options().apply { inSampleSize = sample }
            )
        }.getOrNull()
    }
}

/**
 * MediaStore's own cached thumbnail, not a full decode: this runs while the
 * user is scrolling a list of things they are about to delete, and a 60 MP
 * decode there would stutter or run out of heap.
 */
private suspend fun loadThumb(
    context: Context,
    uriString: String?
): Bitmap? {
    val uri = uriString?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
    return withContext(Dispatchers.IO) {
        runCatching {
            Thumbnails.load(context.contentResolver, uri, Size(1024, 1024))
        }.getOrNull()
    }
}
