package com.pocketide.ui.screens.help

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pocketide.docs.DocSection
import com.pocketide.docs.DocsContent
import com.pocketide.ui.components.SelectableText
import com.pocketide.ui.shell.SectionLabel

/** Help: the guide's pages, the questions people ask, and the terms. All offline, all selectable. */
@Composable
fun HelpScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    var query by remember { mutableStateOf("") }
    val found = remember(query) { DocsContent.search(query) }
    val places = remember(query) { DocsContent.searchPlaces(query) }
    val questions = remember(query) { DocsContent.searchQuestions(query) }
    val openPlace = LocalOpenPlace.current
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
        TitleRow("Help", onBack)
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Search Help and settings") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        if (query.isNotBlank()) {
            if (found.isEmpty() && places.isEmpty() && questions.isEmpty()) {
                SectionLabel("Found")
                Text("Nothing matches. Try one word, such as \"hours\", \"keys\" or \"sign in\".")
            }
            if (places.isNotEmpty()) SectionLabel("In the app")
            places.forEach { place ->
                ListItem(
                    headlineContent = { Text(place.title) },
                    supportingContent = { Text(place.about) },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.clickable { openPlace(place.id) },
                )
            }
            if (found.isNotEmpty()) SectionLabel("Guide")
            found.forEach { SectionRow(it, onOpen) }
            if (questions.isNotEmpty()) SectionLabel("Questions")
            questions.forEach { entry ->
                Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(entry.question, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    entry.answer.forEach { DocBlockView(it, onOpen) }
                }
            }
        } else {
            SectionLabel("Guide")
            DocsContent.guide.forEach { SectionRow(it, onOpen) }
            SectionLabel("Questions")
            DocsContent.faq.forEach { entry ->
                Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(entry.question, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    entry.answer.forEach { DocBlockView(it, onOpen) }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
            SectionLabel("Words used")
            DocsContent.glossary.forEach { term ->
                SelectableText("${term.term}: ${term.meaning}", Modifier.padding(vertical = 4.dp))
            }
            SectionLabel("Terms")
            DocsContent.legal.forEach { SectionRow(it, onOpen) }
        }
    }
}

/** One Help page. An id that no longer exists (a stale link) shows the Help list instead. */
@Composable
fun HelpPageScreen(id: String, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val section = DocsContent.section(id)
    if (section == null) {
        HelpScreen(onBack, onOpen)
        return
    }
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        TitleRow(section.title, onBack)
        section.blocks.forEach { DocBlockView(it, onOpen) }
        if (section.id == DocsContent.NOTICES_ID) SelectableText(DocsContent.notices(context), Modifier.fillMaxWidth(), sizeSp = 12f)
        val questions = DocsContent.faqFor(section.id)
        if (questions.isNotEmpty()) {
            SectionLabel("Questions")
            questions.forEach { entry ->
                Text(entry.question, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                entry.answer.forEach { DocBlockView(it, onOpen) }
            }
        }
    }
}

@Composable
private fun TitleRow(title: String, onBack: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SectionRow(section: DocSection, onOpen: (String) -> Unit) {
    ListItem(
        headlineContent = { Text(section.title) },
        supportingContent = { Text(section.summary) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.clickable { onOpen(section.id) },
    )
}
