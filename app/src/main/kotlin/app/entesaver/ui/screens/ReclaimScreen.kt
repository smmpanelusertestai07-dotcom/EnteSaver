package app.entesaver.ui.screens

import android.app.Activity
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.FreeUpFlow
import app.entesaver.core.logic.KnownClouds
import app.entesaver.core.logic.ListFilters
import app.entesaver.core.logic.ProofLine
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.core.logic.Suggestions
import app.entesaver.data.EnteApp
import app.entesaver.engine.ReclaimEngine
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.ReclaimViewModel
import app.entesaver.ui.Routes
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.CardShape
import app.entesaver.ui.components.EmptyState
import app.entesaver.ui.components.KeyValueRow
import app.entesaver.ui.components.ListFilter
import app.entesaver.ui.components.ListFilterRow
import app.entesaver.ui.components.ListOption
import app.entesaver.ui.components.ListSearchField
import app.entesaver.ui.components.ListTags
import app.entesaver.ui.components.RemovalWarningCard
import app.entesaver.ui.components.StackedTextScale
import app.entesaver.ui.components.WarningNote
import app.entesaver.ui.components.albumFilter
import app.entesaver.ui.components.sizeFilter
import app.entesaver.ui.components.typeFilter
import app.entesaver.ui.goTo
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.TabularFigures
import app.entesaver.util.Formats

/**
 * Reclaim space - the only place in Ente Saver that can remove a user's photo.
 *
 * Everything here is built around one idea: nothing happens that the person
 * did not choose, having been told exactly what it costs. The default mode
 * leaves a viewable file behind, the default action is recoverable for thirty
 * days, and the numbers for all three modes are on screen before any of them
 * is picked.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ReclaimScreen(vm: AppViewModel, rvm: ReclaimViewModel, nav: NavHostController) {
    val entries by rvm.entries.collectAsStateWithLifecycle()
    val selected by rvm.selected.collectAsStateWithLifecycle()
    val mode by rvm.mode.collectAsStateWithLifecycle()
    val loading by rvm.loading.collectAsStateWithLifecycle()
    // A batch is under way: light copies being made, or Android's dialog
    // open. Every button that could start another one waits for it.
    val working by rvm.busy.collectAsStateWithLifecycle()
    val result by rvm.lastResult.collectAsStateWithLifecycle()
    val dry by rvm.dryRun.collectAsStateWithLifecycle()
    val pending by rvm.pendingIntent.collectAsStateWithLifecycle()
    val options by vm.options.collectAsStateWithLifecycle()
    val suggestion by rvm.suggestion.collectAsStateWithLifecycle()
    val sort by rvm.sort.collectAsStateWithLifecycle()
    val grouping by rvm.grouping.collectAsStateWithLifecycle()

    var confirmBig by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var compare by remember { mutableStateOf<ReclaimViewModel.Entry?>(null) }
    // The saved answer arrives a moment after the screen is first drawn, and
    // a plain remember of its value kept the very first one - "not yet" - for
    // the life of the screen, so someone who had already ticked this box was
    // asked to tick it again every time they came back. The tick is held
    // separately and either source counts.
    var justUnderstood by rememberSaveable { mutableStateOf(false) }
    val understood = justUnderstood || options.reclaimUnderstood
    val context = LocalContext.current

    LaunchedEffect(Unit) { rvm.load() }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult()
    ) { r -> rvm.onSystemDialogResult(r.resultCode == Activity.RESULT_OK) }
    LaunchedEffect(pending) {
        pending?.let { if (rvm.takeDialog(it)) launcher.launch(IntentSenderRequest.Builder(it).build()) }
    }

    val exportOk = stringResource(R.string.reclaim_export_ok)
    val exportFail = stringResource(R.string.reclaim_export_failed)
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/csv")
    ) { uri -> uri?.let { rvm.exportSelection(it, exportOk, exportFail) } }

    // The result of the last export, and it belongs to this screen: leaving
    // it in the view model would show a stale note the next time Free-up is
    // opened, which is the trap the settings message fell into.
    val exportMessage by rvm.message.collectAsStateWithLifecycle()
    DisposableEffect(Unit) { onDispose { rvm.dismissMessage() } }

    val shared by rvm.listFilter.collectAsStateWithLifecycle()
    val holdingApps by rvm.holdingApps.collectAsStateWithLifecycle()
    // Filtering and sorting the batch is not free, and this ran four times
    // over on every recomposition - once per call, plus the three that call
    // visible() again inside themselves. On a four-hundred-file selection
    // that is four passes for every checkbox tap, on the one screen that has
    // to feel dependable. Each is now recomputed only when its inputs change.
    // The proof choice is one of the inputs to both, and leaving it out of the
    // keys meant picking a proof filter changed the chip and nothing else: the
    // list kept the rows it already had until something else happened to
    // change. Every input the two functions read is listed here.
    val visible = remember(entries, shared, suggestion, sort, grouping) { rvm.visible() }
    // How many ticked rows this screen's buttons can actually reach.
    //
    // Every action runs over selectedEntries(), which is visible() filtered by
    // the selection - so a tick that survived a filter change is counted by
    // `selected` and touched by nothing. The buttons were enabled on `selected`
    // and could be tapped with no reachable row at all, doing nothing and
    // saying nothing.
    val actionable = remember(visible, selected) { visible.count { it.id in selected } }
    val groups = remember(entries, shared, suggestion, sort, grouping) { rvm.groups() }
    val selectedEntries = remember(visible, selected) {
        visible.filter { it.id in selected }
    }
    val freed = remember(selectedEntries, mode) {
        ReclaimRules.savedBytes(selectedEntries.map { it.candidate }, mode)
    }

    // The search field is in the list, and the decision panel under it: with
    // no room made for the keyboard, typing a search on a phone turned
    // sideways put both underneath it. From Android 11, as on every other
    // list; below it the window itself shrinks for the keyboard.
    val keyboard = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Modifier.imePadding() else Modifier
    Column(Modifier.fillMaxSize().then(keyboard)) {
        Row(
            Modifier.padding(top = 8.dp, start = 4.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { nav.popBackStack() }) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.back)
                )
            }
            Text(
                stringResource(R.string.freeup_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
        }

        // Preparing a batch can take minutes on a slow phone, and a screen
        // that looked idle meanwhile was tapped again.
        if (loading || working) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        // A light copy is being remade, and the background run is finishing
        // the file it was on first: said, so the wait does not look stuck.
        val waitingForStage by rvm.waitingForStage.collectAsStateWithLifecycle()
        if (working && waitingForStage) {
            Text(
                stringResource(R.string.freeup_waiting_for_stage),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }

        // Arrived from "Remove from phone" with a file this screen cannot
        // offer: say which and why, instead of a list of other files. Kept
        // through a turn of the phone, gone once the screen is left.
        val handOver by rvm.handOver.collectAsStateWithLifecycle()
        val hostActivity = LocalActivity.current
        DisposableEffect(Unit) {
            onDispose { if (hostActivity?.isChangingConfigurations != true) rvm.clearHandOver() }
        }
        // Part of what scrolls, not pinned above it: at a large font on a
        // small phone the card was most of the screen, and the list and the
        // decision panel under it shared what little was left for as long as
        // the screen stayed open.
        val handOverCard = @Composable { modifier: Modifier ->
            handOver?.let { note ->
                AppCard(modifier = modifier, tonal = true) {
                    Text(
                        stringResource(R.string.freeup_handover_refused, note.name, refusalLabel(note.refusal)),
                        style = MaterialTheme.typography.bodyMedium
                    )
                    note.readyOn?.let { day ->
                        Text(
                            stringResource(R.string.freeup_handover_ready_on, Formats.date(day)),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }
        }

        if (entries.isEmpty() && !loading) {
            // Nothing to remove is still a screen, and it is the one state
            // here that draws no list at all. Sideways on a phone at a large
            // font the mark, the heading and the sentence under it are taller
            // than the display, so this state scrolls like every other.
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
            ) {
                handOverCard(Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                EmptyState(
                    title = stringResource(R.string.freeup_empty_title),
                    body = stringResource(R.string.freeup_empty)
                )
            }
            return@Column
        }

        // Tagged so a test can scroll it the way lazy lists have to be
        // scrolled. performScrollTo does not support them - it reaches
        // whatever happens to be composed and gives up - which is why an
        // assertion here read "Free a set amount is not displayed" on a
        // screen that was drawing it perfectly well, just further down.
        LazyColumn(
            Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
                .testTag(ListTags.ROWS)
        ) {
            if (handOver != null) {
                item("handover") { handOverCard(Modifier.padding(top = 8.dp)) }
            }
            item("warning") {
                RemovalWarningCard(Modifier.padding(top = 8.dp))
            }
            item("modes") {
                ModePicker(rvm, mode, selectedEntries.map { it.candidate })
            }
            item("targets") {
                // "Free 5 GB" is the thought people actually have; building
                // that selection by hand is forty taps.
                Text(
                    stringResource(R.string.reclaim_target_label),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(top = 14.dp)
                )
                // These five chips used to sit in a row that scrolled
                // sideways, and a sideways scroll inside a vertical list is a
                // gesture nobody goes looking for: there is no edge, no arrow
                // and no half-cut chip to say anything more exists. At a large
                // font on a narrow phone that put "Everything eligible" and
                // "Clear" off the right-hand side with nothing on screen
                // hinting at them, so the two chips that undo a mistaken
                // selection were the two that could not be found. Wrapping
                // puts the overflow on the next line instead, at every width
                // and font size, exactly as the health chips on Home do.
                FlowRow(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (gb in listOf(1L, 5L, 10L)) {
                        AssistChip(
                            onClick = { rvm.selectForTarget(gb * 1_000_000_000L) },
                            label = { Text(stringResource(R.string.calc_chip_gb, gb.toInt())) }
                        )
                    }
                    AssistChip(
                        onClick = { rvm.selectAllVisible() },
                        label = { Text(stringResource(R.string.reclaim_all_eligible)) }
                    )
                    AssistChip(
                        onClick = { rvm.clearSelection() },
                        label = { Text(stringResource(R.string.reclaim_clear)) }
                    )
                }
            }
            // Search and the same four chips as every other list, in place of
            // the three private rows of chips this screen used to carry. The
            // proof and grouping choices stay, because they are Reclaim's own
            // question, but they now open sheets like everything else.
            item("search") {
                ListSearchField(
                    shared.query,
                    { rvm.listFilter.value = shared.copy(query = it) },
                    Modifier.padding(top = 10.dp)
                )
            }
            item("filters") {
                val albums = remember(entries) {
                    ListFilters.albumCounts(
                        entries.map {
                            ListFilters.Candidate(
                                it.id, it.row.displayName, it.row.bucket,
                                it.row.sizeBytes, it.row.isVideo
                            )
                        }
                    )
                }
                ListFilterRow(
                    filters = listOf(
                        typeFilter(shared.type) {
                            rvm.listFilter.value = shared.copy(type = it)
                        },
                        proofFilter(suggestion) { rvm.suggestion.value = it },
                        albumFilter(shared.album, albums) {
                            rvm.listFilter.value = shared.copy(album = it)
                        },
                        sizeFilter(shared.size) {
                            rvm.listFilter.value = shared.copy(size = it)
                        },
                        groupingFilter(grouping) { rvm.setGrouping(it) }
                    ),
                    sort = ListFilter(
                        name = stringResource(R.string.filter_sort),
                        valueLabel = null,
                        options = ReclaimViewModel.Sort.entries.map { option ->
                            ListOption(sortLabel(option), sort == option) { rvm.setSort(option) }
                        }
                    ),
                    modifier = Modifier.padding(top = 10.dp)
                )
                Text(
                    stringResource(R.string.reclaim_no_internet),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 10.dp)
                )
            }

            for ((key, rows) in groups) {
                if (key.isNotEmpty()) {
                    item("h-$key") {
                        Column(Modifier.padding(top = 16.dp)) {
                            // A finger's height at least: the box and one
                            // line of title came to about 24 dp, and this tap
                            // ticks every file in the album at once.
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = Dimens.TouchTarget)
                                    .toggleable(
                                        value = rows.all { it.id in selected },
                                        // The new value, not a fixed "add":
                                        // a ticked group's box unticks it.
                                        onValueChange = { tick -> rvm.tickGroup(key, tick) },
                                        role = Role.Checkbox
                                    )
                            ) {
                                Checkbox(
                                    checked = rows.all { it.id in selected },
                                    onCheckedChange = null
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    pluralStringResource(
                                        R.plurals.reclaim_group_header,
                                        rows.size,
                                        groupTitle(key),
                                        rows.size,
                                        Formats.bytes(rows.sumOf { it.row.sizeBytes })
                                    ),
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                            // What this group's proof actually is. The old
                            // build asked the user to enable the weaker kind
                            // in Settings, which is a question nobody can
                            // answer; saying what it means is the answer.
                            groupExplanation(key)?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 12.dp, bottom = 4.dp)
                                )
                            }
                        }
                    }
                }
                items(rows.size, key = { i -> rows[i].id }) { i ->
                    val entry = rows[i]
                    ReclaimRow(
                        entry = entry,
                        checked = entry.id in selected,
                        onToggle = { rvm.toggle(entry.id) },
                        onCompare = { compare = entry }
                    )
                }
            }
            item("tail") { Spacer(Modifier.height(24.dp)) }
        }

        // The running total sits with the button, because that pair is the
        // decision: this many gigabytes, for this action.
        //
        // The pair is also measured before the list is given anything, so
        // on a short screen - a phone turned sideways, or a small one at
        // the largest font - the tick, the total, the four buttons and the
        // two explanations took the whole display, left the list with none
        // of it, and pushed the last button off the bottom edge. Measuring
        // the space first caps this at half of what is left and lets it
        // scroll inside that: the list keeps the rest, and every button
        // stays reachable however short the screen is.
        BoxWithConstraints {
            Column(
                Modifier
                    .heightIn(max = maxHeight / 2)
                    .verticalScroll(rememberScrollState())
            ) {
                AppCard(modifier = Modifier.padding(12.dp)) {
                    if (!understood) {
                        // The tick that unlocks removal, so it gets a whole
                        // finger's height rather than the 24 dp of its box.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = Dimens.TouchTarget)
                                .toggleable(
                                    value = false,
                                    onValueChange = {
                                        justUnderstood = true
                                        vm.setReclaimUnderstood(true)
                                    },
                                    role = Role.Checkbox
                                )
                        ) {
                            Checkbox(checked = false, onCheckedChange = null)
                            Spacer(Modifier.width(12.dp))
                            Text(
                                stringResource(R.string.reclaim_understand),
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                    Text(
                        stringResource(R.string.reclaim_will_free, Formats.bytes(freed)),
                        // Tabular: this total changes with every tick of a checkbox.
                        style = MaterialTheme.typography.titleMedium.merge(TabularFigures),
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        // Counted the same way as the total above it and the batch
                        // itself: only rows the current filters still show can be
                        // acted on. Counting every tick ever made printed "40 of 5
                        // selected" the moment a filter narrowed the list, and
                        // promised thirty-five files that were never going anywhere.
                        pluralStringResource(
                            R.plurals.reclaim_selected,
                            selectedEntries.size,
                            selectedEntries.size,
                            visible.size
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    // Two buttons side by side is two buttons wide, and "Preview
                    // result" beside "Export list" at the largest accessibility font
                    // is wider than a 320 dp phone: the second one simply left the
                    // screen. Wrapping puts the overflow on the next line instead,
                    // at every width and font size, and keeps the order.
                    FlowRow(
                        Modifier.padding(top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedButton(
                            onClick = { rvm.previewResult() },
                            enabled = actionable > 0 && !working
                        ) {
                            Text(
                                stringResource(R.string.reclaim_preview),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        OutlinedButton(
                            onClick = { exportLauncher.launch("entesaver-free-up.csv") },
                            enabled = actionable > 0 && !working
                        ) {
                            Text(
                                stringResource(R.string.reclaim_export),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                    // Export wrote the file and then said nothing at all -
                    // not when it worked, and not when it failed. Nothing in
                    // the app read the result, so someone who picked a folder
                    // the write could not reach was left believing they had a
                    // list of the photographs they were about to remove.
                    exportMessage?.let { note ->
                        Text(
                            note,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                    FlowRow(
                        Modifier.padding(top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Button(
                            onClick = {
                                // Removing an original always goes through the sheet
                                // that carries the check-your-cloud warning; no batch
                                // is small enough to skip it. Only the copies-only
                                // mode, which touches nothing of the user's own,
                                // keeps the quick path for ordinary batches. On a
                                // phone with no media trash every original removal is
                                // permanent whatever the button was called, so the
                                // sheet opens in its delete-for-good wording there.
                                if (mode != ReclaimRules.Mode.COPIES_ONLY ||
                                    rvm.needsSecondConfirmation(permanent = false)
                                ) {
                                    confirmBig =
                                        mode != ReclaimRules.Mode.COPIES_ONLY && !rvm.canUndoRemoval
                                } else {
                                    rvm.start(permanent = false)
                                }
                            },
                            enabled = actionable > 0 && understood && !working
                        ) {
                            // On a phone with no trash this button deletes for good,
                            // so it says so rather than promising a recovery that
                            // does not exist. Copies-only deletes the app's own
                            // copies outright and touches no original, so it
                            // promises neither a trash nor a removed original.
                            Text(
                                stringResource(
                                    when (FreeUpFlow.buttonWording(mode, rvm.canUndoRemoval)) {
                                        FreeUpFlow.Wording.REMOVE_COPIES -> R.string.reclaim_remove_copies
                                        FreeUpFlow.Wording.TRASH -> R.string.reclaim_trash
                                        FreeUpFlow.Wording.DELETE -> R.string.reclaim_delete
                                    }
                                ),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        if (mode != ReclaimRules.Mode.COPIES_ONLY && rvm.canUndoRemoval) {
                            TextButton(
                                onClick = { confirmBig = true },
                                enabled = actionable > 0 && understood && !working
                            ) {
                                Text(
                                    stringResource(R.string.reclaim_delete),
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                    if (mode != ReclaimRules.Mode.COPIES_ONLY) {
                        // Android 9 puts up no dialog of its own: storage
                        // write access is all it has, and the confirmation
                        // here is the only one there is.
                        val androidAsks = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                        if (androidAsks) {
                            Text(
                                stringResource(R.string.reclaim_why_android_asks),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 6.dp)
                            )
                        }
                        if (!rvm.canUndoRemoval) {
                            Text(
                                stringResource(
                                    if (androidAsks) R.string.reclaim_no_trash_here else R.string.reclaim_no_trash_here_9
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(top = 6.dp)
                            )
                        }
                    }
                }
            }
        }
    }

    // A batch this large is worth stating in words before the system dialog.
    compare?.let { entry ->
        CompareSheet(
            row = entry.row,
            onDismiss = { compare = null },
            onKeepThisOne = {
                // Taking it out of the batch is the whole point of looking.
                if (entry.id in selected) rvm.toggle(entry.id)
                compare = null
            }
        )
    }

    confirmBig?.let { permanent ->
        // Copies-only opens this sheet for a large batch too, and it used to
        // read "Remove N originals" and "Move these to the trash?" over a
        // batch that permanently deletes copies and touches no original.
        val wording = FreeUpFlow.sheetWording(mode, permanent)
        val copiesOnly = wording == FreeUpFlow.Wording.REMOVE_COPIES
        AlertDialog(
            onDismissRequest = { confirmBig = null },
            title = {
                Text(
                    stringResource(
                        when (wording) {
                            FreeUpFlow.Wording.REMOVE_COPIES -> R.string.reclaim_confirm_copies_title
                            FreeUpFlow.Wording.DELETE -> R.string.reclaim_confirm_delete_title
                            FreeUpFlow.Wording.TRASH -> R.string.reclaim_confirm_title
                        }
                    )
                )
            },
            text = {
                // Scrollable, because a dialog's text slot is not. This is the
                // last thing shown before originals are removed for good, and
                // on a small screen at a large font its lower half - the
                // warning and what will happen - was simply off the display.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    // Every number in this sheet is counted from the rows the
                    // batch will actually touch, and only those.
                    //
                    // The batch acts on the selection narrowed by whatever
                    // filters the list is showing - that is what start() takes
                    // - but this sheet counted every tick ever made, filtered
                    // or not. So someone who ticked twelve files and then
                    // narrowed to a single album was shown "12 files, 3.4 GB",
                    // agreed to it, and had five removed. The gap ran through
                    // the whole sheet: the count, the proof tally under it and
                    // the list of cloud apps that keep the copies were all
                    // drawn from files that were never going anywhere. A
                    // consent screen that overstates what it is about to do is
                    // worse than no consent screen, because the person has now
                    // been told a number and believes it. The space figure was
                    // already counted the right way; the rest now matches it.
                    Text(
                        pluralStringResource(
                            if (copiesOnly) R.plurals.reclaim_confirm_copies_body
                            else R.plurals.reclaim_confirm_body,
                            selectedEntries.size,
                            Formats.count(selectedEntries.size),
                            Formats.bytes(freed)
                        )
                    )
                    // What the proof actually is, counted. "Trust us" is not
                    // an acceptable last screen before deleting photographs.
                    val tally = ProofLine.tally(
                        selectedEntries.map {
                            ProofLine.forItem(
                                Evidence.parse(it.row.evidence),
                                isDuplicateExtra = it.row.duplicateOf != null
                            )
                        }
                    )
                    Spacer(Modifier.height(10.dp))
                    for ((kind, count) in tally.entries.sortedBy { it.key.ordinal }) {
                        Text(
                            stringResource(
                                R.string.reclaim_confirm_proof, count, proofLabel(kind)
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 2.dp)
                        )
                    }
                    // Z1.4: what will still exist afterwards, and who holds
                    // it. Proof belongs to the app the file was sent to, so
                    // the sheet names that app even if the selection changed.
                    // Not said over copies-only: that batch removes no
                    // original, so "every file removed here" would be wrong.
                    val holders = selectedEntries
                        .mapNotNull { it.row.batchId?.let { id -> holdingApps[id] } }
                        .distinct()
                        .map { pkg -> KnownClouds.labelOf(pkg) }
                    if (!copiesOnly) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            if (holders.isNotEmpty()) {
                                stringResource(
                                    R.string.reclaim_confirm_keeps,
                                    holders.joinToString(", ")
                                )
                            } else {
                                stringResource(R.string.reclaim_confirm_keeps_generic)
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                    // The blind spot, said at the moment it matters: every
                    // proof this app holds was measured from outside the
                    // cloud app. The one direct check - opening the cloud
                    // app and looking - only the user can do, so the sheet
                    // asks for it and hands over the door.
                    val cloudPkg = EnteApp.installedPackage(context)
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Outlined.WarningAmber,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (cloudPkg != null) {
                                stringResource(R.string.reclaim_blindspot, EnteApp.LABEL)
                            } else {
                                stringResource(R.string.reclaim_blindspot_generic)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    if (cloudPkg != null) {
                        TextButton(
                            onClick = { EnteApp.launch(context) }
                        ) {
                            // The label carries an app name someone else
                            // chose, so it is as long as it is - two lines
                            // rather than a cut through the middle of it.
                            Text(
                                stringResource(R.string.reclaim_open_cloud, EnteApp.LABEL),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmBig = null
                        rvm.start(permanent = permanent)
                    },
                    enabled = !working
                ) { Text(stringResource(R.string.reclaim_continue)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmBig = null }) {
                    Text(stringResource(R.string.cancel))
                }
            }
        )
    }

    dry?.let { run ->
        AlertDialog(
            onDismissRequest = { rvm.dismissDryRun() },
            confirmButton = {
                TextButton(onClick = { rvm.dismissDryRun() }) {
                    Text(stringResource(R.string.ok))
                }
            },
            title = { Text(stringResource(R.string.reclaim_preview_title)) },
            text = {
                // Up to eight refused files are named here, so this slot is
                // the one most able to outgrow the screen it is drawn on.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    KeyValueRow(
                        stringResource(R.string.reclaim_preview_count),
                        Formats.count(run.count)
                    )
                    KeyValueRow(
                        stringResource(R.string.reclaim_preview_freed),
                        Formats.bytes(run.freedBytes)
                    )
                    if (run.dropped.isNotEmpty()) {
                        Text(
                            pluralStringResource(
                                R.plurals.reclaim_preview_dropped,
                                run.dropped.size,
                                run.dropped.size
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                        for ((name, refusal) in run.dropped.take(8)) {
                            Text(
                                "$name - ${refusalLabel(refusal)}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        )
    }

    result?.let { r ->
        AlertDialog(
            onDismissRequest = { rvm.dismissResult() },
            confirmButton = {
                TextButton(onClick = {
                    rvm.dismissResult()
                    rvm.clearDropped()
                }) {
                    Text(stringResource(R.string.ok))
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    rvm.dismissResult()
                    nav.goTo(Routes.RECLAIM_HISTORY)
                }) { Text(stringResource(R.string.reclaim_history_open)) }
            },
            title = { Text(stringResource(R.string.reclaim_done_title)) },
            text = {
                // What was freed, what was left behind and why - all of it
                // has to stay reachable, at any font size.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(
                        pluralStringResource(
                            R.plurals.reclaim_done_body,
                            r.done.size,
                            Formats.bytes(r.freedBytes),
                            Formats.count(r.done.size)
                        )
                    )
                    if (r.trashed) {
                        Text(
                            stringResource(R.string.reclaim_done_trash),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                    // Anything that stopped qualifying between the tap and the
                    // action, named. A batch that quietly did less than it
                    // promised is worse than one that says what it left out.
                    val dropped = rvm.droppedAtAction
                    if (dropped.isNotEmpty()) {
                        Text(
                            pluralStringResource(
                                R.plurals.reclaim_done_dropped,
                                dropped.size,
                                dropped.size,
                                dropped.take(3).joinToString(", ")
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                    if (r.skipped.isNotEmpty()) {
                        Text(
                            pluralStringResource(
                                R.plurals.reclaim_done_skipped,
                                r.skipped.size,
                                r.skipped.size
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                        // Named, with the reason - "3 skipped" alone reads as
                        // an apology; a name and a reason is an answer.
                        for (s in r.skipped.take(3)) {
                            Text(
                                "${s.displayName} - ${skipReasonLabel(s.reason)}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        )
    }
}

/** All three modes with their own totals, so they can be compared first. */
@Composable
private fun ModePicker(
    rvm: ReclaimViewModel,
    mode: ReclaimRules.Mode,
    selected: List<ReclaimRules.Candidate>
) {
    Column(Modifier.padding(top = 8.dp)) {
        for (option in ReclaimRules.Mode.entries) {
            val saving = ReclaimRules.savedBytes(selected, option)
            // Which mode is chosen was said by the card's tint alone, so a
            // screen reader read three identical cards and someone who does
            // not see the green well could not tell either. The card is a
            // radio button now, and draws one. Clipped to the card's outline
            // before the gesture, so the press does not paint a square past
            // the rounded corners.
            AppCard(
                modifier = Modifier
                    .padding(vertical = 4.dp)
                    .clip(CardShape)
                    .selectable(
                        selected = option == mode,
                        role = Role.RadioButton,
                        onClick = { rvm.setMode(option) }
                    ),
                tonal = option == mode
            ) {
                // The dot sits with the title only, so the explanation under
                // it keeps the card's full width on a narrow phone.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = option == mode, onClick = null)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        modeTitle(option),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f)
                    )
                }
                Text(
                    modeBody(option),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
                if (option == ReclaimRules.Mode.REPLACE_WITH_LIGHT) {
                    // Most copies have left the phone by the time anyone is
                    // here (the cloud app collected them), so remaking is the
                    // normal case, not the exception - worth a line.
                    Text(
                        stringResource(R.string.reclaim_mode_replace_note),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                    // Where the replacement lands is a property of this mode,
                    // so it is asked here rather than buried in Settings -
                    // the question only means anything next to the choice it
                    // changes, and only while that choice is the live one.
                    if (option == mode) InPlaceChoice(rvm)
                }
                Text(
                    stringResource(R.string.reclaim_mode_saving, Formats.bytes(saving)),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
        }
    }
}

/**
 * Where the replacement copy goes: its own album, or the original's.
 *
 * In place is the answer to "I want my album exactly as it was, only
 * smaller" - the copy carries the original's name and its date, so the
 * gallery timeline does not move. It is also the one choice here that
 * changes a file a person will meet outside this app, so the trade is
 * spelled out under the switch rather than left to be discovered: the
 * extension can change, and the file in the album is no longer the byte
 * for byte twin of what the cloud holds.
 */
@Composable
private fun InPlaceChoice(rvm: ReclaimViewModel) {
    val inPlace by rvm.keptInPlace.collectAsStateWithLifecycle()
    // The switch is a fixed 52 dp whatever the text does, so past the shared
    // stacking point it goes under the words rather than taking a third of
    // the row from a sentence that by then needs all of it.
    val stacked = LocalDensity.current.fontScale >=
        StackedTextScale
    Column(
        Modifier
            .padding(top = 8.dp)
            .toggleable(
                value = inPlace,
                role = Role.Switch,
                onValueChange = { rvm.setKeptInPlace(it) }
            )
    ) {
        val label: @Composable () -> Unit = {
            Column {
                Text(
                    stringResource(R.string.kept_in_place_title),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    stringResource(R.string.kept_in_place_body),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (stacked) {
            label()
            Switch(checked = inPlace, onCheckedChange = null, modifier = Modifier.padding(top = 6.dp))
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { label() }
                Switch(
                    checked = inPlace,
                    onCheckedChange = null,
                    modifier = Modifier.padding(start = 12.dp)
                )
            }
        }
        if (inPlace) {
            WarningNote(stringResource(R.string.kept_in_place_warning))
        }
    }
}

@Composable
private fun ReclaimRow(
    entry: ReclaimViewModel.Entry,
    checked: Boolean,
    onToggle: () -> Unit,
    onCompare: () -> Unit
) {
    // The card is the checkbox, as the album header above it already is: one
    // node that says "ticked" or "not ticked" and reads the file it means.
    // A tap on the card and a tap on the box used to be two separate controls,
    // and the box was announced with no name at all.
    AppCard(
        modifier = Modifier
            .padding(vertical = 4.dp)
            .clip(CardShape)
            .toggleable(
                value = checked,
                role = Role.Checkbox,
                onValueChange = { onToggle() }
            )
    ) {
        // Seeing the two versions is the only quality test that counts, and
        // it belongs one tap from the checkbox: beside the file's lines while
        // they keep most of the row, under them when they would not. Squeezed
        // into a share of the row instead, "Compare" broke into "Compa / re"
        // on every row of a 320 dp phone, and on a 360 dp one from a slightly
        // larger font.
        val compareLabel = stringResource(R.string.reclaim_compare)
        val labelStyle = MaterialTheme.typography.labelLarge
        val measurer = rememberTextMeasurer()
        val density = LocalDensity.current
        BoxWithConstraints {
            val buttonWidth = with(density) { measurer.measure(compareLabel, labelStyle).size.width.toDp() } +
                TextButtonPadding
            val stacked = LocalDensity.current.fontScale >= StackedTextScale ||
                maxWidth - ReclaimRowChrome - buttonWidth < ReclaimTextMinWidth
            val compare = @Composable { modifier: Modifier ->
                TextButton(onClick = onCompare, modifier = modifier) {
                    Text(compareLabel, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = checked, onCheckedChange = null)
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text(
                        entry.row.displayName,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis
                    )
                    Text(
                        stringResource(
                            R.string.files_size_saving,
                            Formats.bytes(entry.row.sizeBytes),
                            Formats.bytes(entry.row.outputBytes ?: 0L),
                            Formats.percentOf(entry.saving, entry.row.sizeBytes)
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        stringResource(
                            R.string.reclaim_row_meta,
                            entry.row.bucket ?: "-",
                            Formats.date(entry.row.confirmedAt ?: entry.row.releasedAt ?: 0)
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    // How we know, per file, in the same words every other list
                    // uses. This is the sentence the whole feature rests on.
                    Text(
                        proofLabel(
                            ProofLine.forItem(
                                Evidence.parse(entry.row.evidence),
                                isDuplicateExtra = entry.row.duplicateOf != null
                            )
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                    // Lined up with the text it belongs to: a text button's
                    // own padding would set its label in from the lines above.
                    if (stacked) compare(Modifier.offset(x = -TextButtonPadding / 2))
                }
                if (!stacked) compare(Modifier)
            }
        }
    }
}

/** A Material text button's horizontal padding, both sides together. */
private val TextButtonPadding = 24.dp

/** The checkbox and the gap after it, beside a reclaim row's text. */
private val ReclaimRowChrome = 36.dp

/** The least the file's lines are left beside the Compare button. */
private val ReclaimTextMinWidth = 180.dp

@Composable
private fun modeTitle(mode: ReclaimRules.Mode): String = when (mode) {
    ReclaimRules.Mode.REPLACE_WITH_LIGHT -> stringResource(R.string.reclaim_mode_replace)
    ReclaimRules.Mode.FREE_UP_FULLY -> stringResource(R.string.reclaim_mode_full)
    ReclaimRules.Mode.COPIES_ONLY -> stringResource(R.string.reclaim_mode_copies)
}

@Composable
private fun modeBody(mode: ReclaimRules.Mode): String = when (mode) {
    ReclaimRules.Mode.REPLACE_WITH_LIGHT -> stringResource(R.string.reclaim_mode_replace_body)
    ReclaimRules.Mode.FREE_UP_FULLY -> stringResource(R.string.reclaim_mode_full_body)
    ReclaimRules.Mode.COPIES_ONLY -> stringResource(R.string.reclaim_mode_copies_body)
}

@Composable
fun suggestionLabel(kind: Suggestions.Kind): String = when (kind) {
    Suggestions.Kind.BIG_OLD_VIDEOS -> stringResource(R.string.suggest_big_videos)
    Suggestions.Kind.OLD_SCREENSHOTS -> stringResource(R.string.suggest_screenshots)
    Suggestions.Kind.OLD_MEDIA -> stringResource(R.string.suggest_old)
    Suggestions.Kind.DUPLICATES -> stringResource(R.string.suggest_duplicates)
    Suggestions.Kind.CONFIRMED_30_DAYS -> stringResource(R.string.suggest_confirmed)
}

/** A group key as a person would read it. */
@Composable
private fun groupTitle(key: String): String = when (key) {
    ReclaimViewModel.GROUP_EXACT -> stringResource(R.string.group_exact)
    ReclaimViewModel.GROUP_BY_SIZE -> stringResource(R.string.group_by_size)
    "photo" -> stringResource(R.string.scope_photos)
    "video" -> stringResource(R.string.scope_videos)
    else -> key
}

@Composable
private fun groupExplanation(key: String): String? = when (key) {
    ReclaimViewModel.GROUP_EXACT -> stringResource(R.string.group_exact_body)
    ReclaimViewModel.GROUP_BY_SIZE -> stringResource(R.string.group_by_size_body)
    else -> null
}

@Composable
private fun sortLabel(sort: ReclaimViewModel.Sort): String = when (sort) {
    ReclaimViewModel.Sort.LARGEST -> stringResource(R.string.sort_largest)
    ReclaimViewModel.Sort.OLDEST -> stringResource(R.string.sort_oldest)
    ReclaimViewModel.Sort.ALBUM -> stringResource(R.string.sort_album)
}

@Composable
private fun groupingLabel(grouping: ReclaimViewModel.Grouping): String = when (grouping) {
    ReclaimViewModel.Grouping.EVIDENCE -> stringResource(R.string.group_evidence)
    ReclaimViewModel.Grouping.ALBUM -> stringResource(R.string.group_album)
    ReclaimViewModel.Grouping.MONTH -> stringResource(R.string.group_month)
    ReclaimViewModel.Grouping.YEAR -> stringResource(R.string.group_year)
    ReclaimViewModel.Grouping.TYPE -> stringResource(R.string.group_type)
}

/** Why an item in a finished batch was left alone, in the user's words. */
@Composable
private fun skipReasonLabel(reason: String?): String = when (reason) {
    "light_copy_failed" -> stringResource(R.string.skip_light_copy_failed)
    "integrity_failed" -> stringResource(R.string.skip_integrity_failed)
    "original_changed" -> stringResource(R.string.skip_original_changed)
    "not_confirmed" -> stringResource(R.string.skip_not_confirmed)
    ReclaimEngine.STAGE_BUSY -> stringResource(R.string.skip_stage_busy)
    else -> stringResource(R.string.skip_generic)
}

@Composable
private fun refusalLabel(refusal: ReclaimRules.Refusal): String = when (refusal) {
    ReclaimRules.Refusal.NOT_CONFIRMED -> stringResource(R.string.refuse_not_confirmed)
    ReclaimRules.Refusal.TOO_RECENT -> stringResource(R.string.refuse_too_recent)
    ReclaimRules.Refusal.NO_LEDGER, ReclaimRules.Refusal.HASH_CHANGED ->
        stringResource(R.string.refuse_no_proof)
    ReclaimRules.Refusal.CLOUD_UNHEALTHY -> stringResource(R.string.refuse_cloud)
    ReclaimRules.Refusal.WRONG_STATE -> stringResource(R.string.refuse_state)
    ReclaimRules.Refusal.ORIGINAL_GONE -> stringResource(R.string.refuse_gone)
    ReclaimRules.Refusal.EXCLUDED_ALBUM -> stringResource(R.string.refuse_album)
    ReclaimRules.Refusal.FAVOURITE -> stringResource(R.string.refuse_favourite)
    ReclaimRules.Refusal.TOO_SMALL -> stringResource(R.string.refuse_small)
}

/**
 * Reclaim's own filter: which kind of proof a file has.
 *
 * It is the question this screen exists to answer, so it keeps its place in
 * the row - but as a sheet, with the others, rather than as a private strip of
 * chips above them.
 */
@Composable
private fun proofFilter(
    selected: Suggestions.Kind?,
    onSelect: (Suggestions.Kind?) -> Unit
): ListFilter {
    val kinds = Suggestions.ALL.filter { it.kind != Suggestions.Kind.DUPLICATES }
    val allLabel = stringResource(R.string.filter_all)
    return ListFilter(
        name = stringResource(R.string.filter_proof),
        valueLabel = selected?.let { suggestionLabel(it) },
        options = buildList {
            add(ListOption(allLabel, selected == null) { onSelect(null) })
            for (filter in kinds) {
                add(
                    ListOption(suggestionLabel(filter.kind), selected == filter.kind) {
                        onSelect(filter.kind)
                    }
                )
            }
        }
    )
}

/** How the list is grouped, as a sheet rather than a second row of chips. */
@Composable
private fun groupingFilter(
    selected: ReclaimViewModel.Grouping,
    onSelect: (ReclaimViewModel.Grouping) -> Unit
): ListFilter = ListFilter(
    name = stringResource(R.string.filter_grouping),
    valueLabel = if (selected == ReclaimViewModel.Grouping.entries.first()) {
        null
    } else {
        groupingLabel(selected)
    },
    options = ReclaimViewModel.Grouping.entries.map { option ->
        ListOption(groupingLabel(option), option == selected) { onSelect(option) }
    }
)
