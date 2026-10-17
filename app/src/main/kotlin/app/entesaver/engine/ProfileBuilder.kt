package app.entesaver.engine

import android.content.Context
import app.entesaver.core.logic.MediaProfile
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.MediaProfileRow
import app.entesaver.data.db.RatioSample
import app.entesaver.data.prefs.Options
import app.entesaver.media.MediaScanner
import app.entesaver.media.PlannedEncode

/**
 * Recomputes what this phone's media actually looks like.
 *
 * Everything the app estimates comes from here, which is why it is measured
 * per preset and codec: a ratio taken at Max saver says nothing about what
 * Balanced would produce, and quoting one for the other would be a number the
 * app cannot stand behind.
 */
class ProfileBuilder(private val context: Context) {

    private val db = AppDb.get(context)

    suspend fun rebuild(options: Options, now: Long = System.currentTimeMillis()): MediaProfileRow {
        val scanner = MediaScanner(context, db)
        val totals = runCatching { scanner.totals(options.excludedBuckets, now) }
            .getOrDefault(MediaScanner.Totals())

        val photoKey = PlannedEncode.photoKey()
        val videoKey = PlannedEncode.videoKey()
        val photoSamples = db.items().photoRatioSamples(photoKey)
        val videoSamples = db.items().videoRatioSamples(videoKey)

        val photoMedian = MediaProfile.median(photoSamples.map { it.sizeBytes })
        val videoMedian = MediaProfile.median(videoSamples.map { it.sizeBytes })
        val galleryPhotoMedian = if (totals.photoCount > 0) {
            totals.photoBytes / totals.photoCount
        } else {
            0L
        }
        val galleryVideoMedian = if (totals.videoCount > 0) {
            totals.videoBytes / totals.videoCount
        } else {
            0L
        }

        val photoMeasured =
            MediaProfile.isMeasured(photoSamples.size, photoMedian, galleryPhotoMedian)
        val videoMeasured =
            MediaProfile.isMeasured(videoSamples.size, videoMedian, galleryVideoMedian)

        fun ratio(rows: List<RatioSample>): Double {
            val original = rows.sumOf { it.sizeBytes }
            if (original <= 0) return 0.0
            return rows.sumOf { it.outputBytes }.toDouble() / original
        }

        val videoMinutes = videoSamples.sumOf { it.durationMs / 60_000.0 }
        val videoOutMbPerMin = if (videoMinutes > 0.5) {
            videoSamples.sumOf { it.outputBytes.toDouble() } / 1e6 / videoMinutes
        } else {
            0.0
        }

        val photoPredictions = db.items().predictionSamples(video = false)
        val videoPredictions = db.items().predictionSamples(video = true)

        val row = MediaProfileRow(
            preset = photoKey,
            codec = videoKey,
            photoCount = totals.photoCount,
            photoBytes = totals.photoBytes,
            photoMedianBytes = galleryPhotoMedian,
            photoRatio = if (photoMeasured) ratio(photoSamples) else 0.0,
            photoSamples = if (photoMeasured) photoSamples.size else 0,
            photoAsIsShare = asIsShare(video = false),
            videoCount = totals.videoCount,
            videoBytes = totals.videoBytes,
            videoMedianBytes = galleryVideoMedian,
            videoMinutes = totals.videoMinutes,
            videoRatio = if (videoMeasured) ratio(videoSamples) else 0.0,
            videoOutMbPerMin = if (videoMeasured) videoOutMbPerMin else 0.0,
            videoSamples = if (videoMeasured) videoSamples.size else 0,
            videoAsIsShare = asIsShare(video = true),
            photoErrorPercent = MediaProfile.meanAbsolutePercentageError(
                photoPredictions.map { it.predictedBytes },
                photoPredictions.map { it.outputBytes }
            ),
            videoErrorPercent = MediaProfile.meanAbsolutePercentageError(
                videoPredictions.map { it.predictedBytes },
                videoPredictions.map { it.outputBytes }
            ),
            updatedAt = now
        )
        db.profile().put(row)
        return row
    }

    private suspend fun asIsShare(video: Boolean): Double {
        val processed = db.items().processedCountFor(video)
        if (processed <= 0) return 0.0
        return db.items().asIsCount(video).toDouble() / processed
    }

    /**
     * Reads the stored profile into the shape the UI and maths use.
     *
     * When nothing has been measured yet there is no stored row, and this
     * used to return an empty profile - which is how the calculator came to
     * tell someone with 3 471 files that their gallery was 0.00 GB. How big
     * the gallery is comes off a MediaStore scan and has nothing to do with
     * whether the app has encoded anything, so the row is built on demand
     * instead. The encoding ratios inside it stay unmeasured, which is
     * correct and is stated as such.
     */
    suspend fun current(options: Options): MediaProfile.Profile {
        val row = db.profile().get(PlannedEncode.photoKey(), PlannedEncode.videoKey())
            ?: rebuild(options)
        return row.toProfile(db.items().bytesAddedSince(monthAgoSeconds()))
    }

    private fun monthAgoSeconds(): Long = System.currentTimeMillis() / 1000 - 30L * 86_400

    companion object {
        fun MediaProfileRow.toProfile(monthlyBytes: Long): MediaProfile.Profile =
            MediaProfile.Profile(
                photos = MediaProfile.TypeProfile(
                    count = photoCount,
                    totalBytes = photoBytes,
                    medianBytes = photoMedianBytes,
                    ratio = photoRatio,
                    samples = photoSamples,
                    asIsShare = photoAsIsShare,
                    measured = photoSamples > 0 && photoRatio > 0,
                    errorPercent = photoErrorPercent
                ),
                videos = MediaProfile.TypeProfile(
                    count = videoCount,
                    totalBytes = videoBytes,
                    medianBytes = videoMedianBytes,
                    ratio = videoRatio,
                    samples = videoSamples,
                    asIsShare = videoAsIsShare,
                    measured = videoSamples > 0 && videoRatio > 0,
                    outMbPerMin = videoOutMbPerMin,
                    minutes = videoMinutes,
                    errorPercent = videoErrorPercent
                ),
                monthlyBytes = monthlyBytes
            )
    }
}
