package com.pocketide.ui.components

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pocketide.agents.AddedAgent
import com.pocketide.agents.Agent
import com.pocketide.agents.AgentSlot
import com.pocketide.core.AppJson
import com.pocketide.core.Http
import com.pocketide.core.await
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.io.File
import java.io.IOException

/**
 * Each agent's own icon, as its publisher ships it with the extension on Open VSX: fetched from
 * there, and kept in the app's cache folder so it shows at once and offline. Until the first
 * fetch, the agent's initial stands in for it.
 */
@Composable
fun AgentLogo(agent: Agent, modifier: Modifier = Modifier, size: Dp = 40.dp) {
    val context = LocalContext.current
    val icon by produceState<ImageBitmap?>(initialValue = AgentIcons.cached(agent), agent) {
        if (value == null) value = AgentIcons.load(context.cacheDir, agent)
    }
    val shape = RoundedCornerShape(size * 0.26f)
    Box(
        modifier.size(size).clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = icon
        if (bitmap != null) {
            Image(bitmap, contentDescription = null, modifier = Modifier.size(size * 0.78f))
        } else {
            Text(
                agent.displayName.take(1),
                fontWeight = FontWeight.SemiBold,
                fontSize = (size.value * 0.42f).sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Any agent's logo: one of PocketIDE's own three, or one the owner added. */
@Composable
fun AgentLogo(agent: AgentSlot, modifier: Modifier = Modifier, size: Dp = 40.dp) = when (agent) {
    is AgentSlot.Official -> AgentLogo(agent.agent, modifier, size)
    is AgentSlot.Added -> AddedAgentLogo(agent.added, modifier, size)
}

/** An agent the owner added: its extension's own icon from Open VSX, kept like the others; its initial until then. */
@Composable
fun AddedAgentLogo(added: AddedAgent, modifier: Modifier = Modifier, size: Dp = 40.dp) {
    val context = LocalContext.current
    val icon by produceState(AgentIcons.cached(added.extension), added.extension) {
        if (value == null) value = AgentIcons.load(context.cacheDir, added.extension)
    }
    val bitmap = icon
    if (bitmap == null) {
        ExtensionLogo(added.name, modifier, size)
        return
    }
    Box(
        modifier.size(size).clip(RoundedCornerShape(size * 0.26f)).background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        Image(bitmap, contentDescription = null, modifier = Modifier.size(size * 0.78f))
    }
}

/** Any other extension: its initial on a tile, until it is opened (its own icon then shows in its screen). */
@Composable
fun ExtensionLogo(name: String, modifier: Modifier = Modifier, size: Dp = 40.dp) {
    val shape = RoundedCornerShape(size * 0.26f)
    Box(
        modifier.size(size).clip(shape).background(MaterialTheme.colorScheme.secondaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            name.trim().take(1).uppercase(),
            fontWeight = FontWeight.SemiBold,
            fontSize = (size.value * 0.42f).sp,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
        )
    }
}

/**
 * Icons in memory for the process, and on disk in the cache folder (Android may clear it; the icon
 * is then fetched again). A copy older than a week is fetched again, so a new icon arrives.
 */
object AgentIcons {
    private val memory = LruCache<String, ImageBitmap>(ICONS_KEPT)

    fun cached(agent: Agent): ImageBitmap? = memory.get(idOf(agent))

    /** An added agent's icon, by its extension (publisher.name). */
    fun cached(extension: String): ImageBitmap? = memory.get(extension.lowercase())

    /** Fetches every agent's icon ahead of the screens that show them; failures wait for the next time. */
    suspend fun preload(cacheDir: File) = Agent.entries.forEach { load(cacheDir, it) }

    suspend fun load(cacheDir: File, agent: Agent): ImageBitmap? = load(cacheDir, idOf(agent), agent.name.lowercase())

    suspend fun load(cacheDir: File, extension: String): ImageBitmap? = extension.lowercase().let { id -> load(cacheDir, id, "x-$id") }

    private fun idOf(agent: Agent) = "${agent.publisher}.${agent.extensionName}".lowercase()

    private suspend fun load(cacheDir: File, id: String, fileName: String): ImageBitmap? = withContext(Dispatchers.IO) {
        memory.get(id)?.let { return@withContext it }
        val file = File(File(cacheDir, FOLDER), "$fileName.png")
        val kept = file.takeIf { it.isFile }?.readBytes()?.let(::decode)
        if (kept != null && System.currentTimeMillis() - file.lastModified() < REFRESH_MS) {
            memory.put(id, kept)
            return@withContext kept
        }
        val fresh = fetch(id)?.let { bytes -> decode(bytes)?.also { save(file, bytes) } }
        (fresh ?: kept)?.also { memory.put(id, it) }
    }

    private fun decode(bytes: ByteArray): ImageBitmap? = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()

    private fun save(file: File, bytes: ByteArray) {
        try {
            file.parentFile?.mkdirs()
            val temp = File(file.path + ".part")
            temp.writeBytes(bytes)
            if (!temp.renameTo(file)) temp.delete()
        } catch (e: IOException) {
            // The cache is a convenience: the icon is fetched again next time.
        }
    }

    private suspend fun fetch(id: String): ByteArray? = try {
        val info = get("https://open-vsx.org/api/${id.substringBefore('.')}/${id.substringAfter('.')}")?.decodeToString()
        val iconUrl = info?.let { AppJson.parseToJsonElement(it) as? JsonObject }
            ?.get("files")?.let { it as? JsonObject }
            ?.get("icon")?.jsonPrimitive?.content
            ?.takeIf { it.startsWith(OPEN_VSX) }
        iconUrl?.let { get(it) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (e: IOException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    private suspend fun get(url: String): ByteArray? {
        val parsed = url.toHttpUrlOrNull() ?: return null
        return Http.client.newCall(Request.Builder().url(parsed).build()).await().use { response ->
            val small = response.isSuccessful && response.body.contentLength() <= MAX_BYTES
            if (small) response.body.bytes().takeIf { it.size <= MAX_BYTES } else null
        }
    }

    private const val OPEN_VSX = "https://open-vsx.org/"
    private const val MAX_BYTES = 512 * 1024
    private const val FOLDER = "agent-icons"
    private const val ICONS_KEPT = 24
    private const val REFRESH_MS = 7L * 24 * 60 * 60 * 1000
}
