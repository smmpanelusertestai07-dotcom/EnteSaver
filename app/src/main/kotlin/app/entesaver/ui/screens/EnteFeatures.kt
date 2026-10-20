package app.entesaver.ui.screens

import app.entesaver.R
import app.entesaver.data.EnteApp

/** How far a feature is there: yes, in part, or no. */
internal enum class Has { YES, PARTLY, NO }

/** One feature: what the phone, Ente Photos and Ente Saver each do, and Ente's own guide to it. */
internal class EnteFeature(
    val name: Int,
    val phone: Has,
    val phoneSays: Int,
    val ente: Has,
    val enteSays: Int,
    val saver: Has,
    val saverSays: Int,
    val guide: String? = null
)

/**
 * Who does what: the phone itself, Ente Photos and Ente Saver, feature by
 * feature, in Ente's own names and menus as its current app shows them (and
 * its help pages, which open from here). Where Ente already does something
 * well - Free up device space, similar images, duplicates - Ente Saver says
 * so and points to it, rather than doing it a second time.
 */
internal val ENTE_FEATURES = listOf(
    EnteFeature(R.string.feat_backup, Has.NO, R.string.feat_backup_phone, Has.YES, R.string.feat_backup_ente,
        Has.NO, R.string.feat_backup_saver, EnteApp.Help.BACKUP_FOLDERS),
    EnteFeature(R.string.feat_data, Has.PARTLY, R.string.feat_data_phone, Has.PARTLY, R.string.feat_data_ente,
        Has.YES, R.string.feat_data_saver, EnteApp.Help.MOBILE_DATA),
    EnteFeature(R.string.feat_videos, Has.NO, R.string.feat_none, Has.YES, R.string.feat_videos_ente,
        Has.PARTLY, R.string.feat_videos_saver, EnteApp.Help.BACKUP),
    EnteFeature(R.string.feat_smaller, Has.NO, R.string.feat_smaller_phone, Has.NO, R.string.feat_smaller_ente,
        Has.YES, R.string.feat_smaller_saver, EnteApp.Help.COMPRESS),
    EnteFeature(R.string.feat_free_all, Has.PARTLY, R.string.feat_free_all_phone, Has.YES, R.string.feat_free_all_ente,
        Has.YES, R.string.feat_free_all_saver, EnteApp.Help.FREE_UP_DEVICE),
    EnteFeature(R.string.feat_free_folder, Has.NO, R.string.feat_none, Has.YES, R.string.feat_free_folder_ente,
        Has.YES, R.string.feat_free_folder_saver, EnteApp.Help.FREE_UP_FOLDER),
    EnteFeature(R.string.feat_auto, Has.PARTLY, R.string.feat_auto_phone, Has.NO, R.string.feat_auto_ente,
        Has.NO, R.string.feat_auto_saver, EnteApp.Help.STORAGE),
    EnteFeature(R.string.feat_duplicates, Has.PARTLY, R.string.feat_cleaner_apps, Has.YES, R.string.feat_duplicates_ente,
        Has.YES, R.string.feat_duplicates_saver, EnteApp.Help.DUPLICATES),
    EnteFeature(R.string.feat_similar, Has.PARTLY, R.string.feat_gallery_apps, Has.YES, R.string.feat_similar_ente,
        Has.NO, R.string.feat_similar_saver, EnteApp.Help.SIMILAR),
    EnteFeature(R.string.feat_large, Has.PARTLY, R.string.feat_cleaner_apps, Has.YES, R.string.feat_large_ente,
        Has.YES, R.string.feat_large_saver, EnteApp.Help.LARGE_FILES),
    EnteFeature(R.string.feat_trash, Has.YES, R.string.feat_trash_phone, Has.YES, R.string.feat_trash_ente,
        Has.YES, R.string.feat_trash_saver, EnteApp.Help.TRASH),
    EnteFeature(R.string.feat_status, Has.NO, R.string.feat_none, Has.YES, R.string.feat_status_ente,
        Has.YES, R.string.feat_status_saver, EnteApp.Help.BACKUP),
    EnteFeature(R.string.feat_ml, Has.PARTLY, R.string.feat_gallery_apps, Has.YES, R.string.feat_ml_ente,
        Has.NO, R.string.feat_ml_saver, EnteApp.Help.ML),
    EnteFeature(R.string.feat_streams, Has.NO, R.string.feat_none, Has.PARTLY, R.string.feat_streams_ente,
        Has.YES, R.string.feat_streams_saver, EnteApp.Help.STREAMING),
    EnteFeature(R.string.feat_map, Has.PARTLY, R.string.feat_gallery_apps, Has.YES, R.string.feat_map_ente,
        Has.NO, R.string.feat_map_saver, EnteApp.Help.MAP),
    EnteFeature(R.string.feat_lock, Has.YES, R.string.feat_lock_phone, Has.YES, R.string.feat_lock_ente,
        Has.YES, R.string.feat_lock_saver, EnteApp.Help.APP_LOCK),
    EnteFeature(R.string.feat_gallery, Has.YES, R.string.feat_gallery_phone, Has.YES, R.string.feat_gallery_ente,
        Has.YES, R.string.feat_gallery_saver, EnteApp.Help.GALLERY),
    EnteFeature(R.string.feat_storage, Has.NO, R.string.feat_none, Has.YES, R.string.feat_storage_ente,
        Has.YES, R.string.feat_storage_saver, EnteApp.Help.FREE_PLAN)
)
