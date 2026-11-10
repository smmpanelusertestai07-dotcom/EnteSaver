package com.pocketide.ui.screens.cloudshell

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import com.pocketide.cloudshell.CloudShell
import com.pocketide.docs.DocsContent
import com.pocketide.graph
import com.pocketide.link.Holds
import com.pocketide.link.LinkState
import com.pocketide.link.Problem
import com.pocketide.link.SignInResult
import com.pocketide.linux.ComputerState
import com.pocketide.ui.components.ActionRow
import com.pocketide.ui.components.Formats
import com.pocketide.ui.components.SectionCard
import com.pocketide.ui.components.Tone
import com.pocketide.ui.screens.help.HelpPageScreen
import com.pocketide.ui.shell.BrandMark
import com.pocketide.ui.shell.FinePrint
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.NoticeCard
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.ShellPage
import com.pocketide.ui.web.Browser
import kotlinx.coroutines.launch

/**
 * The set-up PocketIDE opens with until its computer, Google Cloud Shell, is ready. Four steps that
 * run by themselves: PocketIDE's connection on this phone (Ubuntu with Google's own gcloud, about
 * 130 MB, once) downloads as soon as this page opens; the owner picks the Google account; gcloud
 * signs in with Google's page (the owner taps Allow); and PocketIDE sets Cloud Shell up through
 * that connection. No Google Cloud project, billing or OAuth client is made.
 */
@Composable
// Four steps on one page, each showing where it is.
@Suppress("CyclomaticComplexMethod", "LongMethod")
fun SetUpScreen() {
    val context = LocalContext.current
    val graph = context.graph
    val scope = rememberCoroutineScope()
    val settings by graph.settings.settings.collectAsStateWithLifecycle()
    val computer by graph.computer.state.collectAsStateWithLifecycle()
    val link by graph.link.state.collectAsStateWithLifecycle()
    var reading by remember { mutableStateOf<String?>(null) }
    var signingIn by remember { mutableStateOf(false) }
    var signInProblem by remember { mutableStateOf<String?>(null) }
    // The connection's notice (with its Disconnect button) needs Android 13's notification permission; without it, it still works.
    // Android asks only after one of the owner's own taps (picking the account), never by itself when the page opens.
    val notices = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val askForNotices = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            runCatching { notices.launch(Manifest.permission.POST_NOTIFICATIONS) }
        }
    }
    val pick = rememberAccountPicker { name ->
        graph.settings.update { it.copy(cloudAccount = name) }
        askForNotices()
    }
    val account = settings.cloudAccount
    val unused = CloudShell.daysUnused(settings, graph.clock.now())
    val installed = computer is ComputerState.Ready || computer is ComputerState.Updating
    val signedIn = settings.gcloudAccount.isNotBlank()
    val resumed by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val startInstall = {
        graph.holds.hold(Holds.SET_UP)
        graph.scope.launch {
            try {
                graph.computer.install()
            } finally {
                graph.holds.release(Holds.SET_UP)
            }
        }
        Unit
    }
    val installConnection = {
        askForNotices()
        startInstall()
    }
    val signInGcloud = {
        signingIn = true
        signInProblem = null
        scope.launch {
            when (val result = graph.link.signIn(account)) {
                is SignInResult.Failed -> signInProblem = result.why
                is SignInResult.SignedIn, SignInResult.Cancelled -> Unit
            }
            signingIn = false
        }
        Unit
    }

    // Each step starts by itself, once, while this screen is in front: the download right away (it
    // needs no account), then gcloud's sign-in and Cloud Shell's set-up. Picking the account is the
    // only tap, besides Google's own Allow.
    var autoInstalled by rememberSaveable { mutableStateOf(false) }
    var autoSignedIn by rememberSaveable { mutableStateOf(false) }
    var autoSetUp by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(computer) {
        if ((computer == ComputerState.NotInstalled || computer is ComputerState.Broken) && !autoInstalled) {
            autoInstalled = true
            startInstall()
        }
    }
    val needsSignIn = installed && !signedIn && account.isNotBlank()
    val signInNext = needsSignIn && !signingIn && resumed.isAtLeast(Lifecycle.State.RESUMED)
    LaunchedEffect(signInNext) {
        if (signInNext && !autoSignedIn) {
            autoSignedIn = true
            signInGcloud()
        }
    }
    val setUpNext = installed && signedIn && link == LinkState.Off
    LaunchedEffect(setUpNext) {
        if (setUpNext && !autoSetUp) {
            autoSetUp = true
            graph.link.connect()
        }
    }

    reading?.let { page ->
        HelpPageScreen(id = page, onBack = { reading = null }, onOpen = { reading = it })
        return
    }
    ShellPage {
        BrandMark(56.dp)
        Gap(16.dp)
        Text("Set up your computer", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text(
            "PocketIDE's computer is Google Cloud Shell: Google's own Linux computer, free with a Google account. Each " +
                "agent gets its own VS Code there, and it opens right here in PocketIDE. Your phone stays cool.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Gap(16.dp)
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (settings.cloudSetUpAt != 0L && unused >= CloudShell.ASK_AGAIN_AFTER_DAYS) {
                NoticeCard(
                    "PocketIDE has not opened Cloud Shell for $unused days, and Google deletes its home folder after " +
                        "${CloudShell.DELETED_AFTER_DAYS} days without use. Connect once: PocketIDE sets up again only what is missing.",
                    tone = Tone.WARN,
                )
            }
            SectionCard("1. Google account") {
                Text(
                    if (account.isBlank()) {
                        "Pick the account Cloud Shell uses. Recommended: a separate Google account just for development. " +
                            "The agents run code and commands in that account's Cloud Shell, so a mistake, a leaked key, or " +
                            "Google limiting Cloud Shell stays away from your main Gmail, Drive and Photos. Your main account " +
                            "works too, the same way: Google's own sign-in, and PocketIDE never sees your password. " +
                            "Either way, turn on 2-Step Verification."
                    } else {
                        "Cloud Shell opens with $account."
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                ActionRow {
                    if (account.isBlank()) PrimaryAction("Choose account", onClick = pick) else OutlinedButton(onClick = pick) { Text("Change") }
                    TextButton(onClick = { Browser.open(context, CloudShell.NEW_ACCOUNT) }) { Text("Create a Google account") }
                }
            }
            SectionCard("2. PocketIDE's connection (once, about 130 MB)") {
                Text(
                    "Google's own gcloud, in PocketIDE's private storage on this phone (with a small Ubuntu, about 500 MB): it " +
                        "signs in with Google and connects to your Cloud Shell. Nothing is made in Google Cloud: no project, no " +
                        "billing, no keys of PocketIDE's own. It downloads by itself as soon as this page opens, and stays for " +
                        "every connection (the agents never run on the phone); Computer > Remove the connection deletes it.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                ConnectorState(computer)
                when (computer) {
                    ComputerState.NotInstalled, is ComputerState.Broken -> PrimaryAction(
                        if (computer is ComputerState.Broken) "Set up again" else "Set up the connection",
                        onClick = installConnection,
                    )
                    else -> Unit
                }
            }
            SectionCard("3. Sign in to gcloud") {
                Text(
                    if (signedIn) {
                        "gcloud is signed in as ${settings.gcloudAccount}."
                    } else {
                        "Google's page opens in Chrome: pick ${account.ifBlank { "your account" }} and tap Allow on \"Google Cloud " +
                            "SDK wants to access your Google Account\". PocketIDE comes back by itself. Once; you can remove it " +
                            "any time in your Google Account (Security > Your connections to third-party apps)."
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                signInProblem?.let { NoticeCard(it, tone = Tone.WARN) }
                if (!signedIn) {
                    ActionRow {
                        PrimaryAction(
                            "Sign in with Google",
                            busy = signingIn,
                            enabled = installed && account.isNotBlank() && !signingIn,
                            onClick = signInGcloud,
                        )
                        if (signingIn) TextButton(onClick = graph.link::cancelSignIn) { Text("Cancel") }
                    }
                }
            }
            SectionCard("4. Set up Cloud Shell (about 5 minutes, once)") {
                Text(
                    "PocketIDE starts your Cloud Shell and installs VS Code with Claude Code, Codex and Antigravity there, each " +
                        "checked before use, in your Cloud Shell home folder. The first time, Google may ask you to accept its " +
                        "terms for Google Cloud: PocketIDE opens that page for you.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                LinkProgress(link)
                val failed = link as? LinkState.Failed
                ActionRow {
                    PrimaryAction(
                        if (failed != null) "Try again" else "Set up Cloud Shell",
                        busy = link is LinkState.Working,
                        enabled = installed && signedIn && link !is LinkState.Working,
                        onClick = { graph.link.connect() },
                    )
                    if (failed?.problem == Problem.CLOUD_SHELL) {
                        OutlinedButton(onClick = { openGooglePage(context, CloudShell.googlePage(account)) }) { Text("Open Google's page (once)") }
                    }
                    if (failed?.problem == Problem.SIGN_IN) {
                        OutlinedButton(onClick = { graph.settings.update { it.copy(gcloudAccount = "") } }) { Text("Sign in again") }
                    }
                }
            }
            SectionCard("Where your data is") {
                Text(
                    "In that account's Cloud Shell home folder (5 GB, which only that account opens): each agent's projects, " +
                        "its chats and its sign-in. Google deletes it after 120 days without use; PocketIDE reminds you before. " +
                        "On this phone, in PocketIDE's private storage: its settings and its connection (Google's gcloud and its " +
                        "sign-in); Android's backup copies none of it. What you ask an agent, and the code it reads, goes to its " +
                        "maker (Anthropic, OpenAI or Google) under your account there.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            FinePrint(
                "Free: 50 hours a week, at most 12 in one session; Cloud Shell stops about 40 minutes after you stop using it, " +
                    "and PocketIDE disconnects 15 minutes after you leave the agents. Use it yourself, as Google intends: no " +
                    "miners, scanners or keep-awake tricks. Google's terms apply.",
            )
            ActionRow {
                TextButton(onClick = { Browser.open(context, CloudShell.TERMS) }) { Text("Google Cloud terms") }
                TextButton(onClick = { reading = DocsContent.COMPUTER_ID }) { Text("How it works") }
            }
        }
    }
}

@Composable
private fun ConnectorState(state: ComputerState) {
    when (state) {
        ComputerState.NotInstalled -> Unit
        is ComputerState.Installing -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(state.step, style = MaterialTheme.typography.bodyMedium)
            val fraction = state.fraction
            if (fraction != null) {
                LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
            if (state.bytesTotal > 0) {
                Text(
                    "${Formats.size(state.bytesDone)} of ${Formats.size(state.bytesTotal)} downloaded. It goes on if you switch apps.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        ComputerState.Ready -> NoticeCard("Ready: Ubuntu and Google's gcloud, in PocketIDE's private storage.", tone = Tone.OK)
        is ComputerState.Updating -> NoticeCard("Ready (updating ${state.what}).", tone = Tone.OK)
        is ComputerState.Broken -> NoticeCard(state.fix, tone = Tone.WARN, title = state.why)
    }
}

@Composable
private fun LinkProgress(state: LinkState) {
    when (state) {
        is LinkState.Working -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(state.step, style = MaterialTheme.typography.bodyMedium)
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            state.detail?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            }
        }
        is LinkState.Failed -> NoticeCard(state.why, tone = Tone.WARN)
        LinkState.On -> NoticeCard("Cloud Shell is set up and connected.", tone = Tone.OK)
        LinkState.Off -> Unit
    }
}
