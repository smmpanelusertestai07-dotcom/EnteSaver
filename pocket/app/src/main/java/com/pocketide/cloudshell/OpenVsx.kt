package com.pocketide.cloudshell

import com.pocketide.core.AppJson
import com.pocketide.core.Http
import com.pocketide.core.await
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.io.IOException

/** The files Open VSX keeps for an extension's version; only its icon is used here. */
@Serializable
data class OpenVsxFiles(val icon: String? = null)

/** An extension as Open VSX's search lists it. */
@Serializable
data class OpenVsxExtension(
    val namespace: String,
    val name: String,
    val version: String = "",
    val displayName: String? = null,
    val description: String? = null,
    val verified: Boolean = false,
    val deprecated: Boolean = false,
    val downloadCount: Long = 0,
    val averageRating: Double? = null,
    val files: OpenVsxFiles = OpenVsxFiles(),
) {
    /** publisher.name, as VS Code and the launcher name it. */
    val id: String get() = "$namespace.$name"
    val title: String get() = displayName?.takeIf { it.isNotBlank() } ?: name
    val page: String get() = "$SITE/extension/$namespace/$name"
}

private const val SITE = "https://open-vsx.org"

@Serializable
private data class OpenVsxDetails(val categories: List<String> = emptyList())

@Serializable
private data class OpenVsxSearch(val extensions: List<OpenVsxExtension> = emptyList(), val error: String? = null)

/**
 * Open VSX (open-vsx.org, the Eclipse Foundation's registry), where each agent's VS Code gets its
 * extensions, searched from the phone: only the words typed go there, with no account and nothing
 * of Cloud Shell's. The launcher in Cloud Shell installs what is picked, after checking its
 * download against Open VSX's checksum.
 */
object OpenVsx {
    sealed interface Found {
        data class Some(val extensions: List<OpenVsxExtension>) : Found

        data class Failed(val why: String) : Found
    }

    /** What Open VSX has for [query], best match first; the most installed ones for a blank query. */
    suspend fun search(query: String): Found = try {
        val url = "$SITE/api/-/search".toHttpUrl().newBuilder()
            .addQueryParameter("query", query.trim().take(QUERY_LIMIT))
            .addQueryParameter("size", RESULTS.toString())
            .addQueryParameter("sortBy", if (query.isBlank()) "downloadCount" else "relevance")
            .addQueryParameter("sortOrder", "desc")
            .build()
        val text = get(url.toString(), SEARCH_BYTES)?.decodeToString()
        val answer = text?.let { AppJson.decodeFromString(OpenVsxSearch.serializer(), it) }
        when {
            answer == null -> Found.Failed(NO_ANSWER)
            answer.error != null -> Found.Failed(answer.error)
            else -> Found.Some(answer.extensions.filter { ID.matches(it.id) })
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (expected: IOException) {
        Found.Failed(NO_ANSWER)
    } catch (expected: SerializationException) {
        Found.Failed(NO_ANSWER)
    } catch (expected: IllegalArgumentException) {
        Found.Failed(NO_ANSWER)
    }

    /**
     * True when Open VSX files [extension] under AI or Chat: an agent, which can have a VS Code and a
     * port of its own; false when not, or when Open VSX did not answer.
     */
    suspend fun isAgent(extension: OpenVsxExtension): Boolean = try {
        val text = get("$SITE/api/${extension.namespace}/${extension.name}", SEARCH_BYTES)?.decodeToString()
        val details = text?.let { AppJson.decodeFromString(OpenVsxDetails.serializer(), it) }
        details?.categories.orEmpty().any { it.equals("AI", ignoreCase = true) || it.equals("Chat", ignoreCase = true) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (expected: IOException) {
        false
    } catch (expected: SerializationException) {
        false
    } catch (expected: IllegalArgumentException) {
        false
    }

    /** [extension]'s icon file (PNG or JPEG), from Open VSX only; null when it has none or it is too big. */
    suspend fun icon(extension: OpenVsxExtension): ByteArray? = try {
        extension.files.icon?.takeIf { it.startsWith("$SITE/") }?.let { get(it, ICON_BYTES) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (expected: IOException) {
        null
    }

    private suspend fun get(url: String, limit: Int): ByteArray? = withContext(Dispatchers.IO) {
        val parsed = url.toHttpUrlOrNull() ?: return@withContext null
        Http.client.newCall(Request.Builder().url(parsed).build()).await().use { response ->
            val small = response.isSuccessful && response.body.contentLength() <= limit
            if (small) response.body.bytes().takeIf { it.size <= limit } else null
        }
    }

    /** An extension's id as the launcher takes it (its extension_name). */
    val ID = Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

    private const val RESULTS = 30
    private const val QUERY_LIMIT = 100
    private const val SEARCH_BYTES = 2 * 1024 * 1024
    private const val ICON_BYTES = 512 * 1024
    private const val NO_ANSWER = "Open VSX did not answer. Check the phone's internet, then try again."
}
