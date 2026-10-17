package app.entesaver.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import app.entesaver.R
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.PhotoFormat
import app.entesaver.core.logic.PhotoSpec
import app.entesaver.core.logic.VideoCodec
import app.entesaver.core.logic.VideoSpec
import app.entesaver.media.HeicSupport
import app.entesaver.ui.AppViewModel
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
