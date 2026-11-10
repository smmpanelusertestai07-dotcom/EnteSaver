package com.pocketide

import android.content.Context
import com.pocketide.cloudshell.CloudShellInfo
import com.pocketide.core.Clock
import com.pocketide.core.LogBackgroundFailure
import com.pocketide.core.SettingsStore
import com.pocketide.core.createSettingsStore
import com.pocketide.downloads.Downloads
import com.pocketide.link.Holds
import com.pocketide.link.Link
import com.pocketide.link.LinkOpener
import com.pocketide.linux.Computer
import com.pocketide.linux.LinuxDirs
import com.pocketide.linux.ProotComputer
import com.pocketide.ui.workspace.AgentPages
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob

/**
 * The app's parts, made on first use. The computer is Google Cloud Shell, where VS Code and the
 * agents run. On the phone PocketIDE keeps its settings (with the Google account Cloud Shell opens
 * with) and its connection to Cloud Shell: Ubuntu under PRoot with Google's own gcloud, which
 * signs in with Google and connects. PocketIDE has no server of its own.
 */
class AppGraph(val context: Context) {
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + LogBackgroundFailure)
    val clock: Clock = Clock.SYSTEM

    val settings: SettingsStore by lazy { createSettingsStore(this) }

    /** The start-up housekeeping (what older versions left); the connection's set-up waits for it. */
    @Volatile
    var housekeeping: Job? = null

    val foreground = Foreground(context)

    val dirs: LinuxDirs by lazy { LinuxDirs.of(context) }

    val computer: Computer by lazy { ProotComputer(context, dirs, clock, beforeFirstWrite = { housekeeping?.join() }) }

    val holds: Holds by lazy { Holds(context) }

    val link: Link by lazy { Link(computer, dirs, settings, holds, clock, bringBack = foreground::bringBack) }

    /** Pages gcloud asks the phone to open (its sign-in), to Chrome. */
    val linkOpener: LinkOpener by lazy { LinkOpener(dirs.openRequests, foreground::openLink) }

    /** The agents' VS Code pages, kept while the app runs so that leaving one does not reload it. */
    val pages: AgentPages by lazy { AgentPages(context) }

    /** Cloud Shell's numbers and the agents' chats, read there over the open connection. */
    val cloudInfo: CloudShellInfo by lazy { CloudShellInfo(context, link, settings) }

    /** Files from Cloud Shell saved on the phone (an agent's links, VS Code's Download), through the door. */
    val downloads: Downloads by lazy { Downloads(context) }
}
