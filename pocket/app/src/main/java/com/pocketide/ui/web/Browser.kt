package com.pocketide.ui.web

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri

/**
 * Opens a web page in Chrome as a Custom Tab: it slides over PocketIDE, keeps Chrome's own
 * sign-ins and password manager, and Back returns to the app. With no browser that supports
 * Custom Tabs, the phone's browser opens instead. Only https addresses leave the app.
 */
object Browser {
    fun open(context: Context, url: String) {
        val tab = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
            .setUrlBarHidingEnabled(false)
            .build()
        launch(context, tab, url)
    }

    /** Opens [url] in [tab], or says why nothing opened. */
    internal fun launch(context: Context, tab: CustomTabsIntent, url: String) {
        if (!WebPolicy.isWebLink(url)) return
        if (context !is Activity) tab.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            tab.launchUrl(context, url.toUri())
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(context, "Install or turn on a web browser to open ${WebPolicy.hostOf(url).orEmpty()}.", Toast.LENGTH_LONG).show()
        }
    }
}
