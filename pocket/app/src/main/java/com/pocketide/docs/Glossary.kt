package com.pocketide.docs

/** The few words PocketIDE uses, in plain language. */
internal object Glossary {
    val all: List<GlossaryEntry> = listOf(
        term("Computer", "Google Cloud Shell, where the agents work."),
        term("Cloud Shell", "A Linux computer Google runs for each Google account, free within weekly limits."),
        term("Home folder", "Your 5 GB in Cloud Shell, the only part it keeps between sessions."),
        term("code-server", "VS Code for the web; each agent has its own in Cloud Shell."),
        term("Agent", "An AI that writes and runs code for you: Claude Code, Codex or Antigravity."),
        term("Extension", "An add-on for VS Code. Each agent is its maker's own extension."),
        term("Open VSX", "The open registry of VS Code extensions, where the agents come from."),
        term("Verified publisher", "A publisher whose ownership Open VSX has checked."),
        term("Terminal", "The computer's command line."),
        term("gcloud", "Google's own command-line tool for Google Cloud; PocketIDE runs it on the phone to reach Cloud Shell."),
        term("Connection", "gcloud's encrypted SSH connection from the phone to your Cloud Shell, through Google's servers."),
        term("Private door", "PocketIDE's own address on the phone for Cloud Shell's ports, answering only its own screens."),
        term("Project", "A folder in ~/projects in Cloud Shell."),
        term("Repository", "A project's code and full history, on GitHub or in Cloud Shell."),
    )
}
