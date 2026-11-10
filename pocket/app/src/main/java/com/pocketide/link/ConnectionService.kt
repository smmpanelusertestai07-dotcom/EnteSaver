package com.pocketide.link

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import com.pocketide.MainActivity
import com.pocketide.R
import com.pocketide.core.Channels
import com.pocketide.core.NotificationIds
import com.pocketide.graph

/**
 * Keeps PocketIDE running while its connection to Cloud Shell is being set up or is open, so
 * Android does not close it when the owner finishes a sign-in in Chrome or switches apps for a
 * moment. An ongoing notification says so, with a Disconnect button. The connection (gcloud and
 * OpenSSH) is this app's own child processes: without this service Android would stop them with
 * the app. It does nothing to keep Cloud Shell itself awake: Cloud Shell stops when you stop using it.
 */
class ConnectionService : LifecycleService() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        when (intent?.action) {
            ACTION_KEEP -> keep(intent.getStringExtra(EXTRA_WHY) ?: Holds.CONNECTED)
            ACTION_RELEASE -> {
                // Started with startForegroundService, so it must show its notice first, however briefly.
                keep(Holds.CONNECTED)
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_STOP -> disconnect()
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun keep(why: String) {
        // Android 14 names the kind of work; older versions take the manifest's word for it.
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NotificationIds.CONNECTION, ongoing(why), type)
    }

    private fun disconnect() {
        graph.link.disconnect()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun ongoing(why: String): Notification {
        val stop = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, ConnectionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, Channels.CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_pocketide)
            .setContentTitle(getString(titleOf(why)))
            .setContentText(getString(textOf(why)))
            .setContentIntent(openApp(this))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (why == Holds.CONNECTED) addAction(0, getString(R.string.connection_stop), stop) }
            .build()
    }

    private fun titleOf(why: String) = when (why) {
        Holds.SET_UP -> R.string.connection_setting_up_title
        Holds.SIGN_IN -> R.string.connection_sign_in_title
        else -> R.string.connection_on_title
    }

    private fun textOf(why: String) = when (why) {
        Holds.SET_UP -> R.string.connection_setting_up_text
        Holds.SIGN_IN -> R.string.connection_sign_in_text
        else -> R.string.connection_on_text
    }

    companion object {
        private const val ACTION_KEEP = "com.pocketide.connection.KEEP"
        private const val EXTRA_WHY = "com.pocketide.connection.WHY"
        private const val ACTION_STOP = "com.pocketide.connection.STOP"
        private const val ACTION_RELEASE = "com.pocketide.connection.RELEASE"
        private const val REQUEST_STOP = 1
        private const val REQUEST_OPEN = 2

        /** Starts the service, or updates what its notice says [why]; called with the app in front (set-up, connecting). */
        fun keep(context: Context, why: String) {
            val intent = Intent(context, ConnectionService::class.java).setAction(ACTION_KEEP).putExtra(EXTRA_WHY, why)
            // Android may refuse a start from the background (a connection that ends there): nothing to keep then.
            runCatching { ContextCompat.startForegroundService(context, intent) }
        }

        /**
         * Ends the service. Through the service itself: stopped before it showed its notice, a
         * service started with startForegroundService would take the app down with it.
         */
        fun release(context: Context) {
            val intent = Intent(context, ConnectionService::class.java).setAction(ACTION_RELEASE)
            val asked = runCatching { ContextCompat.startForegroundService(context, intent) }.isSuccess
            if (!asked) context.stopService(Intent(context, ConnectionService::class.java))
        }

        fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
