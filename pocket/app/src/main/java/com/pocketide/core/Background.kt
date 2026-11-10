package com.pocketide.core

import android.util.Log
import kotlinx.coroutines.CoroutineExceptionHandler

/**
 * For the app's long-lived scopes: background work that fails unexpectedly is written to the
 * phone's log and ends there, instead of closing the whole app. The screens show the state that
 * work publishes (the computer, code-server, the agents), so a failure still shows where it matters.
 */
val LogBackgroundFailure = CoroutineExceptionHandler { _, failure ->
    Log.e("PocketIDE", "Background work stopped", failure)
}
