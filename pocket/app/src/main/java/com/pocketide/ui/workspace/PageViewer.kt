package com.pocketide.ui.workspace

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.os.Message
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/**
 * A page from Cloud Shell's own address (a dev server an agent started, a preview, a link in an
 * agent's chat to localhost), over the agent's VS Code, through PocketIDE's door. Its own Back
 * goes to the page before, and closing it returns to the agent, never to PocketIDE's home.
 * Addresses outside Cloud Shell go to [onOpen], as from the agent's page. A file it cannot show (an
 * APK, a zip) goes to [onDownload]; when that was all it was asked to open, it closes for it.
 */
// Lint flags every Kotlin WebViewClient object, even one that overrides onRenderProcessGone as this one does.
@SuppressLint("SetJavaScriptEnabled", "MissingOnRenderProcessGone")
@Composable
internal fun PageViewer(
    url: String,
    shownAs: (String) -> String,
    isDoor: (String) -> Boolean,
    toDoor: (String) -> String?,
    onOpen: (String, Boolean) -> Unit,
    onDownload: (url: String, contentDisposition: String?, mimeType: String?, contentLength: Long) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    var title by remember(url) { mutableStateOf(shownAs(url)) }
    var progress by remember { mutableIntStateOf(0) }
    var canGoBack by remember { mutableStateOf(false) }
    val web = remember(url) {
        WebView(context).apply {
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                mediaPlaybackRequiresUserGesture = true
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setSupportMultipleWindows(true)
                javaScriptCanOpenWindowsAutomatically = false
                useWideViewPort = true
                loadWithOverviewMode = true
                builtInZoomControls = true
                displayZoomControls = false
            }
            webViewClient = object : WebViewClient() {
                @Suppress("ReturnCount") // A frame, the door, Cloud Shell's localhost, anything else.
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (!request.isForMainFrame) return false
                    val next = request.url.toString()
                    if (isDoor(next)) return false
                    // Cloud Shell's localhost, named as such by the page: through the door instead.
                    toDoor(next)?.let {
                        view.loadUrl(it)
                        return true
                    }
                    onOpen(next, request.hasGesture())
                    return true
                }

                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    title = shownAs(url)
                }

                override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
                    canGoBack = view.canGoBack()
                    title = shownAs(url)
                }

                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    onClose()
                    return true
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, newProgress: Int) {
                    progress = newProgress
                }

                override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                    val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                    val probe = WebView(view.context)
                    probe.webViewClient = ProbeClient(fromTap = isUserGesture) { next ->
                        if (isDoor(next)) view.loadUrl(next) else toDoor(next)?.let(view::loadUrl) ?: onOpen(next, isUserGesture)
                    }
                    transport.webView = probe
                    resultMsg.sendToTarget()
                    return true
                }
            }
            setDownloadListener { next, _, disposition, mime, length ->
                onDownload(next, disposition, mime, length)
                // Nothing was shown before it (the link was the file itself): the agent, under the file's sheet.
                if (copyBackForwardList().size == 0) onClose()
            }
            loadUrl(url)
        }
    }
    DisposableEffect(web) {
        onDispose {
            web.stopLoading()
            web.destroy()
        }
    }
    BackHandler {
        if (web.canGoBack()) web.goBack() else onClose()
    }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { if (web.canGoBack()) web.goBack() else onClose() }) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = if (canGoBack) "Back to the page before" else "Back to the agent")
                }
                Text(
                    title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { web.reload() }) { Icon(Icons.Outlined.Refresh, contentDescription = "Reload the page") }
                IconButton(onClick = onClose) { Icon(Icons.Outlined.Close, contentDescription = "Close the page") }
            }
        }
        if (progress in 1 until FULL) LinearProgressIndicator(progress = { progress / FULL.toFloat() }, modifier = Modifier.fillMaxWidth())
        AndroidView(factory = { web }, modifier = Modifier.weight(1f).fillMaxWidth())
    }
}

private const val FULL = 100
