package app.entesaver.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.entesaver.R
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.PhotoFormat
import app.entesaver.core.logic.PhotoSpec
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.VideoCodec
import app.entesaver.core.logic.VideoSpec
import app.entesaver.media.HeicSupport
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.components.SegmentedChoice
import app.entesaver.util.DeviceTier

/**
 * The Optimisation card: nothing to choose, only what this phone will do.
 * There is one way to optimise - Storage saver's size limits, each file at
 * the quality it measures it needs - so the card says it in the phone's own
 * terms: its memory's photo ceiling, and whether its chip makes HEVC.
 */
@Composable
fun OptimisationCard(plan: AppViewModel.EncodePlan, icon: ImageVector, onInfo: () -> Unit) {
    OptionCard(
        stringResource(R.string.opt_optimise),
        stringResource(R.string.opt_optimise_hint),
        icon = icon,
        value = stringResource(R.string.optimise_value),
        onInfo = onInfo
    ) {
        val shown = DeviceTier.capped(MediaSettings.PHOTO, plan.photoCeilingMp)
        ChoiceNote(
            stringResource(
                R.string.optimise_photos,
                if (shown.maxMp != MediaSettings.PHOTO.maxMp && plan.photoCeilingIsPhones) {
                    stringResource(R.string.photo_size_mp_phone, shown.maxMp)
                } else {
                    photoLimitPhrase(shown)
                }
            )
        )
        ChoiceNote(stringResource(R.string.optimise_videos, codecLabel(plan.videoCodec)))
        ChoiceNote(
            stringResource(
                when (plan.heic) {
                    HeicSupport.State.OK -> R.string.photo_heic_ok
                    HeicSupport.State.FAIL -> R.string.photo_heic_fail
                    HeicSupport.State.UNKNOWN -> R.string.photo_heic_unknown
                }
            )
        )
        ChoiceNote(stringResource(if (plan.hevcHardware) R.string.video_hevc_ok else R.string.video_hevc_none))
        ChoiceNote(stringResource(R.string.optimise_kept_whole))
    }
}

/**
 * Saving space: whether each original is replaced where it is, or a copy is
 * made for Ente. The one choice that decides what happens to a person's own
 * files, so each side says plainly what it does - and Replace on this phone
 * says what Android must allow first, and why that is safe.
 */
@Composable
fun SaveModeCard(
    mode: SaveMode,
    fileAccess: Boolean,
    icon: ImageVector,
    onMode: (SaveMode) -> Unit,
    onGrant: () -> Unit
) {
    OptionCard(
        stringResource(R.string.opt_save_mode),
        stringResource(R.string.opt_save_mode_hint),
        icon = icon,
        value = saveModeLabel(mode)
    ) {
        SegmentedChoice(
            SaveMode.entries.map { it.name to saveModeLabel(it) },
            mode.name
        ) { onMode(SaveMode.valueOf(it)) }
        if (mode == SaveMode.IN_PLACE) {
            ChoiceNote(stringResource(R.string.save_mode_in_place_note))
            ChoiceNote(stringResource(R.string.save_mode_in_place_ente))
            ChoiceNote(stringResource(R.string.save_mode_ente_folders))
            if (fileAccess) {
                ChoiceNote(stringResource(R.string.file_access_granted))
            } else {
                ChoiceNote(stringResource(R.string.file_access_needed))
                ChoiceNote(stringResource(R.string.file_access_safe))
                Button(onClick = onGrant, modifier = Modifier.padding(top = 8.dp)) {
                    Text(stringResource(R.string.file_access_grant))
                }
            }
        } else {
            ChoiceNote(stringResource(R.string.save_mode_copies_note))
            ChoiceNote(stringResource(R.string.save_mode_copies_limit))
        }
        ChoiceNote(stringResource(R.string.save_mode_switch_note))
    }
}

@Composable
fun saveModeLabel(mode: SaveMode): String = stringResource(
    when (mode) {
        SaveMode.IN_PLACE -> R.string.save_mode_in_place
        SaveMode.COPIES -> R.string.save_mode_copies
    }
)

@Composable
fun formatLabel(format: PhotoFormat): String = stringResource(
    when (format) {
        PhotoFormat.HEIC -> R.string.format_heic
        PhotoFormat.JPEG -> R.string.format_jpeg
        PhotoFormat.WEBP -> R.string.format_webp
        PhotoFormat.PNG -> R.string.format_png
    }
)

@Composable
fun codecLabel(codec: VideoCodec): String = stringResource(
    if (codec == VideoCodec.HEVC) R.string.codec_hevc else R.string.codec_h264
)

/** "up to 16 MP" or "full size", for sentences about the size limit. */
@Composable
fun photoLimitPhrase(spec: PhotoSpec): String =
    if (spec.maxMp <= 0) {
        stringResource(R.string.photo_size_full)
    } else {
        stringResource(R.string.photo_size_mp, spec.maxMp)
    }

/** "up to 1080p" or "as filmed". */
@Composable
fun videoLimitPhrase(spec: VideoSpec): String =
    if (spec.longSide <= 0) {
        stringResource(R.string.res_keep)
    } else {
        stringResource(R.string.video_size_p, MediaSettings.pLabel(spec.longSide))
    }
