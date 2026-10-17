package app.entesaver.ui.screens

import android.graphics.Bitmap
import android.net.Uri
import android.util.Size
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.entesaver.R
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.ListFilters
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.RowActions
import app.entesaver.core.logic.VideoCodec
import app.entesaver.data.db.ItemRow
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.components.AccessNotice
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.BadgeTone
import app.entesaver.ui.components.EmptyState
import app.entesaver.ui.components.FilteredEmptyState
import app.entesaver.ui.components.KeyValueRow
import app.entesaver.ui.components.ListActionBar
import app.entesaver.ui.components.ListFilter
import app.entesaver.ui.components.ListOption
import app.entesaver.ui.components.ListScreenScaffold
import app.entesaver.ui.components.SearchEmptyState
import app.entesaver.ui.components.StateBadge
import app.entesaver.ui.components.albumFilter
import app.entesaver.ui.components.rememberListSelection
import app.entesaver.ui.components.selectionSummary
import app.entesaver.ui.components.sizeFilter
import app.entesaver.ui.components.typeFilter
import app.entesaver.util.Formats
import app.entesaver.util.OemPages
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun FilesScreen(vm: AppViewModel) {
    val items by vm.items.collectAsStateWithLifecycle()
    val query by vm.search.collectAsStateWithLifecycle()
    val statusFilter by vm.filesState.collectAsStateWithLifecycle()
    val noAlbumsTicked by vm.noAlbumsTicked.collectAsStateWithLifecycle()
    val sort by vm.filesSort.collectAsStateWithLifecycle()
    var detail by remember { mutableStateOf<ItemRow?>(null) }
    var openError by remember { mutableStateOf<String?>(null) }

    // Y2.7: skipping a file is undoable, and says where the list lives. It
    // is a decision about someone's photograph made with one tap, so it needs
    // a way back that does not involve hunting through Settings.
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val skippedMessage = stringResource(R.string.never_optimise_undo)
    val undoLabel = stringResource(R.string.undo)
    val onSkip: (Long) -> Unit = { id ->
        vm.setNeverOptimise(id, true)
        scope.launch {
            val result = snackbar.showSnackbar(
                message = skippedMessage,
                actionLabel = undoLabel,
                duration = SnackbarDuration.Long
            )
            if (result == SnackbarResult.ActionPerformed) vm.setNeverOptimise(id, false)
        }
    }

    var type by rememberSaveable { mutableStateOf(ListFilters.Type.ALL) }
    var sizeBand by rememberSaveable { mutableStateOf(ListFilters.Size.ANY) }
    var album by rememberSaveable { mutableStateOf<String?>(null) }
    val selection = rememberListSelection()

    // The status filter is applied by the query behind vm.items; the shared
    // chips narrow what came back. Both are filters, so the empty state has to
    // treat them the same way.
    val state = ListFilters.State(type, sizeBand, album, query = "")
    // Null is "the database has not answered yet", and it is drawn as the
    // loading placeholders below, never as an empty gallery: the list is
    // shared only while this screen reads it, so the first frame after
    // opening the tab has no rows to show and must not say so.
    val rows = remember(items, state) {
        items.orEmpty().filter { ListFilters.matches(it.toCandidate(), state) }
    }
    val albums = remember(items) {
        ListFilters.albumCounts(items.orEmpty().map { it.toCandidate() })
    }
    // Recomputed on a change, not on every frame: this list holds the whole
    // gallery, and the sum used to run again on each tick of a selection.
    val chosen = remember(rows, selection.ids) { rows.filter { it.id in selection } }
    val selectedBytes = remember(chosen) { chosen.sumOf { it.sizeBytes } }
    val anyFilter = statusFilter != null || !state.isDefault

    val mediaAccess by vm.mediaAccess.collectAsStateWithLifecycle()
    val appContext = LocalContext.current

    // Stacked, not overlaid. The scaffold draws its own selection action bar
    // pinned to the bottom of the screen, and the undo snackbar used to be
    // aligned to the bottom of the very same box - so the two landed on the
    // same strip of glass. Skip a file, long-press another to start a
    // selection, and "Never optimise this file - Undo" and the optimise bar
    // were drawn on top of one another: whichever won, the other's buttons
    // were unreachable, and the one being covered was the one with ten
    // seconds to live. Giving the snackbar its own row under the scaffold
    // means the bar can only ever sit above it. The row costs nothing while
    // there is no snackbar, because an empty SnackbarHost has no height.
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            ListScreenScaffold(
                title = stringResource(R.string.nav_files),
                onBack = {},
                showBack = false,
                query = query,
                onQuery = { vm.search.value = it },
                filters = listOf(
                    typeFilter(type) { type = it },
                    statusFilterChip(statusFilter) { vm.filesState.value = it },
                    albumFilter(album, albums) { album = it },
                    sizeFilter(sizeBand) { sizeBand = it }
                ),
                sort = ListFilter(
                    name = stringResource(R.string.filter_sort),
                    valueLabel = null,
                    options = listOf(
                        ListOption(
                            stringResource(R.string.list_sort_newest),
                            sort == AppViewModel.FilesSort.NEWEST
                        ) { vm.filesSort.value = AppViewModel.FilesSort.NEWEST },
                        ListOption(
                            stringResource(R.string.list_sort_largest),
                            sort == AppViewModel.FilesSort.LARGEST
                        ) { vm.filesSort.value = AppViewModel.FilesSort.LARGEST },
                        ListOption(
                            stringResource(R.string.list_sort_saved),
                            sort == AppViewModel.FilesSort.SAVED
                        ) { vm.filesSort.value = AppViewModel.FilesSort.SAVED }
                    )
                ),
                selection = selection,
                matchingCount = rows.size,
                onSelectAll = { selection.selectAll(rows.map { it.id }) },
                intro = if (AccessNotice.isLimited(mediaAccess)) {
                    {
                        // The list below shows only what was scanned under full
                        // access; nothing new arrives until access is full again.
                        AssistChip(
                            onClick = { OemPages.openAppInfo(appContext) },
                            label = { Text(stringResource(AccessNotice.chip(mediaAccess))) },
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
                } else {
                    null
                },
                onResetFilters = {
                    type = ListFilters.Type.ALL
                    sizeBand = ListFilters.Size.ANY
                    album = null
                    vm.filesState.value = null
                },
                loading = items == null,
                isEmpty = rows.isEmpty(),
                emptyContent = {
                    // The empty state gets whatever height is left below the title,
                    // the search box and the filter row. Sideways on a phone at a
                    // large font that is well under what it needs, and unscrolled its
                    // lower half - including the button that clears the search - sat
                    // past the bottom edge of the screen.
                    // The scroll belongs to the scaffold's empty branch, which is the
                    // only place that knows how much height the title, the search box
                    // and the chips above have already taken. A second one here is
                    // measured by the first with no ceiling at all, and a scrolling
                    // container asked how tall it would like to be throws rather than
                    // answers - which is what crashed Files and Free up space the
                    // moment a filter or a search left nothing to show.
                    when {
                        query.isNotBlank() -> SearchEmptyState(
                            term = query,
                            onClear = { vm.search.value = "" }
                        )
                        anyFilter -> FilteredEmptyState(
                            onReset = {
                                type = ListFilters.Type.ALL
                                sizeBand = ListFilters.Size.ANY
                                album = null
                                vm.filesState.value = null
                            }
                        )
                        // An empty list has two very different causes, and
                        // for a while both looked the same: nothing left to
                        // do, or no album ever handed over. The second is a
                        // setting, not a state, so it says so and offers the
                        // way to change it.
                        noAlbumsTicked -> EmptyState(
                            title = stringResource(R.string.files_no_albums_title),
                            body = stringResource(R.string.files_no_albums_body)
                        )
                        else -> EmptyState(
                            title = stringResource(R.string.files_empty_title),
                            body = stringResource(R.string.files_empty)
                        )
                    }
                
                },
                actionBar = {
                    // CC6: a mixed selection acts only on what the action can touch,
                    // and says so. Five selected with two already optimised reads
                    // "Optimise 3 of 5" with the skip named - acting on all five
                    // would redo finished work, and acting on three silently reads
                    // as the app losing count. At zero eligible the action is absent.
                    val split = RowActions.splitForOptimise(
                        chosen.map { it.id to it.toActionRow() }
                    )
                    if (split.eligible > 0) {
                        ListActionBar(
                            // frees = false: this bar's action optimises. It writes a
                            // smaller copy and leaves the original where it is, so
                            // nothing is freed here.
                            // Counted over the rows this bar can actually act
                            // on, not over the whole selection. A tick survives
                            // a filter change, so selecting ten and then
                            // narrowing the list left the bar saying "10
                            // selected" beside the size of six, above a button
                            // that optimised six. The count, the size and the
                            // action now describe one set, and the note says
                            // what the filter is holding back.
                            summary = selectionSummary(
                                chosen.size, Formats.bytes(selectedBytes), frees = false
                            ),
                            actionLabel = if (split.skipped > 0) {
                                stringResource(
                                    R.string.bulk_optimise_of, split.eligible, chosen.size
                                )
                            } else {
                                stringResource(R.string.list_optimise_these_first)
                            },
                            note = if (split.skipped > 0) {
                                pluralStringResource(
                                    R.plurals.bulk_skipped_note, split.skipped, split.skipped
                                )
                            } else if (selection.size > chosen.size) {
                                pluralStringResource(
                                    R.plurals.bulk_hidden_note,
                                    selection.size - chosen.size,
                                    selection.size - chosen.size
                                )
                            } else {
                                null
                            },
                            onAction = {
                                vm.optimiseNow(split.eligibleIds)
                                selection.clear()
                            }
                        )
                    }
                }
            ) {
                items(rows, key = { it.id }) { row ->
                    FilesRow(
                        row = row,
                        selected = if (selection.active) row.id in selection else null,
                        onToggle = { selection.toggle(row.id) },
                        onOpenDetail = { detail = row },
                        onLongPress = { selection.toggle(row.id) }
                    )
                }
            }
        }
        SnackbarHost(snackbar)
    }

    openError?.let { message ->
        AlertDialog(
            onDismissRequest = { openError = null },
            confirmButton = {
                TextButton(onClick = { openError = null }) { Text(stringResource(R.string.ok)) }
            },
            text = {
                // The message comes from whatever refused to open the file,
                // so its length is not this app's to predict.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(message)
                }
            }
        )
    }

    detail?.let { row ->
        AlertDialog(
            onDismissRequest = { detail = null },
            confirmButton = {
                TextButton(onClick = { detail = null }) { Text(stringResource(R.string.ok)) }
            },
            dismissButton = {
                // Opening the copy, not just describing it, is what tells the
                // user the optimised file is really fine to keep.
                val cannotOpen = stringResource(R.string.detail_open_failed)
                TextButton(onClick = {
                    if (!vm.openInViewer(row)) {
                        openError = cannotOpen
                    } else {
                        detail = null
                    }
                }) { Text(stringResource(R.string.detail_open)) }
            },
            title = {
                Text(
                    row.displayName,
                    maxLines = 2,
                    // The middle, so the extension survives: which file this
                    // dialog is about is the one thing it must not lose.
                    overflow = TextOverflow.MiddleEllipsis
                )
            },
            text = {
                // Scrollable, because a dialog's text slot is not. This one
                // holds up to a dozen detail rows and the file's actions, and
                // on a small screen at a large font the actions - the reason
                // most people open it - were below the bottom of the display.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    KeyValueRow(stringResource(R.string.detail_state), stateLabel(row))
                    KeyValueRow(stringResource(R.string.detail_evidence), evidenceLabel(row))
                    // Z10.1: the app holding the copy - the one it was sent
                    // to, which after a switch is not the one selected now.
                    val holder by androidx.compose.runtime.produceState<String?>(null, row.id) {
                        value = vm.holdingAppLabel(row)
                    }
                    holder?.let {
                        KeyValueRow(stringResource(R.string.detail_holding_app), it)
                    }
                    KeyValueRow(stringResource(R.string.detail_original), Formats.bytes(row.sizeBytes))
                    row.outputBytes?.let {
                        KeyValueRow(stringResource(R.string.detail_copy), Formats.bytes(it))
                        val saved = row.sizeBytes - it
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
                    KeyValueRow(stringResource(R.string.detail_captured), Formats.dateTime(row.captureAt))
                    row.releasedAt?.let {
                        KeyValueRow(stringResource(R.string.detail_released), Formats.dateTime(it))
                    }
                    row.outputName?.let {
                        KeyValueRow(stringResource(R.string.detail_copy_name), it)
                    }
                    row.bucket?.let {
                        KeyValueRow(stringResource(R.string.detail_album), it)
                    }
                    // The settings the copy was made with, in the words the
                    // Settings screen uses - never the stored key itself.
                    row.presetUsed?.let { key ->
                        val made = if (row.isVideo) {
                            MediaSettings.parseVideoKey(key)?.let { k ->
                                val codec = row.codecUsed
                                    ?.let { c -> VideoCodec.entries.firstOrNull { it.name == c } }
                                    ?: k.codec
                                stringResource(
                                    R.string.detail_video_settings,
                                    codecLabel(codec),
                                    if (k.longSide <= 0) stringResource(R.string.res_keep) else MediaSettings.pLabel(k.longSide)
                                )
                            }
                        } else {
                            MediaSettings.parsePhotoKey(key)?.let { k ->
                                stringResource(
                                    R.string.detail_photo_settings,
                                    row.outputName?.substringAfterLast('.', "")?.uppercase()
                                        ?.takeIf { it.isNotEmpty() } ?: formatLabel(k.format),
                                    if (k.maxMp <= 0) {
                                        stringResource(R.string.photo_size_full)
                                    } else {
                                        stringResource(R.string.photo_size_mp, k.maxMp)
                                    }
                                )
                            }
                        }
                        made?.let { KeyValueRow(stringResource(R.string.detail_preset), it) }
                    }
                    row.outputRelPath?.let { folder ->
                        // Where it went, so the folder to select in Ente is
                        // never a guess - the folder the copy really went to,
                        // which after a move is not always today's.
                        KeyValueRow(stringResource(R.string.detail_folder), folder)
                    }
                    row.skipReason?.let {
                        KeyValueRow(stringResource(R.string.detail_reason), fileSkipReason(it))
                    }
                    // Items copied byte-for-byte explain themselves here.
                    row.lastError?.takeIf { row.outputBytes != null }?.let { error ->
                        KeyValueRow(
                            stringResource(R.string.detail_as_is),
                            asIsReasonLabel(error)
                        )
                    }
                    if (row.originalMissing) {
                        Text(
                            stringResource(R.string.detail_original_missing),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }

                    // Exactly the actions this file's state allows, from the
                    // one rule every list obeys. An already-optimised copy is
                    // not offered "never optimise": the work is done, the
                    // option cannot undo it, and offering it is what made the
                    // counters disagree with no way to tell why.
                    //
                    // Below the details, not above the name. These used to sit
                    // in the dialog's icon slot - the small decorative one that
                    // Material draws above the title - so "Never optimise this
                    // file", which is permanent, was the first thing on screen
                    // and the file it applied to was named underneath it. One
                    // button each to a line, because the labels are sentences.
                    val actions = RowActions.forItem(row.toActionRow())
                    if (actions.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                    }
                    for (action in actions) {
                        when (action) {
                            RowActions.Action.OPTIMISE_FIRST -> TextButton(onClick = {
                                vm.optimiseNow(row.id)
                                detail = null
                            }) { Text(stringResource(R.string.detail_optimise_first)) }

                            RowActions.Action.TRY_AGAIN -> TextButton(onClick = {
                                vm.optimiseNow(row.id)
                                detail = null
                            }) { Text(stringResource(R.string.detail_try_again)) }

                            RowActions.Action.NEVER_OPTIMISE -> TextButton(onClick = {
                                onSkip(row.id)
                                detail = null
                            }) { Text(stringResource(R.string.never_optimise)) }

                            RowActions.Action.ALLOW_AGAIN -> TextButton(onClick = {
                                vm.setNeverOptimise(row.id, false)
                                detail = null
                            }) { Text(stringResource(R.string.detail_optimise_again)) }

                            // OPEN already has its own button; removal lives
                            // on Reclaim, which is the single deletion path.
                            else -> Unit
                        }
                    }
                }
            }
        )
    }
}

/**
 * The item's own picture, so a list of file names becomes a list of photos.
 *
 * MediaStore's own thumbnail cache is used rather than decoding the full
 * image: it is what the gallery draws, so it is already on disk, and a Files
 * list must never be the reason a scroll stutters. A missing thumbnail is
 * normal - the original may be gone - and falls back to the app mark.
 */
@Composable
fun Thumbnail(row: ItemRow) {
    val context = LocalContext.current
    val source = row.outputUri ?: row.contentUri
    val shape = RoundedCornerShape(10.dp)
    val bitmap by produceState<Bitmap?>(initialValue = null, source) {
        value = source?.let { uriString ->
            withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.loadThumbnail(
                        Uri.parse(uriString), Size(128, 128), null
                    )
                }.getOrNull()
            }
        }
    }
    Box(
        Modifier
            .size(52.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center
    ) {
        val bmp = bitmap
        if (bmp != null) {
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Icon(
                painterResource(R.drawable.ic_stat_saver),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

/**
 * Whether a finished file's copy is known to have reached Ente. A copy can
 * also finish without that: cleared for space after waiting its days while
 * Ente's uploads could not be measured, or removed by hand. Calling that
 * "Backed up" in green would be the one thing this screen must never say
 * without proof.
 */
private fun reachedEnte(row: ItemRow): Boolean =
    Evidence.parse(row.evidence).let { it.isPerFile || it == Evidence.VERIFIED }

private fun badgeTone(row: ItemRow): BadgeTone {
    val state = runCatching { ItemState.valueOf(row.state) }.getOrDefault(ItemState.UNKNOWN)
    return when (state) {
        ItemState.NEW -> BadgeTone.NEUTRAL
        ItemState.STAGED, ItemState.RELEASED -> BadgeTone.PROGRESS
        ItemState.GONE, ItemState.DONE -> if (reachedEnte(row)) BadgeTone.SUCCESS else BadgeTone.MUTED
        ItemState.FREED, ItemState.FREED_KEPT -> BadgeTone.SUCCESS
        ItemState.SKIP, ItemState.UNKNOWN -> BadgeTone.MUTED
    }
}

@Composable
fun stateLabel(row: ItemRow): String {
    val state = runCatching { ItemState.valueOf(row.state) }.getOrDefault(ItemState.UNKNOWN)
    return when (state) {
        ItemState.NEW -> stringResource(R.string.state_new)
        ItemState.STAGED -> stringResource(R.string.state_staged)
        ItemState.RELEASED -> stringResource(R.string.state_released)
        ItemState.GONE, ItemState.DONE -> stringResource(
            if (reachedEnte(row)) R.string.state_done else R.string.state_done_unconfirmed
        )
        ItemState.SKIP -> stringResource(R.string.state_skip)
        ItemState.FREED -> stringResource(R.string.state_freed)
        ItemState.FREED_KEPT -> stringResource(if (row.backupUri != null) R.string.state_in_place else R.string.state_freed_kept)
        ItemState.UNKNOWN -> stringResource(R.string.state_unknown)
    }
}

/**
 * Why this one file was set aside, in words. The reason is stored as a code;
 * printed as it was, people read "out_of_memory", or an encoder's own error.
 */
@Composable
private fun fileSkipReason(reason: String): String = when (reason) {
    "removed_before_upload" -> stringResource(R.string.asis_removed_early)
    "user_excluded" -> stringResource(R.string.skip_user_excluded_one)
    else -> skipReasonLabel(reason)
}

/** Plain-English explanation for a file that was copied instead of compressed. */
@Composable
fun asIsReasonLabel(reason: String): String = when (reason) {
    "motion_photo" -> stringResource(R.string.asis_motion_photo)
    "depth_photo" -> stringResource(R.string.asis_depth_photo)
    "multi_picture" -> stringResource(R.string.asis_multi_picture)
    "animated" -> stringResource(R.string.asis_animated)
    "transparency" -> stringResource(R.string.asis_transparency)
    "format_as_is" -> stringResource(R.string.asis_format)
    "already_efficient" -> stringResource(R.string.asis_already_small)
    "not_smaller" -> stringResource(R.string.asis_not_smaller)
    "hdr_not_supported" -> stringResource(R.string.asis_hdr)
    "removed_before_upload" -> stringResource(R.string.asis_removed_early)
    else -> stringResource(R.string.asis_other)
}

@Composable
fun evidenceLabel(row: ItemRow): String {
    return when (Evidence.parse(row.evidence)) {
        Evidence.CONFIRMED_EXACT -> stringResource(R.string.evidence_confirmed_exact)
        Evidence.CONFIRMED_PACED -> stringResource(R.string.evidence_confirmed_paced)
        Evidence.VERIFIED -> stringResource(R.string.evidence_verified)
        Evidence.AGED -> stringResource(R.string.evidence_aged)
        Evidence.NONE -> stringResource(R.string.evidence_none)
    }
}

/**
 * A stored row seen as the action rule needs it.
 *
 * One conversion, used by every screen, so no list can accidentally decide
 * "backed up" differently from the rule that governs deletion.
 */
fun ItemRow.toActionRow(): RowActions.Row = RowActions.Row(
    state = runCatching { ItemState.valueOf(state) }.getOrDefault(ItemState.UNKNOWN),
    evidence = Evidence.parse(evidence),
    neverOptimise = neverOptimise,
    originalMissing = originalMissing
)

/** The Status filter, the one chip that belongs to Files alone. */
@Composable
private fun statusFilterChip(selected: String?, onSelect: (String?) -> Unit): ListFilter {
    val options = listOf(
        null to stringResource(R.string.filter_all),
        ItemState.NEW.name to stringResource(R.string.state_new),
        // Optimised and waiting for Ente, both: the two steps between queued and backed up.
        ItemState.RELEASED.name to stringResource(R.string.filter_in_progress),
        ItemState.DONE.name to stringResource(R.string.state_done),
        ItemState.SKIP.name to stringResource(R.string.state_skip)
    )
    return ListFilter(
        name = stringResource(R.string.filter_status),
        valueLabel = options.firstOrNull { it.first == selected }?.second.takeIf { selected != null },
        options = options.map { (value, label) ->
            ListOption(label, value == selected) { onSelect(value) }
        }
    )
}

/** A stored row as the shared filters need to see it. */
private fun ItemRow.toCandidate() = ListFilters.Candidate(
    id = id,
    name = displayName,
    album = bucket,
    sizeBytes = sizeBytes,
    isVideo = isVideo
)

/**
 * One file on the Files screen.
 *
 * Long-press starts a selection and tap toggles once one is running, which is
 * the gesture every list in the app uses; outside selection a tap opens the
 * details sheet.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FilesRow(
    row: ItemRow,
    selected: Boolean?,
    onToggle: () -> Unit,
    onOpenDetail: () -> Unit,
    onLongPress: () -> Unit
) {
    AppCard(
        modifier = Modifier
            .padding(vertical = 5.dp)
            .combinedClickable(
                onClick = { if (selected != null) onToggle() else onOpenDetail() },
                // Said aloud by a screen reader, so the gesture that starts a
                // selection is offered rather than left to be discovered.
                onLongClickLabel = stringResource(R.string.list_select),
                onLongClick = onLongPress
            )
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (selected != null) {
                // Named after the file it selects, as on every other list. An
                // unlabelled checkbox in a column of them is read out as
                // "checkbox, not ticked" again and again, with nothing to say
                // which photo it means.
                Checkbox(
                    checked = selected,
                    onCheckedChange = { onToggle() },
                    modifier = Modifier.semantics { contentDescription = row.displayName }
                )
                Spacer(Modifier.width(4.dp))
            }
            Thumbnail(row)
            Column(
                Modifier
                    .padding(start = 12.dp)
                    .weight(1f)
            ) {
                Text(
                    row.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    // IMG_20240517_181233.jpg cut at the right loses the date,
                    // which is the part that identifies the photo.
                    overflow = TextOverflow.MiddleEllipsis
                )
                Text(
                    // What it was, what it is, and how much that saved - as a
                    // sentence fragment rather than an arrow-and-numbers formula.
                    row.outputBytes?.let { copy ->
                        val saved = row.sizeBytes - copy
                        if (saved > 0) {
                            stringResource(
                                R.string.files_size_saving,
                                Formats.bytes(row.sizeBytes),
                                Formats.bytes(copy),
                                Formats.percentOf(saved, row.sizeBytes)
                            )
                        } else {
                            stringResource(
                                R.string.files_size_pair,
                                Formats.bytes(row.sizeBytes),
                                Formats.bytes(copy)
                            )
                        }
                    } ?: stringResource(
                        R.string.files_size_waiting,
                        Formats.bytes(row.sizeBytes)
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp)
                )
                StateBadge(
                    stateLabel(row),
                    badgeTone(row),
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
        }
    }
}
