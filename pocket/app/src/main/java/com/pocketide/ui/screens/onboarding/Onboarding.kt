package com.pocketide.ui.screens.onboarding

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Autorenew
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import com.pocketide.AppGraph
import com.pocketide.agents.Agent
import com.pocketide.docs.DocsContent
import com.pocketide.ui.components.AgentLogo
import com.pocketide.ui.screens.help.HelpPageScreen
import com.pocketide.ui.shell.BrandMark
import com.pocketide.ui.shell.Gap
import com.pocketide.ui.shell.IconTile
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.ShellPage

/**
 * First run: what PocketIDE is, with the terms, then the computer's set-up. No account is needed
 * for PocketIDE itself: Cloud Shell uses the owner's Google account, and each agent signs in to its
 * own maker. PocketIDE asks for no permission.
 */
@Composable
fun Onboarding(graph: AppGraph) {
    var reading by remember { mutableStateOf<String?>(null) }
    val page = reading
    when {
        page != null -> HelpPageScreen(id = page, onBack = { reading = null }, onOpen = { reading = it })
        else -> WelcomeScreen(
            onRead = { reading = it },
            onContinue = { graph.settings.update { it.copy(termsAccepted = DocsContent.TERMS_VERSION, onboardingDone = true) } },
        )
    }
}

@Composable
internal fun WelcomeScreen(onRead: (String) -> Unit, onContinue: () -> Unit) {
    ShellPage {
        Gap(8.dp)
        BrandMark(72.dp)
        Gap(20.dp)
        Text("PocketIDE", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
        Text(DocsContent.TAGLINE, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
        Gap(28.dp)
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Feature(
                icon = { IconTile(Icons.Outlined.Cloud, size = 40.dp) },
                title = "Your computer: Google Cloud Shell",
                text = "Google's own Linux computer, free with a Google account: 50 hours a week. The work runs there, so your phone stays cool.",
            )
            Feature(
                icon = { AgentLogo(Agent.CLAUDE, size = 36.dp) },
                title = "The official AI agents",
                text = "Claude Code by Anthropic, Codex by OpenAI and Antigravity by Google, each in its own VS Code with its own settings, " +
                    "extensions and projects.",
            )
            Feature(
                icon = { IconTile(Icons.Outlined.Lock, size = 40.dp) },
                title = "Private by design",
                text = "PocketIDE has no server and no account. Your projects, chats and sign-ins stay in your own Cloud Shell, which only " +
                    "your Google account opens.",
            )
            Feature(
                icon = { IconTile(Icons.Outlined.Autorenew, size = 40.dp) },
                title = "Starts and updates by itself",
                text = "One tap sets it up. Then each agent's VS Code starts when you open it, and Cloud Shell tidies old caches " +
                    "and installs new agent versions, checked before they are used.",
            )
        }
        Gap(28.dp)
        PrimaryAction("Get started", onClick = onContinue)
        Gap(12.dp)
        TermsLine(onRead)
    }
}

@Composable
private fun Feature(icon: @Composable () -> Unit, title: String, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) { icon() }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun TermsLine(onRead: (String) -> Unit) {
    val link = TextLinkStyles(SpanStyle(color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold))
    val text = buildAnnotatedString {
        append("By continuing you agree to PocketIDE's ")
        withLink(LinkAnnotation.Clickable(DocsContent.TERMS_ID, link) { onRead(DocsContent.TERMS_ID) }) { append("Terms of use") }
        append(" and ")
        withLink(LinkAnnotation.Clickable(DocsContent.PRIVACY_ID, link) { onRead(DocsContent.PRIVACY_ID) }) { append("Privacy policy") }
        append(".")
    }
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
    )
}
