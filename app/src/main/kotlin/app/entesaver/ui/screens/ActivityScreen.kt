package app.entesaver.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PauseCircle
import androidx.compose.material.icons.outlined.PlayCircle
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.core.logic.ActivityWording
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.ThemeMode
import app.entesaver.data.db.ActivityRow
import app.entesaver.engine.ActivityLog
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.Routes
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.EmptyState
import app.entesaver.ui.components.ListSkeleton
import app.entesaver.ui.components.ListTags
import app.entesaver.ui.components.SegmentedChoice
import app.entesaver.ui.goTo
import app.entesaver.util.Formats

/**
 * What the app has actually been doing.
 *
 * Background work is invisible by nature and a notification is gone the moment
 * it is swiped, so "is this thing even running" has no answer anywhere else.
 * Every line here is also the reason a notification was posted, which means
 * the user can turn notifications off without losing anything.
 */
@Composable
fun ActivityScreen(vm: AppViewModel, nav: NavHostController) {
    // Null until the log has been read once; see the loading rows below.
    val loaded by vm.activityRows.collectAsStateWithLifecycle()
    val rows = loaded.orEmpty()
    val filter by vm.activityFilter.collectAsStateWithLifecycle()
    var confirmClear by remember { mutableStateOf(false) }

    // Opening the screen is what marks it read; the dot on Home goes with it.
    LaunchedEffect(Unit) { vm.markActivitySeen() }

    val exportOk = stringResource(R.string.activity_export_ok)
    val exportFail = stringResource(R.string.activity_export_failed)
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri -> uri?.let { vm.exportActivity(it, exportOk, exportFail) } }

    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp)
    ) {
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { nav.popBackStack() }) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.back)
                )
            }
            Text(
                stringResource(R.string.nav_activity),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
            // Export and Clear belong in an overflow: they are occasional, and
            // as buttons they sat above the list competing with it.
            var menuOpen by remember { mutableStateOf(false) }
            Box {
                // Export and Clear act on the whole log, not on what the filter
                // is showing. Keying the menu to the visible rows alone meant
                // that picking "Problems" on a phone with no problems logged
                // put Clear out of reach for the rest of the history too.
                IconButton(
                    onClick = { menuOpen = true },
                    enabled = rows.isNotEmpty() || filter != null
                ) {
                    Icon(
                        Icons.Outlined.MoreVert,
                        contentDescription = stringResource(R.string.list_more_actions)
                    )
                }
                DropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false }
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.activity_export)) },
                        onClick = {
                            menuOpen = false
                            exportLauncher.launch("entesaver-activity.txt")
                        }
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.activity_clear)) },
                        onClick = {
                            menuOpen = false
                            confirmClear = true
                        }
                    )
                }
            }
        }

        // One scrolling surface under the title, rather than three fixed bands
        // stacked on top of each other.
        //
        // The filter and the retention note used to be pinned above the list.
        // Turned sideways at the largest accessibility text they are most of a
        // phone's height on their own, and the list they belong to was left a
        // sliver at the bottom - and when there was nothing to list, the empty
        // state itself had no way to scroll and its lower half sat past the
        // edge. As items of the list they take the room they need at any size
        // and scroll out of the way once the history is long.
        //
        // Tagged like every other list in the app: performScrollTo does not
        // work on a lazy list at all (issuetracker 178483889), so anything
        // driving this one has to scroll through the list itself.
        LazyColumn(
            Modifier
                .weight(1f)
                .testTag(ListTags.ROWS)
        ) {
            item(key = "filter") {
                SegmentedChoice(
                    options = listOf(
                        "ALL" to stringResource(R.string.activity_filter_all),
                        ActivityLog.Group.BACKUPS.name to
                            stringResource(R.string.activity_filter_backups),
                        ActivityLog.Group.PROBLEMS.name to
                            stringResource(R.string.activity_filter_problems),
                        ActivityLog.Group.CHANGES.name to
                            stringResource(R.string.activity_filter_changes)
                    ),
                    selected = filter?.name ?: "ALL",
                    onSelect = { value ->
                        vm.activityFilter.value = if (value == "ALL") {
                            null
                        } else {
                            ActivityLog.Group.valueOf(value)
                        }
                    }
                )
            }

            // Nobody switched this on, and nobody has to switch it off. Say how
            // long it is kept and how many lines, so it is not a mystery log
            // growing quietly on the phone.
            item(key = "retention") {
                Text(
                    pluralStringResource(
                        R.plurals.activity_retention,
                        ActivityLog.RETENTION_DAYS,
                        ActivityLog.RETENTION_DAYS,
                        Formats.count(ActivityLog.RETENTION_ROWS)
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }

            if (loaded == null) {
                // Not read yet. The empty state here would be a claim -
                // "Nothing logged yet" - made before the log was opened.
                item(key = "loading") { ListSkeleton(rows = 4) }
            } else if (rows.isEmpty()) {
                item(key = "empty") {
                    // An empty list means two completely different things here
                    // and only one of them was ever said. With a group chosen,
                    // nothing to show means that group has nothing in it - but
                    // the screen still announced "Nothing logged yet", so
                    // tapping Problems on a phone that has never had a problem
                    // told the reader their entire history had gone. The
                    // original message now appears only when the list really
                    // is everything the app has recorded.
                    if (filter == null) {
                        EmptyState(
                            title = stringResource(R.string.activity_empty_title),
                            body = stringResource(R.string.activity_empty_body)
                        )
                    } else {
                        EmptyState(
                            title = stringResource(R.string.activity_empty_group_title),
                            body = stringResource(R.string.activity_empty_group_body)
                        )
                    }
                }
            } else {
                var lastDay = ""
                for (row in rows) {
                    val day = Formats.date(row.atMs)
                    if (day != lastDay) {
                        lastDay = day
                        item(key = "day-$day") {
                            Text(
                                day,
                                style = MaterialTheme.typography.labelLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 14.dp, bottom = 4.dp)
                            )
                        }
                    }
                    item(key = row.id) { ActivityCard(row, nav, vm) }
                }
            }
            // The retention line is stated once, at the top; repeating it
            // at the foot of a 500-row list helps nobody.
            item(key = "footer") { Spacer(Modifier.height(24.dp)) }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.activity_clear_title)) },
            text = {
                // A dialog's text slot does not scroll. On a small screen at a
                // large font its lower half simply sits past the edge, and the
                // buttons are pushed off with it.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(stringResource(R.string.activity_clear_body))
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.clearActivity()
                    confirmClear = false
                }) { Text(stringResource(R.string.activity_clear)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) {
                    Text(stringResource(R.string.cancel))
                }
            }
        )
    }
}

@Composable
private fun ActivityCard(row: ActivityRow, nav: NavHostController, vm: AppViewModel) {
    val kind = runCatching { ActivityLog.Kind.valueOf(row.kind) }.getOrNull()
    // A row that names a group of files takes you to exactly those files,
    // rather than to a list you then have to search yourself.
    val target = row.filterState
    AppCard(
        modifier = Modifier.padding(vertical = 4.dp),
        onClick = if (target != null) {
            {
                vm.filesState.value = target
                nav.goTo(Routes.FILES)
            }
        } else {
            null
        }
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                iconFor(kind),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(20.dp)
                    .padding(end = 0.dp)
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    // A settings change says what changed and to what, in one
                    // sentence. Everything else keeps its own headline.
                    if (kind == ActivityLog.Kind.SETTINGS_CHANGED) {
                        settingSentence(row.detail)
                    } else {
                        kind?.let { headline(it, row) } ?: unknownEventLabel()
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
                if (kind != ActivityLog.Kind.SETTINGS_CHANGED) {
                    row.detail?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 2.dp)
                        )
                    }
                }
            }
            Text(
                Formats.time(row.atMs),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp)
            )
        }
    }
}

/** One line, in the words the rest of the app uses. */
@Composable
private fun headline(kind: ActivityLog.Kind, row: ActivityRow): String = when (kind) {
    ActivityLog.Kind.OPTIMISED ->
        // A run that found nothing did not optimise zero files - it had
        // nothing to do. "Optimised 0 files, saving 0 MB" reads as a
        // failure and is really the ordinary quiet case.
        if (row.count == 0) {
            stringResource(R.string.activity_optimised_none)
        } else {
            pluralStringResource(R.plurals.activity_optimised, row.count, Formats.count(row.count), Formats.bytes(row.bytes))
        }
    ActivityLog.Kind.RELEASED ->
        pluralStringResource(R.plurals.activity_released, row.count, Formats.count(row.count))
    ActivityLog.Kind.BACKED_UP ->
        pluralStringResource(R.plurals.activity_backed_up, row.count, Formats.count(row.count))
    ActivityLog.Kind.RECLAIMED ->
        pluralStringResource(R.plurals.activity_reclaimed, row.count, Formats.count(row.count), Formats.bytes(row.bytes))
    ActivityLog.Kind.PAUSED -> stringResource(R.string.activity_paused)
    ActivityLog.Kind.RESUMED -> stringResource(R.string.activity_resumed)
    ActivityLog.Kind.CLOUD_PROBLEM -> stringResource(R.string.activity_cloud_problem)
    ActivityLog.Kind.SKIPPED -> stringResource(R.string.activity_skipped)
    ActivityLog.Kind.SETTINGS_CHANGED -> stringResource(R.string.activity_settings)
    ActivityLog.Kind.RECOVERED -> stringResource(R.string.activity_recovered)
    ActivityLog.Kind.PROBLEM -> stringResource(R.string.activity_problem)
}

/** A stored event this build does not know about: never show its raw name. */
@Composable
private fun unknownEventLabel(): String = stringResource(R.string.activity_unknown)

/**
 * "Quality changed to Storage saver".
 *
 * Both halves come from the same strings the settings screen uses, so the
 * history and the control can never describe the same choice differently.
 */
@Composable
private fun settingSentence(detail: String?): String {
    val change = ActivityWording.decode(detail)
        ?: return stringResource(R.string.activity_settings)
    val name = stringResource(
        when (change.setting) {
            ActivityWording.Setting.QUALITY -> R.string.opt_group_quality
            ActivityWording.Setting.CLOUD_APP -> R.string.opt_cloud
            ActivityWording.Setting.SPEED -> R.string.opt_speed
            ActivityWording.Setting.LAYOUT -> R.string.opt_output
            ActivityWording.Setting.CODEC -> R.string.opt_videos
            ActivityWording.Setting.PHOTOS -> R.string.opt_photos
            ActivityWording.Setting.VIDEOS -> R.string.opt_videos
            ActivityWording.Setting.FOLDER -> R.string.opt_output
            ActivityWording.Setting.THEME -> R.string.opt_theme
            ActivityWording.Setting.SCOPE -> R.string.opt_scope
            ActivityWording.Setting.SPACE -> R.string.opt_group_space
            ActivityWording.Setting.SAVE_MODE -> R.string.opt_save_mode
        }
    )
    return stringResource(R.string.activity_setting_changed, name, settingValue(change))
}

/** The stored value in the same words the control shows. */
@Composable
private fun settingValue(change: ActivityWording.Change): String {
    val res = when (change.setting) {
        // Before 11 one preset covered both; named here by what it became.
        ActivityWording.Setting.QUALITY -> when (change.value) {
            "STORAGE_SAVER" -> R.string.preset_balanced
            "BALANCED" -> R.string.preset_best
            "MAX_SAVER" -> R.string.preset_smallest
            else -> null
        }
        // Before 14 photos and videos each had presets; an entry from then
        // is named as the screen named it.
        ActivityWording.Setting.PHOTOS, ActivityWording.Setting.VIDEOS -> when (change.value) {
            "BEST" -> R.string.preset_best
            "BALANCED" -> R.string.preset_balanced
            "SMALLEST" -> R.string.preset_smallest
            "CUSTOM" -> R.string.preset_custom
            else -> null
        }
        ActivityWording.Setting.SPEED -> when (change.value) {
            SpeedMode.SMART.name -> R.string.speed_smart
            SpeedMode.CHARGING_ONLY.name -> R.string.speed_charging
            SpeedMode.FAST.name -> R.string.speed_fast
            else -> null
        }
        ActivityWording.Setting.LAYOUT -> when (change.value) {
            OutputMode.SINGLE.name -> R.string.output_single
            OutputMode.SEPARATE.name -> R.string.output_separate
            else -> null
        }
        ActivityWording.Setting.CODEC -> when (change.value) {
            "H264" -> R.string.codec_h264
            "HEVC" -> R.string.codec_hevc
            else -> null
        }
        ActivityWording.Setting.THEME -> when (change.value) {
            ThemeMode.SYSTEM.name -> R.string.theme_system
            ThemeMode.LIGHT.name -> R.string.theme_light
            ThemeMode.DARK.name -> R.string.theme_dark
            else -> null
        }
        ActivityWording.Setting.SCOPE -> when (change.value) {
            BackupScope.ALL.name -> R.string.scope_all
            BackupScope.PHOTOS.name -> R.string.scope_photos
            BackupScope.VIDEOS.name -> R.string.scope_videos
            else -> null
        }
        ActivityWording.Setting.SAVE_MODE -> when (change.value) {
            SaveMode.IN_PLACE.name -> R.string.save_mode_in_place
            SaveMode.COPIES.name -> R.string.save_mode_copies
            else -> null
        }
        // Cloud app, space and folder store a label already fit to read.
        ActivityWording.Setting.CLOUD_APP, ActivityWording.Setting.SPACE, ActivityWording.Setting.FOLDER -> null
    }
    return res?.let { stringResource(it) } ?: change.value
}

/** Every event type has a glyph, so the list can be scanned rather than read. */
@Composable
private fun iconFor(kind: ActivityLog.Kind?): ImageVector =
    when (kind) {
        ActivityLog.Kind.OPTIMISED -> Icons.Outlined.Bolt
        ActivityLog.Kind.RELEASED -> Icons.Outlined.CloudUpload
        ActivityLog.Kind.BACKED_UP -> Icons.Outlined.CloudDone
        ActivityLog.Kind.RECLAIMED -> Icons.Outlined.DeleteSweep
        ActivityLog.Kind.PAUSED -> Icons.Outlined.PauseCircle
        ActivityLog.Kind.RESUMED -> Icons.Outlined.PlayCircle
        ActivityLog.Kind.CLOUD_PROBLEM -> Icons.Outlined.CloudOff
        ActivityLog.Kind.SKIPPED -> Icons.Outlined.Block
        ActivityLog.Kind.SETTINGS_CHANGED -> Icons.Outlined.Tune
        ActivityLog.Kind.RECOVERED -> Icons.Outlined.Restore
        ActivityLog.Kind.PROBLEM -> Icons.Outlined.ErrorOutline
        null -> Icons.Outlined.Info
    }
