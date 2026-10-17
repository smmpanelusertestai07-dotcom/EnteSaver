package app.entesaver.ui.screens

import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.CloudQueue
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import app.entesaver.R
import app.entesaver.core.logic.CapacityMath
import app.entesaver.core.logic.MediaSettings
import app.entesaver.data.EnteApp
import app.entesaver.ui.AppViewModel
import app.entesaver.ui.components.AccessNotice
import app.entesaver.ui.components.AnimatedNumber
import app.entesaver.ui.components.AppCard
import app.entesaver.ui.components.HeroCard
import app.entesaver.ui.components.MetricGrid
import app.entesaver.ui.components.MetricTile
import app.entesaver.ui.components.SectionHeader
import app.entesaver.ui.theme.BrandTile
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.MetricTextStyle
import app.entesaver.ui.theme.OnBrand
import app.entesaver.ui.theme.OnBrandMuted
import app.entesaver.ui.theme.TabularFigures
import app.entesaver.util.Formats
import java.util.Locale

/**
 * "How much of my gallery fits in my cloud?"
 *
 * A screen of its own, and measured only. It used to carry a My-files/Typical
 * selector and a photo-to-video slider, which asked the user to supply two
 * numbers the app already knows: the split comes from their actual gallery,
 * and whether the ratios are measured is a fact, not a preference. Both are
 * gone. What is left is one thing to type and the answer.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CalculatorScreen(vm: AppViewModel, nav: NavHostController) {
    val options by vm.options.collectAsStateWithLifecycle()
    val gallery by vm.calcGallery.collectAsStateWithLifecycle()
    val mediaAccess by vm.mediaAccess.collectAsStateWithLifecycle()
    val ratios by vm.calcRatios.collectAsStateWithLifecycle()
    val profile by vm.profile.collectAsStateWithLifecycle()
    val scheme = MaterialTheme.colorScheme

    LaunchedEffect(options.excludedBuckets) {
        vm.refreshCalculator()
        vm.refreshProfile()
    }

    // Saveable: turning the phone mid-typing must not wipe the figure.
    var freeText by rememberSaveable { mutableStateOf("") }
    var prefilled by rememberSaveable { mutableStateOf(false) }
    // Ente's free plan as a starting point - editable, and labelled as a
    // prefill, never presented as the person's own figure.
    LaunchedEffect(Unit) {
        if (!prefilled && freeText.isEmpty()) {
            freeText = EnteApp.FREE_PLAN_GB.toString()
            prefilled = true
        }
    }

    val freeGb = freeText.replace(',', '.').toDoubleOrNull()
    // The real split of this gallery. No slider, because the answer is not a
    // matter of opinion.
    val share = gallery?.let { CapacityMath.defaultMixShare(it) } ?: 0.5
    val estimate = remember(freeGb, share, gallery, ratios) {
        val g = gallery
        val r = ratios
        if (freeGb != null && freeGb > 0 && g != null && r != null) {
            CapacityMath.estimate(freeGb, CapacityMath.CalcMode.BOTH, share, g, r)
        } else {
            null
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            // This is the one screen in the app with a keyboard on it, and a
            // landscape phone with the keyboard up has around two hundred dp
            // of height left. Without this the field being typed into sits
            // underneath the keyboard and the answer sits under that.
            .keyboardPadding()
            // The title scrolls with everything else rather than being pinned
            // above it. Pinned, it kept its full height out of a viewport a
            // keyboard had already cut to a strip - at the largest font the
            // header alone is taller than what was left, so the page below it
            // had nowhere to draw at all.
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
            // A share of the row rather than whatever the title wants. Beside
            // the arrow at the largest font "Cloud calculator" is wider than a
            // small phone, and with nothing holding it the end of the title
            // was drawn past the edge of the screen. A weight lets it wrap.
            Text(
                stringResource(R.string.calc_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
        }

        Column(Modifier.padding(horizontal = Dimens.Screen)) {
            // 1. The one thing the app cannot know.
            AppCard {
                // Only a number can ever be in here.
                //
                // Decimal is a keyboard hint and nothing more: it asks the
                // system for a numeric pad, it does not stop anything else
                // arriving. A physical keyboard, a pasted line, a keyboard
                // that shows letters anyway - all of them put text in this
                // field that toDoubleOrNull cannot read, and the whole page
                // below then collapsed to "Enter your free space" with no
                // explanation, as though the app had simply lost interest in
                // what had just been typed. Filtering as it is typed means
                // the unusable character never lands: what appears in the
                // field is always something the calculator can answer.
                //
                // The field carries its own name. The words used to sit above
                // it as a separate line, so a screen reader landed on an edit
                // box called nothing at all - on the one screen whose whole
                // question is what to type into it. As the label they are the
                // field's name, and they stay on it once a number is typed.
                OutlinedTextField(
                    value = freeText,
                    onValueChange = { freeText = numericOnly(it) },
                    singleLine = true,
                    label = { Text(stringResource(R.string.calc_input_label)) },
                    leadingIcon = { Icon(Icons.Outlined.CloudQueue, contentDescription = null) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth()
                )
                // The six common plan sizes, flowing rather than scrolling
                // sideways. As a horizontal scroller the last three were off
                // the edge behind a gesture nobody makes on a form, and at the
                // largest font on a 320 dp phone only two were ever in view.
                // Flowed, every preset is visible at any width: the group gets
                // taller instead of running off the end.
                val presets = remember { listOf(5, 10, 20, 50, 100, 200) }
                FlowRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (gb in presets) {
                        FilterChip(
                            selected = freeText == gb.toString(),
                            onClick = { freeText = gb.toString() },
                            label = {
                                Text(
                                    stringResource(R.string.calc_chip_gb, gb),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        )
                    }
                }
                Text(
                    stringResource(R.string.calc_check_inside),
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }

            Spacer(Modifier.height(12.dp))
            // BB1.3: without full access every total would describe the
            // user's selection - or a database nothing is refreshing - rather
            // than their gallery. Waiting text, never a number.
            if (AccessNotice.isLimited(mediaAccess)) {
                AppCard {
                    Text(
                        stringResource(AccessNotice.waiting(mediaAccess)),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.height(28.dp))
                return@Column
            }
            if (estimate == null) {
                AppCard {
                    Text(
                        stringResource(R.string.calc_enter),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.height(28.dp))
                return@Column
            }

            // 2. The answer.
            HeroCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Outlined.CloudQueue,
                        contentDescription = null,
                        tint = OnBrandMuted,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        stringResource(R.string.calc_hero_label),
                        style = MaterialTheme.typography.labelLarge,
                        color = OnBrandMuted
                    )
                }
                AnimatedNumber(
                    value = stringResource(R.string.calc_hero_value, fmt(estimate.originalsGB)),
                    style = calcHeroFigureStyle(),
                    color = OnBrand,
                    modifier = Modifier.padding(top = 4.dp)
                )
                Text(
                    stringResource(R.string.calc_hero_caption, fmt(freeGb ?: 0.0)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = OnBrandMuted
                )
                // CC8: the badge sits inside the result box, not only in the
                // basis line at the foot. A big number read alone is taken as
                // fact; the qualifier has to travel with it.
                Spacer(Modifier.height(10.dp))
                // A shade darker than the banner, not a white wash: white words
                // on a white wash over green came to under 4:1.
                Surface(
                    color = BrandTile,
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Text(
                        stringResource(
                            if (estimate.typicalEstimate) R.string.calc_badge_typical
                            else R.string.calc_badge_measured
                        ),
                        style = MaterialTheme.typography.labelMedium,
                        color = OnBrand,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                    )
                }
                if (estimate.typicalEstimate) {
                    Text(
                        stringResource(R.string.calc_badge_typical_line),
                        style = MaterialTheme.typography.bodySmall,
                        color = OnBrandMuted,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            // Photos got a count and videos only got hours, so the two halves
            // of the same answer could not be compared. Videos now get a count
            // too, worked out from how long this phone's own clips are; when
            // there are no videos to average, the count is absent rather than
            // invented and hours stand alone.
            MetricGrid(
                buildList {
                    add { m: Modifier ->
                        MetricTile(
                            Formats.count(estimate.photoCount),
                            stringResource(R.string.calc_tile_photos),
                            m,
                            icon = Icons.Outlined.PhotoLibrary
                        )
                    }
                    if (estimate.videoCount > 0) {
                        add { m: Modifier ->
                            MetricTile(
                                Formats.count(estimate.videoCount),
                                stringResource(R.string.calc_tile_videos),
                                m,
                                icon = Icons.Outlined.Movie
                            )
                        }
                    }
                    add { m: Modifier ->
                        MetricTile(
                            Formats.hours(estimate.videoHours),
                            stringResource(R.string.calc_tile_video_hours),
                            m,
                            icon = Icons.Outlined.Schedule
                        )
                    }
                }
            )

            // 3. Their gallery against that.
            SectionHeader(stringResource(R.string.calc_your_gallery))
            val galleryGb = gallery?.let {
                (it.photoBytes + it.videoBytes) / CapacityMath.GB
            } ?: 0.0
            AppCard(tonal = estimate.fits) {
                Text(
                    stringResource(
                        R.string.calc_gallery_line, fmt(galleryGb), fmt(estimate.backlogGB)
                    ),
                    style = MaterialTheme.typography.bodyMedium.merge(TabularFigures),
                    color = if (estimate.fits) scheme.onPrimaryContainer else scheme.onSurface
                )
                Text(
                    if (estimate.fits) {
                        stringResource(
                            R.string.calc_spare,
                            fmt(((freeGb ?: 0.0) - estimate.backlogGB).coerceAtLeast(0.0))
                        )
                    } else {
                        stringResource(R.string.calc_needs, fmt(estimate.needMoreGB))
                    },
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (estimate.fits) scheme.onPrimaryContainer else scheme.error,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }

            // 4. Pace, only with enough history to mean anything.
            val monthlyGb = gallery?.let {
                (it.monthlyPhotoBytes + it.monthlyVideoBytes) / CapacityMath.GB
            } ?: 0.0
            if (monthlyGb > 0 && estimate.fits && estimate.monthsLeft >= 0) {
                Spacer(Modifier.height(4.dp))
                AppCard {
                    // Top-aligned: the pace sentence carries a figure inside
                    // it and wraps to two lines on a narrow phone, and the
                    // speedometer then sat between the two rather than at the
                    // start of the sentence it introduces.
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Outlined.Speed,
                            contentDescription = null,
                            tint = scheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp)
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            stringResource(R.string.calc_pace, fmt(monthlyGb)),
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    Text(
                        stringResource(R.string.calc_months, fmt(estimate.monthsLeft)),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp, start = 30.dp)
                    )
                }
            }

            // 5. Quality, always visible - it is the reason the numbers work.
            SectionHeader(stringResource(R.string.calc_quality_header))
            AppCard {
                // All three rows in this card are top-aligned rather than
                // centred. Every one of them is a whole sentence beside an
                // 18 dp icon - the unmeasured wording is two sentences - so at
                // any font size above the smallest they run to several lines,
                // and a centred icon floated in the middle of the paragraph
                // with white space above and below it. Level with the first
                // line, the icon reads as what it is: the mark for that line.
                Row(verticalAlignment = Alignment.Top) {
                    Icon(
                        Icons.Outlined.PhotoLibrary,
                        contentDescription = null,
                        tint = scheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    // A measured figure or an admission, never a number
                    // invented from an unmeasured ratio of zero.
                    Text(
                        profile.photos.shrinkPercent?.let {
                            stringResource(R.string.calc_quality_photos, it)
                        } ?: stringResource(R.string.calc_quality_photos_none),
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Row(
                    verticalAlignment = Alignment.Top,
                    modifier = Modifier.padding(top = 6.dp)
                ) {
                    Icon(
                        Icons.Outlined.Movie,
                        contentDescription = null,
                        tint = scheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        profile.videos.shrinkPercent?.let {
                            stringResource(R.string.calc_quality_videos, it)
                        } ?: stringResource(R.string.calc_quality_videos_none),
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Row(
                    verticalAlignment = Alignment.Top,
                    modifier = Modifier.padding(top = 6.dp)
                ) {
                    Icon(
                        Icons.Outlined.Tune,
                        contentDescription = null,
                        tint = scheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        stringResource(
                            R.string.calc_quality_limits,
                            photoLimitPhrase(MediaSettings.PHOTO),
                            videoLimitPhrase(MediaSettings.VIDEO)
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant
                    )
                }
            }

            // 6. Where the figures came from. Never hidden behind an expander:
            // a number whose basis is invisible cannot be argued with.
            Text(
                if (estimate.typicalEstimate) {
                    stringResource(R.string.calc_basis_rough)
                } else {
                    stringResource(
                        R.string.calc_basis_measured,
                        Formats.count(profile.photos.samples),
                        Formats.count(profile.videos.samples)
                    )
                },
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 14.dp)
            )
            // Whose gallery these numbers describe. Without it the page reads
            // as generic advice about clouds rather than an answer about this
            // phone, which is the only thing it is.
            Text(
                stringResource(R.string.calc_source_note),
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp)
            )
            Spacer(Modifier.height(28.dp))
        }
    }
}

/**
 * GB to two decimals, the way a cloud plan is written.
 *
 * Two significant figures rounded 1.04 GB to 1.0 and 12.4 to 12, which read
 * as different precisions on the same screen and made small differences
 * vanish. Plans are sold in GB, so the calculator counts in GB.
 */
private fun fmt(v: Double): String = String.format(Locale.US, "%.2f", v)

/**
 * What is allowed to survive being typed into the free-space field.
 *
 * Digits, and one decimal separator - either the dot or the comma, because
 * both are written on real keyboards and the reader further up accepts
 * either. Everything else is dropped as it arrives rather than being shown
 * and then quietly ignored, so the field can never hold a value the answer
 * below it cannot be worked out from.
 *
 * Only the plain ASCII digits count. Char.isDigit is true of the digits of
 * every script Unicode knows, and a number written in those would look
 * perfectly typed here and still come back as nothing from toDoubleOrNull.
 */
private fun numericOnly(raw: String): String {
    val out = StringBuilder()
    var separatorTaken = false
    for (ch in raw) {
        when {
            ch in '0'..'9' -> out.append(ch)
            (ch == '.' || ch == ',') && !separatorTaken -> {
                separatorTaken = true
                out.append(ch)
            }
        }
    }
    return out.toString()
}

/**
 * The answer's own type size, held to a width a small phone actually has.
 *
 * The figure is one line that never wraps, so at the largest accessibility
 * font "1,234.56 GB" is wider than a 320 dp screen and the end of it - the
 * unit, and the digits just before it - is the half that gets cut. Past 1.4x
 * the figure stops growing with the setting: it is already by far the biggest
 * thing on the page, and a number shown whole is worth more than a number
 * shown large. Everything else on the screen keeps scaling normally, so the
 * accessibility setting still does what it was turned on to do.
 */
@Composable
private fun calcHeroFigureStyle(): TextStyle {
    val cap = 1.4f
    val scale = LocalDensity.current.fontScale
    if (scale <= cap) return MetricTextStyle
    val factor = cap / scale
    return MetricTextStyle.copy(
        fontSize = MetricTextStyle.fontSize * factor,
        lineHeight = MetricTextStyle.lineHeight * factor
    )
}

/**
 * Room for the keyboard, made exactly once.
 *
 * The keyboard is a window inset from Android 11 (API 30); that is the
 * version that added the type, and it is what `imePadding` reads. Below it
 * there is no such inset to read, and the room is made the old way instead -
 * the manifest asks for `adjustResize` and the system shrinks the whole
 * window before this screen is measured at all.
 *
 * Adding padding on top of that shrink takes the keyboard's height out of the
 * page twice. On Android 10 that left a strip so short the answer card was cut
 * between its label and its figure: the words "Fits about" were on screen and
 * the number they introduce was not - which is how the emulator suite found
 * it, on API 29 alone, while every later version passed.
 */
private fun Modifier.keyboardPadding(): Modifier =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) imePadding() else this
