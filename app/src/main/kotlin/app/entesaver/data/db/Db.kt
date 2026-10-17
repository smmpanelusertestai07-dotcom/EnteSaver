package app.entesaver.data.db

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Delete
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Update
import androidx.room.migration.Migration
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.execSQL
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.StageRules
import kotlinx.coroutines.flow.Flow

/**
 * One row per original gallery item, keyed by its path-independent fingerprint.
 * Enum-typed fields are stored as their enum names (stable, snapshot-friendly).
 */
@Entity(
    tableName = "items",
    indices = [
        Index(value = ["fingerprint"], unique = true), Index("state"), Index("captureAt"),
        // AA3.5: every column the lists filter or sort by. Without these a
        // 10,000-item gallery turns each chip tap into a table scan.
        Index("isVideo"), Index("bucket"), Index("sizeBytes"),
        Index("evidence"), Index("batchId")
    ]
)
data class ItemRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val fingerprint: String,
    val mediaStoreId: Long? = null,
    val contentUri: String? = null,
    val displayName: String,
    val sizeBytes: Long,
    val dateModified: Long,
    val captureAt: Long,
    /**
     * When the user asked for this file to jump the queue, or 0.
     *
     * "Optimise this first" used to write [captureAt] = now, because the queue
     * is ordered by capture date. That is the file's REAL shooting date: it is
     * printed in the details dialog, stamped onto the released copy so the
     * cloud files it chronologically, and used to sort "Newest". Jumping the
     * queue therefore told the user, and the cloud, that a photo from 2019 was
     * taken today - permanently, for a sort order that lasts one run.
     */
    val priorityAt: Long = 0,
    val dateAdded: Long = 0,
    val durationMs: Long = 0,
    val mimeType: String,
    val isVideo: Boolean,
    val bucket: String? = null,
    val state: String,
    val evidence: String = "NONE",
    val goneReason: String? = null,
    val skipReason: String? = null,
    val stagePath: String? = null,
    val outputUri: String? = null,
    val outputName: String? = null,
    val outputBytes: Long? = null,
    /**
     * Pixels the encoder actually read and actually wrote. Zero means unknown
     * (an as-is copy, or a format the app never decoded), which every reader
     * treats as "no detail figure" rather than as a 100% or 0% claim.
     */
    val srcPixels: Long = 0,
    val outPixels: Long = 0,
    val outputSha256: String? = null,
    val outputFolder: String? = null,
    /**
     * The folder this copy was actually released into, as MediaStore wrote
     * it, without the trailing slash. A row answers "is my copy still
     * there?" by looking in its own folder: once a person can move where
     * copies go, the folder a copy was released into and the folder new
     * copies go to are no longer the same thing.
     */
    val outputRelPath: String? = null,
    val presetUsed: String? = null,
    val codecUsed: String? = null,
    val batchId: Long? = null,
    val releasedAt: Long? = null,
    val confirmedAt: Long? = null,
    /**
     * When the copy last left the upload folder: the write that took the row
     * out of RELEASED, whatever it went to - gone, finished, freed, skipped
     * or sent back to the queue. Written there and nowhere else, so no later
     * bookkeeping on the row moves it, and kept when [releasedAt] is cleared.
     * Cleared when the row is released again. A row that left before 12.2
     * carries its last change at the upgrade, never earlier than it left; a
     * restored copy the reattach pass did not find, the time of that pass.
     * Null for a row that never left, or one whose copy may still be in the
     * folder (restored, not yet looked for).
     */
    val leftFolderAt: Long? = null,
    val attempts: Int = 0,
    val lastError: String? = null,
    val originalMissing: Boolean = false,
    val appDeletedCopy: Boolean = false,
    val fromImport: Boolean = false,
    /**
     * Bytes the cloud app transmitted while this copy was waiting, recorded
     * when the copy was graded. Kept for the details screen, so a claim about
     * a file can always be traced back to the number behind it.
     */
    val txObserved: Long = 0,
    /** Which encoder produced the copy, for the details screen. */
    val encoderName: String? = null,
    /** Times a vanished copy was re-sent; two is the limit. */
    val resendCount: Int = 0,
    /**
     * SHA-256 of the ORIGINAL file, computed lazily and only where a size
     * collision makes it worth the read. This is what makes duplicate
     * detection a fact rather than a guess.
     */
    val originalSha256: String? = null,
    /**
     * Fingerprint of the item this one is a byte-identical copy of. Set means
     * "already handled": never optimised, never released, never counted as a
     * problem.
     */
    val duplicateOf: String? = null,
    /** The user asked for this file to be left alone, permanently. */
    val neverOptimise: Boolean = false,
    /** Where the kept light copy lives once the original was replaced. */
    val keptUri: String? = null,
    /**
     * Where the original waits after it was replaced in place: an item of
     * Ente Saver's own in the phone's trash, or (Android 10) a hidden file
     * beside it - 30 days either way, then gone. Null for every other row.
     */
    val backupUri: String? = null,
    /**
     * Output size the profile predicted before this item was processed, kept
     * against the real result so the app can state how wrong its estimates
     * have been instead of implying they are exact.
     */
    val predictedBytes: Long = 0,
    val updatedAt: Long = 0
)

/**
 * The [ItemRow.leftFolderAt] a write taking this row to [state] at [now]
 * carries: [now] when the write takes it out of RELEASED, what it had
 * otherwise. For writers that do not know the state they found the row in.
 */
fun ItemRow.leftFolderAtAfter(state: String, now: Long): Long? =
    if (this.state == ItemState.RELEASED.name && state != ItemState.RELEASED.name) now else leftFolderAt

/**
 * One reclaim batch, so "what did I delete last week" has an answer.
 *
 * Kept for 30 days, which is exactly how long Android's own trash holds the
 * files: past that there is nothing left to restore and nothing to say.
 */
@Entity(tableName = "reclaim_batches", indices = [Index("atMs")])
data class ReclaimBatchRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val atMs: Long,
    /** ReclaimMode name. */
    val mode: String,
    val itemCount: Int,
    val freedBytes: Long,
    /** True when the files went to the system trash rather than being erased. */
    val trashed: Boolean
)

/** One file in a reclaim batch, with enough detail to find it again. */
@Entity(
    tableName = "reclaim_items",
    indices = [Index("batchId"), Index("fingerprint")]
)
data class ReclaimItemRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val batchId: Long,
    val fingerprint: String,
    val displayName: String,
    val album: String? = null,
    val originalBytes: Long,
    val optimisedBytes: Long,
    /** The original's content uri, so a restore can un-trash exactly this file. */
    val contentUri: String? = null,
    val trashed: Boolean,
    /** Set once the user restored it, so the row stops offering to. */
    val restoredAt: Long? = null
)

/**
 * What this phone's media actually looks like, per quality preset and codec.
 *
 * Every estimate the app shows is derived from here, so there is one place to
 * be right and one place to say whether a figure was measured or assumed.
 */
@Entity(tableName = "media_profile", primaryKeys = ["preset", "codec"])
data class MediaProfileRow(
    val preset: String,
    val codec: String,
    val photoCount: Int = 0,
    val photoBytes: Long = 0,
    val photoMedianBytes: Long = 0,
    val photoRatio: Double = 0.0,
    val photoSamples: Int = 0,
    val photoAsIsShare: Double = 0.0,
    val videoCount: Int = 0,
    val videoBytes: Long = 0,
    val videoMedianBytes: Long = 0,
    val videoMinutes: Double = 0.0,
    val videoRatio: Double = 0.0,
    val videoOutMbPerMin: Double = 0.0,
    val videoSamples: Int = 0,
    val videoAsIsShare: Double = 0.0,
    /** Mean absolute percentage error of the last 200 predictions, per type. */
    val photoErrorPercent: Double = 0.0,
    val videoErrorPercent: Double = 0.0,
    val updatedAt: Long = 0
)

/**
 * On-battery work done today (13.G). Keyed by the local date, so the budget
 * simply resets at local midnight - no timer, no alarm.
 */
@Entity(tableName = "day_budget")
data class DayBudgetRow(
    @PrimaryKey val day: String,
    val videoEncodeMs: Long = 0,
    val photosOnBattery: Int = 0
)

/**
 * Permanent record of copies that reached the cloud, keyed by the copy's
 * SHA-256 and the original's fingerprint.
 *
 * This is what stops the queue growing forever. Once a copy is evidenced, the
 * item is finished for good: if the cloud later removes the file from the
 * upload folder - which is exactly what a cloud with a free-up feature does -
 * the app must not read that as "lost" and send it again. The ledger outlives
 * the item row and travels in every snapshot, so a reinstall cannot undo it.
 */
@Entity(tableName = "ledger", indices = [Index(value = ["outputSha256"], unique = true), Index("fingerprint")])
data class LedgerRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val outputSha256: String,
    val fingerprint: String,
    val displayName: String,
    val outputBytes: Long,
    val evidence: String,
    val confirmedAt: Long
)

/**
 * One line in the Activity log: what the app did, in the user's words.
 *
 * Everything that would otherwise only exist as a notification lands here
 * too, so nothing is lost to a swipe.
 */
@Entity(tableName = "activity", indices = [Index("atMs"), Index("kind")])
data class ActivityRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val atMs: Long,
    val kind: String,
    /** Optional detail rendered after the headline, already formatted. */
    val detail: String? = null,
    val count: Int = 0,
    val bytes: Long = 0,
    /** Filters Files when the row is tapped, when it makes sense. */
    val filterState: String? = null
)

/**
 * What a given cloud app can do, learned rather than asked.
 *
 * Defaults come from the registry; observing the app actually free up space
 * promotes it. The user is never asked a question about capabilities.
 */
@Entity(tableName = "cloud_capability")
data class CloudCapabilityRow(
    @PrimaryKey val cloudId: String,
    val hasFreeUpSpace: Boolean,
    val hasHashDedupe: Boolean,
    val packageName: String? = null,
    val lastSeenVersionCode: Long = 0,
    /** Set once the app is seen removing its own uploaded copies. */
    val learnedFreeUp: Boolean = false,
    val updatedAt: Long = 0
)

@Entity(tableName = "batches")
data class BatchRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val releasedAt: Long,
    val totalBytes: Long,
    val folder: String,
    val cloudPackage: String? = null,
    val verifiedAt: Long? = null
)

data class StateCount(val state: String, val cnt: Int)

/**
 * A released copy that has left the folder since: when its row last changed,
 * and what it was proved with.
 */
data class LeftRow(val id: Long, val leftAt: Long, val evidence: String, val confirmedAt: Long?)

/** How many released copies wait in one folder. */
data class FolderCount(val outputRelPath: String, val cnt: Int)

/** Compression outcome sample for the cloud calculator. */
data class RatioSample(val sizeBytes: Long, val outputBytes: Long, val durationMs: Long)

/** What the profile predicted against what actually came out. */
data class PredictionSample(
    val sizeBytes: Long,
    val outputBytes: Long,
    val predictedBytes: Long
)

/**
 * What has to happen to typed text before it becomes part of a SQL pattern.
 *
 * Everything the user types goes into the search box as ordinary characters,
 * but two of them are instructions to SQL LIKE: '%' stands for any run of
 * characters and '_' for any single one. A person searching for the file they
 * literally named "50%_holiday.jpg" was handed their whole library instead,
 * and a search for "IMG_2024" quietly matched "IMGx2024" too. Escaping them
 * here, and naming the same escape character in the query's ESCAPE clause,
 * makes the search mean what was typed.
 */
object Search {

    /** The character the queries name in their ESCAPE clause. */
    const val LIKE_ESCAPE = "\\"

    /**
     * The backslash goes first: escaping it after the wildcards would escape
     * the backslashes this function had just added, and undo its own work.
     */
    fun escapeLike(q: String): String = q
        .replace(LIKE_ESCAPE, LIKE_ESCAPE + LIKE_ESCAPE)
        .replace("%", LIKE_ESCAPE + "%")
        .replace("_", LIKE_ESCAPE + "_")
}

/** Replaced originals still in the trash ([ItemDao.keptOriginalsFlow]). */
data class KeptOriginals(val count: Int, val bytes: Long)

/** The originals that may be freed now (ItemDao.reclaimableBytesFlow explains each clause). */
private const val RECLAIMABLE_BYTES =
    "SELECT COALESCE(SUM(sizeBytes), 0) FROM items " +
        "WHERE originalMissing = 0 AND contentUri IS NOT NULL " +
        "AND outputSha256 IS NOT NULL " +
        "AND state IN ('RELEASED', 'GONE', 'DONE') " +
        "AND sizeBytes >= :minSizeBytes " +
        "AND dateAdded <= :addedBeforeSeconds " +
        "AND outputSha256 IN (SELECT outputSha256 FROM ledger) " +
        // The confirmation has to have aged, whichever grade it is. The
        // fallback is the row itself: no date means nothing has settled.
        "AND COALESCE(confirmedAt, releasedAt, :settledBefore + 1) <= :settledBefore " +
        "AND (evidence IN ('CONFIRMED_EXACT', 'CONFIRMED', 'CONFIRMED_PACED') " +
        "OR (:includeVerified AND evidence = 'VERIFIED'))"

/**
 * When a row that is not RELEASED left the folder: [ItemRow.leftFolderAt],
 * or for a released row without one - restored, its copy perhaps still in
 * the folder - its last change. Null - never matched - for a row that was
 * never released. Until the reattach pass has matched restored rows to the
 * folder, MaintainEngine counts each as there throughout (see
 * [ItemDao.restoredUnmatched]); the pass dates those it did not find to
 * itself ([ItemDao.stampRestoredLeft]).
 */
private const val LEFT_AT =
    "COALESCE(leftFolderAt, CASE WHEN releasedAt IS NOT NULL THEN updatedAt END)"

@Dao
interface ItemDao {

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(row: ItemRow): Long

    @Update
    suspend fun update(row: ItemRow)

    @Query("SELECT * FROM items WHERE fingerprint = :fp LIMIT 1")
    suspend fun byFingerprint(fp: String): ItemRow?

    /**
     * Rows still waiting that nothing has been made from, by address - what
     * the scan checks for files edited in place (StageRules.replaced). Three
     * columns, not whole rows: on a first scan this is the whole gallery.
     */
    @Query(
        "SELECT id, fingerprint, contentUri FROM items WHERE state = 'NEW' " +
            "AND contentUri IS NOT NULL AND stagePath IS NULL AND outputUri IS NULL " +
            "AND releasedAt IS NULL"
    )
    suspend fun waitingAddresses(): List<StageRules.Waiting>

    /**
     * Retires waiting rows whose file was replaced under their address, the
     * way Free up retires a changed original. The conditions are repeated so
     * a row staged since it was read is left alone.
     */
    @Query(
        "UPDATE items SET state = 'DONE', originalMissing = 1, mediaStoreId = NULL, " +
            "contentUri = NULL, updatedAt = :now WHERE id IN (:ids) AND state = 'NEW' " +
            "AND stagePath IS NULL AND outputUri IS NULL AND releasedAt IS NULL"
    )
    suspend fun retireReplaced(ids: List<Long>, now: Long): Int

    /**
     * The one-time repair of rows a 12.1 restore wrote (StartupRecovery).
     *
     * That restore gave a waiting row the history's "never optimise" and
     * evidence without settling it: the photo stayed in the queue and was
     * sent anyway, and its new copy, already "proven", was never watched.
     * It also restored waiting rows with no address, which no scan can ever
     * match, and duplicates without the original they belong to.
     */
    @Query("SELECT * FROM items WHERE neverOptimise = 1 AND state IN ('NEW', 'STAGED')")
    suspend fun waitingButExcluded(): List<ItemRow>

    /** Parks those rows as setNeverOptimise does; their staged files go first. */
    @Query(
        "UPDATE items SET state = 'SKIP', skipReason = 'user_excluded', stagePath = NULL, " +
            "outputName = NULL, outputBytes = NULL, outputSha256 = NULL, outputFolder = NULL, " +
            "updatedAt = :now WHERE neverOptimise = 1 AND state IN ('NEW', 'STAGED')"
    )
    suspend fun parkWaitingExcluded(now: Long): Int

    /** A row still waiting has no copy Ente could have, so no evidence either. */
    @Query(
        "UPDATE items SET evidence = 'NONE', confirmedAt = NULL, updatedAt = :now " +
            "WHERE state IN ('NEW', 'STAGED') AND evidence IS NOT NULL " +
            "AND evidence NOT IN ('', 'NONE')"
    )
    suspend fun clearWaitingEvidence(now: Long): Int

    /** Restored rows nothing can ever match or explain; a scan rebuilds the real ones. */
    @Query(
        "DELETE FROM items WHERE fromImport = 1 AND contentUri IS NULL AND mediaStoreId IS NULL " +
            "AND neverOptimise = 0 AND keptUri IS NULL AND outputSha256 IS NULL " +
            "AND (state = 'NEW' OR (state = 'SKIP' AND skipReason = 'no_uri') " +
            "OR (state = 'SKIP' AND skipReason = 'duplicate' AND duplicateOf IS NULL))"
    )
    suspend fun deleteRestoredGhosts(): Int

    @Query("SELECT * FROM items WHERE id = :id LIMIT 1")
    suspend fun byId(id: Long): ItemRow?

    @Query("SELECT * FROM items WHERE id IN (:ids)")
    suspend fun byIds(ids: List<Long>): List<ItemRow>

    @Query("SELECT * FROM items WHERE id IN (:ids)")
    fun byIdsFlow(ids: List<Long>): Flow<List<ItemRow>>

    @Query("SELECT * FROM items WHERE state = :state")
    suspend fun byState(state: String): List<ItemRow>

    /** Drops a row entirely; used when a folder turns out to be another pipeline's output. */
    @Delete
    suspend fun delete(row: ItemRow)

    /**
     * The newest photos still waiting, for the three-file trial.
     *
     * Photos only. A trial exists to give quick proof, and encoding one 4K
     * clip on a phone can take minutes - long enough that "try it" reads as
     * broken rather than as careful.
     *
     * Ticked albums only. The trial card promises "from the albums you
     * chose", and the scan inventories the whole phone regardless of the
     * choice - so without this clause the trial optimised three photos from
     * albums the user had just declined to hand over. Every question about
     * work the pipeline WILL do carries this same clause; the inventory
     * itself stays whole-phone on purpose, for returned-copy and duplicate
     * detection.
     */
    @Query(
        "SELECT * FROM items WHERE state = 'NEW' AND originalMissing = 0 " +
            "AND isVideo = 0 " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets)) " +
            "ORDER BY captureAt DESC LIMIT :limit"
    )
    suspend fun newestNewPhotos(limit: Int, excludedBuckets: Collection<String>): List<ItemRow>

    @Query(
        "SELECT COUNT(*) FROM items WHERE state = 'NEW' AND originalMissing = 0 " +
            "AND isVideo = 0 " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets))"
    )
    fun waitingPhotoCountFlow(excludedBuckets: Collection<String>): Flow<Int>

    /**
     * How much is genuinely queued: NEW, present, and in a ticked album.
     * This is the number Home's "waiting" tile, the hub's "next" line and
     * the stopped-work warning all quote - a promise about future runs, so
     * it must count only what a run may actually touch.
     */
    @Query(
        "SELECT COUNT(*) FROM items WHERE state = 'NEW' AND originalMissing = 0 " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets))"
    )
    fun newInScopeCountFlow(excludedBuckets: Collection<String>): Flow<Int>

    @Query(
        "SELECT COUNT(*) FROM items WHERE state = 'NEW' AND originalMissing = 0 " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets))"
    )
    suspend fun newInScopeCount(excludedBuckets: Collection<String>): Int

    /**
     * Everything the app knows about that sits in a ticked album, and
     * everything it knows about that sits in any album at all.
     *
     * The pair answers one question cheaply, off the table that is already
     * populated: is the queue empty because the work is done, or because not
     * one album is ticked? Asking MediaStore would mean walking the whole
     * gallery every time Home opened.
     */
    @Query(
        "SELECT COUNT(*) FROM items WHERE bucket IS NOT NULL " +
            "AND bucket NOT IN (:excludedBuckets)"
    )
    fun inScopeItemCountFlow(excludedBuckets: Collection<String>): Flow<Int>

    @Query("SELECT COUNT(*) FROM items WHERE bucket IS NOT NULL")
    fun bucketedItemCountFlow(): Flow<Int>

    /**
     * Detail kept across every file the app really encoded, and how many that
     * is.
     *
     * Averaged per file, not per pixel: the question a person is asking is
     * "what happened to my photos", and one 8K video should not outvote two
     * hundred of them. Rows with no recorded pixel counts are excluded rather
     * than counted as either 0% or 100%.
     */
    @Query(
        "SELECT COALESCE(AVG(CAST(outPixels AS REAL) * 100.0 / srcPixels), 0) FROM items " +
            "WHERE srcPixels > 0 AND outPixels > 0"
    )
    fun detailKeptPercentFlow(): Flow<Double>

    @Query("SELECT COUNT(*) FROM items WHERE srcPixels > 0 AND outPixels > 0")
    fun detailKeptSampleFlow(): Flow<Int>


    @Query("SELECT * FROM items WHERE state = 'STAGED'")
    suspend fun staged(): List<ItemRow>

    /**
     * Self-heal for a staged row whose file is gone: back to the queue. Only
     * while it is still staged on that same file - a restore may have taken
     * it over or parked it since it was read (and deleted the file as it
     * did), and the row read before that must not be written back over it.
     */
    @Query(
        "UPDATE items SET state = 'NEW', stagePath = NULL, outputBytes = NULL, " +
            "outputSha256 = NULL, updatedAt = :now WHERE id = :id AND state = 'STAGED' " +
            "AND stagePath IS :path"
    )
    suspend fun unstageIfStill(id: Long, path: String?, now: Long): Int

    @Query("SELECT * FROM items WHERE state = 'RELEASED'")
    suspend fun released(): List<ItemRow>

    /**
     * Copies that left the folder at or after [since], whatever they are now,
     * with when they left: [ItemRow.leftFolderAt], kept by every way out of
     * RELEASED - a copy sent back to the queue too, whose release time is
     * cleared. A row that left before that was recorded falls back to what
     * was read before: a released row's last change, which is never earlier
     * than the copy leaving.
     */
    @Query(
        "SELECT id, $LEFT_AT AS leftAt, evidence, confirmedAt FROM items " +
            "WHERE state != 'RELEASED' AND $LEFT_AT >= :since"
    )
    suspend fun leftReleasedSince(since: Long): List<LeftRow>

    /**
     * Copies in the folder that carry AGED or VERIFIED, or have no release
     * time. While any is there, nothing beside it can be proved by traffic.
     */
    @Query(
        "SELECT COUNT(*) FROM items WHERE state = 'RELEASED' AND " +
            "(evidence IN ('AGED', 'VERIFIED') OR releasedAt IS NULL)"
    )
    fun gradedInFolderCountFlow(): Flow<Int>

    /** Batches some row belongs to. A batch no row names has nothing to verify. */
    @Query("SELECT DISTINCT batchId FROM items WHERE batchId IS NOT NULL")
    suspend fun linkedBatchIds(): List<Long>

    /** Every folder a copy still waits in. */
    @Query(
        "SELECT DISTINCT outputRelPath FROM items " +
            "WHERE state = 'RELEASED' AND outputRelPath IS NOT NULL"
    )
    suspend fun releasedRoots(): List<String>

    /** Every folder a row restored from a history file says its copy was in. */
    @Query(
        "SELECT DISTINCT outputRelPath FROM items " +
            "WHERE state = 'UNKNOWN' AND outputRelPath IS NOT NULL"
    )
    suspend fun restoredRoots(): List<String>

    /**
     * Rows restored from a history file whose copy may still be in the
     * folder: until the reattach pass has looked, nothing says it is not.
     */
    @Query("SELECT id FROM items WHERE state = 'UNKNOWN' AND releasedAt IS NOT NULL")
    suspend fun restoredUnmatched(): List<Long>

    /**
     * Dates every restored copy the reattach pass did not find as having left
     * at [now], when the pass looked: until then nothing said it was not in
     * the folder. Never earlier than a time it already carries.
     */
    @Query(
        "UPDATE items SET leftFolderAt = :now WHERE state = 'UNKNOWN' AND releasedAt IS NOT NULL " +
            "AND (leftFolderAt IS NULL OR leftFolderAt < :now)"
    )
    suspend fun stampRestoredLeft(now: Long): Int

    /** Rows restored from a history file that came with some upload evidence. */
    @Query(
        "SELECT * FROM items WHERE state = 'UNKNOWN' " +
            "AND evidence IS NOT NULL AND evidence NOT IN ('', 'NONE')"
    )
    suspend fun restoredWithEvidence(): List<ItemRow>

    /** Released copies still waiting, counted per folder. */
    @Query(
        "SELECT outputRelPath, COUNT(*) AS cnt FROM items " +
            "WHERE state = 'RELEASED' AND outputRelPath IS NOT NULL GROUP BY outputRelPath"
    )
    suspend fun releasedPerFolder(): List<FolderCount>

    /** Copies still waiting in [relPath] or a folder inside it. */
    @Query(
        "SELECT COUNT(*) FROM items WHERE state = 'RELEASED' AND " +
            "(outputRelPath = :relPath COLLATE NOCASE OR outputRelPath LIKE :like ESCAPE '\\')"
    )
    suspend fun releasedCountIn(relPath: String, like: String): Int

    /** Released copies still waiting on evidence, oldest first. */
    @Query(
        "SELECT * FROM items WHERE state = 'RELEASED' AND evidence = 'NONE' " +
            "ORDER BY releasedAt ASC"
    )
    suspend fun awaitingEvidence(): List<ItemRow>

    /**
     * Fresh items newest-first, then the backlog largest-first.
     *
     * Recent photos are what the user is thinking about, so they go first;
     * after that, the biggest files free the most space per minute of work,
     * which beats grinding through a thousand old screenshots.
     *
     * [holdOverrun] leaves out a clip that already ran out of time once
     * (Stager.overran: a counted try, or a plain run's hold with its date).
     * A run without a foreground service asks for the queue that way first,
     * so such a clip is no longer first in every one of those runs, burning
     * their whole window; it is taken when nothing else is left, or by a run
     * with the whole budget.
     */
    @Query(
        "SELECT * FROM items WHERE state = 'NEW' AND originalMissing = 0 " +
            "AND ((isVideo = 0 AND :photos = 1) OR (isVideo = 1 AND :videos = 1 " +
            "AND (:videoMaxMs < 0 OR durationMs BETWEEN 1 AND :videoMaxMs) " +
            "AND (:holdOverrun = 0 OR lastError IS NULL OR lastError NOT GLOB 'out_of_time*'))) " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets)) " +
            "AND id NOT IN (:skipIds) " +
            "ORDER BY priorityAt DESC, (captureAt >= :freshAfter) DESC, " +
            "CASE WHEN captureAt >= :freshAfter THEN captureAt ELSE 0 END DESC, " +
            "CASE WHEN captureAt < :freshAfter THEN sizeBytes ELSE 0 END DESC " +
            "LIMIT :limit"
    )
    suspend fun nextByPriority(
        photos: Boolean,
        videos: Boolean,
        excludedBuckets: Collection<String>,
        freshAfter: Long,
        limit: Int,
        /** The longest video to take, in ms; negative for any length. */
        videoMaxMs: Long,
        /** Rows this run has already passed over. */
        skipIds: Collection<Long>,
        /** Leave out clips that already ran out of time once. */
        holdOverrun: Boolean
    ): List<ItemRow>

    @Query(
        "SELECT COALESCE(SUM(sizeBytes - outputBytes), 0) FROM items " +
            "WHERE outputBytes IS NOT NULL AND outputBytes < sizeBytes AND isVideo = :video"
    )
    fun savedBytesFlow(video: Boolean): Flow<Long>

    @Query("SELECT COUNT(*) FROM items WHERE outputBytes IS NOT NULL AND isVideo = :video")
    fun processedCountFlow(video: Boolean): Flow<Int>

    @Query("SELECT COUNT(*) FROM items WHERE outputBytes IS NOT NULL AND isVideo = :video")
    suspend fun processedCountFor(video: Boolean): Int

    /** Copies taken byte-for-byte; lastError carries the reason for those. */
    @Query(
        "SELECT COUNT(*) FROM items WHERE outputBytes IS NOT NULL " +
            "AND lastError IS NOT NULL AND isVideo = :video"
    )
    suspend fun asIsCount(video: Boolean): Int

    @Query(
        "SELECT lastError AS state, COUNT(*) AS cnt FROM items " +
            "WHERE outputBytes IS NOT NULL AND lastError IS NOT NULL AND isVideo = :video " +
            "GROUP BY lastError ORDER BY cnt DESC LIMIT 5"
    )
    suspend fun asIsReasons(video: Boolean): List<StateCount>

    /**
     * Waiting bytes split by media type, ticked albums only.
     *
     * Photos and videos compress very differently, so a projection that
     * averages one ratio across the pile is wrong in both directions. And a
     * projection over albums the user excluded promises savings no run will
     * ever deliver, so the scope clause applies here too.
     */
    @Query(
        "SELECT COALESCE(SUM(sizeBytes), 0) FROM items " +
            "WHERE state = 'NEW' AND originalMissing = 0 AND isVideo = :video " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets))"
    )
    suspend fun pendingBytesByType(video: Boolean, excludedBuckets: Collection<String>): Long

    /** How many are still to do, so the projection can say what it covers. */
    @Query(
        "SELECT COUNT(*) FROM items " +
            "WHERE state = 'NEW' AND originalMissing = 0 AND isVideo = :video " +
            "AND (bucket IS NULL OR bucket NOT IN (:excludedBuckets))"
    )
    suspend fun pendingCountByType(video: Boolean, excludedBuckets: Collection<String>): Int

    /** Bytes saved by work done since [fromMs] - what one run achieved. */
    @Query(
        "SELECT COALESCE(SUM(sizeBytes - outputBytes), 0) FROM items " +
            "WHERE outputBytes IS NOT NULL AND outputBytes < sizeBytes AND updatedAt >= :fromMs"
    )
    suspend fun savedBytesSince(fromMs: Long): Long

    /**
     * Skip reasons with counts, most common first - and only for the skips
     * Home calls problems.
     *
     * `duplicateOf IS NULL` is the same clause [problemSkippedCountFlow] uses
     * for the tile these rows sit under. Without it the rows counted every
     * SKIP including the duplicates the tile deliberately leaves out, so a
     * tile reading three sat above rows adding to eleven - and a reader who
     * adds them up is right and the screen is wrong. A duplicate was handled
     * under its twin, which is the app working, not a reason to explain.
     */
    @Query(
        "SELECT skipReason AS state, COUNT(*) AS cnt FROM items " +
            "WHERE state = 'SKIP' AND skipReason IS NOT NULL AND duplicateOf IS NULL " +
            "GROUP BY skipReason ORDER BY cnt DESC LIMIT 6"
    )
    suspend fun skipReasons(): List<StateCount>

    /**
     * Originals whose size is shared with at least one other file, newest
     * first. Only these are worth hashing: two files of different lengths
     * cannot be byte-identical, so the read is skipped entirely.
     */
    @Query(
        "SELECT * FROM items WHERE originalSha256 IS NULL AND originalMissing = 0 " +
            "AND sizeBytes IN (" +
            "SELECT sizeBytes FROM items WHERE originalMissing = 0 " +
            "GROUP BY sizeBytes HAVING COUNT(*) > 1) " +
            "ORDER BY sizeBytes DESC LIMIT :limit"
    )
    suspend fun sizeCollisions(limit: Int): List<ItemRow>

    /** Every hashed original, for grouping byte-identical files. */
    @Query(
        "SELECT * FROM items WHERE originalSha256 IS NOT NULL AND originalMissing = 0 " +
            "AND state != 'FREED' AND state != 'FREED_KEPT'"
    )
    suspend fun hashedOriginals(): List<ItemRow>

    @Query("SELECT COUNT(*) FROM items WHERE neverOptimise = 1")
    fun neverOptimiseCountFlow(): Flow<Int>

    /**
     * "Clear the list" has to undo what excluding a file did, not just the
     * flag that named it. Excluding parks the row in SKIP with the reason
     * `user_excluded`; clearing only the flag left every one of those rows
     * sitting in SKIP, so the setting said the files were back in the queue
     * and not one of them was.
     *
     * The CASE arms read the row as it was before this statement - SQLite
     * evaluates every SET expression against the old values - so the state
     * and the reason are decided together, and a row parked for some other
     * reason, or whose original has since gone, keeps the state it has.
     */
    @Query(
        "UPDATE items SET neverOptimise = 0, " +
            "state = CASE WHEN state = 'SKIP' AND skipReason = 'user_excluded' " +
            "  AND originalMissing = 0 THEN 'NEW' ELSE state END, " +
            "skipReason = CASE WHEN state = 'SKIP' AND skipReason = 'user_excluded' " +
            "  AND originalMissing = 0 THEN NULL ELSE skipReason END, " +
            "updatedAt = :now WHERE neverOptimise = 1"
    )
    suspend fun clearNeverOptimise(now: Long): Int

    /** The largest originals, for the "biggest space users" list. */
    @Query(
        "SELECT * FROM items WHERE originalMissing = 0 AND state != 'FREED' " +
            "AND state != 'FREED_KEPT' ORDER BY sizeBytes DESC LIMIT :limit"
    )
    suspend fun largest(limit: Int): List<ItemRow>

    /** Light copies the user kept, which are their files now. */
    @Query("SELECT * FROM items WHERE keptUri IS NOT NULL ORDER BY captureAt DESC")
    suspend fun keptCopies(): List<ItemRow>

    @Query("SELECT COALESCE(SUM(outputBytes), 0) FROM items WHERE keptUri IS NOT NULL")
    fun keptBytesFlow(): Flow<Long>

    /**
     * Originals replaced in place that still wait in the trash: how many,
     * and the space they hold. An empty backupUri is an original no longer
     * kept - deleted, or past its 30 days.
     */
    @Query(
        "SELECT COUNT(*) AS count, COALESCE(SUM(sizeBytes), 0) AS bytes FROM items " +
            "WHERE state = 'FREED_KEPT' AND backupUri IS NOT NULL AND backupUri != ''"
    )
    fun keptOriginalsFlow(): Flow<KeptOriginals>

    @Query("SELECT * FROM items WHERE state = 'FREED_KEPT' AND backupUri IS NOT NULL AND backupUri != ''")
    suspend fun keptOriginals(): List<ItemRow>

    /** An original no longer kept: deleted for good, or gone with the trash's 30 days. */
    @Query("UPDATE items SET backupUri = '', updatedAt = :now WHERE id = :id")
    suspend fun forgetBackup(id: Long, now: Long)

    /**
     * Everything reclaim may offer, before the per-item checks. The strict
     * rules live in ReclaimRules; SQL only narrows the set.
     */
    @Query(
        "SELECT * FROM items WHERE originalMissing = 0 AND contentUri IS NOT NULL " +
            "AND state IN ('RELEASED', 'GONE', 'DONE') " +
            "AND evidence IN ('CONFIRMED_EXACT', 'CONFIRMED_PACED', 'CONFIRMED', 'VERIFIED') " +
            "AND outputSha256 IS NOT NULL"
    )
    suspend fun reclaimCandidates(): List<ItemRow>

    /** Prediction accuracy sample: what we said, and what happened. */
    @Query(
        "SELECT sizeBytes, outputBytes, predictedBytes FROM items " +
            "WHERE outputBytes IS NOT NULL AND predictedBytes > 0 AND isVideo = :video " +
            "ORDER BY updatedAt DESC LIMIT 200"
    )
    suspend fun predictionSamples(video: Boolean): List<PredictionSample>


    @Query(
        "SELECT COALESCE(SUM(sizeBytes), 0) FROM items WHERE dateAdded > :sinceSeconds"
    )
    suspend fun bytesAddedSince(sinceSeconds: Long): Long

    @Query("SELECT * FROM items WHERE state = 'GONE'")
    suspend fun gone(): List<ItemRow>

    /** Which of [fps] the ledger has a row for, in any state. */
    @Query("SELECT fingerprint FROM items WHERE fingerprint IN (:fps)")
    suspend fun knownFingerprints(fps: List<String>): List<String>

    @Query("SELECT COUNT(*) FROM items WHERE state = :state")
    suspend fun countByState(state: String): Int

    @Query("SELECT state, COUNT(*) AS cnt FROM items GROUP BY state")
    fun stateCountsFlow(): Flow<List<StateCount>>

    /**
     * Skipped for a reason the user might want to do something about.
     *
     * A duplicate is a normal outcome - the file was handled once, under its
     * twin - not a problem, and counting it as one made a tidy gallery look
     * broken.
     */
    @Query("SELECT COUNT(*) FROM items WHERE state = 'SKIP' AND duplicateOf IS NULL")
    fun problemSkippedCountFlow(): Flow<Int>

    /** Files whose identical twin was optimised instead. */
    @Query("SELECT COUNT(*) FROM items WHERE duplicateOf IS NOT NULL")
    fun duplicatesHandledCountFlow(): Flow<Int>

    @Query(
        "SELECT COUNT(*) FROM items " +
            "WHERE evidence IN ('CONFIRMED_EXACT', 'CONFIRMED_PACED', 'CONFIRMED')"
    )
    fun confirmedCountFlow(): Flow<Int>

    @Query(
        "SELECT COUNT(*) FROM items " +
            "WHERE evidence IN ('CONFIRMED_EXACT', 'CONFIRMED_PACED', 'CONFIRMED')"
    )
    suspend fun confirmedCount(): Int

    @Query("SELECT COUNT(*) FROM items WHERE evidence = 'VERIFIED'")
    fun verifiedCountFlow(): Flow<Int>

    @Query(
        "SELECT COALESCE(SUM(sizeBytes - outputBytes), 0) FROM items " +
            "WHERE outputBytes IS NOT NULL AND outputBytes < sizeBytes"
    )
    fun savedBytesFlow(): Flow<Long>

    @Query("SELECT COUNT(*) FROM items WHERE outputBytes IS NOT NULL")
    fun processedCountFlow(): Flow<Int>

    /**
     * Files whose name contains what was typed, already narrowed to the chip
     * the user tapped and ordered the way they asked.
     *
     * The filter, the album scope and the sort are all in the statement
     * because the statement has a LIMIT. Doing any of them in Kotlin means
     * doing them to the newest 500 rows of the whole table - and the worker
     * takes newest first, so on a mature library those 500 are all finished
     * work. Tapping "Waiting" over a queue of twelve thousand filtered five
     * hundred DONE rows down to nothing and printed "No files match these
     * filters", while Home's own counter - a COUNT over the same table - said
     * twelve thousand. The list has to be cut after the question is asked,
     * not before.
     *
     * The ESCAPE clause is what makes that sentence true. In SQL LIKE, '%'
     * means "anything" and '_' means "any one character", so typing a percent
     * sign into the search box used to match every file on the phone, and
     * typing an underscore - which half the screenshots and camera exports
     * have in their names - matched names that had nothing in common with it.
     * The caller escapes those two characters (and the escape character
     * itself) with [Search.escapeLike], and this clause tells SQLite to read
     * them as the literal characters the user pressed.
     */
    @Query(
        "SELECT * FROM items WHERE displayName LIKE '%' || :q || '%' ESCAPE '\\' " +
            "AND (:anyState = 1 OR state IN (:states)) " +
            "AND (state != 'NEW' OR bucket IS NULL OR bucket NOT IN (:excludedBuckets)) " +
            "ORDER BY CASE :sortKey " +
            "  WHEN 1 THEN CASE WHEN outputBytes IS NULL THEN 0 ELSE sizeBytes - outputBytes END " +
            "  WHEN 2 THEN sizeBytes " +
            "  ELSE captureAt END DESC " +
            "LIMIT :limit"
    )
    fun searchFlow(
        q: String,
        states: Collection<String>,
        anyState: Int,
        excludedBuckets: Collection<String>,
        sortKey: Int,
        limit: Int
    ): Flow<List<ItemRow>>




    @Query("SELECT * FROM items")
    suspend fun all(): List<ItemRow>

    @Query("SELECT COUNT(*) FROM items")
    suspend fun count(): Int

    @Query("SELECT COALESCE(SUM(outputBytes), 0) FROM items WHERE state = 'RELEASED'")
    suspend fun releasedBytes(): Long

    /**
     * The headline on the Storage screen, which must agree with what Reclaim
     * space actually lists - otherwise the entry point to that screen stays
     * hidden while there are files behind it.
     *
     * It has to agree in the other direction too, and it did not. This sum
     * asked for less than [reclaimCandidates] does: it missed the copy's hash
     * (no hash, no proof the copy in the cloud is the one we made), the
     * original's uri (nothing to hand the system a delete request for) and
     * the three states a file has to be in before its original may go. Every
     * row that failed one of those was counted here and then refused on the
     * Free up screen, so "you could free 12 GB" led to a list that offered
     * four. A number this app prints is a number it can deliver, so the two
     * queries now ask the same questions.
     *
     * Three of those questions were still missing, and each of them can only
     * make the answer smaller: an original whose copy has no ledger entry has
     * no proof it ever went out, one added in the last thirty days has not
     * waited, and one under the size floor is never offered at all. Without
     * them the tab could wear a mark for a screen with nothing on it.
     *
     * `ReclaimRules.refuse` is still the authority - it also asks the cloud
     * app is installed, which SQL cannot, so the caller answers that before
     * asking at all. What this cannot ask is whether a photograph is a
     * favourite: that lives in MediaStore, not here.
     */
    @Query(RECLAIMABLE_BYTES)
    fun reclaimableBytesFlow(
        settledBefore: Long,
        addedBeforeSeconds: Long,
        minSizeBytes: Long,
        includeVerified: Boolean
    ): Flow<Long>

    /** The same total, asked once - by the maintenance pass (FreeableNote). */
    @Query(RECLAIMABLE_BYTES)
    suspend fun reclaimableBytes(
        settledBefore: Long,
        addedBeforeSeconds: Long,
        minSizeBytes: Long,
        includeVerified: Boolean
    ): Long

    @Query(
        "SELECT sizeBytes, outputBytes, durationMs FROM items " +
            "WHERE outputBytes IS NOT NULL AND isVideo = 0 AND presetUsed = :key " +
            "ORDER BY updatedAt DESC LIMIT 500"
    )
    suspend fun photoRatioSamples(key: String): List<RatioSample>

    @Query(
        "SELECT sizeBytes, outputBytes, durationMs FROM items " +
            "WHERE outputBytes IS NOT NULL AND isVideo = 1 AND presetUsed = :key " +
            "ORDER BY updatedAt DESC LIMIT 500"
    )
    suspend fun videoRatioSamples(key: String): List<RatioSample>
}

@Dao
interface BatchDao {

    @Insert
    suspend fun insert(batch: BatchRow): Long

    @Query("SELECT * FROM batches WHERE verifiedAt IS NULL")
    suspend fun unverified(): List<BatchRow>

    @Query("UPDATE batches SET verifiedAt = :at WHERE id = :id")
    suspend fun markVerified(id: Long, at: Long)

    /** Verified batches that a VERIFIED copy still in its folder belongs to. */
    @Query(
        "SELECT * FROM batches WHERE verifiedAt IS NOT NULL AND id IN " +
            "(SELECT batchId FROM items WHERE state = 'RELEASED' AND evidence = 'VERIFIED')"
    )
    suspend fun verifiedOfReleased(): List<BatchRow>

    @Query("UPDATE batches SET totalBytes = :bytes WHERE id = :id")
    suspend fun setTotalBytes(id: Long, bytes: Long)

    /** Drops a batch in which nothing was actually released. */
    @Query("DELETE FROM batches WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("SELECT COALESCE(SUM(totalBytes), 0) FROM batches WHERE releasedAt >= :fromMs")
    suspend fun bytesSince(fromMs: Long): Long


    @Query("SELECT * FROM batches")
    suspend fun all(): List<BatchRow>

    @Query("SELECT * FROM batches WHERE id = :id LIMIT 1")
    suspend fun byId(id: Long): BatchRow?
}

@Dao
interface DayBudgetDao {

    @Query("SELECT * FROM day_budget WHERE day = :day LIMIT 1")
    suspend fun byDay(day: String): DayBudgetRow?

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(row: DayBudgetRow): Long

    @Query("UPDATE day_budget SET videoEncodeMs = videoEncodeMs + :ms WHERE day = :day")
    suspend fun addEncodeMs(day: String, ms: Long)

    @Query("UPDATE day_budget SET photosOnBattery = photosOnBattery + :n WHERE day = :day")
    suspend fun addPhotos(day: String, n: Int)

    /** Yesterday and older are useless; keep the table at one row. */
    @Query("DELETE FROM day_budget WHERE day <> :day")
    suspend fun pruneOlderThan(day: String)
}

@Dao
interface LedgerDao {

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(row: LedgerRow): Long

    @Query("SELECT * FROM ledger WHERE outputSha256 = :sha LIMIT 1")
    suspend fun bySha(sha: String): LedgerRow?

    /** Sets the entry for [sha] to [evidence] where it holds one of [weaker]. */
    @Query(
        "UPDATE ledger SET evidence = :evidence, confirmedAt = :at " +
            "WHERE outputSha256 = :sha AND evidence IN (:weaker)"
    )
    suspend fun raise(sha: String, evidence: String, at: Long, weaker: List<String>): Int

    @Query("SELECT * FROM ledger")
    suspend fun all(): List<LedgerRow>
}

/**
 * Records a delivered copy, or raises the entry it already has when [row]
 * proves more: a copy verified with its batch and proven on its own later
 * keeps one entry, with its best proof. Never lowers one.
 */
suspend fun LedgerDao.record(row: LedgerRow) {
    if (insert(row) != -1L) return
    val grade = Evidence.parse(row.evidence)
    val weaker = Evidence.entries.filter { it.ordinal < grade.ordinal }.map { it.name }
    if (weaker.isNotEmpty()) raise(row.outputSha256, grade.name, row.confirmedAt, weaker)
}

@Dao
interface ActivityDao {

    @Insert
    suspend fun insert(row: ActivityRow): Long

    @Query("SELECT * FROM activity ORDER BY atMs DESC LIMIT :limit")
    fun recentFlow(limit: Int): Flow<List<ActivityRow>>

    @Query("SELECT * FROM activity WHERE kind IN (:kinds) ORDER BY atMs DESC LIMIT :limit")
    fun byKindsFlow(kinds: Collection<String>, limit: Int): Flow<List<ActivityRow>>

    @Query("SELECT * FROM activity ORDER BY atMs DESC LIMIT :limit")
    suspend fun recent(limit: Int): List<ActivityRow>

    @Query("SELECT COUNT(*) FROM activity WHERE atMs > :since")
    fun unreadCountFlow(since: Long): Flow<Int>

    /** Retention: 30 days or 500 rows, whichever bites first. */
    @Query("DELETE FROM activity WHERE atMs < :before")
    suspend fun pruneOlderThan(before: Long)

    @Query(
        "DELETE FROM activity WHERE id NOT IN " +
            "(SELECT id FROM activity ORDER BY atMs DESC LIMIT :keep)"
    )
    suspend fun pruneBeyond(keep: Int)

    @Query("DELETE FROM activity")
    suspend fun clear()
}

@Dao
interface ReclaimDao {

    @Insert
    suspend fun insertBatch(row: ReclaimBatchRow): Long

    @Insert
    suspend fun insertItems(rows: List<ReclaimItemRow>)

    @Query("SELECT * FROM reclaim_batches ORDER BY atMs DESC LIMIT :limit")
    fun recentBatchesFlow(limit: Int): Flow<List<ReclaimBatchRow>>

    @Query("SELECT * FROM reclaim_batches WHERE id = :id LIMIT 1")
    suspend fun batch(id: Long): ReclaimBatchRow?

    @Query("SELECT * FROM reclaim_items WHERE batchId = :batchId ORDER BY originalBytes DESC")
    suspend fun itemsOf(batchId: Long): List<ReclaimItemRow>


    @Query("UPDATE reclaim_items SET restoredAt = :at WHERE id = :id")
    suspend fun markRestored(id: Long, at: Long)

    /** History lives exactly as long as Android's own trash does. */
    @Query("DELETE FROM reclaim_batches WHERE atMs < :before")
    suspend fun pruneBatches(before: Long)

    @Query(
        "DELETE FROM reclaim_items WHERE batchId NOT IN (SELECT id FROM reclaim_batches)"
    )
    suspend fun pruneOrphanItems()
}

@Dao
interface MediaProfileDao {

    @Query("SELECT * FROM media_profile WHERE preset = :preset AND codec = :codec LIMIT 1")
    suspend fun get(preset: String, codec: String): MediaProfileRow?

    @Query("SELECT * FROM media_profile WHERE preset = :preset AND codec = :codec LIMIT 1")
    fun flow(preset: String, codec: String): Flow<MediaProfileRow?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(row: MediaProfileRow)
}

@Dao
interface CloudCapabilityDao {

    @Query("SELECT * FROM cloud_capability WHERE cloudId = :id LIMIT 1")
    suspend fun byId(id: String): CloudCapabilityRow?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(row: CloudCapabilityRow)

    @Query("SELECT * FROM cloud_capability")
    suspend fun all(): List<CloudCapabilityRow>
}

@Database(
    entities = [
        ItemRow::class, BatchRow::class, DayBudgetRow::class,
        LedgerRow::class, ActivityRow::class, CloudCapabilityRow::class,
        ReclaimBatchRow::class, ReclaimItemRow::class, MediaProfileRow::class
    ],
    version = 10,
    exportSchema = false
)
abstract class AppDb : RoomDatabase() {

    abstract fun items(): ItemDao
    abstract fun batches(): BatchDao
    abstract fun dayBudget(): DayBudgetDao
    abstract fun ledger(): LedgerDao
    abstract fun activity(): ActivityDao
    abstract fun capabilities(): CloudCapabilityDao
    abstract fun reclaim(): ReclaimDao
    abstract fun profile(): MediaProfileDao

    companion object {
        /** v2 adds the daily on-battery budget table (13.G). */
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `day_budget` (" +
                        "`day` TEXT NOT NULL, " +
                        "`videoEncodeMs` INTEGER NOT NULL, " +
                        "`photosOnBattery` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`day`))"
                )
            }
        }

        /**
         * v3 adds the upload ledger, the activity log, learned cloud
         * capabilities, and the three item columns paced release needs.
         */
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `ledger` (" +
                        "`id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "`outputSha256` TEXT NOT NULL, " +
                        "`fingerprint` TEXT NOT NULL, " +
                        "`displayName` TEXT NOT NULL, " +
                        "`outputBytes` INTEGER NOT NULL, " +
                        "`evidence` TEXT NOT NULL, " +
                        "`confirmedAt` INTEGER NOT NULL)"
                )
                connection.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS `index_ledger_outputSha256` " +
                        "ON `ledger` (`outputSha256`)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_ledger_fingerprint` " +
                        "ON `ledger` (`fingerprint`)"
                )
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `activity` (" +
                        "`id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "`atMs` INTEGER NOT NULL, " +
                        "`kind` TEXT NOT NULL, " +
                        "`detail` TEXT, " +
                        "`count` INTEGER NOT NULL, " +
                        "`bytes` INTEGER NOT NULL, " +
                        "`filterState` TEXT)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_activity_atMs` ON `activity` (`atMs`)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_activity_kind` ON `activity` (`kind`)"
                )
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `cloud_capability` (" +
                        "`cloudId` TEXT NOT NULL PRIMARY KEY, " +
                        "`hasFreeUpSpace` INTEGER NOT NULL, " +
                        "`hasHashDedupe` INTEGER NOT NULL, " +
                        "`packageName` TEXT, " +
                        "`lastSeenVersionCode` INTEGER NOT NULL, " +
                        "`learnedFreeUp` INTEGER NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL)"
                )
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `txObserved` INTEGER NOT NULL DEFAULT 0")
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `encoderName` TEXT")
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `resendCount` INTEGER NOT NULL DEFAULT 0")
            }
        }

        /**
         * v4 adds duplicate detection, the reclaim history and the media
         * profile that every estimate is derived from.
         */
        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `originalSha256` TEXT")
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `duplicateOf` TEXT")
                connection.execSQL(
                    "ALTER TABLE `items` ADD COLUMN `neverOptimise` INTEGER NOT NULL DEFAULT 0"
                )
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `keptUri` TEXT")
                connection.execSQL(
                    "ALTER TABLE `items` ADD COLUMN `predictedBytes` INTEGER NOT NULL DEFAULT 0"
                )
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `reclaim_batches` (" +
                        "`id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "`atMs` INTEGER NOT NULL, `mode` TEXT NOT NULL, " +
                        "`itemCount` INTEGER NOT NULL, `freedBytes` INTEGER NOT NULL, " +
                        "`trashed` INTEGER NOT NULL)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_reclaim_batches_atMs` " +
                        "ON `reclaim_batches` (`atMs`)"
                )
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `reclaim_items` (" +
                        "`id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "`batchId` INTEGER NOT NULL, `fingerprint` TEXT NOT NULL, " +
                        "`displayName` TEXT NOT NULL, `album` TEXT, " +
                        "`originalBytes` INTEGER NOT NULL, `optimisedBytes` INTEGER NOT NULL, " +
                        "`contentUri` TEXT, `trashed` INTEGER NOT NULL, `restoredAt` INTEGER)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_reclaim_items_batchId` " +
                        "ON `reclaim_items` (`batchId`)"
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_reclaim_items_fingerprint` " +
                        "ON `reclaim_items` (`fingerprint`)"
                )
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `media_profile` (" +
                        "`preset` TEXT NOT NULL, `codec` TEXT NOT NULL, " +
                        "`photoCount` INTEGER NOT NULL, `photoBytes` INTEGER NOT NULL, " +
                        "`photoMedianBytes` INTEGER NOT NULL, `photoRatio` REAL NOT NULL, " +
                        "`photoSamples` INTEGER NOT NULL, `photoAsIsShare` REAL NOT NULL, " +
                        "`videoCount` INTEGER NOT NULL, `videoBytes` INTEGER NOT NULL, " +
                        "`videoMedianBytes` INTEGER NOT NULL, `videoMinutes` REAL NOT NULL, " +
                        "`videoRatio` REAL NOT NULL, `videoOutMbPerMin` REAL NOT NULL, " +
                        "`videoSamples` INTEGER NOT NULL, `videoAsIsShare` REAL NOT NULL, " +
                        "`photoErrorPercent` REAL NOT NULL, `videoErrorPercent` REAL NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL, PRIMARY KEY(`preset`, `codec`))"
                )
            }
        }

        /**
         * v5 records the pixels each encode read and wrote, so the detail-kept
         * figure is measured per file instead of inferred from the preset.
         * Existing rows keep 0, which reads as "not measured" everywhere.
         */
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL(
                    "ALTER TABLE `items` ADD COLUMN `srcPixels` INTEGER NOT NULL DEFAULT 0"
                )
                connection.execSQL(
                    "ALTER TABLE `items` ADD COLUMN `outPixels` INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        /**
         * v6 adds the indices behind list filtering and sorting (AA3.5).
         * Pure additions: no data moves, nothing can be lost.
         */
        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(connection: SQLiteConnection) {
                for (column in listOf(
                    "isVideo", "bucket", "sizeBytes", "evidence", "batchId"
                )) {
                    connection.execSQL(
                        "CREATE INDEX IF NOT EXISTS `index_items_$column` " +
                            "ON `items` (`$column`)"
                    )
                }
            }
        }

        /**
         * v7 separates "the user asked for this first" from the file's real
         * shooting date.
         *
         * Until now "Optimise this first" wrote captureAt = now, because the
         * queue is ordered by capture date - so a photo from 2019 became a
         * photo from today, in the details dialog, in the Newest sort, and on
         * the copy handed to the cloud. Existing rows keep 0, which means "no
         * jump asked for" and leaves every real date untouched. Nothing is
         * rewritten: the dates already corrupted cannot be recovered, because
         * the original value was overwritten in place, and inventing one would
         * be worse than leaving what the file itself says.
         */
        private val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL(
                    "ALTER TABLE `items` ADD COLUMN `priorityAt` INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        /**
         * v8 records the folder each copy was released into, forgets other
         * cloud apps, and re-files encode results under the photo and video
         * settings that replaced the single preset.
         *
         * Every copy released so far went to the folder its layout named, so
         * that is filled in from the layout column; a copy released before
         * the layout column existed went to the single folder. Rows that
         * never reached a folder stay empty and are filled in on release.
         */
        private val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `outputRelPath` TEXT")
                connection.execSQL(
                    "UPDATE `items` SET `outputRelPath` = CASE `outputFolder` " +
                        "WHEN 'PHOTOS' THEN '${Defaults.LEGACY_OUTPUT_DIR_PHOTOS}' " +
                        "WHEN 'VIDEOS' THEN '${Defaults.LEGACY_OUTPUT_DIR_VIDEOS}' " +
                        "ELSE '${Defaults.LEGACY_OUTPUT_DIR}' END " +
                        "WHERE `outputUri` IS NOT NULL OR `releasedAt` IS NOT NULL"
                )
                // Ente Saver works with Ente Photos only. What was learned
                // about other cloud apps describes apps it no longer talks to.
                connection.execSQL("DELETE FROM `cloud_capability` WHERE `cloudId` != 'ente'")
                // Photos and videos have their own settings now, and encode
                // results are grouped by what each setting stood for. The old
                // single preset's results are re-filed under the same encode
                // in the new terms, so no estimate starts again from nothing.
                connection.execSQL(
                    "UPDATE `items` SET `presetUsed` = CASE `presetUsed` " +
                        "WHEN 'STORAGE_SAVER' THEN 'jpeg-16-82' " +
                        "WHEN 'BALANCED' THEN 'jpeg-24-85' " +
                        "WHEN 'MAX_SAVER' THEN 'jpeg-8-80' ELSE `presetUsed` END, " +
                        "`codecUsed` = NULL WHERE `isVideo` = 0"
                )
                connection.execSQL(
                    "UPDATE `items` SET `presetUsed` = lower(COALESCE(`codecUsed`, 'H264')) || '-' || " +
                        "CASE `presetUsed` WHEN 'STORAGE_SAVER' THEN '1920' " +
                        "WHEN 'BALANCED' THEN '2560' ELSE '1280' END || '-std' " +
                        "WHERE `isVideo` = 1 AND `presetUsed` IN ('STORAGE_SAVER', 'BALANCED', 'MAX_SAVER')"
                )
                // The stored profiles were keyed by the old preset; each is
                // rebuilt the first time it is asked for.
                connection.execSQL("DELETE FROM `media_profile`")
            }
        }

        /**
         * v9 records when each copy left the upload folder, so a copy that
         * shared Ente's traffic with another is known by when it left - not
         * by its row's last change, which any bookkeeping moves, and not only
         * while it keeps a release time, which a copy sent back to the queue
         * loses. A row that had already left gets its last change now - what
         * it was read by until today, never earlier than it left - so later
         * bookkeeping no longer moves it. A restored row (UNKNOWN), whose copy
         * may still be in the folder, stays empty and is read as before.
         */
        private val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `leftFolderAt` INTEGER")
                connection.execSQL(
                    "UPDATE `items` SET `leftFolderAt` = `updatedAt` " +
                        "WHERE `state` NOT IN ('RELEASED', 'UNKNOWN') AND `releasedAt` IS NOT NULL"
                )
            }
        }

        /** v10: where a replaced-in-place original waits ([ItemRow.backupUri]). */
        private val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `items` ADD COLUMN `backupUri` TEXT")
            }
        }

        /**
         * Every migration, in order. Public so the instrumented suite can
         * open a database built at an older version and prove the upgrade
         * path works: a wrong ALTER here does not fail the build, it crashes
         * the app on the first launch after an update.
         */
        val MIGRATIONS = arrayOf(
            MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5,
            MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10
        )

        @Volatile
        private var instance: AppDb? = null

        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                AppDb::class.java,
                // The file every install keeps its records in; a new name in
                // an update would start from an empty one.
                "entesaver.db"
            ).addMigrations(*MIGRATIONS).build().also { instance = it }
        }
    }
}
