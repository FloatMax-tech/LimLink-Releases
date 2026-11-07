package com.limlink.app.preview

import java.io.File
import java.io.InputStream
import java.net.URI
import kotlin.math.max
import kotlin.math.roundToInt

enum class PreviewKind { IMAGE, PDF, VIDEO, AUDIO, TEXT, UNSUPPORTED }
data class PreviewText(val text: String, val truncated: Boolean)

/** Classification uses the original name, never the private send-*.part snapshot name. */
object PreviewPolicy {
    const val TEXT_LIMIT = 256 * 1024
    private val images = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif")
    private val videos = setOf("mp4", "m4v", "mov", "webm", "mkv", "3gp")
    private val audio = setOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus")
    private val text = setOf("txt", "md", "csv", "tsv", "json", "xml", "log", "yaml", "yml", "ini", "conf", "kt", "java", "swift", "c", "h", "cpp", "js", "ts", "css", "html")
    private val external = setOf("doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "pages", "numbers", "key", "exe", "apk", "msi", "app", "dmg", "bat", "cmd", "sh", "com", "jar", "zip")
    fun kind(name: String, mime: String?): PreviewKind {
        val extension = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        return when {
            extension in external -> PreviewKind.UNSUPPORTED
            extension in images -> PreviewKind.IMAGE
            extension == "pdf" -> PreviewKind.PDF
            extension in videos -> PreviewKind.VIDEO
            extension in audio -> PreviewKind.AUDIO
            extension in text -> PreviewKind.TEXT
            mime?.startsWith("image/") == true -> PreviewKind.IMAGE
            mime == "application/pdf" -> PreviewKind.PDF
            mime?.startsWith("video/") == true -> PreviewKind.VIDEO
            mime?.startsWith("audio/") == true -> PreviewKind.AUDIO
            mime?.startsWith("text/") == true -> PreviewKind.TEXT
            else -> PreviewKind.UNSUPPORTED
        }
    }

    fun mime(name: String, offered: String? = null): String {
        if (!offered.isNullOrBlank() && offered != "application/octet-stream") return offered
        val ext = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "bmp" -> "image/bmp"
            "heic", "heif" -> "image/heif"
            "avif" -> "image/avif"
            "pdf" -> "application/pdf"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "webm" -> "video/webm"
            "mp3" -> "audio/mpeg"
            "m4a", "aac" -> "audio/mp4"
            "wav" -> "audio/wav"
            "flac" -> "audio/flac"
            "ogg", "opus" -> "audio/ogg"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            in text -> "text/plain"
            else -> "application/octet-stream"
        }
    }

    /** Only a small header is needed for type-less received images; never decode whole payloads. */
    fun sniff(header: ByteArray): String? {
        fun starts(vararg values: Int) = header.size >= values.size && values.indices.all { (header[it].toInt() and 255) == values[it] }
        fun ascii(offset: Int, length: Int) = if (header.size >= offset + length) String(header, offset, length, Charsets.US_ASCII) else ""
        return when {
            starts(0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10) -> "image/png"
            starts(0xff, 0xd8, 0xff) -> "image/jpeg"
            ascii(0, 6) in setOf("GIF87a", "GIF89a") -> "image/gif"
            ascii(0, 4) == "RIFF" && ascii(8, 4) == "WEBP" -> "image/webp"
            ascii(0, 2) == "BM" -> "image/bmp"
            ascii(4, 4) == "ftyp" && ascii(8, 4) in setOf("heic", "heix", "hevc", "hevx", "mif1", "msf1") -> "image/heif"
            ascii(4, 4) == "ftyp" && ascii(8, 4) in setOf("avif", "avis") -> "image/avif"
            ascii(0, 5) == "%PDF-" -> "application/pdf"
            else -> null
        }
    }

    fun localLocator(locator: String): Boolean = runCatching {
        if (locator.startsWith('/')) return@runCatching true
        val uri = URI(locator)
        when (uri.scheme) {
            "content" -> !uri.authority.isNullOrBlank() && !uri.path.isNullOrBlank()
            "file" -> uri.authority.isNullOrEmpty() && uri.path?.startsWith('/') == true
            else -> false
        }
    }.getOrDefault(false)

    fun fileAvailable(locator: String): Boolean = runCatching {
        val file = if (locator.startsWith('/')) File(locator) else File(URI(locator))
        file.isFile && file.canRead()
    }.getOrDefault(false)

    fun renderSize(width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val scale = max(1.0, max(width, height).toDouble() / 2048.0)
        return max(1, (width / scale).roundToInt()) to max(1, (height / scale).roundToInt())
    }

    fun readText(input: InputStream, limit: Int = TEXT_LIMIT): PreviewText {
        require(limit in 1..TEXT_LIMIT)
        val bytes = ByteArray(limit + 1)
        var count = 0
        while (count < bytes.size) {
            val n = input.read(bytes, count, bytes.size - count)
            if (n < 0) break
            if (n == 0) { val one = input.read(); if (one < 0) break; bytes[count++] = one.toByte() } else count += n
        }
        val size = minOf(count, limit)
        val charset = when {
            size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> Charsets.UTF_16LE
            size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        val offset = when {
            charset != Charsets.UTF_8 -> 2
            size >= 3 && bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() && bytes[2] == 0xbf.toByte() -> 3
            else -> 0
        }
        if (charset == Charsets.UTF_8) require((offset until size).none { bytes[it] == 0.toByte() })
        return PreviewText(String(bytes, offset, max(0, size - offset), charset), count > limit)
    }
}
