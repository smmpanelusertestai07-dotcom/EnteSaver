package com.pocketide

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.pocketide.ui.web.Browser

/**
 * Which of PocketIDE's screens is in front, for what happens outside them: a page gcloud asks the
 * phone to open goes to Chrome over that screen (so Chrome's back arrow returns to it), and when a
 * sign-in in Chrome is done, that screen comes back to the front.
 */
class Foreground(private val app: Context) : Application.ActivityLifecycleCallbacks {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var resumed: Activity? = null

    /** The last of PocketIDE's screens that was in front, even when Chrome is in front of it now. */
    @Volatile
    private var last: Class<out Activity>? = null

    /** Opens [url] in Chrome, over the screen in front (from any thread). */
    fun openLink(url: String) {
        main.post { Browser.open(resumed ?: app, url) }
    }

    /** Brings the last screen back in front of Chrome, closing the sign-in tab above it (from any thread). */
    fun bringBack() {
        main.post {
            if (resumed != null) return@post
            val screen = last ?: MainActivity::class.java
            runCatching {
                app.startActivity(
                    Intent(app, screen).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
            }
        }
    }

    override fun onActivityResumed(activity: Activity) {
        resumed = activity
        if (activity is MainActivity || activity is com.pocketide.ui.workspace.WorkspaceActivity) last = activity.javaClass
    }

    override fun onActivityPaused(activity: Activity) {
        if (resumed === activity) resumed = null
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
