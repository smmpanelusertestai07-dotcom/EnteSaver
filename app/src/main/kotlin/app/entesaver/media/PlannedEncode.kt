package app.entesaver.media

import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.PhotoFormat

/**
 * What optimising turns into on this phone, before any file is looked at:
 * the keys encode results are grouped under, so an estimate only ever quotes
 * files that were made the way new ones will be.
 *
 * Every video keeps its own codec, so its results are grouped by the codec it
 * was kept in, and an estimate quotes every video made the way new ones are
 * made, in either codec. Photos keep their own format, so their key is that
 * of the format nearly every phone photo is in.
 */
object PlannedEncode {

    fun photoKey(): String = MediaSettings.photoKey(PhotoFormat.JPEG)

    /** The keys of every video made the way new ones are made. */
    fun videoKeys(): List<String> = MediaSettings.videoKeys()

    /** The stored profile's name for those videos. */
    fun videoKey(): String = videoKeys().joinToString("+")
}
