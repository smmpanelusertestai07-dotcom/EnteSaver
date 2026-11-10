package com.pocketide.agents

/**
 * The three official agents, each the maker's own VS Code extension from its verified publisher
 * account on Open VSX. Cloud Shell's set-up installs each in its own VS Code; PocketIDE opens them
 * and never talks to the AI companies itself.
 */
@Suppress("LongParameterList") // One field per fact about an agent; each entry names them all.
enum class Agent(
    val displayName: String,
    val maker: String,
    /** The extension's id on Open VSX (and the VS Code Marketplace). */
    val extensionId: String,
    /** Where, in Cloud Shell's home folder, the agent keeps its chats and sign-in. */
    val chatsFolder: String,
    val signIn: String,
    val dataGoesTo: String,
    val docsUrl: String,
    val privacyUrl: String,
    val termsUrl: String,
) {
    CLAUDE(
        displayName = "Claude Code",
        maker = "Anthropic",
        extensionId = "anthropic.claude-code",
        chatsFolder = "~/.claude",
        signIn = "A Claude account on a plan that includes Claude Code, or an Anthropic Console account.",
        dataGoesTo = "Your prompts, and the code and files Claude Code reads, go to Anthropic.",
        docsUrl = "https://code.claude.com/docs/en/vs-code",
        privacyUrl = "https://www.anthropic.com/legal/privacy",
        termsUrl = "https://www.anthropic.com/legal/consumer-terms",
    ),
    CODEX(
        displayName = "Codex",
        maker = "OpenAI",
        extensionId = "openai.chatgpt",
        chatsFolder = "~/.codex",
        signIn = "A ChatGPT account on a plan that includes Codex, or an OpenAI API key.",
        dataGoesTo = "Your prompts, and the code and files Codex reads, go to OpenAI.",
        docsUrl = "https://developers.openai.com/codex/ide",
        privacyUrl = "https://openai.com/policies/privacy-policy/",
        termsUrl = "https://openai.com/policies/terms-of-use/",
    ),
    ANTIGRAVITY(
        displayName = "Antigravity",
        maker = "Google",
        extensionId = "google.google-antigravity",
        chatsFolder = "~/.gemini/antigravity",
        signIn = "A Google account. Google allows its sign-in only in a real browser, so it opens in Chrome.",
        dataGoesTo = "Your prompts, and the code and files Antigravity reads, go to Google.",
        docsUrl = "https://antigravity.google/docs",
        privacyUrl = "https://policies.google.com/privacy",
        termsUrl = "https://policies.google.com/terms",
    ),
    ;

    /** The publisher and name parts of [extensionId]. */
    val publisher: String get() = extensionId.substringBefore('.')
    val extensionName: String get() = extensionId.substringAfter('.')

    /** The extension's page on Open VSX, where its publisher's verified badge shows. */
    val openVsxUrl: String get() = "https://open-vsx.org/extension/$publisher/$extensionName"
}
