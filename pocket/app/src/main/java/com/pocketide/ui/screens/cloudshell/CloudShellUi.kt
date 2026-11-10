package com.pocketide.ui.screens.cloudshell

import android.accounts.AccountManager
import android.app.Activity
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.pocketide.agents.Agent
import com.pocketide.graph
import com.pocketide.ui.web.Browser

/**
 * Opens Google's own Cloud Shell page in the browser, for what only that page settles once (its
 * terms, a verification), and notes when PocketIDE last opened Cloud Shell.
 */
fun openGooglePage(context: Context, url: String) {
    val graph = context.graph
    graph.settings.update { it.copy(cloudOpenedAt = graph.clock.now()) }
    Browser.open(context, url)
}

/**
 * Android's own account chooser for Google accounts, with Add account in it: nothing opens with an
 * account by itself, and PocketIDE sees only the one account picked (no contacts permission).
 */
@Composable
fun rememberAccountPicker(onPicked: (String) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val name = result.data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
        if (result.resultCode == Activity.RESULT_OK && !name.isNullOrBlank()) onPicked(name)
    }
    return { launcher.launch(AccountManager.newChooseAccountIntent(null, null, arrayOf(GOOGLE), null, null, null, null)) }
}

private const val GOOGLE = "com.google"

/** How [agent] signs in, in its own panel inside PocketIDE. */
fun signInSteps(agent: Agent): String = when (agent) {
    Agent.CLAUDE ->
        "In Claude Code, tap Sign in. Chrome opens: sign in, and the page returns to Claude Code by itself (or copy " +
            "the code the page shows and paste it where Claude Code asks: the Paste key above the keyboard does it)."
    Agent.CODEX ->
        "In Codex, tap Sign in with ChatGPT and sign in in Chrome. The page returns to Codex by itself."
    Agent.ANTIGRAVITY ->
        "In Antigravity, tap Continue with Google and sign in in Chrome. The page returns to Antigravity by itself."
}

@Composable
fun SignInHelpDialog(agent: Agent, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sign in to ${agent.displayName}") },
        text = {
            Text(signInSteps(agent), style = MaterialTheme.typography.bodyMedium)
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}
