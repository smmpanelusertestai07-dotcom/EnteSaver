package com.pocketide.ui.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Android
import androidx.compose.material.icons.outlined.Audiotrack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pocketide.downloads.Download
import com.pocketide.downloads.Downloads
import com.pocketide.downloads.FileKinds
import com.pocketide.downloads.FileOffer
import com.pocketide.downloads.HeldFile

/** What the sheet does for the owner; each is one button. */
internal class FileActions(
    val save: () -> Unit,
    val cancel: () -> Unit,
    val open: () -> Unit,
    val share: () -> Unit,
    val retry: () -> Unit,
    val close: () -> Unit,
)

/**
 * A file from Cloud Shell at the bottom of the screen, as Android's own downloads show one: first
 * what it is (when a page offered it, nothing is saved before the owner says so), then how far it
 * is, then where it is, with Open and Share. An APK opens in the phone's Files app, which installs
 * it (Android asks first): PocketIDE itself installs nothing.
 */
@Composable
internal fun FileSheet(offer: FileOffer?, download: Download?, actions: FileActions) {
    val name = download?.name ?: offer?.name ?: return
    val mime = download?.mime ?: offer?.mime.orEmpty()
    val size = download?.total?.takeIf { it >= 0 } ?: offer?.size ?: -1
    val kind = FileKinds.kind(name, mime)
    val apk = kind == FileKinds.Kind.APP
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = SCRIM))
            .clickable(interactionSource = null, indication = null, onClickLabel = "Close", onClick = actions.close),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            modifier = Modifier
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .pointerInput(Unit) { detectTapGestures {} },
        ) {
            Column(Modifier.navigationBarsPadding().padding(start = 20.dp, end = 8.dp, top = 16.dp, bottom = 16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(52.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(iconOf(kind), contentDescription = null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.size(28.dp))
                        }
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(name, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(
                            listOf(FileKinds.sizeText(size), kind.word, "from Cloud Shell").filter { it.isNotEmpty() }.joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = actions.close) { Icon(Icons.Outlined.Close, contentDescription = "Close") }
                }
                Spacer(Modifier.height(12.dp))
                Column(Modifier.padding(end = 12.dp)) {
                    when (download?.state) {
                        null -> Offered(apk, actions)
                        Download.State.RUNNING -> Running(download, actions)
                        Download.State.DONE -> Done(apk, actions)
                        Download.State.FAILED -> Failed(download.why, download.canRetry, actions)
                        Download.State.CANCELLED -> Unit
                    }
                }
            }
        }
    }
}

@Composable
private fun Offered(apk: Boolean, actions: FileActions) {
    Note(
        "It is in Cloud Shell. PocketIDE saves it in your phone's Downloads, in ${Downloads.FOLDER}." +
            if (apk) " To install it, open it there in Files: Android asks you first." else "",
    )
    Buttons {
        TextButton(onClick = actions.close) { Text("Cancel") }
        Button(onClick = actions.save) { Text("Download") }
    }
}

@Composable
private fun Running(download: Download, actions: FileActions) {
    val total = download.total.takeIf { it > 0 }
    if (total != null) {
        LinearProgressIndicator(progress = { (download.received.toFloat() / total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
    } else {
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
    Note(if (total != null) "${FileKinds.sizeText(download.received)} of ${FileKinds.sizeText(total)}" else "${FileKinds.sizeText(download.received)} so far")
    Buttons { TextButton(onClick = actions.cancel) { Text("Cancel") } }
}

@Composable
private fun Done(apk: Boolean, actions: FileActions) {
    Note(
        if (apk) {
            "In Download/${Downloads.FOLDER}. To install it, tap it there in Files: Android asks you first."
        } else {
            "In Download/${Downloads.FOLDER}."
        },
    )
    Buttons {
        OutlinedButton(onClick = actions.share) { Text("Share") }
        Button(onClick = actions.open) { Text(if (apk) "Open in Files" else "Open") }
    }
}

@Composable
private fun Failed(why: String?, canRetry: Boolean, actions: FileActions) {
    Note(why ?: "It did not arrive.", error = true)
    Buttons {
        TextButton(onClick = actions.close) { Text("Close") }
        if (canRetry) Button(onClick = actions.retry) { Text("Try again") }
    }
}

@Composable
private fun Note(text: String, error: Boolean = false) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 8.dp),
    )
}

@Composable
private fun Buttons(content: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

private fun iconOf(kind: FileKinds.Kind): ImageVector = when (kind) {
    FileKinds.Kind.APP -> Icons.Outlined.Android
    FileKinds.Kind.IMAGE -> Icons.Outlined.Image
    FileKinds.Kind.VIDEO -> Icons.Outlined.Movie
    FileKinds.Kind.AUDIO -> Icons.Outlined.Audiotrack
    FileKinds.Kind.PDF -> Icons.Outlined.PictureAsPdf
    FileKinds.Kind.ARCHIVE -> Icons.Outlined.FolderZip
    FileKinds.Kind.TEXT -> Icons.AutoMirrored.Outlined.Article
    FileKinds.Kind.DOCUMENT -> Icons.Outlined.Description
    FileKinds.Kind.OTHER -> Icons.AutoMirrored.Outlined.InsertDriveFile
}

private const val SCRIM = 0.4f

/**
 * A screen's file sheet: what a page offered (shown first, nothing saved yet), or the download it
 * follows. A page hands files to [take]; the owner's own choice (PocketIDE's Download buttons, VS
 * Code's Download, a file the page [held] for it) starts at once.
 */
internal class FileFlow(private val downloads: Downloads, private val toast: (String) -> Unit) {
    var offer by mutableStateOf<FileOffer?>(null)
    var shown by mutableStateOf<Int?>(null)

    fun take(url: String, contentDisposition: String?, mimeType: String?, contentLength: Long, fromVsCode: Boolean, held: HeldFile? = null) {
        if (held != null || url.startsWith("data:")) {
            (held?.let(downloads::startHeld) ?: downloads.startData(url, null))?.let { shown = it } ?: toast(NOT_FROM_CLOUD_SHELL)
            return
        }
        val offered = FileOffer.of(url, contentDisposition, mimeType, contentLength, fromVsCode)
        when {
            offered == null -> toast(NOT_FROM_CLOUD_SHELL)
            offered.decided -> shown = downloads.start(offered)
            else -> offer = offered
        }
    }

    fun close() {
        offer = null
        shown = null
    }

    private companion object {
        const val NOT_FROM_CLOUD_SHELL = "PocketIDE saves files from Cloud Shell; this one was made inside the page, and stays there."
    }
}

@Composable
internal fun rememberFileFlow(downloads: Downloads, toast: (String) -> Unit): FileFlow = remember { FileFlow(downloads, toast) }

/** The sheet of [flow], over everything else on the screen; Back closes it (a download goes on, with its notice). */
@Composable
internal fun FileFlowSheet(flow: FileFlow, downloads: Downloads, toast: (String) -> Unit) {
    val context = LocalContext.current
    val items by downloads.items.collectAsStateWithLifecycle()
    val download = items.firstOrNull { it.id == flow.shown }
    val offer = flow.offer
    if (offer == null && download == null) return
    BackHandler { flow.close() }
    FileSheet(
        offer,
        download,
        FileActions(
            save = {
                offer?.let { flow.shown = downloads.start(it) }
                flow.offer = null
            },
            cancel = {
                download?.let { downloads.cancel(it.id) }
                flow.close()
            },
            open = {
                if (download != null && !downloads.open(context, download)) {
                    toast("No app on this phone opens it. It is in Download/${Downloads.FOLDER}: open it from the Files app.")
                }
            },
            share = { download?.let { downloads.share(context, it) } },
            retry = { download?.let { downloads.retry(it) }?.let { flow.shown = it } },
            close = flow::close,
        ),
    )
}
