package com.pocketide

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.lifecycle.ProcessLifecycleOwner
import com.pocketide.core.Channels
import com.pocketide.ui.lock.AppLock

/** Holds the app's single [AppGraph]. */
class PocketApp : Application() {
    lateinit var graph: AppGraph
        private set

    lateinit var appLock: AppLock
        private set

    override fun onCreate() {
        super.onCreate()
        // The screen that says an error stopped the app runs alone in its own process.
        if (StopNote.isNoteProcess()) return
        // Debug builds (the tests) keep Android's own handling, which reports the error to the test.
        if (!BuildConfig.DEBUG) StopNote.install(this)
        graph = AppGraph(this)
        appLock = AppLock(graph.clock)
        ProcessLifecycleOwner.get().lifecycle.addObserver(appLock)
        registerActivityLifecycleCallbacks(graph.foreground)
        createChannels()
        AppStartup.onCreate(graph)
    }

    /** The ongoing "Connected to Cloud Shell" notice, and each file's on its way to the phone's Downloads. */
    private fun createChannels() {
        val connection = NotificationChannel(Channels.CONNECTION, getString(R.string.connection_channel_name), NotificationManager.IMPORTANCE_LOW)
        connection.description = getString(R.string.connection_channel_description)
        connection.setShowBadge(false)
        val downloads = NotificationChannel(Channels.DOWNLOADS, getString(R.string.downloads_channel_name), NotificationManager.IMPORTANCE_LOW)
        downloads.description = getString(R.string.downloads_channel_description)
        downloads.setShowBadge(false)
        getSystemService(NotificationManager::class.java)?.createNotificationChannels(listOf(connection, downloads))
    }
}

/** Reaches the graph from anything with a context. */
val android.content.Context.graph: AppGraph
    get() = (applicationContext as PocketApp).graph
