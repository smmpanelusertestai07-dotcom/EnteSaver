package com.pocketide.downloads

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/**
 * A file a page in PocketIDE hands the phone (a link an agent gave, PocketIDE's own file page, VS
 * Code's own Download), before anything is saved. [decided]: the owner already chose to save it (a
 * Download button on PocketIDE's file page, VS Code's Download), so it starts at once; otherwise
 * PocketIDE shows what it is first, and asks.
 */
data class FileOffer(
    val url: String,
    val name: String,
    val mime: String,
    val size: Long,
    val decided: Boolean,
) {
    val isApk: Boolean get() = FileKinds.isApk(name, mime)

    companion object {
        /** `<port>-<32 hex key>.localhost`: an address of PocketIDE's door to Cloud Shell. */
        private val DOOR_HOST = Regex("""^(\d{2,5})-[0-9a-f]{32}\.localhost$""")

        /** Cloud Shell's file links (files.py), whose own Download buttons ask nothing more. */
        const val FILES_PORT = 6081

        /**
         * What a download from a page is, from what the WebView says of it; null when PocketIDE cannot
         * fetch it itself (a file a page made in its own memory, or one from anywhere but Cloud Shell).
         * [fromVsCode]: VS Code's own Download, which the owner chose in its menu.
         */
        fun of(url: String, contentDisposition: String?, mimeType: String?, contentLength: Long, fromVsCode: Boolean): FileOffer? {
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            val port = uri.host?.lowercase(Locale.ROOT)?.let { DOOR_HOST.matchEntire(it) }?.groupValues?.get(1)?.toIntOrNull()
            if (uri.scheme?.lowercase(Locale.ROOT) != "http" || port == null) return null
            val asked = uri.rawQuery.orEmpty().split('&').map { it.substringBefore('=') }.toSet()
            // files.py's Download and Download as zip: the owner tapped them on its page.
            val ours = port == FILES_PORT && ("download" in asked || "zip" in asked)
            val name = FileKinds.name(contentDisposition, url, mimeType)
            return FileOffer(
                url = url,
                name = name,
                mime = FileKinds.mime(name, mimeType),
                size = contentLength.takeIf { it >= 0 } ?: -1,
                decided = ours || fromVsCode,
            )
        }
    }
}

/** What kind of file a name and type are, for its icon, its words and what opens it. */
object FileKinds {
    const val APK = "application/vnd.android.package-archive"
    private const val OCTETS = "application/octet-stream"
    private const val MAX_NAME = 120

    enum class Kind(val word: String) {
        APP("Android app"),
        IMAGE("Picture"),
        VIDEO("Video"),
        AUDIO("Sound"),
        PDF("PDF"),
        ARCHIVE("Archive"),
        TEXT("Text"),
        DOCUMENT("Document"),
        OTHER("File"),
    }

    private val TYPES = mapOf(
        "apk" to APK, "aab" to OCTETS, "zip" to "application/zip", "jar" to "application/java-archive",
        "gz" to "application/gzip", "tgz" to "application/gzip", "tar" to "application/x-tar", "7z" to "application/x-7z-compressed",
        "pdf" to "application/pdf", "png" to "image/png", "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "gif" to "image/gif",
        "webp" to "image/webp", "svg" to "image/svg+xml", "bmp" to "image/bmp", "ico" to "image/x-icon", "avif" to "image/avif",
        "mp4" to "video/mp4", "m4v" to "video/mp4", "webm" to "video/webm", "mov" to "video/quicktime", "3gp" to "video/3gpp",
        "mkv" to "video/x-matroska", "mp3" to "audio/mpeg", "wav" to "audio/wav", "ogg" to "audio/ogg", "opus" to "audio/ogg",
        "m4a" to "audio/mp4", "aac" to "audio/aac", "flac" to "audio/flac", "txt" to "text/plain", "log" to "text/plain",
        "md" to "text/markdown", "csv" to "text/csv", "json" to "application/json", "xml" to "text/xml", "html" to "text/html",
        "htm" to "text/html", "doc" to "application/msword", "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel", "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint", "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )
    private val ARCHIVES = setOf("zip", "jar", "aar", "aab", "gz", "tgz", "tar", "7z", "xz", "bz2", "rar")
    private val DOCUMENTS = setOf("doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf")

    /**
     * The file's name: Content-Disposition's (its UTF-8 filename* first), else the file VS Code's own
     * download names (/vscode-remote-resource?path=…), else the address's last part.
     */
    fun name(contentDisposition: String?, url: String, mime: String?): String {
        val uri = runCatching { URI(url) }.getOrNull()
        val vsCodeFile = uri?.rawQuery.orEmpty().split('&').firstOrNull { it.startsWith("path=") }
            ?.removePrefix("path=")?.let(::decode)?.substringAfterLast('/')
        val given = contentDisposition?.let(::fromDisposition)
            ?: vsCodeFile?.takeIf { it.isNotBlank() }
            ?: uri?.rawPath?.substringAfterLast('/')?.let(::decode)
        return plainName(given, mime)
    }

    /** [given] as a name Android's Downloads takes; download.<the type's extension> when there is none. */
    fun plainName(given: String?, mime: String?): String {
        val plain = safe(given.orEmpty())
        if (plain.isNotEmpty()) return plain
        val ext = TYPES.entries.firstOrNull { it.value == mime?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT) }?.key
        return if (ext != null) "download.$ext" else "download"
    }

    /** The type to save it as: the one Cloud Shell gave, unless it says no more than "bytes" and the name says more. */
    fun mime(name: String, given: String?): String {
        val sent = given?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() }
        val byName = TYPES[extension(name)]
        return when {
            byName == APK -> APK
            sent != null && sent != OCTETS -> sent
            else -> byName ?: OCTETS
        }
    }

    fun isApk(name: String, mime: String): Boolean = mime == APK || extension(name) == "apk"

    fun kind(name: String, mime: String): Kind {
        val ext = extension(name)
        return when {
            isApk(name, mime) -> Kind.APP
            mime.startsWith("image/") -> Kind.IMAGE
            mime.startsWith("video/") -> Kind.VIDEO
            mime.startsWith("audio/") -> Kind.AUDIO
            mime == "application/pdf" -> Kind.PDF
            ext in ARCHIVES -> Kind.ARCHIVE
            ext in DOCUMENTS -> Kind.DOCUMENT
            mime.startsWith("text/") || mime == "application/json" -> Kind.TEXT
            else -> Kind.OTHER
        }
    }

    /** 12.3 MB, as files.py and Android's own Files app say it. */
    fun sizeText(bytes: Long): String {
        if (bytes < 0) return ""
        if (bytes < KILO) return "$bytes bytes"
        var size = bytes.toDouble()
        for (unit in listOf("KB", "MB", "GB")) {
            size /= KILO
            if (size < KILO || unit == "GB") return String.format(Locale.US, "%.1f %s", size, unit).replace(".0 ", " ")
        }
        return ""
    }

    private fun extension(name: String): String = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    private fun fromDisposition(header: String): String? {
        val encoded = Regex("""filename\*\s*=\s*([A-Za-z0-9_-]+)'[^']*'([^;]+)""", RegexOption.IGNORE_CASE).find(header)?.let { match ->
            val charset = runCatching { charset(match.groupValues[1].trim()) }.getOrDefault(StandardCharsets.UTF_8)
            runCatching { URLDecoder.decode(match.groupValues[2].trim().replace("+", "%2B"), charset.name()) }.getOrNull()
        }
        val quoted = Regex("""filename\s*=\s*"((?:[^"\\]|\\.)*)"""", RegexOption.IGNORE_CASE).find(header)
            ?.groupValues?.get(1)?.replace("\\\"", "\"")
        return encoded ?: quoted ?: Regex("""filename\s*=\s*([^;\s]+)""", RegexOption.IGNORE_CASE).find(header)?.groupValues?.get(1)
    }

    private fun decode(part: String): String = runCatching { URLDecoder.decode(part.replace("+", "%2B"), "UTF-8") }.getOrDefault(part)

    /** A name Android's Downloads takes: no folders, no control characters, not too long. */
    private fun safe(raw: String): String {
        val name = raw.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\x00-\\x1f\\x7f]"), "").trim()
        val ext = name.substringAfterLast('.', "").take(MAX_EXT)
        return when {
            name == "." || name == ".." -> ""
            name.length <= MAX_NAME -> name
            ext.isEmpty() -> name.take(MAX_NAME)
            else -> name.take(MAX_NAME - ext.length - 1) + "." + ext
        }
    }

    private const val KILO = 1024
    private const val MAX_EXT = 12
}
