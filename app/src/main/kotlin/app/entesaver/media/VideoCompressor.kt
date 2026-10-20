package app.entesaver.media

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.muxer.Muxer
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.EncoderSelector
import androidx.media3.transformer.EncoderUtil
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import app.entesaver.core.logic.AudioPlan
import app.entesaver.core.logic.BitrateCalc
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.QualityFloor
import app.entesaver.core.logic.RunDecider
import app.entesaver.core.logic.VideoCodec
import app.entesaver.core.logic.VideoCodecResolver
import app.entesaver.core.logic.VideoShare
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
 * Video pipeline (Media3 Transformer): a copy that keeps everything about
 * its original but its bitrate - the codec (H.264 stays H.264, HEVC stays
 * HEVC), the size, the frame rate, the rotation, HDR, the sound's codec,
 * channels and sample rate, and the date and place it was filmed.
 *
 * How many bits a clip gets is read from its picture, not assumed: a few
 * pairs of its frames say how much it moves and how dark it is
 * ([MotionProbe]), and the clip is given that share of the standard rate
 * ([VideoShare], [BitrateCalc]) - a still scene little, fast motion and night
 * much more. Nothing is test-encoded first. Sound that is already lean is
 * copied across untouched, and a heavy AAC track written again as AAC
 * ([AudioPlan]). Key frames every few seconds and B-frames where the chip
 * makes them spend the bits on the picture.
 *
 * A video this phone's chip cannot write in its own codec, at its own size
 * and frame rate, is left exactly as it is: nothing is converted to another
 * codec, made smaller in size or played at another rate to make it fit.
 * Every copy is read back before it is kept, and one that came out in
 * another codec, at another size or with frames missing is thrown away.
 *
 * Known Media3 pitfalls are handled with a mandatory result check and a
 * retry ladder in the same codec: VBR with B-frames -> VBR -> CBR (-> for
 * H.264, Android's own software encoder) -> copy as-is. Where Android's
 * quality floor would raise a VBR encode (QualityFloor), CBR comes first. A
 * rung that overshoots its target has the next one asked for less, by as far
 * as it went over. An item is never lost.
 */
@OptIn(UnstableApi::class)
object VideoCompressor {

    data class Probe(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val durationMs: Long,
        val bitrateBps: Long,
        val fps: Float,
        /** The picture's codec and its own bitrate, when the file says. */
        val videoMime: String? = null,
        val videoBps: Long? = null,
        /** How many frames the picture holds, when the file says. */
        val frameCount: Int? = null
    )

    private data class Attempt(
        val cbr: Boolean,
        val software: Boolean,
        val label: String,
        val codec: VideoCodec,
        /**
         * Media3's table of what each chip encodes best with (B-frames and
         * frame layering where they work, none where they break); the next
         * rung goes without it.
         */
        val tuned: Boolean = false
    )

    /**
     * The rungs for a clip kept in [codec]. VBR spends a clip's bits where
     * its motion is, but where Android's quality floor holds a VBR encode far
     * above the rate asked for (QualityFloor) the clip is written in CBR
     * first ([cbrFirst]), which the floor leaves alone: one encode at the
     * size the app chose instead of two thrown away. An H.264 clip no chip
     * rung could write gets Android's own software encoder last ([software]),
     * at 1080p or less; HEVC is never handed to software - on a budget phone
     * that is many times the clip's own length, running hot. Without a chip
     * that takes the clip ([chip]), software is the only rung.
     */
    private fun attemptsFor(codec: VideoCodec, cbrFirst: Boolean, chip: Boolean, software: Boolean): List<Attempt> {
        val sw = Attempt(cbr = false, software = true, label = "sw", codec = codec)
        if (!chip) return if (software) listOf(sw) else emptyList()
        val vbr = Attempt(cbr = false, software = false, label = "vbr", codec = codec)
        val cbr = Attempt(cbr = true, software = false, label = "cbr", codec = codec)
        val rungs = if (cbrFirst) {
            listOf(cbr.copy(label = "tuned_cbr", tuned = true), cbr, vbr)
        } else {
            listOf(vbr.copy(label = "tuned", tuned = true), vbr, cbr)
        }
        return if (software) rungs + sw else rungs
    }

    private fun mimeOf(codec: VideoCodec): String =
        if (codec == VideoCodec.H264) MimeTypes.VIDEO_H264 else MimeTypes.VIDEO_H265

    /**
     * The containers a copy can be written in: the MP4 family, which the MP4
     * writer makes. A video in any other (Matroska, WebM, AVI) stays as it is.
     */
    private val KEPT_CONTAINERS = setOf("video/mp4", "video/quicktime", "video/3gpp", "video/3gpp2")

    /** The interval motion is read over: a thirtieth of a second, what VideoShare's curve was set at. */
    internal const val MOTION_FPS = 30f

    /** Why a video stays exactly as it is, when a copy would have to change it. */
    const val CODEC_KEPT = "codec_kept"
    const val CONTAINER_KEPT = "container_kept"
    const val SIZE_KEPT = "size_kept"
    const val CHIP_CANNOT_KEEP = "chip_cannot_keep"
    const val SOUND_KEPT = "sound_kept"

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
     * on the picture. Ente plays a file it has downloaded whole, so eight
     * seconds - x264's own default, 250 frames - costs nothing in seeking and
     * saves on every still scene.
     */
    const val KEY_FRAME_SECONDS = 8f

    /** MediaCodec's priority for work nobody is watching in real time. */
    private const val NON_REALTIME = 1

    /** Twice the clip's own frame rate: well ahead of real time, short of flat out. */
    private fun operatingRateFor(fps: Float): Int = (2 * (if (fps.isFinite() && fps > 1f) fps else 30f)).toInt().coerceIn(30, 240)

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
        maxTotalMs: Long = DEFAULT_TOTAL_MS,
        screenRecording: Boolean = false
    ): CompressResult {
        // Started before the probe, because probing a damaged file can itself
        // take a while and the caller was promised a bound on the whole call.
        val budgetEndsAt = System.currentTimeMillis() + maxTotalMs
        // Made by Ente Saver already: measured again it would only be
        // compared with itself and taken down another step.
        if (MarkReader.isMarked(context, uri, srcBytes)) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "already_optimised")
        }
        if (mimeType.lowercase() !in KEPT_CONTAINERS) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, CONTAINER_KEPT)
        }
        val probe = probe(context, uri)
            ?: return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "probe_failed")
        // The copy is in its original's own codec, or there is no copy.
        val codec = VideoCodecResolver.keptCodec(probe.videoMime)
            ?: return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, CODEC_KEPT)
        // What of the file Media3 does not carry, to put back - or a track or
        // trailer no copy can keep, which keeps the whole video as it is.
        val same = SameAsSource.read(context, uri)
            ?: return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "probe_failed")
        same.keepsWhole?.let { return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, it) }

        val upright = if (probe.rotation == 90 || probe.rotation == 270) {
            probe.height to probe.width
        } else {
            probe.width to probe.height
        }
        // Its own size and frame rate: an encoder writes even sizes only, so
        // a picture of odd size stays as it is rather than lose a line.
        val (outW, outH) = BitrateCalc.outputDims(upright.first, upright.second, spec.longSideLimit)
        if (outW != upright.first || outH != upright.second) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, SIZE_KEPT)
        }
        val outFps = probe.fps
        val codecMime = mimeOf(codec)
        // A chip that writes this codec at this size and frame rate - none on
        // the smallest phones above 1080p, whose memory a 4K encode would not
        // fit - or, for H.264 up to 1080p, Android's own software encoder.
        val smallestPhone = DeviceTier.tier(context) == DeviceTier.Tier.VERY_LOW
        val chip = !(smallestPhone && maxOf(outW, outH) > MediaSettings.FULL_HD) &&
            EncoderCaps.hardwareFits(codecMime, outW, outH, outFps)
        val software = codec == VideoCodec.H264 && EncoderCaps.softwareFits(codecMime, outW, outH, outFps)
        if (!chip && !software) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, CHIP_CANNOT_KEEP)
        }
        // HDR is kept, or so is the video: only HEVC carries it, and only on a
        // chip Media3 itself counts as editing HDR (Android 13 and up). Its
        // own test, because where it fails Media3 would quietly tone-map the
        // copy to SDR, washing its colours out.
        val hdr = MediaTraits.hdrOf(context, uri)
        if (hdr != MediaTraits.Hdr.NONE &&
            !(codec == VideoCodec.HEVC && chip && EncoderCaps.writesHdr(same.colorInfo))
        ) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "hdr_not_supported")
        }
        // The sound stays in its own codec too (AudioPlan). A heavy AAC track
        // is written again only by the AAC encoder whose start-up delay Media3
        // allows for; with any other the sound would play a few hundredths of
        // a second late, so it is copied as it is instead.
        val sound = audioTrackOf(context, uri)
        val audio = sound?.let { AudioPlan.decide(it.mime, it.channels, it.bitrateBps) }
            ?.let { if (it is AudioPlan.Decision.Encode && !EncoderCaps.aacKeepsSync()) AudioPlan.Decision.Keep else it }
        if (audio == AudioPlan.Decision.KeepsVideoAsIs) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, SOUND_KEPT)
        }
        // Android's quality floor holds a VBR encode of this picture to its
        // own table, far above these rates (QualityFloor), so where it
        // applies the clip is written in CBR - if the chip has CBR for this
        // codec. Where it has not, a VBR copy at the floor is the least this
        // phone can make, and every check below judges it as that.
        val floored = EncoderCaps.qualityFloorApplies(context, outW, outH)
        val cbrFirst = chip && floored && EncoderCaps.cbrFits(codecMime, outW, outH, outFps)
        val heldTo = { rate: Int, cbr: Boolean ->
            if (floored && !cbr) QualityFloor.vbrBps(rate, outW, outH, codec) else rate
        }
        // The standard rate for this picture; what the clip is given is a
        // share of it read from its frames (VideoShare).
        val base = BitrateCalc.targetBps(outW, outH, outFps, codec)
        val srcLongSide = maxOf(upright.first, upright.second)

        // Leaner already than the least any clip is given: nothing to win.
        if (BitrateCalc.shouldCopyAsIs(
                srcLongSide, spec.longSideLimit, probe.bitrateBps, heldTo((base * VideoShare.MIN).toInt(), cbrFirst), true
            )
        ) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "already_efficient")
        }

        val motion = MotionProbe.read(context, uri, probe.durationMs, MOTION_FPS)
        val share = VideoShare.of(motion?.ti, motion?.meanLuma, screenRecording)
        // Never more than the source's own picture holds, at its own size
        // (BitrateCalc.sourceCapBps): the file's own figure for its picture,
        // or the whole file less its sound.
        val sourceVideoBps = probe.videoBps ?: (probe.bitrateBps - (sound?.bitrateBps ?: 0)).takeIf { it > 0 }
        val target = run {
            val asked = (base * share).toInt()
            val cap = sourceVideoBps?.let {
                BitrateCalc.sourceCapBps(
                    it, probe.videoMime, upright.first, upright.second, probe.fps, outW, outH, outFps, codec
                )
            }
            if (cap != null) minOf(asked, cap) else asked
        }
        // Measured, the clip needs no fewer bits than it already has.
        if (BitrateCalc.shouldCopyAsIs(srcLongSide, spec.longSideLimit, probe.bitrateBps, heldTo(target, cbrFirst), true)) {
            return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, "already_efficient")
        }

        var outOfTime = false
        var notSmaller = false
        var detail = ""
        // The smallest copy that only missed its bitrate target, kept in case
        // no rung meets it (BitrateCalc.worthKeeping).
        var fallback: CompressResult? = null
        // After an encode that overshot, what the next one asks for: lowered
        // by as far as it went over (BitrateCalc.correctedRequestBps).
        var request: Int? = null
        val ext = displayName.substringAfterLast('.', "mp4").lowercase().ifEmpty { "mp4" }
        val attempts = attemptsFor(codec, cbrFirst, chip, software)
        for (attempt in attempts) {
            val asked = request ?: target
            // Under the floor a VBR rung comes out at the floor, never smaller
            // than a copy already made that only missed its own target.
            if (fallback != null && floored && !attempt.cbr) break
            // Each rung gets what is left of the budget, not a fresh twenty
            // minutes of its own, so three attempts can never cost three times
            // the number the caller asked for.
            val leftMs = budgetEndsAt - System.currentTimeMillis()
            if (leftMs < MIN_ATTEMPT_MS) {
                outOfTime = true
                break
            }
            val outFile = File(tempDir, "video_${System.nanoTime()}_${attempt.label}.$ext")
            val export = try {
                runTransform(
                    context, uri, outFile, asked, codecMime, attempt, leftMs,
                    audio = audio,
                    muxer = same.muxerFactory(),
                    operatingRate = operatingRateFor(outFps),
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
            if (export == null || !outFile.exists()) {
                outFile.delete()
                continue
            }
            // Read back before anything else: a copy in another codec, at
            // another size or rotation, or with frames missing is not a copy
            // of this video, however small.
            val changed = KeptCheck.changes(context, uri, probe, codecMime, outFile)
            if (changed.isNotEmpty()) {
                detail = "${attempt.label}: changed ${changed.joinToString(" ")}"
                outFile.delete()
                continue
            }
            // A MOV says it is a MOV again, a 3GP a 3GP.
            same.restoreType(outFile)
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
            // The file's bitrate counts its sound too, and at these picture
            // rates a kept 128 kbps track is a fifth of a small clip: the
            // check allows for the sound this rung writes, and for the floor
            // a VBR rung is held to.
            val rungSound = soundBps(audio, sound?.bitrateBps)
            val rungTarget = heldTo(target, attempt.cbr) + rungSound
            val made = CompressResult(
                outFile,
                outBytes,
                asIs = false,
                reason = "compressed_${attempt.label}${if (hdr == MediaTraits.Hdr.NONE) "" else "_hdr"}",
                ext = ext,
                srcPixels = upright.first.toLong() * upright.second.toLong(),
                outPixels = outW.toLong() * outH.toLong(),
                codec = codec
            )
            if (BitrateCalc.resultAcceptable(srcBytes, outBytes, outBps, rungTarget, probe.durationMs, outDur)) {
                // A later rung can pass at a higher target - the floor's - and
                // still be the bigger copy.
                val earlier = fallback
                if (earlier != null && earlier.bytes <= outBytes) {
                    outFile.delete()
                    return earlier
                }
                earlier?.file?.delete()
                return made
            }
            detail = "${attempt.label}: $outBytes of $srcBytes bytes, $outBps of $rungTarget bps " +
                "(asked $asked), $outDur of ${probe.durationMs} ms"
            // Judged against the target, asked for less: the next encode
            // lands near the target instead of over it a second time. Not
            // under the floor, where a VBR rung is raised whatever it asks and
            // the floor is what overshot.
            if (outDur > 0 && !(floored && !attempt.cbr)) {
                request = BitrateCalc.correctedRequestBps(asked, outBps - rungSound, target) ?: request
            }
            if (BitrateCalc.worthKeeping(srcBytes, outBytes, probe.durationMs, outDur) &&
                outBytes < (fallback?.bytes ?: Long.MAX_VALUE)
            ) {
                fallback?.file?.delete()
                fallback = made.copy(detail = detail)
                continue
            }
            outFile.delete()
            if (outBytes >= srcBytes && outBps <= rungTarget * BitrateCalc.RESULT_BITRATE_FACTOR) {
                // The encoder kept to its target and the copy is still no
                // smaller: the original is already leaner than the setting,
                // and the next rung aims at the same target. Trying it
                // would only spend the battery a second time.
                notSmaller = true
                break
            }
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
            else -> "encoder_rejected"
        }
        return PhotoCompressor.copyAsIs(context, uri, displayName, tempDir, failReason).copy(detail = detail)
    }

    /** Runs a single Transformer export; null on any export error or timeout. */
    private suspend fun runTransform(
        context: Context,
        uri: Uri,
        outFile: File,
        bitrateBps: Int,
        codecMime: String,
        attempt: Attempt,
        attemptMs: Long,
        audio: AudioPlan.Decision?,
        muxer: Muxer.Factory,
        operatingRate: Int,
        onError: (String) -> Unit
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
                // Best effort at twice the clip's own frame rate, not as fast
                // as the chip can go: Media3's default runs the encoder flat
                // out, and that heat is what a game in the foreground feels.
                val videoSettings = VideoEncoderSettings.Builder()
                    .setBitrate(bitrateBps)
                    .setBitrateMode(bitrateMode)
                    .setiFrameIntervalSeconds(KEY_FRAME_SECONDS)
                    .setEncoderPerformanceParameters(operatingRate, NON_REALTIME)
                    .build()
                // Asking for any sound settings at all makes Media3 re-encode
                // the sound, so a track that is kept asks for none. One that is
                // written again is AAC-LC, at its own sample rate and channels.
                val encode = audio as? AudioPlan.Decision.Encode
                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(videoSettings)
                    .apply {
                        if (encode != null) {
                            setRequestedAudioEncoderSettings(
                                AudioEncoderSettings.Builder()
                                    .setBitrate(encode.bps)
                                    .setProfile(MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                                    .build()
                            )
                        }
                    }
                    // Fallback picks another encoder or bitrate where one is
                    // refused, never another size: a copy at another size is
                    // not a copy of the video.
                    .setEnableFallback(true)
                    .setEnableFormatFallback(false)
                    .setEnableCodecDbLite(attempt.tuned)
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
                    .setMuxerFactory(muxer)
                    .addListener(listener)
                    .build()
                transformerRef.set(transformer)

                // No effects: the picture is written at its own size, frame
                // rate and rotation. The bitrate asked for is what makes Media3
                // re-encode it (DefaultEncoderFactory.videoNeedsEncoding), and
                // its encoder is set up at the original's own frame rate, with
                // the original's rotation kept on the new file.
                fun edited(item: MediaItem) = EditedMediaItem.Builder(item).build()
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
                // copy is smaller, valid, and either silent or padded.
                val sequence = if (audio != null) {
                    EditedMediaItemSequence.withAudioAndVideoFrom(listOf(edited(MediaItem.fromUri(uri))))
                } else {
                    EditedMediaItemSequence.withVideoFrom(listOf(edited(MediaItem.fromUri(uri))))
                }
                // HDR is kept as it is; a video whose HDR this phone cannot
                // write never gets here (compress).
                val composition = Composition.Builder(sequence).setHdrMode(Composition.HDR_MODE_KEEP_HDR).build()
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

    /** The sound a copy carries, in bits a second: what the result check allows for it. */
    private fun soundBps(audio: AudioPlan.Decision?, sourceBps: Int?): Int = when (audio) {
        null, AudioPlan.Decision.KeepsVideoAsIs -> 0
        AudioPlan.Decision.Keep -> sourceBps?.takeIf { it > 0 } ?: AudioPlan.KEEP_STEREO_BPS
        is AudioPlan.Decision.Encode -> audio.bps
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
                EncoderCaps.isSoftware(info) ||
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
            val track = videoTrackOf(context, uri)
            Probe(
                width = w,
                height = h,
                rotation = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull() ?: 0,
                durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L,
                bitrateBps = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                    ?.toLongOrNull() ?: 0L,
                fps = track?.fps ?: 30f,
                videoMime = track?.mime,
                videoBps = track?.bitrateBps,
                frameCount = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                    ?.toIntOrNull()?.takeIf { it > 0 }
            )
        } catch (e: Exception) {
            null
        } finally {
            runCatching { mmr.release() }
        }
    }

    private data class SourceVideo(val mime: String, val fps: Float?, val bitrateBps: Long?)

    private fun videoTrackOf(context: Context, uri: Uri): SourceVideo? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(context, uri, null)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    val fps = try {
                        format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                    } catch (e: Exception) {
                        try {
                            format.getFloat(MediaFormat.KEY_FRAME_RATE)
                        } catch (e2: Exception) {
                            null
                        }
                    }
                    // Often missing; never worth losing the frame rate over.
                    val bps = runCatching {
                        if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
                            format.getInteger(MediaFormat.KEY_BIT_RATE).toLong()
                        } else {
                            null
                        }
                    }.getOrNull()?.takeIf { it > 0 }
                    return SourceVideo(mime, fps, bps)
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
