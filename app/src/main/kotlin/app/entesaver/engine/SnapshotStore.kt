package app.entesaver.engine

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.room.withTransaction
import app.entesaver.R
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.GoneReason
import app.entesaver.core.logic.ImportMerge
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.SecureBackup
import app.entesaver.core.logic.SnapshotCodec
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.LedgerRow
import app.entesaver.data.db.record
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.OutputInventory
import app.entesaver.util.BoundedRead
import app.entesaver.util.Locks
import app.entesaver.util.Permissions
import java.io.File
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * State durability. Room is the source of truth; the daily history file
 * exists so a new install - after an uninstall, "Clear data" or on a new
 * phone - can pick up where the old one stopped (see Defaults.HISTORY_DIR for
 * why it is a visible file). The same format is what Settings, Backup and
 * restore saves and opens.
 *
 * Items imported without upload evidence become UNKNOWN until their copy is
 * found in the Ente Saver folder (ReattachRules); they are never freed on a
 * file's say-so.
 */
class SnapshotStore(
    private val context: Context,
    private val db: AppDb,
    private val optionsRepo: OptionsRepo
) {

    companion object {
        private val FOLDER_KEYS = setOf("folderSingle", "folderPhotos", "folderVideos")

        /**
         * How many rebuildable item rows a snapshot carries.
         *
         * The whole snapshot is encoded as one JSON document held in memory,
         * so an unbounded gallery means an unbounded allocation in a
         * background worker - and the failure is silent, because the daily
         * pass catches it and simply writes nothing. A phone that grows to
         * fifty thousand photos would quietly stop having a snapshot at all,
         * which is only discovered on the reinstall that needed it.
         *
         * Nothing safety-critical is ever dropped: rows that carry evidence
         * or a delivered copy are always written, whatever the count, because
         * losing one of those could let a file be sent to the cloud twice.
         * The rest are queue state, and a scan rebuilds them.
         */
        const val MAX_REBUILDABLE_ITEMS = 5_000
    }

    suspend fun build(): SnapshotCodec.Snapshot {
        val rows = db.items().all()
        // Anything the cloud has already seen, or that holds a copy, is
        // irreplaceable knowledge; everything else can be scanned again.
        val (critical, rebuildable) = rows.partition {
            it.outputSha256 != null || Evidence.parse(it.evidence) != Evidence.NONE
        }
        val kept = if (rebuildable.size <= MAX_REBUILDABLE_ITEMS) {
            rows
        } else {
            critical + rebuildable
                .sortedByDescending { it.updatedAt }
                .take(MAX_REBUILDABLE_ITEMS)
        }
        val items = kept.map { row ->
            SnapshotCodec.SnapItem(
                fingerprint = row.fingerprint,
                displayName = row.displayName,
                sizeBytes = row.sizeBytes,
                dateModified = row.dateModified,
                captureAt = row.captureAt,
                mimeType = row.mimeType,
                isVideo = row.isVideo,
                state = enumOr(row.state, ItemState.UNKNOWN),
                evidence = Evidence.parse(row.evidence),
                goneReason = enumOrNull<GoneReason>(row.goneReason),
                skipReason = row.skipReason,
                outputName = row.outputName,
                outputBytes = row.outputBytes,
                outputSha256 = row.outputSha256,
                outputFolder = enumOrNull<OutFolder>(row.outputFolder),
                releasedAt = row.releasedAt,
                confirmedAt = row.confirmedAt,
                keptUri = row.keptUri,
                neverOptimise = row.neverOptimise,
                outputRelPath = row.outputRelPath,
                duplicateOf = row.duplicateOf,
                leftFolderAt = row.leftFolderAt,
                backupUri = row.backupUri,
                // The hash a kept original is checked against; only rows
                // replaced on this phone carry one in the file.
                originalSha256 = row.originalSha256.takeIf { row.backupUri != null }
            )
        }
        val batches = db.batches().all().map { b ->
            SnapshotCodec.SnapBatch(
                releasedAt = b.releasedAt,
                totalBytes = b.totalBytes,
                folder = enumOr(b.folder, OutFolder.SINGLE),
                cloudPackage = b.cloudPackage,
                verifiedAt = b.verifiedAt
            )
        }
        val ledger = db.ledger().all().map { l ->
            SnapshotCodec.SnapLedger(
                outputSha256 = l.outputSha256,
                fingerprint = l.fingerprint,
                displayName = l.displayName,
                outputBytes = l.outputBytes,
                evidence = Evidence.parse(l.evidence),
                confirmedAt = l.confirmedAt
            )
        }
        val access = Permissions.mediaAccess(context).name
        return SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = System.currentTimeMillis(),
            options = optionsRepo.exportMap(),
            items = items,
            batches = batches,
            ledger = ledger,
            mediaAccess = access
        )
    }

    /**
     * Writes the daily history file (CC9.1/CC9.3).
     *
     * Two copies, deliberately: history.json in the shared folder, which
     * survives an uninstall and travels to a new phone with the person's
     * files, and one inside the app's own files directory that survives
     * nothing but is always writable.
     *
     * Returns true when the shared copy was written. A failure there is a
     * Problem the user is told about, in words: it means an uninstall would
     * lose their history.
     */
    suspend fun writeSafetySnapshot(): Boolean {
        // CC9.1: a fresh install that never finished setup leaves nothing
        // behind. Before onboarding completes there is no state worth a file
        // in the user's Documents folder.
        if (!optionsRepo.current().onboardingDone) return false
        val json = SnapshotCodec.encode(build())
        val written = Defaults.SNAPSHOT_TARGETS.any { (dir, name) -> writeTo(json, dir, name) }
        // Always kept, whatever the shared write did.
        writePrivate(json)

        if (written) {
            removePrevious()
        } else {
            ActivityLog(context).record(
                ActivityLog.Kind.PROBLEM,
                detail = context.getString(
                    R.string.problem_snapshot_failed,
                    Defaults.SNAPSHOT_TARGETS.joinToString(", ") { (dir, name) -> "$dir/$name" }
                )
            )
        }
        return written
    }

    /**
     * Empties the hidden folders builds before 12.0 wrote to. Android had
     * renamed each one ("_.cloudsaver") and the app, never finding its file
     * again, added a new one every pass - so there can be many. Only this
     * install's own files are removed; one left by an install since removed
     * is not this app's to delete without asking. Each folder goes too once
     * nothing is left in it.
     */
    private fun removePrevious() {
        val resolver = context.contentResolver
        for (dir in Defaults.PREVIOUS_SNAPSHOT_DIRS) {
            for (row in ownFiles(dir)) {
                runCatching { resolver.delete(row.uri, null, null) }
            }
            @Suppress("DEPRECATION")
            runCatching { File(Environment.getExternalStorageDirectory(), dir).delete() }
        }
    }

    /** The copy inside the app's own storage. Cheap, and always permitted. */
    private fun writePrivate(json: String): Boolean = try {
        File(context.filesDir, Defaults.SNAPSHOT_PRIVATE_NAME)
            .writeText(json, Charsets.UTF_8)
        true
    } catch (e: Exception) {
        false
    }

    private fun readPrivate(): String? = try {
        val file = File(context.filesDir, Defaults.SNAPSHOT_PRIVATE_NAME)
        if (file.isFile) file.readText(Charsets.UTF_8) else null
    } catch (e: Exception) {
        null
    }

    /**
     * Whether the shared history file is where it should be (CC9.3).
     *
     * A user tidying Documents can delete it; the next maintenance pass sees
     * the gap here and rewrites silently - no chip, no alert, because a file
     * the app can recreate in full is not a problem, only a chore.
     */
    fun sharedTargetsPresent(): Boolean = Defaults.SNAPSHOT_TARGETS.any { (dir, name) ->
        ownFiles(dir, name).isNotEmpty()
    }

    /**
     * Reads back the newest snapshot that passes its integrity check, from
     * every place this install can see one. A corrupted or hand-edited copy
     * is skipped rather than trusted - it could otherwise promote evidence
     * and put an original in front of the user for deletion.
     *
     * After an uninstall or "Clear data", Android shows the new install none
     * of the shared files the old one wrote; then only Restore, with the
     * person picking history.json, brings the history back.
     */
    suspend fun readBestSnapshot(): SnapshotCodec.Snapshot? {
        var best: SnapshotCodec.Snapshot? = null
        fun consider(json: String?) {
            if (json == null) return
            val snapshot = try {
                SnapshotCodec.decode(json)
            } catch (e: Exception) {
                return
            }
            if (best == null || snapshot.exportedAt > best!!.exportedAt) best = snapshot
        }
        for ((dir, name) in Defaults.SNAPSHOT_TARGETS + Defaults.LEGACY_SNAPSHOT_TARGETS) {
            for (row in ownFiles(dir, name)) consider(read(row.uri))
        }
        for (dir in Defaults.PREVIOUS_SNAPSHOT_DIRS) {
            for (row in ownFiles(dir)) consider(read(row.uri))
        }
        consider(readPrivate())
        return best
    }

    private data class SharedFile(val uri: Uri, val name: String, val modified: Long)

    /**
     * This install's files in [relativeDir], newest first: all of them, or
     * only those named like [name] - "history.json", or the "history (1).json"
     * Android makes when a file of that name is already there.
     *
     * By owner, because that is all Android shows an app of the non-media
     * files in shared storage: the ones this install wrote.
     */
    private fun ownFiles(relativeDir: String, name: String? = null): List<SharedFile> {
        val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        var selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
            "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?"
        val args = mutableListOf("$relativeDir/", context.packageName)
        if (name != null) {
            val base = name.substringBeforeLast('.')
            val ext = name.substringAfterLast('.', "")
            selection += " AND (${MediaStore.MediaColumns.DISPLAY_NAME} = ? OR " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?)"
            args += name
            args += "$base (%).$ext"
        }
        return try {
            val out = mutableListOf<SharedFile>()
            context.contentResolver.query(
                files,
                arrayOf(
                    MediaStore.MediaColumns._ID,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.DATE_MODIFIED
                ),
                selection, args.toTypedArray(), null
            )?.use { c ->
                while (c.moveToNext()) {
                    out += SharedFile(
                        ContentUris.withAppendedId(files, c.getLong(0)),
                        c.getString(1).orEmpty(),
                        c.getLong(2)
                    )
                }
            }
            out.sortedByDescending { it.modified }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun read(uri: Uri): String? = try {
        context.contentResolver.openInputStream(uri)?.use {
            BoundedRead.readAtMost(it, BoundedRead.MAX_BACKUP_BYTES)?.toString(Charsets.UTF_8)
        }
    } catch (e: Exception) {
        null
    } catch (e: OutOfMemoryError) {
        null
    }

    /**
     * Writes [name] in [relativeDir] through MediaStore: over this install's
     * own file when there is one, so there is only ever one, and as a new
     * file otherwise. Any second copy of its own - two passes that raced -
     * is removed.
     */
    private fun writeTo(json: String, relativeDir: String, name: String): Boolean {
        val resolver = context.contentResolver
        return try {
            val own = ownFiles(relativeDir, name)
            val target = own.firstOrNull()?.uri ?: run {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "$relativeDir/")
                }
                // Android 10 takes a non-media file under Download only
                // through the Downloads collection.
                val collection = if (relativeDir.startsWith("${Environment.DIRECTORY_DOWNLOADS}/")) {
                    MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                } else {
                    MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                }
                resolver.insert(collection, values)
            } ?: return false
            resolver.openOutputStream(target, "wt")?.use { out ->
                out.write(json.toByteArray(Charsets.UTF_8))
            } ?: return false
            for (extra in own.drop(1)) runCatching { resolver.delete(extra.uri, null, null) }
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Manual export to a user-chosen location. With a password the file is
     * encrypted on-device (AES-256-GCM); without one it is plain JSON.
     */
    suspend fun exportTo(uri: Uri, password: String?): Boolean = try {
        val json = SnapshotCodec.encode(build()).toByteArray(Charsets.UTF_8)
        val payload = if (password.isNullOrEmpty()) {
            json
        } else {
            SecureBackup.encrypt(json, password.toCharArray())
        }
        context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
            out.write(payload)
        } != null
    } catch (e: Exception) {
        false
    }

    /** Outcome of an import attempt, so the UI can ask for a password. */
    sealed interface ImportResult {
        data class Success(val imported: Int) : ImportResult
        data object NeedsPassword : ImportResult
        data object WrongPassword : ImportResult
        data object Unreadable : ImportResult

        /** Far bigger than any backup: most likely a photo or video picked by mistake. */
        data object TooLarge : ImportResult
    }

    /** Import from a chosen file; handles both plain and encrypted backups. */
    suspend fun importFrom(uri: Uri, password: String?): ImportResult {
        // The picker takes any file, so a big one is turned away by its
        // reported size before a byte is read, and by the count while
        // reading when the provider reports none (BoundedRead).
        val reported = reportedSize(uri)
        if (reported != null && reported > BoundedRead.MAX_BACKUP_BYTES) return ImportResult.TooLarge
        val bytes = try {
            val stream = context.contentResolver.openInputStream(uri) ?: return ImportResult.Unreadable
            stream.use { BoundedRead.readAtMost(it, BoundedRead.MAX_BACKUP_BYTES) }
                ?: return ImportResult.TooLarge
        } catch (e: Exception) {
            return ImportResult.Unreadable
        } catch (e: OutOfMemoryError) {
            return ImportResult.TooLarge
        }
        val json = if (SecureBackup.isEncrypted(bytes)) {
            if (password.isNullOrEmpty()) return ImportResult.NeedsPassword
            try {
                SecureBackup.decrypt(bytes, password.toCharArray()).toString(Charsets.UTF_8)
            } catch (e: SecureBackup.WrongPasswordException) {
                return ImportResult.WrongPassword
            } catch (e: Exception) {
                return ImportResult.Unreadable
            } catch (e: OutOfMemoryError) {
                return ImportResult.TooLarge
            }
        } else {
            bytes.toString(Charsets.UTF_8)
        }
        // A file under the limit can still be too much to decode on a small
        // heap; the merge is one transaction, so nothing is left half-written.
        return try {
            ImportResult.Success(merge(SnapshotCodec.decode(json)))
        } catch (e: Exception) {
            ImportResult.Unreadable
        } catch (e: OutOfMemoryError) {
            ImportResult.TooLarge
        }
    }

    /** The size the provider reports for [uri], or null when it gives none. */
    private fun reportedSize(uri: Uri): Long? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }
    } catch (e: Exception) {
        null
    }

    /**
     * Merges a snapshot: never downgrades existing rows, applies UNKNOWN rules.
     *
     * [importOptions] carries the snapshot's settings across too. It is what
     * the user asks for when they restore a backup by hand, and what an
     * untouched install wants after a reinstall - but it must be off wherever
     * this install already holds choices of its own, because importing then
     * silently overwrites them.
     *
     * [onlyIfSetupUntouched] asks again at the moment of writing. The row
     * merge can take a while on a large history, and the person may have
     * started setup in the meantime - ticking albums the import would then
     * have put back the way the old phone had them.
     */
    suspend fun merge(
        snapshot: SnapshotCodec.Snapshot,
        importOptions: Boolean = true,
        onlyIfSetupUntouched: Boolean = false
    ): Int = Locks.stage.withLock {
        // The stage lock first: a row being encoded right now is written
        // back from the row Stager read before the encode, which would undo
        // a takeover or an exclusion made here meanwhile. Then the release
        // lock, in the order Releaser takes the two: a row still waiting can
        // be handed its history here, and its staged file removed, only
        // while no release is publishing that file.
        Locks.release.withLock {
            Locks.ledger.withLock { mergeLocked(snapshot, importOptions, onlyIfSetupUntouched) }
        }
    }

    private suspend fun mergeLocked(
        snapshot: SnapshotCodec.Snapshot,
        importOptions: Boolean,
        onlyIfSetupUntouched: Boolean
    ): Int {
        // BB1.5: a snapshot exported under partial access is a fragment, not
        // an inventory. Merging stays safe because it only ever adds rows,
        // raises evidence on the same copy, or settles a row still waiting
        // (ImportMerge), and the next scan - which only runs under full
        // access - fills in what the fragment lacks.
        // Every row lands in one transaction, or none does.
        //
        // The rows used to go in one commit at a time, and the first launch
        // after a reinstall starts this before setup is finished - the one
        // moment a person is most likely to swipe the app away, and a phone
        // that is nearly full (this app's whole audience) is the one most
        // likely to throw mid-way. Whatever had landed stayed, and the next
        // launch saw a table that was not empty, wrote RESTORE_DONE and
        // never looked at the snapshot again: a half-restored history with
        // no ledger, taken for a finished one. A transaction either lands
        // the whole snapshot or leaves the table empty for the next launch
        // to try again. Settings go in after it - they live in DataStore,
        // which has no part in a Room transaction.
        // Whether this history brought back copies not matched to the folder
        // yet: only those start a watch, so importing a backup again does not.
        val (imported, restoredCopies) = db.withTransaction {
            val before = db.items().restoredUnmatched().toSet()
            val merged = mergeRows(snapshot)
            merged to (db.items().restoredUnmatched().toSet() - before).isNotEmpty()
        }
        // Restored rows are matched to the copies still in the folder on the
        // next run (ReattachEngine), however long this install has been
        // running - a restore picked by hand comes after its first. That
        // includes rows already here that this history only gave evidence.
        // Once the rows are in, the request for a pass goes in too: leaving
        // the screen must not cancel it between the two.
        withContext(NonCancellable) {
            if (imported > 0 || db.items().countByState(ItemState.UNKNOWN.name) > 0) {
                // Watched from now when copies came back: one may be on a card
                // put in later.
                optionsRepo.markRestored(restoredCopies, System.currentTimeMillis())
            }
        }
        if (importOptions && snapshot.options.isNotEmpty()) {
            optionsRepo.importMap(withoutForeignFolders(snapshot.options), onlyIfSetupUntouched)
        }
        return imported
    }

    /**
     * A backup's own folder names, less any that now hold photos or videos of
     * the person's own - or that could not be checked. A backup file is
     * found by name and can be written by anything, so a folder it names is
     * held to the same check as one typed in Settings; a dropped one leaves
     * the default in place.
     */
    private fun withoutForeignFolders(options: Map<String, String>): Map<String, String> {
        val inventory = OutputInventory(context)
        return options.filterNot { (key, value) ->
            key in FOLDER_KEYS && value.isNotEmpty() && inventory.othersIn(value) != 0
        }
    }

    private suspend fun mergeRows(snapshot: SnapshotCodec.Snapshot): Int {
        var imported = 0
        val now = System.currentTimeMillis()
        for (raw in snapshot.items) {
            val existing = db.items().byFingerprint(raw.fingerprint)
            if (existing == null) {
                val mapped = ImportMerge.forInsert(SnapshotCodec.applyImportMapping(raw)) ?: continue
                val row = ItemRow(
                    fingerprint = mapped.fingerprint,
                    displayName = mapped.displayName,
                    sizeBytes = mapped.sizeBytes,
                    dateModified = mapped.dateModified,
                    captureAt = mapped.captureAt,
                    mimeType = mapped.mimeType,
                    isVideo = mapped.isVideo,
                    state = mapped.state.name,
                    evidence = mapped.evidence.name,
                    goneReason = raw.goneReason?.name,
                    skipReason = mapped.skipReason,
                    outputName = mapped.outputName,
                    outputBytes = mapped.outputBytes,
                    outputSha256 = mapped.outputSha256,
                    outputFolder = mapped.outputFolder?.name,
                    outputRelPath = restoredRelPath(mapped),
                    releasedAt = mapped.releasedAt,
                    confirmedAt = mapped.confirmedAt,
                    leftFolderAt = ImportMerge.leftAtOnImport(raw, now),
                    keptUri = mapped.keptUri,
                    // Replaced on this phone: never a light copy to remove,
                    // and Put back stays possible while the original is kept.
                    backupUri = raw.backupUri,
                    originalSha256 = raw.originalSha256,
                    neverOptimise = mapped.neverOptimise,
                    duplicateOf = mapped.duplicateOf,
                    fromImport = true,
                    updatedAt = now
                )
                if (db.items().insert(row) != -1L) imported++
            } else {
                // Never downgrade local knowledge (ImportMerge says how). A
                // "never optimise" in the snapshot is honoured too: it only
                // ever makes the app do less to a file, which is the one
                // direction an import may move a choice on its own.
                val mapped = SnapshotCodec.applyImportMapping(raw)
                val plan = ImportMerge.plan(
                    ImportMerge.Local(
                        state = enumOr(existing.state, ItemState.UNKNOWN),
                        evidence = Evidence.parse(existing.evidence),
                        outputSha256 = existing.outputSha256,
                        neverOptimise = existing.neverOptimise,
                        outputName = existing.outputName,
                        outputBytes = existing.outputBytes
                    ),
                    mapped
                )
                if (!plan.changes) continue
                // A waiting row loses its staged file either way: it is taken
                // over by the history's copy, or parked as the person asked.
                // The release lock (merge) keeps a release from using it now.
                if (plan.takeOver || plan.exclude) {
                    existing.stagePath?.let { runCatching { File(it).delete() } }
                }
                val never = existing.neverOptimise || mapped.neverOptimise
                val updated = when {
                    // The scan's location fields stay; the copy's record is
                    // the history's, as it would be in an empty table.
                    plan.takeOver -> existing.copy(
                        state = ImportMerge.takenOverState(mapped).name,
                        keptUri = ImportMerge.keptUriAfterTakeOver(mapped, existing.contentUri),
                        evidence = mapped.evidence.name,
                        goneReason = raw.goneReason?.name,
                        skipReason = null,
                        stagePath = null,
                        outputUri = null,
                        outputName = mapped.outputName,
                        outputBytes = mapped.outputBytes,
                        outputSha256 = mapped.outputSha256,
                        outputFolder = mapped.outputFolder?.name,
                        outputRelPath = restoredRelPath(mapped),
                        releasedAt = mapped.releasedAt,
                        confirmedAt = mapped.confirmedAt,
                        // The later of the two: a copy this phone sent back
                        // to the queue keeps the time it left the folder.
                        leftFolderAt = listOfNotNull(
                            existing.leftFolderAt, ImportMerge.leftAtOnImport(raw, now)
                        ).maxOrNull(),
                        neverOptimise = never,
                        fromImport = true,
                        updatedAt = now
                    )
                    // As setNeverOptimise parks a row, so the queue skips it.
                    plan.exclude -> existing.copy(
                        state = ItemState.SKIP.name,
                        skipReason = ImportMerge.USER_EXCLUDED,
                        stagePath = null,
                        outputName = null,
                        outputBytes = null,
                        outputSha256 = null,
                        outputFolder = null,
                        neverOptimise = never,
                        updatedAt = now
                    )
                    else -> existing.copy(
                        evidence = if (plan.raiseEvidence) mapped.evidence.name else existing.evidence,
                        // An adopted copy found its file, not its hash; the
                        // history's is what lines it up with the ledger.
                        outputSha256 = if (plan.raiseEvidence) {
                            existing.outputSha256 ?: mapped.outputSha256
                        } else {
                            existing.outputSha256
                        },
                        confirmedAt = if (plan.raiseEvidence) {
                            mapped.confirmedAt ?: existing.confirmedAt
                        } else {
                            existing.confirmedAt
                        },
                        neverOptimise = never,
                        updatedAt = now
                    )
                }
                db.items().update(updated)
            }
        }
        // The ledger goes in before anything else can act on it: a restored
        // install must know what the cloud already has before it decides
        // anything is missing.
        for (l in snapshot.ledger) {
            if (l.outputSha256.isEmpty()) continue
            db.ledger().record(
                LedgerRow(
                    outputSha256 = l.outputSha256,
                    fingerprint = l.fingerprint,
                    displayName = l.displayName,
                    outputBytes = l.outputBytes,
                    evidence = l.evidence.name,
                    confirmedAt = l.confirmedAt
                )
            )
        }
        // Batches are written to the file but never read back. No restored
        // row points at one, so they only ever counted twice against today's
        // allowance on a second import, and an old phone's unverified batch
        // moved the start of this phone's traffic window back to its date -
        // letting traffic sent before any real batch verify one.
        return imported
    }

    /** The folder a restored copy was released into; older files name only the kind. */
    private fun restoredRelPath(mapped: SnapshotCodec.SnapItem): String? =
        mapped.outputRelPath
            ?: mapped.outputFolder?.takeIf { mapped.releasedAt != null }
                ?.let { Defaults.legacyRelPath(it) }

    private inline fun <reified T : Enum<T>> enumOr(value: String?, fallback: T): T =
        enumOrNull<T>(value) ?: fallback

    private inline fun <reified T : Enum<T>> enumOrNull(value: String?): T? {
        if (value.isNullOrEmpty()) return null
        return try {
            enumValueOf<T>(value)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}
