package com.pocketide.ui.nav

import kotlinx.serialization.Serializable

// The app's destinations. The five in the bottom bar are tabs; the rest open over them.

@Serializable
data object HomeRoute

/** The agents' chats, read from Cloud Shell. */
@Serializable
data object ChatsRoute

/** One chat: [agent] is info.py's name for it (claude-code, codex, antigravity). */
@Serializable
data class ChatRoute(val agent: String, val id: String)

/** Cloud Shell's machine, the week's hours and the agents' usage, live. */
@Serializable
data object UsageRoute

/** The computer: Google Cloud Shell, its account, limits, data and safety. */
@Serializable
data object ComputerRoute

@Serializable
data object SettingsRoute

@Serializable
data object DataRoute

/** Open VSX searched from the phone; each agent's extensions in Cloud Shell. */
@Serializable
data object ExtensionsRoute

@Serializable
data object HelpRoute

@Serializable
data class HelpPageRoute(val id: String)
