package app.entesaver.ui.screens

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.BatterySaver
import androidx.compose.material.icons.outlined.Compress
import androidx.compose.material.icons.outlined.Gavel
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.Straighten
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.BuildConfig
import app.entesaver.R
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.Platform
import app.entesaver.core.logic.QualityKept
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.Routes
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.BrandMark
import app.entesaver.ui.components.KeyValueRow
import app.entesaver.ui.components.PhotosIcon
import app.entesaver.ui.components.ShortcutDialog
import app.entesaver.ui.goTo
import app.entesaver.util.Errand
import app.entesaver.util.Formats
import app.entesaver.util.OemPages
import app.entesaver.util.PhoneLimits
import app.entesaver.util.PhotosShortcut
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun HelpPage(
    nav: NavHostController,
    title: String,
    content: @Composable () -> Unit
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
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
            // A share of the row rather than whatever the title asks for.
            // Beside the back arrow at the largest accessibility font a title
            // like "Quality explained" is wider than a 320 dp phone, and with
            // nothing holding it the end of it was simply drawn past the edge
            // of the screen. A weight lets it wrap onto a second line instead.
            Text(
                title,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
        }
        Spacer(Modifier.height(8.dp))
        content()
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
fun HelpScreen(vm: AppViewModel, nav: NavHostController) {
    HelpPage(nav, stringResource(R.string.nav_help)) {
        HelpLink(stringResource(R.string.help_faq)) { nav.goTo(Routes.HELP_FAQ) }
        HelpLink(stringResource(R.string.help_deleted)) { nav.goTo(Routes.HELP_DELETED) }
        // The page this opens is titled "Quality explained", and Settings calls
        // it that too. Only this link ever said "Quality & Technology", so
        // tapping it landed you somewhere apparently else.
        HelpLink(stringResource(R.string.quality_explained_title)) {
            nav.goTo(Routes.HELP_QUALITY)
        }
        HelpLink(stringResource(R.string.help_cloud)) { nav.goTo(Routes.HELP_CLOUD) }
        HelpLink(stringResource(R.string.help_ente_features)) { nav.goTo(Routes.HELP_ENTE_FEATURES) }
        HelpLink(stringResource(R.string.help_gallery)) { nav.goTo(Routes.HELP_GALLERY) }
        HelpLink(stringResource(R.string.help_privacy)) { nav.goTo(Routes.HELP_PRIVACY) }
        HelpLink(stringResource(R.string.help_licenses)) { nav.goTo(Routes.HELP_LICENSES) }
        HelpLink(stringResource(R.string.help_about)) { nav.goTo(Routes.HELP_ABOUT) }
        Text(
            stringResource(R.string.about_version_line, BuildConfig.VERSION_NAME),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp),
            textAlign = TextAlign.Center
        )
    }
}

@Composable
internal fun HelpLink(label: String, onClick: () -> Unit) {
    AppCard(modifier = Modifier.padding(vertical = 4.dp), onClick = onClick) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // The label takes the room that is left and wraps; without a
            // weight a long one - or any one at 200% text - pushed the chevron
            // off the end of the card and out of the screen.
            Text(
                label,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f)
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp)
            )
        }
    }
}

private val FAQ = listOf(
    R.string.faq_q1 to R.string.faq_a1,
    R.string.faq_q2 to R.string.faq_a2,
    R.string.faq_q3 to R.string.faq_a3,
    R.string.faq_q4 to R.string.faq_a4,
    R.string.faq_q5 to R.string.faq_a5,
    R.string.faq_q6 to R.string.faq_a6,
    R.string.faq_q7 to R.string.faq_a7,
    R.string.faq_q8 to R.string.faq_a8,
    R.string.faq_q9 to R.string.faq_a9,
    R.string.faq_q10 to R.string.faq_a10,
    R.string.faq_q11 to R.string.faq_a11,
    R.string.faq_q12 to R.string.faq_a12,
    R.string.faq_q13 to R.string.faq_a13,
    R.string.faq_q14 to R.string.faq_a14,
    R.string.faq_q15 to R.string.faq_a15,
    R.string.faq_q16 to R.string.faq_a16,
    R.string.faq_q17 to R.string.faq_a17,
    R.string.faq_q18 to R.string.faq_a18,
    R.string.faq_q19 to R.string.faq_a19,
    R.string.faq_q20 to R.string.faq_a20
)

/**
 * Every place a file can disappear from, and what happens next (DD5).
 *
 * The FAQ answers these one at a time; this page is the whole map on one
 * screen, for the moment someone is actually worried. Six conditions, one
 * card each - a real table would fight large fonts and narrow phones.
 */
@Composable
fun HelpDeletedScreen(nav: NavHostController) {
    HelpPage(nav, stringResource(R.string.help_deleted)) {
        Text(
            stringResource(R.string.help_deleted_intro),
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(bottom = 8.dp)
        )
        val rows = listOf(
            R.string.deleted_r1_t to R.string.deleted_r1_b,
            R.string.deleted_r2_t to R.string.deleted_r2_b,
            R.string.deleted_r3_t to R.string.deleted_r3_b,
            R.string.deleted_r4_t to R.string.deleted_r4_b,
            R.string.deleted_r5_t to R.string.deleted_r5_b,
            R.string.deleted_r6_t to R.string.deleted_r6_b
        )
        for ((title, body) in rows) {
            AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
                Text(
                    stringResource(title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    stringResource(body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
        }
    }
}

@Composable
fun HelpFaqScreen(nav: NavHostController) {
    // Saveable, not just remembered: turning the phone while an answer is
    // open rebuilds the screen, and the answer someone was halfway
    // through reading closed itself every time.
    var open by rememberSaveable { mutableIntStateOf(-1) }
    HelpPage(nav, stringResource(R.string.help_faq)) {
        FAQ.forEachIndexed { index, (q, a) ->
            val expanded = open == index
            val arrow by animateFloatAsState(
                targetValue = if (expanded) 0f else -90f,
                label = "faqArrow"
            )
            // The turning arrow is the only sign an answer is open, and a
            // screen reader cannot see it turn: a question read the same
            // before and after the tap, with the answer arriving unannounced
            // underneath it.
            val state = stringResource(if (expanded) R.string.a11y_expanded else R.string.a11y_collapsed)
            AppCard(
                modifier = Modifier
                    .padding(vertical = 4.dp)
                    .semantics { stateDescription = state },
                onClick = { open = if (expanded) -1 else index }
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        stringResource(q),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f)
                    )
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .rotate(arrow)
                    )
                }
                AnimatedVisibility(
                    visible = expanded,
                    enter = fadeIn() + expandVertically(),
                    exit = fadeOut() + shrinkVertically()
                ) {
                    Text(
                        stringResource(a),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
            }
        }
        // The worry behind half these questions, gathered on one page.
        HelpLink(stringResource(R.string.faq_deleted_link)) {
            nav.goTo(Routes.HELP_DELETED)
        }
        // And the question question seven opens, answered step by step.
        HelpLink(stringResource(R.string.help_gallery)) {
            nav.goTo(Routes.HELP_GALLERY)
        }
    }
}

/**
 * What optimising does, in five short blocks and no jargon.
 *
 * The glossary is gone with the words it existed to explain: a page that has
 * to define "bits per pixel" before it can make its point was making the
 * wrong point. What is left is what happens, how small, how it looks, and
 * what this phone actually measured.
 */
@Composable
fun HelpQualityScreen(nav: NavHostController, vm: AppViewModel) {
    val measured by vm.measuredQuality.collectAsStateWithLifecycle()
    val kept by vm.detailKept.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.refreshMeasuredQuality() }

    val photoSpec = MediaSettings.PHOTO
    val videoSpec = MediaSettings.VIDEO

    HelpPage(nav, stringResource(R.string.quality_explained_title)) {
        // The one way files are optimised, in numbers, and how each file's
        // quality is checked - there is nothing to choose, so nothing to
        // guess about.
        AppCard(modifier = Modifier.padding(vertical = 4.dp), tonal = true) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Tune,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                // The heading takes the room left beside the icon and
                // wraps; unheld it ran past the card at a large text size.
                Text(
                    stringResource(R.string.quality_current_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(
                stringResource(R.string.quality_current_limits, photoLimitPhrase(photoSpec)),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 10.dp)
            )
            QualityKept.screenHeadroom(photoSpec)?.let { headroom ->
                Text(
                    stringResource(
                        R.string.quality_current_headroom,
                        // Every number the app prints goes through Formats, so
                        // this one is written the way the phone writes numbers.
                        Formats.count(headroom.roundToInt())
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
            // How it looks - deliberately separate from the pixel table
            // below, because "kept 33% of the pixels" and "looks the same"
            // are both true at once and the difference is the entire subject
            // of this screen.
            for (line in listOf(R.string.quality_looks_photo, R.string.quality_looks_video)) {
                Text(
                    stringResource(line),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
            Text(
                stringResource(R.string.quality_looks_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
        }

        QualityBlock(
            Icons.Outlined.AutoAwesome,
            stringResource(R.string.quality_what_title),
            stringResource(R.string.quality_what)
        )

        // Detail kept, per common size, on the preset that is actually on.
        AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Straighten,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                // The heading takes the room left beside the icon and
                // wraps; unheld it ran past the card at a large text size.
                Text(
                    stringResource(R.string.quality_detail_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(
                stringResource(R.string.quality_detail_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp, bottom = 4.dp)
            )
            for (mp in listOf(12.0, 24.0, 48.0)) {
                KeyValueRow(
                    stringResource(R.string.quality_detail_photo, mp.toInt()),
                    stringResource(
                        R.string.quality_detail_kept,
                        QualityKept.photoDetailKeptPercent(mp, photoSpec)
                    )
                )
            }
            for ((label, side) in listOf("1080p" to 1920, "4K" to 3840)) {
                KeyValueRow(
                    label,
                    stringResource(
                        R.string.quality_detail_kept,
                        QualityKept.videoDetailKeptPercent(side, videoSpec)
                    )
                )
            }
        }

        AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Compress,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                // The heading takes the room left beside the icon and
                // wraps; unheld it ran past the card at a large text size.
                Text(
                    stringResource(R.string.quality_table_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
            }
            // Said once, under the heading: the numbers below are one
            // preset's, and a preset switcher sits three lines above them.
            // A reader who changes the preset and watches this table not move
            // is entitled to think one of the two is broken.
            Text(
                stringResource(R.string.quality_table_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, bottom = 6.dp)
            )
            KeyValueRow(
                stringResource(R.string.quality_row1_k),
                stringResource(R.string.quality_row1_v)
            )
            KeyValueRow(
                stringResource(R.string.quality_row2_k),
                stringResource(R.string.quality_row2_v)
            )
            KeyValueRow(
                stringResource(R.string.quality_row3_k),
                stringResource(R.string.quality_row3_v)
            )
            KeyValueRow(
                stringResource(R.string.quality_row4_k),
                stringResource(R.string.quality_row4_v)
            )
        }

        QualityBlock(
            Icons.Outlined.Visibility,
            stringResource(R.string.quality_look_title),
            stringResource(R.string.quality_look)
        )

        // This phone's own numbers: the only figures on the page that are a
        // measurement rather than a guide.
        AppCard(modifier = Modifier.padding(vertical = 4.dp), tonal = measured.hasAny) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Insights,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                // The heading takes the room left beside the icon and
                // wraps; unheld it ran past the card at a large text size.
                Text(
                    stringResource(R.string.quality_measured_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
            }
            if (!measured.hasAny) {
                Text(
                    stringResource(R.string.quality_measured_none),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 6.dp)
                )
            } else {
                if (measured.photoCount > 0) {
                    Text(
                        stringResource(
                            R.string.quality_measured_photos,
                            "${measured.photoShrinkPercent}%",
                            Formats.count(measured.photoCount),
                            photoLimitPhrase(photoSpec)
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
                if (measured.videoCount > 0) {
                    Text(
                        stringResource(
                            R.string.quality_measured_videos,
                            "${measured.videoShrinkPercent}%",
                            Formats.count(measured.videoCount),
                            videoLimitPhrase(videoSpec)
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
            }
            // The one figure that answers "how much quality did I lose" with a
            // measurement instead of a policy: the pixels the encoder really
            // kept, averaged over the files it really encoded.
            kept?.let { k ->
                HorizontalDivider(Modifier.padding(vertical = 12.dp))
                Text(
                    stringResource(R.string.quality_kept_overall, k.percent),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    pluralStringResource(R.plurals.quality_kept_overall_sub, k.files, k.files),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
        }

        QualityBlock(
            Icons.Outlined.Movie,
            stringResource(R.string.quality_codec_title),
            stringResource(R.string.quality_codec_text)
        )

        Text(
            stringResource(R.string.quality_originals_safe),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 12.dp)
        )
    }
}

/** One titled block of the quality page. */
@Composable
private fun QualityBlock(
    icon: ImageVector,
    title: String,
    body: String
) {
    AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp)
            )
            Spacer(Modifier.width(10.dp))
            // The heading gets the rest of the row, so it wraps under itself
            // rather than running past the card at a large text size.
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
        }
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp)
        )
    }
}

@Composable
fun HelpPrivacyScreen(nav: NavHostController) {
    HelpPage(nav, stringResource(R.string.help_privacy)) {
        // Six short blocks with icons rather than one paragraph. The old wall
        // of text said all of this and nobody read any of it.
        PrivacyBlock(
            Icons.Outlined.WifiOff,
            stringResource(R.string.privacy_b1_title),
            stringResource(R.string.privacy_b1)
        )
        PrivacyBlock(
            Icons.Outlined.Visibility,
            stringResource(R.string.privacy_b2_title),
            stringResource(R.string.privacy_b2)
        )
        PrivacyBlock(
            Icons.Outlined.Storage,
            stringResource(R.string.privacy_b3_title),
            stringResource(R.string.privacy_b3)
        )
        PrivacyBlock(
            Icons.Outlined.Shield,
            stringResource(R.string.privacy_b4_title),
            stringResource(R.string.privacy_b4)
        )
        PrivacyBlock(
            Icons.Outlined.Info,
            stringResource(R.string.privacy_b5_title),
            stringResource(R.string.privacy_b5)
        )
        PrivacyBlock(
            Icons.Outlined.BatterySaver,
            stringResource(R.string.privacy_b7_title),
            stringResource(R.string.privacy_b7)
        )
        PrivacyBlock(
            Icons.Outlined.Gavel,
            stringResource(R.string.privacy_b6_title),
            stringResource(R.string.privacy_b6)
        )
    }
}

/** One titled block of the privacy page: icon, heading, three sentences. */
@Composable
private fun PrivacyBlock(
    icon: ImageVector,
    title: String,
    body: String
) {
    AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp)
            )
            Spacer(Modifier.width(10.dp))
            // The heading gets the rest of the row, so it wraps under itself
            // rather than running past the card at a large text size.
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
        }
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp)
        )
    }
}

@Composable
fun HelpLicensesScreen(nav: NavHostController) {
    HelpPage(nav, stringResource(R.string.help_licenses)) {
        AppCard {
            Text(
                stringResource(R.string.licenses_intro),
                style = MaterialTheme.typography.bodyMedium
            )
            Text(
                stringResource(R.string.licenses_text),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 10.dp)
            )
        }
    }
}

@Composable
fun HelpAboutScreen(vm: AppViewModel, nav: NavHostController) {
    val options by vm.options.collectAsStateWithLifecycle()
    val context = LocalContext.current
    HelpPage(nav, stringResource(R.string.help_about)) {
        AppCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BrandMark(size = 52.dp)
                // The mark keeps its size; the words beside it take what is
                // left. Without a weight the version line was measured at the
                // width it wanted and, at a large text size on a narrow phone,
                // that width was past the edge of the card.
                Column(
                    Modifier
                        .weight(1f)
                        .padding(start = 12.dp)
                ) {
                    Text(
                        stringResource(R.string.app_name),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        stringResource(R.string.about_version_line, BuildConfig.VERSION_NAME),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Text(
                stringResource(R.string.app_tagline),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 14.dp)
            )
            Text(
                stringResource(R.string.about_text),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp)
            )
            Text(
                stringResource(R.string.about_partner),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp)
            )
        }
        // What the app is for, said once, on the page a person opens to ask
        // exactly that. Everything else here describes how it behaves; this
        // is the only card that says why any of it is worth doing.
        AppCard(modifier = Modifier.padding(top = 10.dp)) {
            Text(
                stringResource(R.string.about_mission_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                stringResource(R.string.about_mission_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
        // What this phone gets, and nothing about any other phone. Version
        // ranges and "2019 onwards" made a reader work out whether the
        // sentence applied to them; this one already knows.
        AppCard(modifier = Modifier.padding(top = 10.dp)) {
            Text(
                stringResource(R.string.about_requires_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
            val release = Platform.releaseName(Build.VERSION.SDK_INT, Build.VERSION.RELEASE)
            val full = Platform.supportFor(Build.VERSION.SDK_INT) ==
                Platform.Support.FULL
            // What the app needs, then what this particular phone gets. The
            // first is the question someone asks before installing; the
            // second is the only one the phone in their hand can answer.
            Text(
                stringResource(R.string.about_requires_min),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
            Text(
                stringResource(
                    if (full) R.string.about_running_full else R.string.about_running_ten,
                    release
                ),
                style = MaterialTheme.typography.bodyMedium,
                color = if (full) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.error
                },
                modifier = Modifier.padding(top = 6.dp)
            )
            // Only what limits Ente Saver here, each with what it does
            // instead. Read off the phone, so it never claims a limit this
            // phone does not have.
            val limits by produceState<List<String>?>(null, options.minFreeBytes, options.storageVolume) {
                value = withContext(Dispatchers.IO) {
                    PhoneLimits.lines(context, options.minFreeBytes, options.storageVolume)
                }
            }
            limits?.let { lines ->
                for (line in lines.ifEmpty { listOf(stringResource(R.string.limit_none)) }) {
                    Text(
                        "\u2022 $line",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }
        }

        // What it may access, said on the page where someone checks. A
        // permission list is one of the few things an About page owes a
        // reader, and it is two sentences here rather than a settings dive.
        AppCard(modifier = Modifier.padding(top = 10.dp)) {
            Text(
                stringResource(R.string.about_permissions_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                stringResource(R.string.about_permissions_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
        }

        // What a person actually checks here: that the app cannot reach the
        // internet. The build-chain facts that used to fill this card -
        // package name, build number, the signing fingerprint - are
        // release-page material and ship in the release notes instead. The
        // app is finished software: nothing here talks about updating it,
        // because there is nothing to update to.
        AppCard(modifier = Modifier.padding(top = 10.dp)) {
            Text(
                stringResource(R.string.about_network_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                stringResource(R.string.about_network_none),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        // The setting a reader is most likely to want from this page, shown as
        // a fact with one way to act on it. The control itself stays on Quality
        // explained: two places to change the same thing is two places to
        // disagree about what it currently is.
        AppCard(
            modifier = Modifier.padding(top = 10.dp),
            onClick = { nav.goTo(Routes.HELP_QUALITY) }
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Tune,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                // The heading takes the room left beside the icon and
                // wraps; unheld it ran past the card at a large text size.
                Text(
                    stringResource(R.string.about_quality_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(
                stringResource(
                    R.string.about_quality_line,
                    photoLimitPhrase(MediaSettings.PHOTO),
                    videoLimitPhrase(MediaSettings.VIDEO)
                ),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp)
            )
            Text(
                stringResource(R.string.about_quality_change),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        // Where the app comes from and where to say something is wrong: the
        // two questions an About page is opened for, after "what is this".
        AppCard(modifier = Modifier.padding(top = 10.dp)) {
            Text(
                stringResource(R.string.about_source_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                stringResource(R.string.about_source_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
            TextButton(onClick = { OemPages.openWebPage(context, OemPages.RELEASES_URL) }) {
                Text(stringResource(R.string.about_source_open))
            }
            TextButton(onClick = { OemPages.openWebPage(context, OemPages.ISSUES_URL) }) {
                Text(stringResource(R.string.about_issue_open))
            }
        }

        AppCard(modifier = Modifier.padding(top = 10.dp), onClick = { nav.goTo(Routes.HELP_PRIVACY) }) {
            Text(
                stringResource(R.string.help_privacy),
                style = MaterialTheme.typography.titleSmall
            )
            Text(
                stringResource(R.string.about_privacy_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
        // Other apps are named in this one, and drawn in their own colours,
        // so a person can find theirs. Saying whose names they are, and that
        // this app is none of theirs, is the least that is owed.
        Text(
            stringResource(R.string.about_trademarks),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 14.dp)
        )
    }
}

/**
 * Everything about the other half of the job, in one place.
 *
 * Why Ente Photos, in one place: why a second app at all, why Ente, the one
 * setting that matters in it, what having everything in one place gives,
 * how Ente Saver knows a copy arrived, what happens before Ente is
 * installed, and what happened to copies sent through another app before.
 */
@Composable
fun HelpCloudScreen(nav: NavHostController) {
    HelpPage(nav, stringResource(R.string.help_cloud)) {
        CloudHelpBlock(R.string.cloudhelp_intro_t, R.string.cloudhelp_intro_b)
        CloudHelpBlock(R.string.cloudhelp_which_t, R.string.cloudhelp_which_b)
        CloudHelpBlock(R.string.cloudhelp_setup_t, R.string.cloudhelp_setup_b)
        CloudHelpBlock(R.string.cloudhelp_detect_t, R.string.cloudhelp_detect_b)
        CloudHelpBlock(R.string.cloudhelp_proof_t, R.string.cloudhelp_proof_b)
        CloudHelpBlock(R.string.cloudhelp_none_t, R.string.cloudhelp_none_b)
        CloudHelpBlock(R.string.cloudhelp_switch_t, R.string.cloudhelp_switch_b)
    }
}

@Composable
private fun CloudHelpBlock(title: Int, body: Int) {
    AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            stringResource(body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp)
        )
    }
}

/**
 * How to make Ente the phone's gallery, so there is one photo app and no
 * confusion: the default app, the icon (Ente's own choices or this app's
 * icon pack), a "Photos" shortcut, Ente's on-device search, and why Ente's
 * Free up space also empties Ente Saver's folder.
 */
@Composable
fun HelpGalleryScreen(nav: NavHostController) {
    val context = LocalContext.current
    var adding by rememberSaveable { mutableStateOf(false) }
    HelpPage(nav, stringResource(R.string.help_gallery)) {
        Text(
            stringResource(R.string.gallery_intro),
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(vertical = 4.dp)
        )
        GalleryBlock(R.string.gallery_default_t, R.string.gallery_default_b) {
            OutlinedButton(onClick = {
                val intent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                Errand.begin()
                if (runCatching { context.startActivity(intent) }.isFailure) {
                    Errand.cancel()
                    runCatching {
                        Errand.begin()
                        context.startActivity(
                            Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }.onFailure { Errand.cancel() }
                }
            }) { Text(stringResource(R.string.gallery_default_button)) }
        }
        GalleryBlock(R.string.gallery_icon_t, R.string.gallery_icon_b)
        GalleryBlock(R.string.gallery_pack_t, R.string.gallery_pack_b) {
            PhotosIcon()
        }
        GalleryBlock(R.string.gallery_shortcut_t, R.string.gallery_shortcut_b) {
            if (PhotosShortcut.supported(context)) {
                OutlinedButton(onClick = { adding = true }) {
                    Text(stringResource(R.string.gallery_shortcut_button))
                }
            } else {
                Text(
                    stringResource(R.string.shortcut_unsupported),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        GalleryBlock(R.string.gallery_rename_t, R.string.gallery_rename_b)
        GalleryBlock(R.string.gallery_ml_t, R.string.gallery_ml_b)
        GalleryBlock(R.string.gallery_freeup_t, R.string.gallery_freeup_b)
    }
    if (adding) ShortcutDialog(onDone = { adding = false })
}

@Composable
private fun GalleryBlock(title: Int, body: Int, extra: (@Composable () -> Unit)? = null) {
    AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            stringResource(body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp)
        )
        if (extra != null) {
            Spacer(Modifier.padding(top = 8.dp))
            extra()
        }
    }
}

@Composable
fun HelpEnteFeaturesScreen(nav: NavHostController, vm: AppViewModel) {
    HelpPage(nav, stringResource(R.string.help_ente_features)) {
        Text(
            stringResource(R.string.feat_intro),
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(vertical = 4.dp)
        )
        for (feature in ENTE_FEATURES) {
            AppCard(modifier = Modifier.padding(vertical = 4.dp)) {
                Text(
                    stringResource(feature.name),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                FeatureLine(R.string.feat_who_phone, feature.phone, feature.phoneSays)
                FeatureLine(R.string.feat_who_ente, feature.ente, feature.enteSays)
                FeatureLine(R.string.feat_who_saver, feature.saver, feature.saverSays)
                feature.guide?.let { url ->
                    TextButton(onClick = { vm.openEnteHelp(url) }) { Text(stringResource(R.string.hub_ente_guide)) }
                }
            }
        }
        Text(
            stringResource(R.string.feat_footer),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp)
        )
    }
}

/** "✓ Ente Photos: Settings › Backup › …": the mark, who, and what. */
@Composable
private fun FeatureLine(who: Int, has: Has, says: Int) {
    val scheme = MaterialTheme.colorScheme
    val (mark, word, colour) = when (has) {
        Has.YES -> Triple("✓", stringResource(R.string.feat_yes), scheme.primary)
        Has.PARTLY -> Triple("◐", stringResource(R.string.feat_partly), scheme.tertiary)
        Has.NO -> Triple("✗", stringResource(R.string.feat_no), scheme.error)
    }
    val whoText = stringResource(who)
    val saysText = stringResource(says)
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .padding(top = 6.dp)
            .semantics(mergeDescendants = true) { contentDescription = "$whoText: $word. $saysText" }
    ) {
        Text(
            mark,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = colour,
            modifier = Modifier.width(22.dp)
        )
        Text(
            "$whoText — $saysText",
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
    }
}
