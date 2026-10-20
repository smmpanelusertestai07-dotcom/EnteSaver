package app.entesaver.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.CleaningServices
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.PhotoSizeSelectLarge
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.core.logic.SaveMode
import app.entesaver.data.EnteApp
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.Routes
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.goTo
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.TabularFigures
import app.entesaver.util.Formats

/**
 * Every way to make room, on one screen (Z1).
 *
 * Four sections, four screens behind them, and one honest header: which
 * volume this cleans, how much is free now, and roughly how much would be
 * free afterwards. A section whose size is zero is absent rather than shown
 * with a dash - a row reading "0 MB" is a question with no answer.
 *
 * The hub adds nothing of its own on purpose. The lists behind it carry the
 * warnings, the proof checks and Android's own confirmation; putting a
 * summary here and the safety there means the safety cannot be bypassed by
 * entering through a different door.
 */
@Composable
fun FreeSpaceHubScreen(vm: AppViewModel, nav: NavHostController) {
    val findSpace by vm.findSpace.collectAsStateWithLifecycle()
    val checked by vm.findSpaceChecked.collectAsStateWithLifecycle()
    val countersRead by vm.counters.collectAsStateWithLifecycle()
    val counters = countersRead ?: AppViewModel.Counters()
    val stats by vm.storageStats.collectAsStateWithLifecycle()
    val volumes by vm.volumes.collectAsStateWithLifecycle()
    val options by vm.options.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        vm.refreshFindSpace()
        vm.refreshStorage()
        vm.refreshVolumes()
    }

    val total = findSpace.reclaimableBytes + findSpace.duplicateBytes + stats.tempBytes
    val scheme = MaterialTheme.colorScheme

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        Row(
            Modifier.padding(top = 8.dp, start = 4.dp, end = Dimens.Screen),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { nav.popBackStack() }) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.back)
                )
            }
            // A share of the row rather than whatever the title wants: beside
            // the arrow at the largest font it is wider than a small phone,
            // and with nothing to hold it the end of the title was drawn past
            // the edge of the screen. A weight lets it wrap instead.
            Text(
                stringResource(R.string.hub_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
        }

        Column(Modifier.padding(horizontal = Dimens.Screen)) {
            // Z1.5: which volume, free now, and free after - so "free up
            // space" is a promise with a number, not a mood.
            val volume = volumes.firstOrNull { vol ->
                if (options.storageVolume.isEmpty()) vol.isPrimary
                else vol.mediaVolumeName == options.storageVolume
            } ?: volumes.firstOrNull { it.isPrimary }
            if (volume != null) {
                val where = stringResource(
                    if (volume.isPrimary) R.string.volume_internal else R.string.volume_sd
                )
                val freeNow = Formats.bytes(volume.shownFreeBytes)
                val freeAfter = Formats.bytes(volume.shownFreeBytes + total)
                Text(
                    // "5.85 GB free now, about 5.85 GB after" is what this
                    // printed whenever the saving was too small to move the
                    // figure - a sentence that names the same number twice and
                    // promises nothing. When the second half would not differ
                    // from the first, it is left off rather than printed.
                    if (freeAfter == freeNow) {
                        stringResource(R.string.hub_volume_line_only, where, freeNow)
                    } else {
                        stringResource(R.string.hub_volume_line, where, freeNow, freeAfter)
                    },
                    style = MaterialTheme.typography.bodyMedium.merge(TabularFigures),
                    color = scheme.onSurfaceVariant
                )
            }
            Text(
                // Three states, not two: a figure, "nothing", and the honest
                // gap between them while the scan is still hashing files.
                // Saying "nothing to free up yet" during that gap was a wrong
                // answer that corrected itself a few seconds later, which is
                // worse than no answer at all.
                when {
                    total > 0 -> stringResource(R.string.hub_could_free, Formats.bytes(total))
                    !checked -> stringResource(R.string.hub_checking)
                    else -> stringResource(R.string.hub_nothing)
                },
                style = MaterialTheme.typography.titleMedium.merge(TabularFigures),
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 6.dp, bottom = 10.dp)
            )
            // An empty hub is not a dead end; it is a place in a journey.
            // Say where the files actually are - waiting to be optimised,
            // or optimised and waiting for the cloud app to collect them -
            // with real counts, and only the lines that have a count. A
            // sentence about nothing, twice, is the old screen.
            if (total == 0L && checked) {
                Text(
                    stringResource(R.string.hub_journey),
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp)
                )
                if (counters.waiting > 0) {
                    Text(
                        pluralStringResource(
                            R.plurals.hub_next_optimise,
                            counters.waiting, counters.waiting
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 4.dp)
                    )
                }
                if (counters.inFolder > 0) {
                    Text(
                        pluralStringResource(
                            R.plurals.hub_next_upload,
                            counters.inFolder, counters.inFolder
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 4.dp)
                    )
                }
            }

            if (findSpace.reclaimableBytes > 0) {
                HubCard(
                    icon = Icons.Outlined.CloudDone,
                    title = stringResource(R.string.hub_backed_up),
                    hint = stringResource(R.string.hub_backed_up_hint),
                    value = Formats.bytes(findSpace.reclaimableBytes),
                    onClick = { nav.goTo(Routes.FREE_UP) }
                )
            }
            if (findSpace.duplicateBytes > 0) {
                HubCard(
                    icon = Icons.Outlined.ContentCopy,
                    title = stringResource(R.string.find_duplicates),
                    hint = stringResource(R.string.hub_duplicates_hint),
                    value = Formats.bytes(findSpace.duplicateBytes),
                    onClick = { nav.goTo(Routes.DUPLICATES) }
                )
            }
            if (findSpace.biggestBytes > 0) {
                HubCard(
                    icon = Icons.Outlined.PhotoSizeSelectLarge,
                    title = stringResource(R.string.find_biggest),
                    hint = stringResource(R.string.hub_biggest_hint),
                    value = Formats.bytes(findSpace.biggestBytes),
                    onClick = { nav.goTo(Routes.BIGGEST) }
                )
            }
            // Leftover work files are the app's own half-finished output, so
            // clearing them needs no proof and no system dialog - the one
            // section that acts in place rather than opening a list.
            if (stats.tempBytes > 0) {
                AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Outlined.CleaningServices,
                            contentDescription = null,
                            tint = scheme.onSurfaceVariant,
                            modifier = Modifier.size(22.dp)
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                stringResource(R.string.hub_leftovers),
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Medium
                            )
                            Text(
                                stringResource(R.string.hub_leftovers_hint),
                                style = MaterialTheme.typography.bodySmall,
                                color = scheme.onSurfaceVariant
                            )
                        }
                        // The size takes a share of the row, not whatever it
                        // wants. "1,023.45 MB" at the largest font is most of
                        // a small phone's width, and with no bound on it the
                        // name and the line under it were squeezed to nothing.
                        Text(
                            Formats.bytes(stats.tempBytes),
                            style = MaterialTheme.typography.titleMedium.merge(TabularFigures),
                            color = scheme.primary,
                            textAlign = TextAlign.End,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(0.45f, fill = false)
                                .padding(start = 8.dp)
                        )
                    }
                    OutlinedButton(
                        onClick = { vm.cleanTemp() },
                        modifier = Modifier.padding(top = 10.dp)
                    ) {
                        Text(
                            stringResource(R.string.hub_clean_now),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            EnteTools(saveMode = options.saveMode, onGuide = { vm.openEnteHelp(it) })
        }
        Spacer(Modifier.height(28.dp))
    }
}

/**
 * Ente Photos' own tools for space, by Ente's own names and menu path, with
 * where each one acts. Ente Saver does not copy what Ente already does well -
 * it says where it is, and opens Ente's own guide to it.
 */
@Composable
private fun EnteTools(saveMode: SaveMode, onGuide: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Text(
        stringResource(R.string.hub_ente_title),
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .padding(top = 18.dp)
            .semantics { heading() }
    )
    Text(
        stringResource(R.string.hub_ente_intro),
        style = MaterialTheme.typography.bodySmall,
        color = scheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 2.dp, bottom = 4.dp)
    )
    val tools = listOf(
        EnteTool(
            R.string.ente_tool_free_device, R.string.ente_tool_free_device_what, R.string.hub_ente_on_phone,
            review = false, EnteApp.Help.FREE_UP_DEVICE,
            extra = if (saveMode == SaveMode.IN_PLACE) R.string.ente_tool_free_device_in_place else R.string.ente_tool_free_device_copies
        ),
        EnteTool(R.string.ente_tool_similar, R.string.ente_tool_similar_what, R.string.hub_ente_on_ente, review = true, EnteApp.Help.SIMILAR),
        EnteTool(R.string.ente_tool_duplicates, R.string.ente_tool_duplicates_what, R.string.hub_ente_on_ente, review = true, EnteApp.Help.DUPLICATES),
        EnteTool(R.string.ente_tool_large, R.string.ente_tool_large_what, R.string.hub_ente_on_both, review = true, EnteApp.Help.LARGE_FILES),
        EnteTool(R.string.ente_tool_suggestions, R.string.ente_tool_suggestions_what, R.string.hub_ente_on_ente, review = true, EnteApp.Help.SUGGESTIONS),
        EnteTool(R.string.ente_tool_cache, R.string.ente_tool_cache_what, R.string.hub_ente_on_phone, review = false, EnteApp.Help.DEVICE_CACHE),
        EnteTool(R.string.ente_tool_trash, R.string.ente_tool_trash_what, R.string.hub_ente_on_both, review = false, EnteApp.Help.TRASH)
    )
    for (tool in tools) {
        val name = stringResource(tool.name)
        AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
            Text(name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            Text(
                stringResource(tool.acts),
                style = MaterialTheme.typography.labelMedium,
                color = scheme.primary
            )
            Text(
                stringResource(tool.what),
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
            tool.extra?.let {
                Text(
                    stringResource(it),
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
            Text(
                stringResource(if (tool.review) R.string.hub_ente_where_review else R.string.hub_ente_where, name),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp)
            )
            TextButton(onClick = { onGuide(tool.guide) }) { Text(stringResource(R.string.hub_ente_guide)) }
        }
    }
}

private class EnteTool(
    val name: Int,
    val what: Int,
    val acts: Int,
    val review: Boolean,
    val guide: String,
    val extra: Int? = null
)

/** One section: icon, name, one line, its size, a chevron. */
@Composable
private fun HubCard(
    icon: ImageVector,
    title: String,
    hint: String,
    value: String,
    onClick: () -> Unit
) {
    val scheme = MaterialTheme.colorScheme
    AppCard(modifier = Modifier.padding(vertical = 4.dp), onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon,
                contentDescription = null,
                tint = scheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant
                )
            }
            // Bounded for the same reason as the name beside it: a size and a
            // chevron with no limit between them take the whole row at a large
            // font, and the section's name is what is left with nothing.
            Text(
                value,
                style = MaterialTheme.typography.titleMedium.merge(TabularFigures),
                color = scheme.primary,
                textAlign = TextAlign.End,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(0.45f, fill = false)
                    .padding(start = 8.dp)
            )
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = scheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp)
            )
        }
    }
}
