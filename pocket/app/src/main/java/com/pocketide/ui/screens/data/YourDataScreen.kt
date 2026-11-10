package com.pocketide.ui.screens.data

import android.content.Context
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.agents.Agent
import com.pocketide.cloudshell.CloudShell
import com.pocketide.core.AppFolders
import com.pocketide.core.OldComputer
import com.pocketide.docs.AppPlace
import com.pocketide.docs.DocsContent
import com.pocketide.graph
import com.pocketide.link.LinkState
import com.pocketide.ui.components.ActionRow
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.components.DialogBody
import com.pocketide.ui.components.Formats
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.screens.help.LocalOpenPlace
import com.pocketide.ui.shell.LocalBottomBarPadding
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.web.Browser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

private enum class Ask { DELETE_OLD, DELETE_PHONE }

/**
 * Each agent's sign-in, kept in Cloud Shell: its own sign-out from here (Claude Code, Codex), or
 * where to find it (Antigravity's is in its panel); and where each company ends every sign-in.
 */
@Composable
private fun SignOutCard() {
    val graph = LocalContext.current.graph
    val scope = rememberCoroutineScope()
    val link by graph.link.state.collectAsStateWithLifecycle()
    var said by remember { mutableStateOf<Pair<Agent, String>?>(null) }
    var working by remember { mutableStateOf<Agent?>(null) }
    SectionCard("Sign an agent out") {
        Text(
            "Each agent keeps its sign-in in your Cloud Shell. Sign out runs the agent's own sign-out there (Antigravity's " +
                "is in its panel's account menu). To end the sign-in at the company as well: claude.ai > Settings > Account; " +
                "chatgpt.com > Settings > Security > Log out of all devices.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Agent.entries.forEach { agent ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                AgentLogo(agent, size = 28.dp)
                Spacer(Modifier.width(10.dp))
                Text(agent.displayName, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                if (working == agent) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    OutlinedButton(enabled = working == null && link == LinkState.On, onClick = {
                        working = agent
                        scope.launch {
                            var last: String? = null
                            val done = graph.link.signOutAgent(agent) { last = it }
                            working = null
                            said = agent to when {
                                done -> "${agent.displayName} is signed out in Cloud Shell. Sign in again in its panel."
                                else -> last ?: "It did not sign out. Try again."
                            }
                        }
                    }) { Text("Sign out") }
                }
            }
            said?.takeIf { it.first == agent }?.let { Text(it.second, style = MaterialTheme.typography.bodySmall) }
        }
        if (link != LinkState.On) {
            Text(
                "Connect first (Home > Open the computer): the sign-ins are in Cloud Shell.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Where each piece of the owner's data lives, who can see it, and how to delete it. The work is in
 * the owner's Cloud Shell; the phone keeps only PocketIDE's settings, and, after an update from
 * version 5, that version's computer until the owner saves what they want from it and deletes it.
 */
@Composable
fun YourDataScreen(onBack: (() -> Unit)?, onHelpPage: (String) -> Unit) {
    val context = LocalContext.current
    val graph = context.graph
    val scope = rememberCoroutineScope()
    val openPlace = LocalOpenPlace.current
    val old = remember { OldComputer(AppFolders.of(context).oldComputer) }
    var oldThere by remember { mutableStateOf(old.exists()) }
    var busy by remember { mutableStateOf(false) }
    var asking by remember { mutableStateOf<Ask?>(null) }

    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
            } else {
                Icon(Icons.Outlined.DeleteSweep, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                Spacer(Modifier.width(10.dp))
            }
            Text("Your data", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        }
        Text(
            "PocketIDE has no server and no database of its own. Your work is in your own Google Cloud Shell; this phone " +
                "keeps PocketIDE's settings and its connection to Cloud Shell.",
            style = MaterialTheme.typography.bodyMedium,
        )
        HowToDeleteCard()
        Place(
            "In your Cloud Shell",
            "Your projects (~/projects), each agent's chats and sign-in (~/.claude, ~/.codex, Antigravity's ~/.gemini/antigravity) " +
                "and each agent's VS " +
                "Code (~/.pocketide). Only your Google account opens it. Google deletes it after " +
                "${CloudShell.DELETED_AFTER_DAYS} days without use.",
        ) {
            OutlinedButton(onClick = { openPlace(AppPlace.COMPUTER.id) }) { Text("See it, download it, delete it") }
        }
        Place(
            "On this phone",
            "PocketIDE's settings: the theme, App lock, the Google account Cloud Shell opens with, and when it was set up and " +
                "last opened. PocketIDE's connection, in its private storage: Ubuntu with Google's gcloud and gcloud's " +
                "sign-in (a Google token only this app can read), and the pages of the agents' VS Code the app keeps " +
                "while it runs. No project, file or chat of yours. Android's own backup copies none of it.",
        )
        Place(
            "At the AI companies",
            "What you ask an agent, and the code it reads, goes to its company under your account there. Their own policies say " +
                "how long they keep it and whether it trains their models.",
        ) {
            ActionRow {
                Agent.entries.forEach { agent ->
                    OutlinedButton(onClick = { Browser.open(context, agent.privacyUrl) }) { Text(agent.maker) }
                }
            }
        }
        SignOutCard()
        if (oldThere) OldComputerCard(old, busy = busy, onBusy = { busy = it }, onDelete = { asking = Ask.DELETE_OLD })
        SectionCard("Delete PocketIDE's data on this phone") {
            Text(
                "Signs gcloud out (Google ends that sign-in too), then deletes PocketIDE's connection, settings and files on " +
                    "this phone; the app starts again from the welcome. Your Cloud Shell stays as it is: delete it there " +
                    "(Computer > Delete). Uninstalling PocketIDE deletes the same, but cannot sign gcloud out: remove " +
                    "\"Google Cloud SDK\" in your Google Account (Security) then.",
                style = MaterialTheme.typography.bodyMedium,
            )
            PrimaryAction("Delete from this phone", onClick = { asking = Ask.DELETE_PHONE }, enabled = !busy)
            TextButton(onClick = { onHelpPage(DocsContent.YOUR_DATA_ID) }) { Text("More about your data") }
        }
        // Room to scroll the last card clear of the bottom bar.
        Spacer(Modifier.height(LocalBottomBarPadding.current))
    }

    asking?.let { ask ->
        DeleteDialog(ask, withOld = oldThere, onDismiss = { asking = null }) {
            asking = null
            scope.launch {
                if (ask == Ask.DELETE_OLD) {
                    withContext(Dispatchers.IO) { old.delete() }
                    oldThere = old.exists()
                    if (oldThere) Toast.makeText(context, "Part of it could not be deleted; try again.", Toast.LENGTH_LONG).show()
                } else {
                    deletePhoneData(context, graph)
                }
            }
        }
    }
}

/** The whole of deleting, in order: the phone, Cloud Shell, the AI companies, and what uninstalling does. */
@Composable
private fun HowToDeleteCard() {
    SectionCard("How to delete your data") {
        listOf(
            "1. This phone: scroll down to \"Delete from this phone\" and confirm. It signs Google out of the app and " +
                "deletes the app's settings, connection and files. The app starts again from the welcome.",
            "2. Your Cloud Shell (projects, chats, the agents' sign-ins): open the Computer tab > Delete, or run " +
                "sudo rm -rf \$HOME in Cloud Shell and restart it. This cannot be undone: download what you want first.",
            "3. One agent only: \"Sign out\" below removes that agent's sign-in from Cloud Shell.",
            "4. At the AI companies: what you sent to an agent is kept under your account with its company. Delete it " +
                "there with the buttons under \"At the AI companies\".",
            "5. Uninstalling the app deletes everything on this phone, but not your Cloud Shell and not Google's " +
                "sign-in: do steps 1 and 2 first.",
        ).forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
    }
}

/** PocketIDE 5's computer: its size, a zip of its projects and chats, and deleting it. */
@Composable
private fun OldComputerCard(old: OldComputer, busy: Boolean, onBusy: (Boolean) -> Unit, onDelete: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var size by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(old) { size = withContext(Dispatchers.IO) { old.size() } }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(ZIP)) { uri ->
        if (uri != null) {
            scope.launch {
                onBusy(true)
                val saved = withContext(Dispatchers.IO) { saveZip(context, old, uri) }
                onBusy(false)
                val said = when (saved) {
                    null -> "Could not save the zip there. Try another folder."
                    0 -> "There were no projects or chats to save."
                    else -> "Saved $saved files."
                }
                Toast.makeText(context, said, Toast.LENGTH_LONG).show()
            }
        }
    }
    SectionCard("PocketIDE 5's phone computer") {
        Text(
            "Version 5 kept a Linux computer on this phone" + (size?.let { " (${Formats.size(it)})" } ?: "") +
                ". Version 6 works in Cloud Shell and cannot open it. Save its projects and the agents' chats as a zip " +
                "(sign-ins are left out), upload the zip to Cloud Shell if you like (its ⋮ menu > Upload), then delete it " +
                "to free the space.",
            style = MaterialTheme.typography.bodyMedium,
        )
        ActionRow {
            PrimaryAction(if (busy) "Saving…" else "Save as a zip", onClick = { save.launch(ZIP_NAME) }, enabled = !busy, busy = busy)
            OutlinedButton(onClick = onDelete, enabled = !busy) { Text("Delete it") }
        }
    }
}

/** How many files the zip at [uri] holds, or null when it could not be written there. */
private fun saveZip(context: Context, old: OldComputer, uri: Uri): Int? = try {
    context.contentResolver.openOutputStream(uri)?.let(old::saveTo)
} catch (e: IOException) {
    null
} catch (e: SecurityException) {
    null
}

@Composable
private fun DeleteDialog(ask: Ask, withOld: Boolean, onDismiss: () -> Unit, onDelete: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (ask == Ask.DELETE_OLD) "Delete the phone computer?" else "Delete PocketIDE's data?") },
        text = {
            DialogBody {
                Text(
                    if (ask == Ask.DELETE_OLD) {
                        "Its projects, chats and sign-ins are deleted from this phone. This cannot be undone: save the zip first."
                    } else {
                        "PocketIDE's settings and files on this phone are deleted" +
                            (if (withOld) ", PocketIDE 5's phone computer with them" else "") +
                            ". Your Cloud Shell is not touched."
                    },
                )
            }
        },
        confirmButton = { TextButton(onClick = onDelete) { Text("Delete") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun Place(title: String, text: String, actions: @Composable () -> Unit = {}) {
    SectionCard(title) {
        Text(text, style = MaterialTheme.typography.bodyMedium)
        actions()
    }
}

private const val ZIP = "application/zip"
private const val ZIP_NAME = "pocketide-phone-projects.zip"
