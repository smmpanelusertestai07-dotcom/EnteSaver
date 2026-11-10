package com.pocketide.ui.lock

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp

/** The words on the cover, also its description for screen readers. */
const val CONTENT_HIDDEN = "App content hidden"

/**
 * What Recents shows of PocketIDE while App lock is on: a black card with the content hidden, as
 * banking apps show. It is drawn whenever the app is not in front, so the picture Android keeps
 * for Recents is this cover and not the code or chat behind it. Screenshots stay allowed.
 */
@Composable
fun HiddenContentCover(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().background(Color.Black).clearAndSetSemantics { contentDescription = CONTENT_HIDDEN }) {
        Icon(Icons.Outlined.VisibilityOff, contentDescription = null, tint = CoverMark, modifier = Modifier.size(96.dp).align(Alignment.Center))
        Row(
            Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 56.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Shield, contentDescription = null, tint = CoverText, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(CONTENT_HIDDEN, color = CoverText, style = MaterialTheme.typography.bodyLarge)
        }
    }
}

private val CoverMark = Color(0xFF3C3C3C)
private val CoverText = Color(0xFF626262)
