package app.entesaver.ui.screens

import android.Manifest
import android.app.usage.UsageStatsManager
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.engine.UsageVerifier
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.SectionHeader
import app.entesaver.ui.theme.Dimens
import app.entesaver.util.OemPages
import app.entesaver.util.PermissionLedger
import app.entesaver.util.Permissions
import app.entesaver.util.PowerPages

/**
 * Every permission and battery switch this app depends on, with its live
 * state and the way to it - the permission manager a sideloaded app has to
 * be for itself.
 *
 * Setup showed the battery rows once and Settings showed none of them, so a
 * Realme owner whose phone stopped the app a day later had no way back to
 * the auto-launch page short of finding it in the system by hand. Each row
 * here re-reads its state every time the screen comes to the front, says
 * plainly which states Android can report and which it cannot, and for the
 * ones it cannot, names the page in the phone's own words.
 *
 * Three more switches Android does report were missing until this version:
 * the per-app "Restricted" ban under the app's battery entry, the reset that
 * takes permissions away from an app nobody opens for months, and the
 * phone-wide Battery Saver. Each is the kind of thing that stops the work
 * without a word, and each was invisible here. The bottom of the screen is
 * the ledger: every permission in the shipped manifest with what it is for
 * and whether it is held, and the list of what is never asked for - read
 * from the phone rather than promised in a paragraph.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PermissionsScreen(vm: AppViewModel, nav: NavHostController) {
    val context = LocalContext.current
    // Bumped on every return to the screen: each state below is read fresh
    // through it, because all of them are granted on some other screen.
    var tick by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        tick++
        vm.refreshPowerRequirements()
        vm.refreshHealth()
    }
    val access = remember(tick) { Permissions.mediaAccess(context) }
    val mediaLocation = remember(tick) { Permissions.hasMediaLocation(context) }
    val notifications = remember(tick) { Permissions.hasNotifications(context) }
    val alertsChannelOff = remember(tick) { Permissions.alertsChannelOff(context) }
    val usage = remember(tick) { UsageVerifier.hasUsageAccess(context) }
    val battery = remember(tick) { Permissions.isIgnoringBatteryOptimizations(context) }
    val backgroundRestricted = remember(tick) { Permissions.isBackgroundRestricted(context) }
    val autoReset = remember(tick) { Permissions.permissionsAutoResetOn(context) }
    val saver = remember(tick) { Permissions.batterySaverOn(context) }
    val bucket = remember(tick) { Permissions.standbyBucket(context) }
    val ledger = remember(tick) { PermissionLedger.read(context) }
    val neverAsked = remember { PermissionLedger.neverAsked(context) }
    var ledgerOpen by remember { mutableStateOf(false) }
    val vendor = remember { PowerPages.vendor() }
    val makerRows = remember(vendor, battery, backgroundRestricted, autoReset) {
        PowerPages.requirementsFor(vendor, battery, backgroundRestricted, autoReset)
            .filter { !it.readable }
    }

    // Asking is one tap; a refusal Android has stopped asking about goes to
    // the page where the switch lives instead of a button that does nothing.
    // Only that refusal: a first "Don't allow", or Android 14's "Select
    // photos", is an answer, and being thrown straight into app info for
    // giving it felt like being argued with.
    val activity = LocalActivity.current
    val mediaLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        tick++
        val stillShort = Permissions.mediaAccess(context) != Permissions.MediaAccess.FULL
        val androidStoppedAsking = activity != null &&
            Permissions.mediaPermissionsToRequest().none {
                ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
            }
        if (stillShort && androidStoppedAsking) OemPages.openAppInfo(context)
    }
    val locationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { ok ->
        tick++
        if (!ok) OemPages.openAppInfo(context)
    }
    val notifLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { ok ->
        tick++
        if (!ok) OemPages.openNotificationSettings(context)
    }

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
            Text(
                stringResource(R.string.perm_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
        }
        Column(Modifier.padding(horizontal = Dimens.Screen)) {
            Text(
                stringResource(R.string.perm_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            SectionHeader(stringResource(R.string.perm_group_access))
            PermissionRow(
                title = stringResource(R.string.perm_media),
                status = stringResource(
                    when (access) {
                        Permissions.MediaAccess.FULL -> R.string.perm_media_full
                        Permissions.MediaAccess.PARTIAL -> R.string.perm_media_partial
                        Permissions.MediaAccess.NONE -> R.string.perm_media_none
                    }
                ),
                state = if (access == Permissions.MediaAccess.FULL) State.OK else State.PROBLEM,
                actionLabel = stringResource(R.string.perm_change)
            ) {
                if (access == Permissions.MediaAccess.FULL) {
                    OemPages.openAppInfo(context)
                } else {
                    mediaLauncher.launch(Permissions.mediaPermissionsToRequest())
                }
            }
            // Its own row, because it fails on its own: refused, everything
            // else works and every copy quietly loses where it was taken.
            // Shown only once there is media access for it to go with, and
            // never on Android 9, which hides no photo's location and so has
            // no such permission to show.
            if (access != Permissions.MediaAccess.NONE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                PermissionRow(
                    title = stringResource(R.string.perm_name_media_location),
                    status = stringResource(
                        if (mediaLocation) R.string.perm_media_location_on else R.string.perm_media_location_off
                    ),
                    state = if (mediaLocation) State.OK else State.UNKNOWN,
                    actionLabel = stringResource(if (mediaLocation) R.string.perm_change else R.string.perm_allow)
                ) {
                    if (mediaLocation) {
                        OemPages.openAppInfo(context)
                    } else {
                        locationLauncher.launch(Manifest.permission.ACCESS_MEDIA_LOCATION)
                    }
                }
            }
            // Three states, not two: allowed, blocked, and allowed with the
            // one category that carries the warnings switched off on its own.
            PermissionRow(
                title = stringResource(R.string.perm_notifications),
                status = stringResource(
                    when {
                        !notifications -> R.string.perm_notifications_off
                        alertsChannelOff -> R.string.perm_alerts_channel_off
                        else -> R.string.perm_on
                    }
                ),
                state = if (notifications && !alertsChannelOff) State.OK else State.PROBLEM,
                actionLabel = stringResource(
                    if (notifications) R.string.perm_open else R.string.perm_allow
                )
            ) {
                when {
                    !notifications && Build.VERSION.SDK_INT >= 33 ->
                        notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    notifications && alertsChannelOff -> OemPages.openAlertsChannelSettings(context)
                    else -> OemPages.openNotificationSettings(context)
                }
            }
            PermissionRow(
                title = stringResource(R.string.perm_usage),
                status = stringResource(if (usage) R.string.perm_usage_on else R.string.perm_usage_off),
                state = if (usage) State.OK else State.PROBLEM,
                actionLabel = stringResource(R.string.perm_open),
                detail = if (!usage && Build.VERSION.SDK_INT >= 35) stringResource(R.string.usage_restricted) else null
            ) { OemPages.openUsageAccess(context) }

            SectionHeader(stringResource(R.string.perm_group_battery))
            // Optional, and said so. "Optimised" is Android's default and the
            // work runs under it - a run may just wait for the charger - so
            // it is an information mark, not a red one. Allowed, the button
            // is "Change": the same page is where it is taken back.
            PermissionRow(
                title = stringResource(R.string.perm_battery),
                status = stringResource(
                    if (battery) R.string.perm_battery_on else R.string.perm_battery_off
                ),
                state = if (battery) State.OK else State.UNKNOWN,
                detail = PowerPages.pathHint(vendor, PowerPages.ID_BATTERY_UNRESTRICTED),
                actionLabel = stringResource(
                    if (battery) R.string.perm_change else R.string.perm_allow
                )
            ) { PowerPages.open(context, PowerPages.ID_BATTERY_UNRESTRICTED) }
            PermissionRow(
                title = stringResource(R.string.perm_background_restriction),
                status = stringResource(
                    if (backgroundRestricted) R.string.perm_background_restriction_on
                    else R.string.perm_background_restriction_off
                ),
                state = if (backgroundRestricted) State.PROBLEM else State.OK,
                detail = PowerPages.pathHint(vendor, PowerPages.ID_BACKGROUND_RESTRICTION),
                actionLabel = stringResource(R.string.perm_open)
            ) { PowerPages.open(context, PowerPages.ID_BACKGROUND_RESTRICTION) }
            if (autoReset != null) {
                PermissionRow(
                    title = stringResource(R.string.perm_keep_permissions),
                    status = stringResource(
                        if (autoReset) R.string.perm_keep_permissions_armed
                        else R.string.perm_keep_permissions_off
                    ),
                    state = if (autoReset) State.PROBLEM else State.OK,
                    detail = PowerPages.pathHint(vendor, PowerPages.ID_KEEP_PERMISSIONS),
                    actionLabel = stringResource(R.string.perm_open)
                ) { PowerPages.open(context, PowerPages.ID_KEEP_PERMISSIONS) }
            }
            // Not a switch on this app but on the phone, and the one people
            // forget they turned on. It is read, not guessed.
            PermissionRow(
                title = stringResource(R.string.perm_saver),
                status = stringResource(if (saver) R.string.perm_saver_on else R.string.perm_saver_off),
                state = if (saver) State.PROBLEM else State.OK,
                detail = stringResource(R.string.perm_saver_detail),
                actionLabel = stringResource(R.string.perm_open)
            ) { OemPages.openBatterySaverSettings(context) }
            if (bucket != null) {
                PermissionRow(
                    title = stringResource(R.string.perm_bucket),
                    status = stringResource(
                        when (bucket) {
                            UsageStatsManager.STANDBY_BUCKET_ACTIVE -> R.string.perm_bucket_active
                            UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> R.string.perm_bucket_working
                            UsageStatsManager.STANDBY_BUCKET_FREQUENT -> R.string.perm_bucket_frequent
                            UsageStatsManager.STANDBY_BUCKET_RARE -> R.string.perm_bucket_rare
                            UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> R.string.perm_bucket_restricted
                            else -> R.string.perm_bucket_other
                        }
                    ),
                    state = when (bucket) {
                        UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> State.PROBLEM
                        UsageStatsManager.STANDBY_BUCKET_RARE -> State.UNKNOWN
                        else -> State.OK
                    },
                    detail = stringResource(R.string.perm_bucket_detail)
                )
            }
            for (requirement in makerRows) {
                PermissionRow(
                    title = stringResource(
                        if (requirement.id == PowerPages.ID_AUTO_LAUNCH) R.string.perm_auto_launch
                        else R.string.perm_background
                    ),
                    status = stringResource(R.string.perm_unknown),
                    state = State.UNKNOWN,
                    detail = PowerPages.pathHint(vendor, requirement.id),
                    actionLabel = stringResource(R.string.perm_open)
                ) { PowerPages.open(context, requirement.id) }
            }

            Text(
                stringResource(R.string.perm_why),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )

            // The ledger: what the app holds, from the manifest that shipped.
            SectionHeader(stringResource(R.string.perm_group_ledger))
            Text(
                stringResource(R.string.perm_ledger_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            val applicable = ledger.filter { !it.notOnThisAndroid }
            Text(
                stringResource(
                    R.string.perm_ledger_summary,
                    applicable.count { it.held },
                    applicable.size,
                    applicable.count { it.held && it.runtime }
                ),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(top = 6.dp)
            )
            TextButton(onClick = { ledgerOpen = !ledgerOpen }) {
                Text(
                    stringResource(
                        if (ledgerOpen) R.string.perm_ledger_hide else R.string.perm_ledger_show
                    )
                )
            }
            if (ledgerOpen) {
                for (entry in ledger) LedgerRow(entry)
                Text(
                    stringResource(R.string.perm_never_asked_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 14.dp, bottom = 4.dp)
                )
                for (absent in neverAsked) NeverAskedRow(absent)
            }
            TextButton(onClick = { OemPages.openAppInfo(context) }) {
                Text(stringResource(R.string.perm_app_info))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

private enum class State { OK, PROBLEM, UNKNOWN }

/**
 * One switch: its name, its state in a colour, the path to it when Android
 * cannot read it, and a button when there is somewhere to go. A row with no
 * button is a fact, not a task.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PermissionRow(
    title: String,
    status: String,
    state: State,
    actionLabel: String? = null,
    detail: String? = null,
    onAction: (() -> Unit)? = null
) {
    val scheme = MaterialTheme.colorScheme
    AppCard(modifier = Modifier.padding(vertical = 5.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                when (state) {
                    State.OK -> Icons.Outlined.CheckCircle
                    State.PROBLEM -> Icons.Outlined.ErrorOutline
                    State.UNKNOWN -> Icons.Outlined.Info
                },
                contentDescription = null,
                tint = when (state) {
                    State.OK -> scheme.primary
                    State.PROBLEM -> scheme.error
                    State.UNKNOWN -> scheme.onSurfaceVariant
                },
                modifier = Modifier
                    .padding(top = 2.dp)
                    .size(22.dp)
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    status,
                    style = MaterialTheme.typography.bodySmall,
                    color = when (state) {
                        State.OK -> scheme.primary
                        State.PROBLEM -> scheme.error
                        State.UNKNOWN -> scheme.onSurfaceVariant
                    },
                    modifier = Modifier.padding(top = 2.dp)
                )
                if (detail != null) {
                    Text(
                        detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
            }
        }
        // Its own line, flowing: beside the text at the largest font the
        // button squeezed the words into a column one word wide.
        if (actionLabel != null && onAction != null) {
            FlowRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp)
            ) {
                OutlinedButton(onClick = onAction) {
                    Text(actionLabel, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** One permission from the shipped manifest: name, purpose, and whether it is held. */
@Composable
private fun LedgerRow(entry: PermissionLedger.Entry) {
    val scheme = MaterialTheme.colorScheme
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
    ) {
        Icon(
            when {
                entry.notOnThisAndroid -> Icons.Outlined.Info
                entry.held -> Icons.Outlined.CheckCircle
                else -> Icons.Outlined.RemoveCircleOutline
            },
            contentDescription = null,
            tint = when {
                entry.notOnThisAndroid -> scheme.onSurfaceVariant
                entry.held -> scheme.primary
                else -> scheme.onSurfaceVariant
            },
            modifier = Modifier
                .padding(top = 2.dp)
                .size(20.dp)
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.name, style = MaterialTheme.typography.titleSmall)
            Text(
                entry.purpose,
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
            Text(
                stringResource(
                    when {
                        entry.notOnThisAndroid -> R.string.perm_state_na
                        entry.held && entry.runtime -> R.string.perm_state_on_yours
                        entry.held -> R.string.perm_state_on
                        else -> R.string.perm_state_off
                    }
                ),
                style = MaterialTheme.typography.labelSmall,
                color = if (entry.held && !entry.notOnThisAndroid) scheme.primary else scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
    }
}

/** Something the app never asks for, and why it never needs to. */
@Composable
private fun NeverAskedRow(absent: PermissionLedger.NeverAsked) {
    val scheme = MaterialTheme.colorScheme
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
    ) {
        Icon(
            Icons.Outlined.Block,
            contentDescription = null,
            tint = scheme.onSurfaceVariant,
            modifier = Modifier
                .padding(top = 2.dp)
                .size(20.dp)
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(absent.name, style = MaterialTheme.typography.titleSmall)
            Text(
                absent.why,
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
    }
}
