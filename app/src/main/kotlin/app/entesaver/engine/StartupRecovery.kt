package app.entesaver.engine

import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import androidx.room.withTransaction
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.ScanSources
import app.entesaver.data.db.AppDb
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.MediaScanner
import app.entesaver.media.Stager
import app.entesaver.util.Locks
import app.entesaver.util.Permissions
import java.io.File
import kotlinx.coroutines.sync.withLock

/**
 * Runs once per launch, before anything else touches the database.
 *
 * Room is the source of truth, but it lives in app data, which "Clear data"
 * and an uninstall both wipe. The hidden snapshots outlive that, so if the
 * database is empty and a valid snapshot exists, the state comes back on its
 * own - the user is not asked to restore anything, and Free-up offers nothing
 * it cannot justify, because imported items arrive without evidence.
 */
class StartupRecovery(private val context: Context) {

    data class Result(
        val restoredItems: Int,
        val removedPlaceholders: Int
    )

    suspend fun run(): Result {
        // A replace or put back the phone cut short is finished or undone
        // first, at every start: until it is, a half-written file sits in
        // the gallery, and in Ente's upload queue. Background runs may wait
        // days for their conditions; opening the app does not. Not waited
        // for while a run holds the encoder: that run settled it before it
        // took a file, and the rest of start-up must not wait on a video.
        if (Locks.stage.tryLock()) {
            try {
                runCatching { Stager(context, AppDb.get(context)).recoverLocked() }
            } finally {
                Locks.stage.unlock()
            }
        }
        // Read the old visible snapshot before deleting it: on an upgrade it
        // may be the only state left.
        val restored = restoreIfEmpty()
        // Tried again next launch if it fails; the steps below still run.
        runCatching { repairQueueOnce() }
        val placeholders = removeLegacyPlaceholders()
        removeLegacyVisibleSnapshot()
        purgeOutputFolderItems()
        return Result(restored, placeholders)
    }

    /**
     * Older builds scanned every folder, so another pipeline's output - Ente's
     * upload folder, or this app's own copies under a previous name - could
     * already be queued for re-compression. Those rows are dropped.
     *
     * Only NEW and STAGED go: a RELEASED row carries upload evidence that the
     * user's Free-up decisions rest on, and that must not be rewritten here.
     */
    private suspend fun purgeOutputFolderItems(): Int {
        val db = AppDb.get(context)
        // Nothing queued means nothing this pass could purge. Ask that first:
        // the folder-reason scan below walks the whole gallery, tens of
        // thousands of rows on a full phone, and it ran at every single
        // launch even when the queue was empty - which is the normal state
        // once the backlog is through.
        val queued = db.items().countByState(ItemState.NEW.name) +
            db.items().countByState(ItemState.STAGED.name)
        if (queued == 0) return 0
        val scanner = MediaScanner(context, db)
        val excluded = runCatching { scanner.excludedBucketReasons() }.getOrNull() ?: return 0
        if (excluded.isEmpty()) return 0

        var purged = 0
        for (state in listOf(ItemState.NEW, ItemState.STAGED)) {
            for (row in db.items().byState(state.name)) {
                val bucket = row.bucket ?: continue
                if (bucket !in excluded) continue
                // A staged copy has a file behind it; drop that too.
                row.stagePath?.let { runCatching { File(it).delete() } }
                db.items().delete(row)
                purged++
            }
        }
        if (purged > 0) {
            // Keep the picker honest about it from now on.
            val repo = OptionsRepo.get(context)
            val current = repo.current().excludedBuckets
            repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, current + excluded.keys)
        }
        return purged
    }

    /**
     * Sets right, once, the rows a restore by 12.1 left inconsistent (the
     * DAO calls say which). A restore now settles them as it merges, but
     * nothing revisits rows already written that way: an excluded photo kept
     * being sent, and its "proven" copy was never watched.
     *
     * Under the locks a restore takes, in its order, so no encode or release
     * is working on these rows meanwhile. One transaction, and the flag only
     * after it lands, so a failure is simply tried again next launch.
     */
    private suspend fun repairQueueOnce() {
        val db = AppDb.get(context)
        val repo = OptionsRepo.get(context)
        if (repo.current().queueRepaired) return
        Locks.stage.withLock {
            Locks.release.withLock {
                Locks.ledger.withLock {
                    val now = System.currentTimeMillis()
                    db.withTransaction {
                        val staged = db.items().waitingButExcluded().mapNotNull { it.stagePath }
                        db.items().parkWaitingExcluded(now)
                        db.items().clearWaitingEvidence(now)
                        db.items().deleteRestoredGhosts()
                        staged
                    }.forEach { runCatching { File(it).delete() } }
                }
            }
        }
        repo.setBool(OptionsRepo.K.QUEUE_REPAIRED, true)
    }

    /**
     * Restores from the newest valid snapshot when the database is empty.
     * A populated database is never overwritten: the local copy is always
     * fresher than a snapshot that is at most a day old.
     */
    private suspend fun restoreIfEmpty(): Int {
        val db = AppDb.get(context)
        val repo = OptionsRepo.get(context)
        val o = repo.current()
        // Once per install, not "whenever the table is empty". The old
        // condition held true on every launch until the first file was
        // optimised, and each launch re-imported the snapshot's settings over
        // whatever the user had just chosen - a ticked album came back
        // unticked after every restart.
        if (o.restoreDone) return 0
        // A count, not the table: this runs at every launch, and a large
        // gallery means twenty thousand rows built only to be discarded.
        if (db.items().count() > 0) {
            repo.setBool(OptionsRepo.K.RESTORE_DONE, true)
            return 0
        }

        val store = SnapshotStore(context, db, repo)
        val snapshot = store.readBestSnapshot() ?: return 0
        // Settings come back only where nothing here has been chosen yet: a
        // fresh install after a reinstall, which is what restoring is for.
        // Someone already walking through setup keeps their own answers.
        val untouched = !o.onboardingDone && o.onboardingStep == 0
        val imported = try {
            store.merge(snapshot, importOptions = untouched, onlyIfSetupUntouched = true)
        } catch (e: Exception) {
            return 0
        }
        repo.setBool(OptionsRepo.K.RESTORE_DONE, true)
        // Asked again now, not from before the merge: someone who started
        // setup while it ran is left to finish it, rather than lifted out of
        // it halfway onto a Home whose settings were never restored.
        val stillUntouched = repo.current().let { !it.onboardingDone && it.onboardingStep == 0 }
        if (imported > 0 && untouched && stillUntouched) {
            // Clear-data keeps runtime permissions, a reinstall does not. Only
            // skip setup when the app can actually see the gallery; otherwise
            // the restored install would land on Home unable to do anything,
            // with the one screen that asks for access already behind it.
            if (Permissions.mediaAccess(context) ==
                Permissions.MediaAccess.FULL
            ) {
                repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
            }
        }
        return imported
    }

    /**
     * Earlier builds wrote the automatic snapshot to a visible
     * Documents/CloudSaver folder, which is exactly where someone browsing
     * Files finds a folder they never created. Snapshots are hidden now, so
     * the old visible one is removed once its contents have been read.
     */
    private fun removeLegacyVisibleSnapshot(): Int {
        val resolver = context.contentResolver
        val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
            "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?"
        val args = arrayOf(
            "${Defaults.SNAPSHOT_DIR_LEGACY_VISIBLE}/",
            Defaults.SNAPSHOT_NAME,
            context.packageName
        )
        return try {
            val ids = mutableListOf<Long>()
            resolver.query(
                files, arrayOf(MediaStore.MediaColumns._ID), selection, args, null
            )?.use { c ->
                while (c.moveToNext()) ids += c.getLong(0)
            }
            var removed = 0
            for (id in ids) {
                val uri = ContentUris.withAppendedId(files, id)
                if (runCatching { resolver.delete(uri, null, null) }.getOrDefault(0) > 0) {
                    removed++
                }
            }
            removed
        } catch (e: Exception) {
            0
        }
    }

    /**
     * Earlier builds parked a placeholder image in the output folder to stop
     * cloud apps forgetting it. The anchor rule replaced that, so any leftover
     * is deleted - it is app-owned, which means no user confirmation is needed.
     */
    private fun removeLegacyPlaceholders(): Int {
        val resolver = context.contentResolver
        var removed = 0
        for (volume in runCatching { MediaStore.getExternalVolumeNames(context) }
            .getOrDefault(setOf(MediaStore.VOLUME_EXTERNAL_PRIMARY))) {
            val collection = MediaStore.Images.Media.getContentUri(volume)
            val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?"
            val args = arrayOf(Defaults.LEGACY_OUTPUT_DIR_LIKE, context.packageName)
            try {
                val ids = mutableListOf<Long>()
                resolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME),
                    selection,
                    args,
                    null
                )?.use { c ->
                    while (c.moveToNext()) {
                        // The name is judged in Kotlin. Asking SQL for it needs
                        // an ESCAPE clause to keep the underscore literal, and
                        // the query that did not have one matched nothing.
                        if (ScanSources.isKeepPlaceholderName(c.getString(1))) ids += c.getLong(0)
                    }
                }
                for (id in ids) {
                    val uri = ContentUris.withAppendedId(collection, id)
                    if (runCatching { resolver.delete(uri, null, null) }.getOrDefault(0) > 0) {
                        removed++
                    }
                }
            } catch (e: Exception) {
                // Cleanup is best effort; the next launch tries again.
            }
        }
        return removed
    }
}
