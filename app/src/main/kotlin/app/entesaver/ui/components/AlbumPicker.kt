package app.entesaver.ui.components

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Size
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isFinite
import app.entesaver.R
import app.entesaver.media.MediaScanner
import app.entesaver.ui.theme.Dimens
import app.entesaver.util.Errand
import app.entesaver.util.Thumbnails
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The grid's ceiling, from the space it is actually given.
 *
 * A fixed 300 dp was one row of covers plus the header on any phone: a
 * gallery with three albums showed two, the third sat below the fold, and
 * nothing said so - it read as a glitch, and as an album that was never
 * offered. Inside a dialog the box has a height, and the grid takes most of
 * it; on the setup page, which scrolls itself, the box is unbounded and the
 * grid takes room for two rows of covers - but never more than about half of
 * the page's own visible height ([viewportHeight], measured by the page). A
 * fixed 440 dp was taller than a phone turned sideways shows, and inside the
 * page's scroll every drag moved the albums first, so "Use these albums"
 * could only be reached through the whole grid. Either way it says when there
 * is more below.
 */
private fun gridCeiling(boxMaxHeight: Dp, viewportHeight: Dp): Dp = when {
    boxMaxHeight.isFinite -> maxOf(320.dp, boxMaxHeight * 0.7f)
    viewportHeight.isFinite -> (viewportHeight * 0.55f).coerceIn(200.dp, 440.dp)
    else -> 440.dp
}

/**
 * The album picker, drawn the way a gallery draws it: a grid of covers with
 * the tick over the photo, not a column of checkboxes beside bare words.
 * "Camera" is a name; the photo taken this morning is the album. Both the
 * setup step and the Settings dialog use this one grid, so the two pickers
 * cannot drift apart.
 *
 * Every tile is one toggle - the whole tile takes the tap and announces
 * itself as a checkbox with the album's name, so a screen reader hears
 * "Camera, checkbox, ticked" rather than an unnamed box.
 */
@Composable
fun AlbumGrid(
    albums: List<MediaScanner.Album>,
    excluded: Set<String>,
    onToggle: (String, Boolean) -> Unit,
    modifier: Modifier = Modifier,
    testTag: String? = null,
    // Full-width rows above and below the tiles, inside the grid's own
    // scroll. A dialog that put these outside the grid had a body that
    // could not scroll, and on a short screen at a large font whatever sat
    // below the tiles was simply past the edge.
    header: (@Composable () -> Unit)? = null,
    footer: (@Composable () -> Unit)? = null,
    state: LazyGridState = rememberLazyGridState(),
    // How tall the page around an unbounded grid shows, where the page
    // scrolls; unknown in a dialog or a sheet, which bound the grid instead.
    viewportHeight: Dp = Dp.Infinity
) {
    // The album held down, shown in a sheet over the picker.
    var peeking by remember { mutableStateOf<MediaScanner.Album?>(null) }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val maxHeight = gridCeiling(this.maxHeight, viewportHeight)
        // Three across on any phone, more on a wider screen. "Adaptive at
        // 100 dp" was written for a 360 dp screen, but the grid never gets
        // the whole screen - a card's padding or a dialog's leaves it about
        // 270-290 dp - so a phone drew two columns, and a third album sat
        // alone on a second row below the fold, looking like it was missing.
        val columns = (this.maxWidth / 110.dp).toInt().coerceIn(3, 6)
        Column(Modifier.fillMaxWidth()) {
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns),
            state = state,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                // This grid lives inside things that scroll (the setup page, a
                // dialog). A lazy container measured with no ceiling there does
                // not draw - the ceiling is what lets it measure at all; past it,
                // the grid scrolls its own tiles.
                .heightIn(max = maxHeight)
                .let { if (testTag != null) it.testTag(testTag) else it }
        ) {
            header?.let {
                item(key = "header", span = { GridItemSpan(maxLineSpan) }) { it() }
            }
            if (albums.isNotEmpty()) {
                // Long-press is invisible until someone says it exists. One quiet
                // line above the tiles, in every picker, is how it exists.
                item(key = "peek-hint", span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        stringResource(R.string.album_peek_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 2.dp)
                    )
                }
            }
            items(albums, key = { it.name }) { album ->
                AlbumTile(
                    album = album,
                    checked = album.name !in excluded,
                    onToggle = { include -> onToggle(album.name, include) },
                    onPeek = { peeking = album }
                )
            }
            footer?.let {
                item(key = "footer", span = { GridItemSpan(maxLineSpan) }) { it() }
            }
        }
        // Below the fold is invisible until someone says it exists. A grid
        // that can still scroll says so in one line, with the total, so
        // "two albums" is never mistaken for the whole gallery.
        if (state.canScrollForward) {
            Text(
                pluralStringResource(R.plurals.album_scroll_hint, albums.size, albums.size),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
        }
    }
    peeking?.let { album ->
        AlbumPeekSheet(
            album = album,
            included = album.name !in excluded,
            onToggle = { include -> onToggle(album.name, include) },
            onDismiss = { peeking = null }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AlbumTile(
    album: MediaScanner.Album,
    checked: Boolean,
    onToggle: (Boolean) -> Unit,
    onPeek: () -> Unit
) {
    val scheme = MaterialTheme.colorScheme
    Column(
        Modifier
            .heightIn(min = Dimens.TouchTarget)
            .clip(RoundedCornerShape(14.dp))
            // A tap ticks, exactly as before. A long press shows the album's
            // newest photos in a sheet over the picker. It used to hand the
            // cover to another app, which put the phone's whole "open with"
            // list - every gallery, WhatsApp - in front of a choice that only
            // needed a look. The semantics stay a checkbox with a state: a
            // screen reader still hears "Camera, checkbox, ticked", and the
            // tests still find a toggleable carrying the album's name.
            .combinedClickable(
                role = Role.Checkbox,
                onClick = { onToggle(!checked) },
                onLongClick = onPeek
            )
            .semantics {
                toggleableState = if (checked) ToggleableState.On else ToggleableState.Off
            }
            .padding(2.dp)
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                // Square, as a gallery's album grid draws them: a portrait
                // crop made each row so tall that one row and a sliver of
                // the next was all a dialog could show.
                .aspectRatio(1f)
                .clip(RoundedCornerShape(12.dp))
                .background(scheme.surfaceVariant)
        ) {
            val cover = albumCover(album.coverUri)
            if (cover != null) {
                Image(
                    bitmap = cover,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                // No cover to show - the album is empty of readable media, or
                // the thumbnail could not be decoded. A neutral glyph, never
                // a broken image.
                Icon(
                    Icons.Outlined.PhotoLibrary,
                    contentDescription = null,
                    tint = scheme.onSurfaceVariant,
                    modifier = Modifier
                        .size(32.dp)
                        .align(Alignment.Center)
                )
            }
            // The tick sits on the photo, the way every gallery draws
            // selection: a filled badge, and nothing else. The dark veil
            // that used to cover a ticked cover is gone - dimming exactly
            // the albums someone chose made the choice look like a penalty,
            // and no backup picker on the phone does it.
            if (checked) {
                Box(
                    Modifier
                        .padding(6.dp)
                        .size(22.dp)
                        .align(Alignment.TopEnd)
                        .background(scheme.primary, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = null,
                        tint = scheme.onPrimary,
                        modifier = Modifier.size(15.dp)
                    )
                }
            }
        }
        Text(
            album.name,
            style = MaterialTheme.typography.labelLarge,
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
            modifier = Modifier.padding(top = 6.dp)
        )
        Text(
            pluralStringResource(R.plurals.album_item_count, album.count, album.count),
            style = MaterialTheme.typography.labelSmall,
            color = scheme.onSurfaceVariant
        )
    }
}

/**
 * A look inside one album, from a long press in any album picker.
 *
 * The newest photos, the tick, and - for anyone who wants the full gallery -
 * one button out to it. Answering "which album is this?" never needs another
 * app, so it never starts one by itself.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun AlbumPeekSheet(
    album: MediaScanner.Album,
    included: Boolean,
    onToggle: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        // Clear of the navigation buttons on a phone turned sideways too.
        contentWindowInsets = { WindowInsets.safeDrawing }
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Dimens.Screen)
                .padding(bottom = 24.dp)
        ) {
            Text(album.name, style = MaterialTheme.typography.titleLarge)
            Text(
                pluralStringResource(R.plurals.album_item_count, album.count, album.count),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(12.dp))
            if (album.recentUris.isEmpty()) {
                Text(
                    stringResource(R.string.album_peek_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            // Rows of three, drawn plainly: twelve thumbnails at most, inside
            // a sheet that scrolls, so a lazy grid would only add a second
            // scroller to fight the first. Never wider than a phone draws
            // them: across a phone turned sideways three to a row were 200 dp
            // each, and the buttons under them 800 dp down.
            for (row in album.recentUris.chunked(3)) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier
                        .widthIn(max = PeekRowMaxWidth)
                        .fillMaxWidth()
                        .padding(bottom = 6.dp)
                ) {
                    for (uri in row) {
                        Box(
                            Modifier
                                .weight(1f)
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                        ) {
                            albumCover(uri)?.let {
                                Image(
                                    bitmap = it,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                        }
                    }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Spacer(Modifier.height(8.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (included) {
                    OutlinedButton(onClick = { onToggle(false); onDismiss() }) {
                        Text(stringResource(R.string.album_peek_exclude))
                    }
                } else {
                    Button(onClick = { onToggle(true); onDismiss() }) {
                        Text(stringResource(R.string.album_peek_include))
                    }
                }
                album.coverUri?.let { cover ->
                    TextButton(onClick = { peekAlbum(context, cover) }) {
                        Text(stringResource(R.string.album_peek_open))
                    }
                }
            }
        }
    }
}

/** Three thumbnails across, as wide as a phone held upright draws them. */
private val PeekRowMaxWidth = 360.dp

/**
 * Opens the album's newest photo in the phone's own viewer, from the peek
 * sheet's "Open in gallery".
 *
 * A plain view intent, not a chooser. A chooser forced the full "open with"
 * sheet - every gallery, WhatsApp, the lot - on every single press, with no
 * way to say "always this one". A plain intent lets Android do what it does
 * for every other app: open the default gallery where one is set, and where
 * none is, offer the list once with "Just once" and "Always" so the choice
 * sticks. Read access travels with that one uri only, and a phone with no
 * viewer at all falls back to the sheet rather than crashing the picker.
 */
private fun peekAlbum(context: Context, coverUri: String) {
    runCatching {
        val uri = Uri.parse(coverUri)
        val mime = context.contentResolver.getType(uri) ?: "image/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        // A trip the app started: the lock lets this one return through.
        Errand.begin()
        try {
            context.startActivity(view)
        } catch (e: ActivityNotFoundException) {
            context.startActivity(Intent.createChooser(view, null))
        }
    }.onFailure { Errand.cancel() }
}

/**
 * The album's cover, loaded through MediaStore's own thumbnailer off the main
 * thread. Null while loading and null on failure - the tile shows its
 * placeholder either way, so a slow SD card or a revoked half of the media
 * permission degrades to a plain grid rather than an error.
 */
@Composable
private fun albumCover(uri: String?): ImageBitmap? {
    if (uri == null) return null
    val resolver = LocalContext.current.contentResolver
    val bitmap by produceState<ImageBitmap?>(initialValue = null, uri) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                Thumbnails.load(resolver, Uri.parse(uri), Size(256, 256))
                    .asImageBitmap()
            }.getOrNull()
        }
    }
    return bitmap
}
