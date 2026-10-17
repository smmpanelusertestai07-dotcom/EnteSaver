package app.entesaver.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Backup
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.DataUsage
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PauseCircle
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.SdCard
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.ThemeMode
import app.entesaver.data.EnteApp
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.Lock as AppLock
import app.entesaver.ui.Routes
import app.entesaver.ui.components.AlbumGrid
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.EmptyState
import app.entesaver.ui.components.EnteIcon
import app.entesaver.ui.components.EnteInstallButtons
import app.entesaver.ui.components.FolderChoiceRows
import app.entesaver.ui.components.FolderDialog
import app.entesaver.ui.components.ListTags
import app.entesaver.ui.components.MeterBar
import app.entesaver.ui.components.OpenHistory
import app.entesaver.ui.components.PasswordDialog
import app.entesaver.ui.components.SectionHeader
import app.entesaver.ui.components.SegmentedChoice
import app.entesaver.ui.components.StackedTextScale
import app.entesaver.ui.components.WarningNote
import app.entesaver.ui.components.WarningText
import app.entesaver.ui.goTo
import app.entesaver.ui.theme.Dimens
import app.entesaver.util.Formats
import app.entesaver.util.OemPages
import app.entesaver.util.Permissions

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OptionsScreen(vm: AppViewModel, nav: NavHostController) {
    val o by vm.options.collectAsStateWithLifecycle()
    val transferMessage by vm.transferMessage.collectAsStateWithLifecycle()
    // The message belongs to the screen that caused it. Nothing ever called
    // dismissTransferMessage(), so a backup result set in Settings stayed in
    // the shared view model for the rest of the session and was rendered again
    // by setup - a screen that did nothing to produce it - with no way to make
    // it go away.
    DisposableEffect(Unit) { onDispose { vm.dismissTransferMessage() } }
    val volumes by vm.volumes.collectAsStateWithLifecycle()
    val writableVolumes by vm.writableVolumes.collectAsStateWithLifecycle()
    val context = LocalContext.current

    val activityUnread by vm.activityUnread.collectAsStateWithLifecycle()
    val recommended by vm.recommended.collectAsStateWithLifecycle()
    val storage by vm.storageStats.collectAsStateWithLifecycle()
    val deviceFree = volumes.firstOrNull {
        (o.storageVolume.isEmpty() && it.isPrimary) || it.mediaVolumeName == o.storageVolume
    }?.freeBytes ?: 0L

    LaunchedEffect(Unit) {
        vm.refreshVolumes()
        vm.refreshRecommended()
        vm.refreshStorage()
    }

    var showFolders by remember { mutableStateOf(false) }
    var showAdvanced by rememberSaveable { mutableStateOf(false) }
    // Changing the layout means the cloud app has to be pointed at a different
    // folder or the backup quietly stops covering new files. Confirmed, not
    // applied on a stray tap.
    var changingFolder by remember { mutableStateOf<OutFolder?>(null) }
    var pendingLayout by remember { mutableStateOf<OutputMode?>(null) }
    // Moving to or from the SD card applies to new files only, and the ones
    // already written stay where they are. That is worth saying before the
    // change, not discovering afterwards.
    var pendingVolume by remember { mutableStateOf<String?>(null) }

    val exportOkLabel = stringResource(R.string.transfer_export_ok)
    val importOkLabel = stringResource(R.string.transfer_import_ok)
    val failedLabel = stringResource(R.string.transfer_failed)
    val wrongPasswordLabel = stringResource(R.string.transfer_wrong_password)

    // The password is chosen before the file picker opens and used once the
    // user has picked a destination; it waits in the view model, which the
    // trip through the picker cannot clear (AppViewModel.backupPassword).
    var askExportPassword by rememberSaveable { mutableStateOf(false) }
    val pendingImport by vm.pendingImportUri.collectAsStateWithLifecycle()
    val importWrongPassword by vm.importPasswordWrong.collectAsStateWithLifecycle()
    val transferBusy by vm.transferBusy.collectAsStateWithLifecycle()

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream")
    ) { uri ->
        if (uri != null) {
            vm.exportState(uri, vm.backupPassword, exportOkLabel, failedLabel)
        }
        vm.backupPassword = null
    }
    val importLauncher = rememberLauncherForActivityResult(OpenHistory()) { uri ->
        if (uri != null) {
            vm.importState(uri, null, importOkLabel, failedLabel, wrongPasswordLabel)
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            // The Scaffold above hands down the status and navigation bar
            // insets, but not the cutout: a notch only takes a slice out of
            // the top in portrait, where the status bar has already covered
            // it, and takes a slice out of one side in landscape, where
            // nothing has. Sixteen dp of screen padding is not enough to
            // clear a 44 dp camera hole, so the sides are asked for
            // separately - and only the sides, or every notched phone would
            // gain a second status bar's worth of empty space at the top.
            .windowInsetsPadding(WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal))
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
    ) {
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.nav_options),
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.semantics { heading() }
        )
        Spacer(Modifier.height(10.dp))

        SectionHeader(stringResource(R.string.opt_group_backup))
        // Ente Photos: the one app light copies are made for. Whether it is on
        // the phone is asked again whenever Settings comes back, so someone
        // sent off to install it returns to a card that already knows.
        val enteHere by vm.enteInstalled.collectAsStateWithLifecycle()
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refreshEnte() }
        OptionCard(
            stringResource(R.string.opt_cloud),
            stringResource(R.string.cloud_intended),
            icon = IconCloud,
            value = stringResource(
                if (enteHere) R.string.cloud_installed_mark else R.string.cloud_not_installed_mark
            )
        ) {
            // Ente's own icon beside what to do about it. It used to sit on a
            // line of its own with "Ente Photos" written next to it, directly
            // under a card already titled "Ente Photos" - the name twice, and
            // a row that looked like something to tap and was not. The icon
            // stays, because it is Ente's real one when Ente is installed and
            // the green tile when it is not.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 6.dp)
            ) {
                EnteIcon(installed = enteHere)
                Spacer(Modifier.width(10.dp))
                if (enteHere) {
                    OutlinedButton(onClick = { vm.openEnte() }) {
                        Text(
                            stringResource(R.string.onb5_open, EnteApp.LABEL),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                } else {
                    Text(
                        stringResource(R.string.ente_missing_body),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
            if (!enteHere) {
                EnteInstallButtons(
                    onInstall = { vm.installEnte(it) },
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
            Text(
                stringResource(R.string.cl_ente),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
            TextButton(onClick = { nav.goTo(Routes.HELP_CLOUD) }) {
                Text(stringResource(R.string.help_cloud))
            }
        }

        // Albums
        OptionCard(
            stringResource(R.string.opt_folders),
            stringResource(R.string.opt_folders_hint),
            icon = IconAlbums
        ) {
            // Counted from the albums on the phone, not from the stored list
            // of exclusions: that list also holds the app's own output
            // folders and albums since deleted, so "3 albums excluded" could
            // sit above a picker with one box unticked.
            val phoneAlbums by vm.buckets.collectAsStateWithLifecycle()
            // Listing albums reads the whole gallery, so once; opening the
            // picker reads it again, and that keeps the count current.
            LaunchedEffect(Unit) { if (!vm.bucketsLoaded.value) vm.loadBuckets() }
            val included = phoneAlbums.count { it !in o.excludedBuckets }
            OutlinedButton(onClick = { vm.loadBuckets(); showFolders = true }) {
                Text(
                    when {
                        phoneAlbums.isNotEmpty() && included == phoneAlbums.size ->
                            stringResource(R.string.folders_all)
                        phoneAlbums.isNotEmpty() -> pluralStringResource(
                            R.plurals.folders_included,
                            phoneAlbums.size,
                            included,
                            phoneAlbums.size
                        )
                        o.excludedBuckets.isEmpty() -> stringResource(R.string.folders_all)
                        else -> pluralStringResource(
                            R.plurals.folders_excluded,
                            o.excludedBuckets.size,
                            o.excludedBuckets.size
                        )
                    }
                )
            }
            ChoiceNote(stringResource(R.string.folders_gap_note))
        }

        // Optimisation: nothing to choose, only what this phone will do,
        // which depends on its encoder chips - asked once per visit.
        val plan by vm.encodePlan.collectAsStateWithLifecycle()
        LaunchedEffect(Unit) { vm.refreshEncodePlan() }
        OptimisationCard(plan = plan, icon = IconQuality, onInfo = { nav.goTo(Routes.HELP_QUALITY) })

        // When to work
        OptionCard(
            stringResource(R.string.opt_speed),
            stringResource(R.string.opt_speed_hint),
            icon = IconSpeed,
            value = speedLabel(o.speed)
        ) {
            SegmentedChoice(
                listOf(
                    SpeedMode.SMART.name to stringResource(R.string.speed_smart),
                    SpeedMode.CHARGING_ONLY.name to stringResource(R.string.speed_charging),
                    SpeedMode.FAST.name to stringResource(R.string.speed_fast)
                ),
                o.speed.name
            ) { vm.setSpeed(SpeedMode.valueOf(it)) }
            Text(
                when (o.speed) {
                    SpeedMode.SMART -> stringResource(R.string.speed_smart_note)
                    SpeedMode.CHARGING_ONLY -> stringResource(R.string.speed_charging_note)
                    SpeedMode.FAST -> stringResource(R.string.speed_fast_note)
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        SwitchCard(
            title = stringResource(R.string.opt_pause),
            hint = stringResource(R.string.opt_pause_hint),
            icon = IconPause,
            checked = o.pauseAll
        ) { vm.setPauseAll(it) }

        SectionHeader(stringResource(R.string.opt_group_appearance))
        // Theme
        OptionCard(
            stringResource(R.string.opt_theme),
            stringResource(R.string.opt_theme_hint),
            icon = IconTheme,
            value = themeLabel(o.theme)
        ) {
            SegmentedChoice(
                listOf(
                    ThemeMode.SYSTEM.name to stringResource(R.string.theme_system),
                    ThemeMode.LIGHT.name to stringResource(R.string.theme_light),
                    ThemeMode.DARK.name to stringResource(R.string.theme_dark)
                ),
                o.theme.name
            ) { vm.setTheme(ThemeMode.valueOf(it)) }
            // Wallpaper colours exist from Android 12. Below that the switch
            // flipped and nothing changed, which reads as a broken setting.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                SwitchRow(
                    stringResource(R.string.theme_dynamic),
                    o.dynamicColor
                ) { vm.setDynamicColor(it) }
            }
        }

        SectionHeader(stringResource(R.string.opt_group_privacy))
        // Every permission and battery switch this app depends on, with its
        // live state and the phone-maker's own path to it - the "permission
        // manager" a sideloaded app has to be for itself.
        OptionCard(
            stringResource(R.string.opt_permissions),
            stringResource(R.string.opt_permissions_hint),
            icon = Icons.Outlined.PhoneAndroid
        ) {
            OutlinedButton(onClick = { nav.goTo(Routes.PERMISSIONS) }) {
                Text(stringResource(R.string.opt_permissions_open))
            }
        }
        // Switches sit on the row itself. Wrapping one in a card that repeats
        // its own title read as two settings with the same name.
        // Enabling the lock proves identity first - turning on a gate you
        // could not open would only be discovered at the worst moment - and
        // refuses with the reason when the phone has no screen lock at all.
        val lockActivity = LocalActivity.current
            as? FragmentActivity
        var lockEnableFailed by remember { mutableStateOf(false) }
        SwitchCard(
            title = stringResource(R.string.opt_lock),
            hint = stringResource(R.string.opt_lock_hint),
            icon = IconLock,
            checked = o.appLock
        ) { wanted ->
            if (!wanted) {
                vm.setAppLock(false)
                lockEnableFailed = false
            } else if (!AppLock.canEnable(context)) {
                lockEnableFailed = true
            } else {
                val act = lockActivity
                if (act == null) {
                    lockEnableFailed = true
                } else {
                    AppLock.authenticate(
                        act,
                        act.getString(R.string.lock_title),
                        act.getString(R.string.lock_subtitle)
                    ) { outcome ->
                        if (outcome == AppLock.Outcome.Unlocked) {
                            vm.setAppLock(true)
                            lockEnableFailed = false
                        }
                    }
                }
            }
        }
        if (lockEnableFailed) {
            WarningText(stringResource(R.string.lock_enable_needs_credential))
        }
        SwitchCard(
            title = stringResource(R.string.opt_warnings),
            hint = stringResource(R.string.opt_warnings_hint),
            icon = IconAlerts,
            checked = o.warningsNotif
        ) { vm.setWarningsNotif(it) }
        AlertsPermissionRow(wanted = o.warningsNotif)
        // "Mute for 7 days" is a button on the alert itself, and it used to
        // leave no trace anywhere: alerts simply stopped, with this switch
        // still on. While a mute runs it says so here, and how to end it.
        if (o.warningsNotif && o.alertsMutedUntil > System.currentTimeMillis()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
            ) {
                Text(
                    stringResource(R.string.alerts_muted_until, Formats.date(o.alertsMutedUntil)),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = { vm.unmuteAlerts() }) {
                    Text(stringResource(R.string.alerts_unmute))
                }
            }
        }

        // Everything most people never need, behind one row: the defaults
        // suit nearly every phone, and each of these says what it changes.
        SectionHeader(stringResource(R.string.opt_group_advanced))
        NavRow(
            title = stringResource(if (showAdvanced) R.string.opt_advanced_hide else R.string.opt_advanced_show),
            hint = stringResource(R.string.opt_advanced_hint),
            icon = IconAdvanced,
            expanded = showAdvanced,
            onClick = { showAdvanced = !showAdvanced }
        )
        if (showAdvanced) {
            // Space limits: Automatic follows this phone's storage and needs no
            // decision at all; Custom shows the three figures to pick.
            OptionCard(
                stringResource(R.string.opt_space),
                stringResource(R.string.opt_space_hint),
                icon = IconLimit,
                value = stringResource(if (o.spaceAuto) R.string.space_auto else R.string.space_custom)
            ) {
                SwitchRow(stringResource(R.string.space_auto_switch), o.spaceAuto) { vm.setSpaceAuto(it) }

                // Under Custom the three cards below say the same.

                if (o.spaceAuto) {

                    ChoiceNote(

                        stringResource(

                            R.string.space_auto_line,

                            capLabel(o.dailyCapMb),

                            Formats.mbLabel(o.minFreeMb),

                            capLabel(o.maxExtraMb)

                        )

                    )

                }
            }
            if (!o.spaceAuto) {
                // How much new copies may add in a day
                OptionCard(
                    stringResource(R.string.opt_daily_cap),
                    stringResource(R.string.opt_daily_cap_hint),
                    icon = IconLimit,
                    value = capLabel(o.dailyCapMb)
                ) {
                    SegmentedChoice(
                        Defaults.DAILY_CAP_CHOICES_MB.map { mb ->
                            mb.toString() to capLabel(mb)
                        },
                        o.dailyCapMb.toString()
                    ) { vm.setDailyCap(it.toInt()) }
                    // Z10.5: what this limit controls, and what it cannot. The upload
                    // itself belongs to the cloud app; only the feed rate is ours.
                    Text(
                        stringResource(R.string.daily_limit_note),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                    if (o.dailyCapMb < 0) WarningText(stringResource(R.string.unlimited_warning))
                    if (recommended.computed) {
                        RecommendationNote(
                            text = stringResource(
                                R.string.recommend_cap,
                                Formats.mbLabel(recommended.dailyCapMb)
                            ),
                            onApply = if (o.dailyCapMb != recommended.dailyCapMb) {
                                { vm.applyRecommendedCap() }
                            } else {
                                null
                            },
                            warning = recommended.capLooksWrong
                        )
                    }
                }

                // Two limits that sound alike and mean opposite things, so each
                // gets its own card, its own sentence, and its own live number.
                OptionCard(
                    stringResource(R.string.space_min_free_title),
                    stringResource(R.string.space_min_free_body),
                    icon = IconFree,
                    value = Formats.mbLabel(o.minFreeMb)
                ) {
                    SegmentedChoice(
                        Defaults.MIN_FREE_CHOICES_MB.map { it.toString() to Formats.mbLabel(it) },
                        o.minFreeMb.toString()
                    ) { vm.setMinFree(it.toInt()) }
                    LiveValue(stringResource(R.string.space_now_free, Formats.bytes(deviceFree)))
                    if (recommended.computed) {
                        RecommendationNote(
                            text = stringResource(
                                R.string.recommend_space, Formats.mbLabel(recommended.minFreeMb)
                            ),
                            onApply = if (o.minFreeMb != recommended.minFreeMb) {
                                { vm.applyRecommendedMinFree() }
                            } else {
                                null
                            },
                            warning = recommended.freeLooksWrong
                        )
                    }
                }
                OptionCard(
                    stringResource(R.string.space_max_extra_title),
                    stringResource(R.string.space_max_extra_body),
                    icon = IconOwnSpace,
                    value = capLabel(o.maxExtraMb)
                ) {
                    SegmentedChoice(
                        Defaults.MAX_EXTRA_CHOICES_MB.map { mb ->
                            mb.toString() to capLabel(mb)
                        },
                        o.maxExtraMb.toString()
                    ) { vm.setMaxExtra(it.toInt()) }
                    LiveValue(
                        stringResource(
                            R.string.space_now_using,
                            Formats.bytes(storage.stageBytes + storage.outputBytes)
                        )
                    )
                    if (o.maxExtraMb < 0) WarningText(stringResource(R.string.unlimited_warning))
                    if (recommended.computed) {
                        RecommendationNote(
                            text = stringResource(
                                R.string.recommend_extra, Formats.mbLabel(recommended.maxExtraMb)
                            ),
                            onApply = if (o.maxExtraMb != recommended.maxExtraMb) {
                                { vm.applyRecommendedMaxExtra() }
                            } else {
                                null
                            }
                        )
                    }
                }
            }
            // What to back up. Leaving one kind out means Ente Saver never sends
            // it to Ente, which is worth a warning, not a quiet chip.
            OptionCard(
                stringResource(R.string.opt_scope),
                stringResource(R.string.opt_scope_hint),
                icon = IconScope,
                value = scopeLabel(o.scope)
            ) {
                SegmentedChoice(
                    listOf(
                        BackupScope.ALL.name to stringResource(R.string.scope_all_short),
                        BackupScope.PHOTOS.name to stringResource(R.string.scope_photos),
                        BackupScope.VIDEOS.name to stringResource(R.string.scope_videos)
                    ),
                    o.scope.name
                ) { vm.setScope(BackupScope.valueOf(it)) }
                if (o.scope != BackupScope.ALL) WarningText(stringResource(R.string.scope_left_out_warning))
            }

            // Upload folders
            OptionCard(
                stringResource(R.string.opt_output),
                stringResource(R.string.opt_output_hint),
                icon = IconLayout
            ) {
                SegmentedChoice(
                    listOf(
                        OutputMode.SINGLE.name to stringResource(R.string.output_single),
                        OutputMode.SEPARATE.name to stringResource(R.string.output_separate)
                    ),
                    o.outputMode.name
                ) { pendingLayout = OutputMode.valueOf(it) }
                // The user has to pick this exact string inside another app, so it
                // is printed rather than described - once, beside the kind of copy
                // it is for, with the default or a folder of the person's own.
                FolderPaths(o.layout, showPaths = false)
                FolderChoiceRows(o.layout) { changingFolder = it }
                CopyPathButton(o.layout)
            }
            changingFolder?.let { folder ->
                FolderDialog(vm, o.layout, folder) { changingFolder = null }
            }

            // 7b. Storage location (13.D; shown only when an SD card exists).
            // BB2.2: a card that fails the writability probe is absent from the
            // choices - not greyed - and one line says why. Greyed would invite
            // "why not?"; absent-with-the-reason answers it.
            val offerable = volumes.filter {
                it.isPrimary || it.mediaVolumeName in writableVolumes
            }
            val sdBlocked = volumes.size > offerable.size
            if (volumes.size > 1 || o.storageVolume.isNotEmpty()) {
                OptionCard(
                        stringResource(R.string.opt_volume),
                        stringResource(R.string.opt_volume_hint),
                        icon = IconVolume
                    ) {
                    if (sdBlocked) {
                        Text(
                            stringResource(R.string.volume_sd_unwritable),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                    }
                    SegmentedChoice(
                        offerable.map { vol ->
                            val value = if (vol.isPrimary) "" else vol.mediaVolumeName
                            value to if (vol.isPrimary) {
                                stringResource(R.string.volume_internal)
                            } else {
                                stringResource(R.string.volume_sd)
                            }
                        },
                        o.storageVolume
                    ) { pendingVolume = it }
                    // Only the chosen volume's capacity belongs here; the Storage
                    // tab is where every volume is listed.
                    val chosen = volumes.firstOrNull { vol ->
                        if (o.storageVolume.isEmpty()) vol.isPrimary
                        else vol.mediaVolumeName == o.storageVolume
                    }
                    if (chosen != null) {
                        // The same figures as the Storage screen and the phone's
                        // own Settings, so no two screens disagree about one phone.
                        val used = (chosen.shownTotalBytes - chosen.shownFreeBytes).coerceAtLeast(0)
                        val fraction = if (chosen.shownTotalBytes > 0) {
                            used.toFloat() / chosen.shownTotalBytes
                        } else {
                            0f
                        }
                        MeterBar(
                            fraction = fraction,
                            warn = fraction > 0.9f,
                            modifier = Modifier.padding(top = 12.dp)
                        )
                        Text(
                            stringResource(
                                R.string.volume_free_line, Formats.bytes(chosen.shownFreeBytes)
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 6.dp)
                        )
                    } else if (o.storageVolume.isNotEmpty()) {
                        WarningText(stringResource(R.string.volume_missing_warning))
                    }
                    if (o.storageVolume.isNotEmpty()) {
                        WarningNote(stringResource(R.string.volume_sd_note))
                    }
                }
            }

            // The rule this switch turns on has always been written down - a
            // day's byte total says a day's photographs went out, not that this
            // photograph did, so it counts "only behind an explicit opt-in". The
            // opt-in was stored, had a setter, and no screen anywhere reached it,
            // while the Free-up screen offered those files regardless. Now the
            // switch exists and the answer is the user's, off by default: an
            // original is offered on per-file proof unless they say otherwise.
            SwitchCard(
                title = stringResource(R.string.opt_verified30),
                hint = stringResource(R.string.opt_verified30_hint),
                icon = IconProof,
                checked = o.freeUpAllowVerified30
            ) { vm.setFreeUpVerified30(it) }
            // The list of files the user said never to touch belongs with the
            // other safety settings, not among the colours.
            val excludedFiles by vm.neverOptimiseCount.collectAsStateWithLifecycle()
            if (excludedFiles > 0) {
                OptionCard(
                    stringResource(R.string.never_optimise_title),
                    stringResource(R.string.never_optimise_hint),
                    icon = IconExcluded,
                    value = Formats.count(excludedFiles)
                ) {
                    Text(
                        pluralStringResource(
                            R.plurals.never_optimise_count, excludedFiles, excludedFiles
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                    TextButton(onClick = { vm.clearNeverOptimise() }) {
                        Text(stringResource(R.string.never_optimise_clear))
                    }
                }
            }

            // Backup and restore.
            // The history already looks after itself; that has to be the first
            // thing this section says, because a section named "Backup" reads as
            // a chore - and someone who never does the chore must not spend a
            // reinstall believing their record is gone.
            Text(
                stringResource(R.string.opt_history_auto),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
            // 17. Export / Import
            OptionCard(
                stringResource(R.string.opt_transfer),
                stringResource(R.string.opt_transfer_hint),
                icon = IconTransfer
            ) {
                // Two buttons side by side is the arrangement that breaks first:
                // on a 320 dp phone at the largest accessibility font there is not
                // room for both, and a plain Row would push the second one off the
                // edge of the card. Flowing, the second simply drops underneath.
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(
                        enabled = !transferBusy,
                        onClick = { askExportPassword = true }
                    ) {
                        Text(
                            stringResource(R.string.transfer_export),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    OutlinedButton(
                        enabled = !transferBusy,
                        onClick = { importLauncher.launch(arrayOf("*/*")) }
                    ) {
                        Text(
                            stringResource(R.string.transfer_import),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                if (transferBusy) {
                    Text(
                        stringResource(R.string.transfer_working),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
                transferMessage?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }

        }

        SectionHeader(stringResource(R.string.opt_group_help))
        // 18. Help and Activity. Both used to hang off Home, where they
        // competed with the one number that screen exists to show. They are
        // reference material, so they live with the other reference material.
        NavRow(
            title = stringResource(R.string.nav_help),
            hint = stringResource(R.string.help_entry),
            icon = IconHelp,
            onClick = { nav.goTo(Routes.HELP) }
        )
        NavRow(
            title = stringResource(R.string.nav_activity),
            hint = stringResource(R.string.activity_entry),
            icon = IconActivity,
            dot = activityUnread > 0,
            onClick = { nav.goTo(Routes.ACTIVITY) }
        )

        Text(
            stringResource(R.string.options_footer),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 12.dp)
        )
        Spacer(Modifier.height(16.dp))
    }

    if (askExportPassword) {
        PasswordDialog(
            title = stringResource(R.string.backup_password_title),
            body = stringResource(R.string.backup_password_body),
            confirmMode = true,
            allowSkip = true,
            onDismiss = { askExportPassword = false },
            onConfirm = { password ->
                askExportPassword = false
                vm.backupPassword = password.ifEmpty { null }
                exportLauncher.launch(
                    if (password.isEmpty()) "entesaver-backup.json" else "entesaver-backup.csb"
                )
            }
        )
    }

    pendingImport?.let { uri ->
        PasswordDialog(
            title = stringResource(R.string.restore_password_title),
            body = stringResource(R.string.restore_password_body),
            confirmMode = false,
            errorText = if (importWrongPassword) {
                stringResource(R.string.transfer_wrong_password)
            } else {
                null
            },
            onDismiss = { vm.cancelPendingImport() },
            onConfirm = { password ->
                vm.importState(uri, password, importOkLabel, failedLabel, wrongPasswordLabel)
            }
        )
    }

    pendingVolume?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingVolume = null },
            confirmButton = {
                TextButton(onClick = {
                    vm.setStorageVolume(target)
                    pendingVolume = null
                }) { Text(stringResource(R.string.volume_switch_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingVolume = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
            title = { Text(stringResource(R.string.volume_switch_title)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(stringResource(R.string.volume_switch_body))
                    if (target.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            stringResource(R.string.volume_sd_note),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        )
    }

    pendingLayout?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingLayout = null },
            confirmButton = {
                TextButton(onClick = {
                    vm.setOutputMode(target)
                    pendingLayout = null
                }) { Text(stringResource(R.string.output_switch_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingLayout = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
            title = { Text(stringResource(R.string.output_switch_title)) },
            text = {
                // Two full folder paths and two paragraphs. Folder paths wrap
                // rather than truncate - a half-shown path looks right and is
                // not - so this is the body most able to outgrow its dialog.
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(stringResource(R.string.output_switch_body))
                    Spacer(Modifier.height(10.dp))
                    FolderPaths(o.layout.copy(mode = target))
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.output_switch_note),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        )
    }

    if (showFolders) {
        val buckets by vm.buckets.collectAsStateWithLifecycle()
        val albums by vm.albums.collectAsStateWithLifecycle()
        val bucketsLoaded by vm.bucketsLoaded.collectAsStateWithLifecycle()
        val lockedBuckets by vm.lockedBuckets.collectAsStateWithLifecycle()
        // The same measured figure the setup step shows: a count of albums says
        // nothing about how much gallery it is. It is measured out here rather
        // than inside the list below, because an effect that lives in a row of
        // a lazy list is cancelled the moment that row is scrolled off the
        // screen - and this is the effect that keeps the figure honest.
        val tickedBytes by vm.selectedAlbumBytes.collectAsStateWithLifecycle()
        LaunchedEffect(o.excludedBuckets, buckets) {
            vm.refreshSelectedAlbumBytes()
        }
        AlertDialog(
            onDismissRequest = { showFolders = false },
            confirmButton = {
                TextButton(onClick = { showFolders = false }) { Text(stringResource(R.string.ok)) }
            },
            // The total is in the title, so two visible tiles are never
            // mistaken for the whole gallery.
            title = {
                Text(
                    if (buckets.isEmpty()) stringResource(R.string.opt_folders)
                    else stringResource(R.string.opt_folders_title_count, buckets.size)
                )
            },
            text = {
                // The same grid the setup step draws, because the two pickers
                // are one decision seen from two doors. The body is a plain
                // column and only the grid scrolls: a scrolling column around
                // a lazy grid is two scrollers arguing over one drag, and a
                // lazy grid with no ceiling in an unbounded dialog does not
                // draw at all.
                val included = buckets.count { it !in o.excludedBuckets }
                if (buckets.isEmpty()) {
                    // Empty has two meanings. Until the scan has answered,
                    // this is a wait; once it has answered with nothing, the
                    // phone has no photos on it and "Loading albums..." is a
                    // wait that never ends. Scrollable, because a dialog's
                    // text slot clips rather than scrolls on its own.
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                    ) {
                        if (bucketsLoaded) {
                            EmptyState(
                                title = stringResource(R.string.folders_none_title),
                                body = stringResource(R.string.folders_none_body)
                            )
                        } else {
                            Text(stringResource(R.string.folders_loading))
                        }
                    }
                } else {
                    // Everything in this body lives inside the grid's own
                    // scroll - the size line above the tiles and the
                    // auto-excluded folders below them ride as full-width
                    // rows, so a short screen at a large font can still reach
                    // all of it. Two scrollers in one dialog, or rows a
                    // non-scrolling column could clip, are how the last two
                    // layouts here failed.
                    AlbumGrid(
                        albums = albums,
                        excluded = o.excludedBuckets,
                        onToggle = { name, include ->
                            vm.setAlbumIncluded(name, include)
                        },
                        testTag = ListTags.ROWS,
                        header = {
                            // The same running count and select-all the setup
                            // step offers - two doors, one picker contract.
                            Column(Modifier.fillMaxWidth()) {
                                FlowRow(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Text(
                                        if (included == 0) {
                                            stringResource(R.string.onb_albums_none_yet)
                                        } else {
                                            pluralStringResource(
                                                R.plurals.onb_albums_selected,
                                                included, included
                                            )
                                        },
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium
                                    )
                                    TextButton(onClick = {
                                        vm.setExcludedBuckets(
                                            if (included == 0) emptySet()
                                            else buckets.toSet()
                                        )
                                    }) {
                                        Text(
                                            stringResource(
                                                if (included == 0) R.string.onb_albums_all
                                                else R.string.onb_albums_none
                                            ),
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                                if (included > 0) tickedBytes?.let { bytes ->
                                    Text(
                                        stringResource(
                                            R.string.onb_albums_size,
                                            Formats.bytes(bytes)
                                        ),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        },
                        footer = if (lockedBuckets.isNotEmpty()) {
                            {
                                // Folders holding another pipeline's
                                // compressed copies. Named so the absence is
                                // explained; never tickable, because
                                // re-compressing copies of copies helps
                                // nobody.
                                Column(Modifier.fillMaxWidth()) {
                                    Text(
                                        stringResource(R.string.folders_auto_excluded),
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(top = 4.dp)
                                    )
                                    for ((bucket, _) in lockedBuckets) {
                                        Text(
                                            bucket,
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1,
                                            overflow = TextOverflow.MiddleEllipsis
                                        )
                                    }
                                }
                            }
                        } else {
                            null
                        }
                    )
                }
            }
        )
    }
}

/**
 * The Alerts switch says whether alerts are wanted; on Android 13 and later
 * the notification permission says whether they can be shown. Setup asks for
 * that permission once and offers Skip, and the system lets a person revoke
 * it later, so the switch could sit ON while every alert was dropped at the
 * moment of posting, with no screen saying so - including the alert that
 * Free-up is holding deletions, the one a person most needs while they are
 * not in the app. This row says so, and offers the permission again; once the
 * system has stopped asking, it offers the page where the switch lives.
 */
@Composable
private fun AlertsPermissionRow(wanted: Boolean) {
    // Not gated on Android 13. The runtime permission is new there, but the switch in system
    // settings that silences an app is on every version, and a phone with that switch off
    // used to get no warning at all here below 13.
    if (!wanted) return
    val context = LocalContext.current
    var granted by remember { mutableStateOf(Permissions.hasNotifications(context)) }
    var refused by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        granted = Permissions.hasNotifications(context)
    }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { ok ->
        granted = ok
        if (!ok) refused = true
    }
    if (granted) return
    WarningText(stringResource(R.string.alerts_need_permission))
    TextButton(
        onClick = {
            // Below 13 there is no prompt to launch: the switch lives in settings only.
            if (refused || Build.VERSION.SDK_INT < 33) {
                OemPages.openNotificationSettings(context)
            } else {
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    ) {
        Text(
            stringResource(
                if (refused || Build.VERSION.SDK_INT < 33) R.string.alerts_open_settings
                else R.string.alerts_allow
            )
        )
    }
}

@Composable
private fun LiveValue(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 8.dp)
    )
}

/**
 * "Recommended" as a plain tag.
 *
 * As a filled pill it read as a third option next to the real ones, and
 * people tapped it expecting something to happen.
 */
@Composable
fun RecommendedTag(modifier: Modifier = Modifier) {
    Text(
        stringResource(R.string.tag_recommended),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier
    )
}

@Composable
private fun RecommendationNote(
    text: String,
    onApply: (() -> Unit)?,
    warning: Boolean = false
) {
    // Always on the card once measured, so "what should this be?" keeps its
    // answer in view. The button appears exactly while the stored value
    // differs and applies only the setting it sits under - it used to rewrite
    // three limits from one card, and to vanish for good after any small
    // manual change. Warning colour marks real drift; the note stays quiet.
    Column(Modifier.padding(top = 10.dp)) {
        if (warning) {
            WarningText(text)
        } else {
            Text(
                text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        // Where the number came from, said under the number itself. "This
        // phone" is a claim, and a claim about someone's storage should be
        // answerable without leaving the setting it belongs to; the full
        // working is in Help, under its own question.
        Text(
            stringResource(R.string.recommend_basis),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (onApply != null) {
            TextButton(onClick = onApply, contentPadding = PaddingValues(horizontal = 4.dp)) {
                Text(stringResource(R.string.recommend_apply))
            }
        }
    }
}

// Material Symbols, one set app-wide. A settings screen without icons is a
// form; with them it can be scanned.
// The collapsed row has to say what the setting is currently set to, so the
// value shown here is the same word the expanded control is showing.
@Composable
private fun scopeLabel(scope: BackupScope): String = stringResource(
    when (scope) {
        BackupScope.ALL -> R.string.scope_all
        BackupScope.PHOTOS -> R.string.scope_photos
        BackupScope.VIDEOS -> R.string.scope_videos
    }
)

@Composable
private fun speedLabel(speed: SpeedMode): String = stringResource(
    when (speed) {
        SpeedMode.SMART -> R.string.speed_smart
        SpeedMode.CHARGING_ONLY -> R.string.speed_charging
        SpeedMode.FAST -> R.string.speed_fast
    }
)

@Composable
private fun themeLabel(theme: ThemeMode): String = stringResource(
    when (theme) {
        ThemeMode.SYSTEM -> R.string.theme_system
        ThemeMode.LIGHT -> R.string.theme_light
        ThemeMode.DARK -> R.string.theme_dark
    }
)

// Negative means no ceiling, and "Unlimited" is the word the chips use.
@Composable
internal fun capLabel(mb: Int): String =
    if (mb < 0) stringResource(R.string.unlimited) else Formats.mbLabel(mb)

private val IconScope = Icons.Outlined.PhotoLibrary
private val IconAlbums = Icons.Outlined.Folder
private val IconLayout = Icons.Outlined.CreateNewFolder
private val IconCloud = Icons.Outlined.CloudUpload
private val IconSpeed = Icons.Outlined.Bolt
private val IconLimit = Icons.Outlined.DataUsage
private val IconFree = Icons.Outlined.PhoneAndroid
private val IconOwnSpace = Icons.Outlined.Storage
private val IconVolume = Icons.Outlined.SdCard
private val IconQuality = Icons.Outlined.Tune
private val IconCodec = Icons.Outlined.Movie
private val IconTheme = Icons.Outlined.Palette
private val IconLock = Icons.Outlined.Lock
private val IconAlerts = Icons.Outlined.Notifications
private val IconPause = Icons.Outlined.PauseCircle
private val IconExcluded = Icons.Outlined.Block
private val IconProof = Icons.Outlined.VerifiedUser
private val IconTransfer = Icons.Outlined.Backup
private val IconHelp = Icons.AutoMirrored.Outlined.HelpOutline
private val IconActivity = Icons.Outlined.History
private val IconAdvanced = Icons.Outlined.Settings

private val InfoIcon = Icons.Outlined.Info

/**
 * One setting: icon, title, what it does, and the value it is set to.
 *
 * The icon is not decoration - a column of text rows reads as a form, and a
 * settings screen people are meant to understand at a glance needs something
 * to scan by. [value] repeats the current choice in words next to the title,
 * so the answer is readable without parsing the control below it.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun OptionCard(
    title: String,
    hint: String,
    icon: ImageVector? = null,
    value: String? = null,
    onInfo: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    AppCard(modifier = Modifier.padding(vertical = 5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(Modifier.width(14.dp))
            }
            Column(Modifier.weight(1f)) {
                // The setting's name and the setting's value share one line
                // for as long as both fit, and the value drops onto a line of
                // its own the moment they do not.
                //
                // Splitting the line by weight instead - which is what this
                // was - divides it in half whether or not half is enough. On a
                // 320 dp phone at the largest accessibility font that left the
                // title a word wide down the left edge and cut "Photos and
                // videos" to "Photos a...", so neither half could be read.
                // Flowing, each is shown in full; one of them just moves down
                // a line to get there.
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                    value?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            textAlign = TextAlign.End,
                            modifier = Modifier.padding(start = 12.dp)
                        )
                    }
                }
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
            if (onInfo != null) {
                IconButton(onClick = onInfo) {
                    Icon(
                        InfoIcon,
                        contentDescription = stringResource(R.string.quality_explained_title),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        content()
    }
}

/**
 * A setting that is just on or off: same row shape as [OptionCard], with the
 * switch where the value would be. Tapping anywhere on the row toggles it.
 */
@Composable
private fun SwitchCard(
    title: String,
    hint: String,
    icon: ImageVector,
    checked: Boolean,
    onChange: (Boolean) -> Unit
) {
    // Once the text is large enough, the switch goes under the words instead
    // of beside them.
    //
    // A Switch is a fixed 52 dp whatever the reader's text size, and the icon
    // and its gap take another 38. On a 320 dp phone at 200% that leaves the
    // words about 150 dp: "Require unlock to open Ente Saver" came out as five
    // short lines beside a switch pinned at the top of them, which reads as a
    // control belonging to whichever line it happens to sit next to. Stacked,
    // the title has the whole card and the switch sits under it on the end of
    // the row, where it belongs to all of it.
    val stacked = LocalDensity.current.fontScale >= StackedTextScale
    AppCard(
        // Toggleable, not clickable: the whole card is a switch, so it is
        // announced with its title and its state rather than as a button
        // that happens to have a switch drawn on the end of it. The Switch
        // inside takes onCheckedChange = null and is decoration.
        modifier = Modifier
            .padding(vertical = 5.dp)
            .toggleable(value = checked, onValueChange = onChange, role = Role.Switch)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
                if (stacked) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp),
                        horizontalArrangement = Arrangement.End,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Switch(checked = checked, onCheckedChange = null)
                    }
                }
            }
            if (!stacked) {
                Spacer(Modifier.width(12.dp))
                Switch(checked = checked, onCheckedChange = null)
            }
        }
    }
}

/**
 * A settings row that opens another screen instead of holding a control.
 * Same shape as [OptionCard] so the column keeps one rhythm, with a chevron
 * where the control would be.
 */
@Composable
private fun NavRow(
    title: String,
    hint: String,
    icon: ImageVector,
    dot: Boolean = false,
    /** Set for a row that folds a section open in place rather than opening a screen. */
    expanded: Boolean? = null,
    onClick: () -> Unit
) {
    // What the chevron and the dot say to the eye, said to a screen reader
    // too. The dot was never announced, so "Activity" read the same whether or
    // not something new was waiting there.
    val state = listOfNotNull(
        expanded?.let { stringResource(if (it) R.string.a11y_expanded else R.string.a11y_collapsed) },
        if (dot) stringResource(R.string.a11y_needs_attention) else null
    ).joinToString(", ").ifEmpty { null }
    AppCard(
        modifier = Modifier
            .padding(vertical = 5.dp)
            .then(if (state != null) Modifier.semantics { stateDescription = state } else Modifier),
        onClick = onClick
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        // Weighted so the title yields to the unread dot
                        // rather than the other way round. Unweighted it was
                        // measured first and took the whole line at a large
                        // font, leaving the dot nothing - and a badge that is
                        // not drawn is the same as no unread mark at all.
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (dot) {
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                        )
                    }
                }
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
            Icon(
                when (expanded) {
                    null -> Icons.AutoMirrored.Outlined.KeyboardArrowRight
                    true -> Icons.Outlined.ExpandLess
                    false -> Icons.Outlined.ExpandMore
                },
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            // A finger's height whatever the label is. One short line beside
            // a switch with no click handler of its own came to about 36 dp.
            .heightIn(min = Dimens.TouchTarget)
            // The whole row is the control, not the switch on the end of it.
            // As two separate nodes a screen reader read out "switch, on" with
            // nothing to say what it switched, and the label was not something
            // you could tap. Toggling here merges the label into the one node
            // that carries the state.
            .toggleable(value = checked, onValueChange = onChange, role = Role.Switch)
            .padding(top = 4.dp)
    ) {
        // Label first in its own column with a fixed gap: a long label used to
        // run under the switch, and neither could then be read.
        Text(
            label,
            modifier = Modifier
                .weight(1f)
                .padding(end = 16.dp),
            style = MaterialTheme.typography.bodyMedium
        )
        Switch(checked = checked, onCheckedChange = null)
    }
}

/** One quiet line under a choice, saying what the selection means. */
@Composable
internal fun ChoiceNote(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 8.dp)
    )
}

