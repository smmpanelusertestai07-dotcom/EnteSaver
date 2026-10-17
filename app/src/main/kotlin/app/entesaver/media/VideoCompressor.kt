package app.entesaver.media

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.EncoderSelector
import androidx.media3.transformer.EncoderUtil
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import app.entesaver.core.logic.AudioPlan
import app.entesaver.core.logic.BitrateCalc
import app.entesaver.core.logic.HdrPolicy
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.QualityLadder
import app.entesaver.core.logic.RunDecider
import app.entesaver.core.logic.Ssim
import app.entesaver.core.logic.VideoCodec
import app.entesaver.core.logic.VideoCodecResolver
import app.entesaver.core.logic.VideoSpec
import app.entesaver.util.DeviceTier
import com.google.common.collect.ImmutableList
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * Video pipeline (Media3 Transformer): MP4 out, H.264 or HEVC (HEVC only on a
 * hardware encoder that takes the clip), aspect kept, rotation applied
 * upright, an ordinary high frame rate capped (slow motion kept).
 *
 * How many bits a clip gets is measured, not assumed: two short stretches
 * of it are encoded at candidate rates and compared with a near-lossless
 * encode of the same stretches ([QualityLadder], [Ssim]), and the clip gets
 * the cheapest rate that still looks like it. Sound that is already lean is
 * copied across untouched ([AudioPlan]). Key frames every few seconds and
 * B-frames where the chip makes them spend the bits on the picture.
 *
 * Known Media3 pitfalls are handled with a mandatory result check and a
 * retry ladder: VBR with B-frames -> VBR -> CBR -> H.264 (on its hardware
 * for an HEVC clip, in software for an H.264 one) -> copy as-is. An item is
 * never lost.
 */
@OptIn(UnstableApi::class)
object VideoCompressor {

    data class Probe(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val durationMs: Long,
        val bitrateBps: Long,
        val fps: Float
    )

    private data class Attempt(
        val cbr: Boolean,
        val software: Boolean,
        val label: String,
        val codec: VideoCodec,
        /** B-frames: about a tenth smaller where the chip makes them; the next rung goes without. */
        val bFrames: Boolean = false
    )

    /**
     * The rungs for a clip encoded as [codec]. HEVC is never handed to a
     * software encoder - on a budget phone that is many times the clip's own
     * length, running hot - so its last rung is H.264 on the hardware every
     * phone has.
     */
    private fun attemptsFor(codec: VideoCodec): List<Attempt> = listOf(
        Attempt(cbr = false, software = false, label = "vbr_b", codec = codec, bFrames = true),
        Attempt(cbr = false, software = false, label = "vbr", codec = codec),
        Attempt(cbr = true, software = false, label = "cbr", codec = codec),
        if (codec == VideoCodec.HEVC) {
            Attempt(cbr = false, software = false, label = "h264", codec = VideoCodec.H264)
        } else {
            Attempt(cbr = false, software = true, label = "sw", codec = VideoCodec.H264)
        }
    )

    private val COPY_OK_CONTAINERS = setOf("video/mp4", "video/quicktime", "video/3gpp")

    /**
     * The whole ladder's time budget, for a caller with no deadline of its own.
     *
     * This used to be the budget for one attempt, and there are three attempts,
     * so a stubborn video could hold the worker for an hour - twenty minutes of
     * VBR, twenty of CBR, twenty on the software encoder. CompressWorker's own
     * run deadline is forty minutes and the foreground-service allowance the
     * system grants is smaller again, so both expired underneath it: the run
     * came back long after it was supposed to have finished, having encoded one
     * file, and the next run was refused because the allowance was spent. It is
     * the budget for the whole call now, so the number here is the truth.
     */
    const val DEFAULT_TOTAL_MS = 20 * 60_000L

    /**
     * The least the ladder is ever given, however little of a run is left.
     *
     * A video handed thirty seconds cannot finish anything, and the fallback
     * for "nothing finished" is copying it across untouched - which is then
     * what is backed up, permanently, because a copied item is done. Better to
     * overrun a nearly-finished run by a few minutes than to quietly ship the
     * full-size file.
     */
    const val MIN_TOTAL_MS = 5 * 60_000L

    /** The ladder ran out of a budget the caller had cut short (see [compress]). */
    class OutOfTime(detail: String) : Exception(detail)

    /** Below this there is no point starting another attempt at all. */
    private const val MIN_ATTEMPT_MS = 60_000L

    /**
     * Seconds between key frames. A camera writes one every second so it can
     * be cut anywhere; a copy that is only watched spends those bits better
     * on the picture, and three seconds is what streaming services use.
     */
    const val KEY_FRAME_SECONDS = 3f

    /** Each probe encodes two stretches this long, a third and two thirds in. */
    private const val PROBE_WINDOW_MS = 1_500L

    /** Where the two stretches are compared: two frames in each. */
    private val PROBE_FRAMES_US = longArrayOf(400_000L, 1_100_000L, 1_900_000L, 2_600_000L)

    /** The yardstick's rate, as a share of the standard one: enough to look like the original. */
    private const val REFERENCE_SHARE = 3.0

    /** The most measuring may take of a clip's budget, and of a short budget, a quarter. */
    private const val PROBE_BUDGET_MS = 3 * 60_000L

    /**
     * The ladder's budget for a caller with [remainingMs] left on its deadline.
     *
     * Never more than one video's fair share of a run, and never so little that
     * the attempt is hopeless - see [MIN_TOTAL_MS].
     */
    fun budgetFor(remainingMs: Long): Long =
        maxOf(MIN_TOTAL_MS, minOf(DEFAULT_TOTAL_MS, remainingMs))

    suspend fun compress(
        context: Context,
        uri: Uri,
        displayName: String,
        mimeType: String,
        srcBytes: Long,
        spec: VideoSpec,
        tempDir: File,
        maxTotalMs: Long = DEFAULT_TOTAL_MS
    ): CompressResult {
        // Started before the probe, because probing a damaged file can itself
        // take a while and the caller was promised a bound on the whole call.
        val budgetEndsAt = System.currentTimeMillis() + maxTotalMs
        val probe = probe(context, uri)
            ?: return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "probe_failed")

        val upright = if (probe.rotation == 90 || probe.rotation == 270) {
            probe.height to probe.width
        } else {
            probe.width to probe.height
        }
        // An ordinary 60 fps clip is written at 30; slow motion keeps every frame.
        val cappedFps = MediaSettings.outputFps(probe.fps, spec.fpsCap)
        val outFps = cappedFps ?: probe.fps
        var dims = BitrateCalc.outputDims(upright.first, upright.second, spec.longSideLimit)
        if (EncoderCaps.holdsToFullHd(
                dims.first, dims.second, outFps, smallestPhone = DeviceTier.tier(context) == DeviceTier.Tier.VERY_LOW
            )
        ) {
            dims = BitrateCalc.outputDims(upright.first, upright.second, MediaSettings.FULL_HD)
        }
        val (outW, outH) = dims
        val codec = VideoCodecResolver.resolve(
            spec.codec, VideoCodecResolver.Hardware(hevcFits = EncoderCaps.hevcFits(outW, outH, outFps))
        )
        // The standard rate for this picture; what the clip is given is a
        // measured share of it (QualityLadder).
        val base = BitrateCalc.targetBps(outW, outH, outFps, codec, spec.quality)
        val containerOk = mimeType.lowercase() in COPY_OK_CONTAINERS
        val srcLongSide = maxOf(upright.first, upright.second)

        // Leaner already than the least any clip is given: nothing to win.
        if (cappedFps == null && BitrateCalc.shouldCopyAsIs(
                srcLongSide, spec.longSideLimit, probe.bitrateBps, (base * QualityLadder.RUNGS.first()).toInt(), containerOk
            )
        ) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "already_efficient")
        }

        // HDR policy: H.264 cannot carry HDR, so it is tone-mapped to SDR, as
        // is everything when the setting asks for SDR. HEVC keeps HDR only
        // when this device can actually encode 10-bit HDR; otherwise it is
        // tone-mapped too. A device that can do neither ends at the as-is
        // copy below - colours are never silently washed out.
        val hdr = MediaTraits.hdrOf(context, uri)
        val keepHdr = hdr != MediaTraits.Hdr.NONE &&
            spec.hdr == HdrPolicy.KEEP_WHEN_POSSIBLE &&
            codec == VideoCodec.HEVC &&
            MediaTraits.deviceSupportsHdrHevcEncode()
        // The phone's own decoder does it where it can: lighter than a GL
        // pass. Not every decoder that runs Android 12 will, though, and one
        // that will not ends the export - so a rung that fails that way is
        // run again through OpenGL, and every rung after it too.
        var toneMap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC
        } else {
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
        }
        val hdrTag = when {
            hdr == MediaTraits.Hdr.NONE -> ""
            keepHdr -> "_hdr"
            else -> "_tonemap"
        }
        val sound = audioTrackOf(context, uri)
        val audio = sound?.let { AudioPlan.decide(it.mime, it.channels, it.bitrateBps) }

        // A 10-bit HDR picture read back as 8-bit frames would be compared
        // with the wrong thing, so it keeps the standard rate.
        val share = if (probe.durationMs >= QualityLadder.MIN_PROBE_DURATION_MS && !keepHdr) {
            measuredShare(
                context, uri, probe.durationMs, outW, outH, base, codec,
                hdrMode = if (hdr == MediaTraits.Hdr.NONE) Composition.HDR_MODE_KEEP_HDR else toneMap,
                frameRateCap = cappedFps?.toInt(),
                tempDir = tempDir,
                budgetMs = minOf(PROBE_BUDGET_MS, (budgetEndsAt - System.currentTimeMillis()) / 4)
            )
        } else {
            QualityLadder.UNPROBED
        }
        val rateFor = { c: VideoCodec -> (BitrateCalc.targetBps(outW, outH, outFps, c, spec.quality) * share).toInt() }
        // Measured, the clip needs no fewer bits than it already has.
        if (cappedFps == null &&
            BitrateCalc.shouldCopyAsIs(srcLongSide, spec.longSideLimit, probe.bitrateBps, rateFor(codec), containerOk)
        ) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "already_efficient")
        }

        var outOfTime = false
        var notSmaller = false
        var detail = ""
        // The smallest copy that only missed its bitrate target, kept in case
        // no rung meets it (BitrateCalc.worthKeeping).
        var fallback: CompressResult? = null
        val attempts = attemptsFor(codec)
        var rung = 0
        while (rung < attempts.size) {
            val attempt = attempts[rung]
            // Keeping HDR is a promise about HEVC; the H.264 rung tone-maps.
            val hdrMode = when {
                hdr == MediaTraits.Hdr.NONE -> Composition.HDR_MODE_KEEP_HDR
                keepHdr && attempt.codec == VideoCodec.HEVC -> Composition.HDR_MODE_KEEP_HDR
                else -> toneMap
            }
            val codecMime = if (attempt.codec == VideoCodec.H264) MimeTypes.VIDEO_H264 else MimeTypes.VIDEO_H265
            // Each rung gets what is left of the budget, not a fresh twenty
            // minutes of its own, so three attempts can never cost three times
            // the number the caller asked for.
            val leftMs = budgetEndsAt - System.currentTimeMillis()
            if (leftMs < MIN_ATTEMPT_MS) {
                outOfTime = true
                break
            }
            val outFile = File(tempDir, "video_${System.nanoTime()}_${attempt.label}.mp4")
            val export = try {
                runTransform(
                    context, uri, outFile, outW, outH, rateFor(attempt.codec),
                    codecMime, attempt, hdrMode, leftMs,
                    audio = audio,
                    frameRateCap = cappedFps?.toInt(),
                    onError = { detail = "${attempt.label}: $it" }
                )
            } catch (ce: CancellationException) {
                outFile.delete()
                fallback?.file?.delete()
                throw ce
            } catch (e: Exception) {
                detail = "${attempt.label}: ${e.javaClass.simpleName}"
                null
            }
            if (export == null && hdrMode == Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC) {
                outFile.delete()
                toneMap = Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
                continue
            }
            if (export != null && outFile.exists()) {
                val outBytes = outFile.length()
                // Media3 renamed this to say what it always was: the muxer's
                // own figure, close but not exact. The name changed, the
                // number did not, and a zero still means "ask the file".
                val outDur = if (export.approximateDurationMs > 0) {
                    export.approximateDurationMs
                } else {
                    probeDurationMs(outFile)
                }
                val outBps = if (outDur > 0) outBytes * 8000L / outDur else Long.MAX_VALUE
                val rungTarget = rateFor(attempt.codec)
                if (BitrateCalc.resultAcceptable(srcBytes, outBytes, outBps, rungTarget, probe.durationMs, outDur)) {
                    return CompressResult(
                        outFile,
                        outBytes,
                        asIs = false,
                        reason = "compressed_${attempt.label}$hdrTag",
                        ext = "mp4",
                        srcPixels = upright.first.toLong() * upright.second.toLong(),
                        outPixels = outW.toLong() * outH.toLong(),
                        codec = attempt.codec
                    )
                }
                detail = "${attempt.label}: $outBytes of $srcBytes bytes, $outBps of $rungTarget bps, " +
                    "$outDur of ${probe.durationMs} ms"
                if (BitrateCalc.worthKeeping(srcBytes, outBytes, probe.durationMs, outDur) &&
                    outBytes < (fallback?.bytes ?: Long.MAX_VALUE)
                ) {
                    fallback?.file?.delete()
                    fallback = CompressResult(
                        outFile,
                        outBytes,
                        asIs = false,
                        reason = "compressed_${attempt.label}$hdrTag",
                        ext = "mp4",
                        srcPixels = upright.first.toLong() * upright.second.toLong(),
                        outPixels = outW.toLong() * outH.toLong(),
                        codec = attempt.codec,
                        detail = detail
                    )
                    rung++
                    continue
                }
                if (outBytes >= srcBytes && outBps <= rungTarget * BitrateCalc.RESULT_BITRATE_FACTOR) {
                    // The encoder kept to its target and the copy is still no
                    // smaller: the original is already leaner than the setting,
                    // and the next rung aims at the same target. Trying it
                    // would only spend the battery a second time.
                    notSmaller = true
                    outFile.delete()
                    break
                }
            }
            outFile.delete()
            rung++
        }
        fallback?.let { return it }
        if (outOfTime && RunDecider.outOfTimeWaits(maxTotalMs, DEFAULT_TOTAL_MS)) {
            // The budget was cut short by the caller's run, not spent on a
            // clip too long for any run. An as-is copy is final, so making
            // one here would back the full-size file up for good; the clip
            // waits for a run with the whole budget instead. The wait is
            // counted (Stager), so a phone that never gives that budget sets
            // the clip aside after three tries rather than retrying it for ever.
            throw OutOfTime(detail)
        }
        val failReason = when {
            outOfTime -> "out_of_time"
            notSmaller -> "not_smaller"
            hdr == MediaTraits.Hdr.NONE -> "encoder_rejected"
            else -> "hdr_not_supported"
        }
        return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, failReason).copy(detail = detail)
    }

    /** Runs a single Transformer export; null on any export error or timeout. */
    private suspend fun runTransform(
        context: Context,
        uri: Uri,
        outFile: File,
        outW: Int,
        outH: Int,
        bitrateBps: Int,
        codecMime: String,
        attempt: Attempt,
        hdrMode: Int,
        attemptMs: Long,
        audio: AudioPlan.Decision?,
        frameRateCap: Int?,
        onError: (String) -> Unit,
        windowsMs: List<LongRange>? = null
    ): ExportResult? = withContext(Dispatchers.Default) {
        // Background priority: encoding must never make the phone feel slow.
        val thread = HandlerThread("entesaver-transform", Process.THREAD_PRIORITY_BACKGROUND)
        thread.start()
        val handler = Handler(thread.looper)
        val done = CompletableDeferred<ExportResult?>()
        val transformerRef = AtomicReference<Transformer?>(null)

        handler.post {
            try {
                val bitrateMode = if (attempt.cbr) {
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                } else {
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                }
                // Profile and level are left to Media3, which asks for H.264
                // High at the highest level the chip supports (minus the chips
                // known to break on it), and HEVC Main.
                val videoSettings = VideoEncoderSettings.Builder()
                    .setBitrate(bitrateBps)
                    .setBitrateMode(bitrateMode)
                    .setiFrameIntervalSeconds(KEY_FRAME_SECONDS)
                    .apply { if (attempt.bFrames) setMaxBFrames(1) }
                    .build()
                // Asking for any sound settings at all makes Media3 re-encode
                // the sound, so a track that is kept asks for none.
                val encode = audio as? AudioPlan.Decision.Encode
                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(videoSettings)
                    .apply {
                        if (encode != null) {
                            setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(encode.bps).build())
                        }
                    }
                    .setEnableFallback(true)
                    .apply { if (attempt.software) setVideoEncoderSelector(SOFTWARE_SELECTOR) }
                    .build()

                val listener = object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        done.complete(exportResult)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException
                    ) {
                        onError("${exportException.errorCodeName} ${exportException.cause?.javaClass?.simpleName.orEmpty()}")
                        done.complete(null)
                    }
                }

                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(codecMime)
                    .apply { if (encode != null) setAudioMimeType(MimeTypes.AUDIO_AAC) }
                    .setEncoderFactory(encoderFactory)
                    .addListener(listener)
                    .build()
                transformerRef.set(transformer)

                // Presentation is always applied: it keeps aspect (even dims) and
                // forces a real re-encode so the bitrate settings actually apply.
                fun edited(item: MediaItem) = EditedMediaItem.Builder(item)
                    .setEffects(
                        Effects(
                            emptyList<AudioProcessor>(),
                            listOf<Effect>(
                                Presentation.createForWidthAndHeight(
                                    outW, outH, Presentation.LAYOUT_SCALE_TO_FIT
                                )
                            )
                        )
                    )
                    // A cap, not a target: Media3 drops frames only from a
                    // clip that runs faster than this.
                    .apply { if (frameRateCap != null) setFrameRate(frameRateCap) }
                    .build()
                // The track set is chosen from the clip, not assumed. Read in
                // Media3's own bytecode, a sequence's track types do two
                // things: the exporter strips any track the set does not name,
                // and it FORCES any track the set does name - a set with audio
                // in it makes forceAudioTrack true, and a clip with no audio
                // is given a generated silent one. The constructor Media3
                // deprecated named "default", which neither strips nor forces.
                // So: video only for a silent clip (a timelapse, a screen
                // recording with the mic off), both for a clip with sound.
                // Either way the copy carries exactly the tracks the original
                // did. Both branches are pinned by instrumented tests against
                // real clips, because the wrong choice fails nothing else - the
                // copy is smaller, valid, and either silent or padded. A probe
                // is its stretches of picture alone.
                val sequence = when {
                    windowsMs != null -> EditedMediaItemSequence.withVideoFrom(
                        windowsMs.map { window ->
                            edited(
                                MediaItem.Builder().setUri(uri).setClippingConfiguration(
                                    MediaItem.ClippingConfiguration.Builder()
                                        .setStartPositionMs(window.first)
                                        .setEndPositionMs(window.last)
                                        .build()
                                ).build()
                            )
                        }
                    )
                    audio != null -> EditedMediaItemSequence.withAudioAndVideoFrom(listOf(edited(MediaItem.fromUri(uri))))
                    else -> EditedMediaItemSequence.withVideoFrom(listOf(edited(MediaItem.fromUri(uri))))
                }
                val composition = Composition.Builder(sequence).setHdrMode(hdrMode).build()
                transformer.start(composition, outFile.absolutePath)
            } catch (t: Throwable) {
                onError("start ${t.javaClass.simpleName}")
                done.complete(null)
            }
        }

        try {
            withTimeout(attemptMs) { done.await() }
        } catch (e: TimeoutCancellationException) {
            handler.post { runCatching { transformerRef.get()?.cancel() } }
            null
        } catch (ce: CancellationException) {
            handler.post { runCatching { transformerRef.get()?.cancel() } }
            throw ce
        } finally {
            handler.post { thread.quitSafely() }
        }
    }

    /**
     * The share of the standard rate this clip needs (see [QualityLadder]).
     *
     * Every probe encodes the same two stretches of the clip in the same way;
     * the first, at [REFERENCE_SHARE], is the yardstick. Compared with that
     * rather than with the original, the frames line up exactly and the
     * scaling is the same on both sides, so the one difference measured is
     * what the lower rate cost. A probe that cannot be made or read ends the
     * measuring with what is known ([QualityLadder.settle]); it never fails
     * the clip.
     */
    private suspend fun measuredShare(
        context: Context,
        uri: Uri,
        durationMs: Long,
        outW: Int,
        outH: Int,
        base: Int,
        codec: VideoCodec,
        hdrMode: Int,
        frameRateCap: Int?,
        tempDir: File,
        budgetMs: Long
    ): Double {
        val endsAt = System.currentTimeMillis() + budgetMs
        val windows = listOf(durationMs / 3, durationMs * 2 / 3).map { mid ->
            val start = (mid - PROBE_WINDOW_MS / 2).coerceAtLeast(0L)
            start..(start + PROBE_WINDOW_MS)
        }
        val attempt = attemptsFor(codec).first()
        val codecMime = if (codec == VideoCodec.H264) MimeTypes.VIDEO_H264 else MimeTypes.VIDEO_H265
        val ceiling = 2 * BitrateCalc.capFor(outW, outH)
        val target = Ssim.Targets.VIDEO

        suspend fun framesAt(share: Double): List<FrameQuality.Luma>? {
            val leftMs = endsAt - System.currentTimeMillis()
            if (leftMs <= 0) return null
            val file = File(tempDir, "probe_${System.nanoTime()}.mp4")
            try {
                val bps = (base * share).toLong().coerceAtMost(ceiling.toLong()).toInt()
                runTransform(
                    context, uri, file, outW, outH, bps, codecMime, attempt, hdrMode, leftMs,
                    audio = null, frameRateCap = frameRateCap, onError = {}, windowsMs = windows
                ) ?: return null
                return FrameQuality.framesOf(file, PROBE_FRAMES_US)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                return null
            } finally {
                file.delete()
            }
        }

        val reference = framesAt(REFERENCE_SHARE) ?: return QualityLadder.UNPROBED
        val points = mutableListOf<QualityLadder.Point>()
        while (true) {
            when (val step = QualityLadder.next(points, target)) {
                is QualityLadder.Step.Encode -> return step.share
                is QualityLadder.Step.Probe -> {
                    val ssim = framesAt(step.share)?.let { FrameQuality.score(reference, it) }
                        ?: return QualityLadder.settle(points, target)
                    points += QualityLadder.Point(step.share, ssim)
                }
            }
        }
    }

    /** The original's sound track; null when it has none (or cannot be read). */
    private data class SourceAudio(val mime: String?, val channels: Int, val bitrateBps: Int?)

    private fun audioTrackOf(context: Context, uri: Uri): SourceAudio? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(context, uri, null)
            (0 until extractor.trackCount).asSequence()
                .map { extractor.getTrackFormat(it) }
                .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                ?.let { f ->
                    SourceAudio(
                        mime = f.getString(MediaFormat.KEY_MIME),
                        channels = if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) f.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2,
                        bitrateBps = if (f.containsKey(MediaFormat.KEY_BIT_RATE)) f.getInteger(MediaFormat.KEY_BIT_RATE) else null
                    )
                }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { extractor.release() }
        }
    }

    private val SOFTWARE_SELECTOR = EncoderSelector { mimeType ->
        val all = EncoderUtil.getSupportedEncoders(mimeType)
        val software = all.filter { info ->
            try {
                info.isSoftwareOnly ||
                    info.name.startsWith("c2.android.", ignoreCase = true) ||
                    info.name.startsWith("OMX.google.", ignoreCase = true)
            } catch (e: Exception) {
                false
            }
        }
        ImmutableList.copyOf(software)
    }

    fun probe(context: Context, uri: Uri): Probe? {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(context, uri)
            val w = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            val h = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            if (w == null || h == null || w <= 0 || h <= 0) return null
            Probe(
                width = w,
                height = h,
                rotation = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull() ?: 0,
                durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L,
                bitrateBps = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                    ?.toLongOrNull() ?: 0L,
                fps = extractFps(context, uri) ?: 30f
            )
        } catch (e: Exception) {
            null
        } finally {
            runCatching { mmr.release() }
        }
    }

    private fun extractFps(context: Context, uri: Uri): Float? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(context, uri, null)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    return try {
                        format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                    } catch (e: Exception) {
                        try {
                            format.getFloat(MediaFormat.KEY_FRAME_RATE)
                        } catch (e2: Exception) {
                            null
                        }
                    }
                }
            }
            null
        } catch (e: Exception) {
            null
        } finally {
            runCatching { extractor.release() }
        }
    }

    private fun probeDurationMs(file: File): Long {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(file.absolutePath)
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            0L
        } finally {
            runCatching { mmr.release() }
        }
    }
}
