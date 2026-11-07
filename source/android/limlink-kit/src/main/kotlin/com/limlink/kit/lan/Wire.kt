package com.limlink.kit.lan

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import com.google.gson.Strictness
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Base64

object Limits {
    const val MAX_FILE = 5_000_000_000L
    const val CHUNK = 1_048_576
    const val TIMEOUT_MS = 120_000
    const val COMPLETION_TIMEOUT_MS = 1_800_000
    const val PREFIX = "/limlink/v1"
    private val completionPath = Regex("$PREFIX/sessions/[A-Za-z0-9_-]{1,128}/files/[A-Za-z0-9_-]{1,128}/complete")
    fun requestTimeoutMillis(method: String, path: String): Int =
        if (method == "POST" && completionPath.matches(path)) COMPLETION_TIMEOUT_MS else TIMEOUT_MS
    fun size(value: Long): Long { require(value >= 0) { "E_BAD_REQUEST" }; require(value <= MAX_FILE) { "E_FILE_TOO_LARGE" }; return value }
    fun name(value: String): String {
        require(value.isNotEmpty() && value != "." && value != ".." && value.length <= 240 &&
            value.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }) { "E_PATH_INVALID" }
        return value
    }
    fun id(value: String): String { require(value.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "E_BAD_REQUEST" }; return value }
}

object Fingerprints {
    fun of(certificate: X509Certificate): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(MessageDigest.getInstance("SHA-256").digest(certificate.publicKey.encoded))
    fun valid(value: String): Boolean = runCatching {
        value.length == 43 && Base64.getUrlDecoder().decode(value).size == 32 &&
            Base64.getUrlEncoder().withoutPadding().encodeToString(Base64.getUrlDecoder().decode(value)) == value
    }.getOrDefault(false)
}

object Json {
    private val gson = GsonBuilder().serializeNulls().setStrictness(Strictness.STRICT).create()
    fun bytes(value: Any): ByteArray = gson.toJson(value).toByteArray(Charsets.UTF_8)
    fun parse(bytes: ByteArray): JsonObject = requireNotNull(gson.fromJson(String(bytes, Charsets.UTF_8), JsonObject::class.java))
    fun text(value: JsonObject, key: String): String {
        val field = requireNotNull(value[key]); require(field.isJsonPrimitive && field.asJsonPrimitive.isString)
        return field.asString
    }
    fun long(value: JsonObject, key: String): Long {
        val field = requireNotNull(value[key]); require(field.isJsonPrimitive && field.asJsonPrimitive.isNumber)
        return field.asBigDecimal.longValueExact()
    }
    fun bool(value: JsonObject, key: String): Boolean {
        val field = requireNotNull(value[key]); require(field.isJsonPrimitive && field.asJsonPrimitive.isBoolean)
        return field.asBoolean
    }
}

data class Frame(val start: String, val headers: Map<String, String>, val body: ByteArray) {
    val status: Int get() {
        val pieces = start.split(' ')
        require(pieces.size >= 2 && pieces[0] == "HTTP/1.1")
        return pieces[1].toInt()
    }
    val json: JsonObject get() = Json.parse(body)
}

/** Content-Length only: the body allocation is rejected before reading any payload. */
object Wire {
    @JvmOverloads fun read(input: InputStream, maxBody: Int = Limits.CHUNK): Frame {
        val header = ByteArrayOutputStream()
        var tail = 0
        while (tail != 0x0d0a0d0a) {
            val byte = input.read()
            if (byte < 0) throw EOFException()
            header.write(byte)
            require(header.size() <= 16_384) { "E_HEADER_TOO_LARGE" }
            tail = (tail shl 8) or byte
        }
        val lines = header.toString("US-ASCII").dropLast(4).split("\r\n")
        require(lines.first().isNotBlank())
        val headers = linkedMapOf<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':'); require(colon > 0)
            val name = line.substring(0, colon).lowercase()
            require(name.matches(Regex("[a-z0-9-]+")) && name != "transfer-encoding" && !headers.containsKey(name))
            headers[name] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"] ?: "0"
        require(length.matches(Regex("[0-9]+")))
        val count = length.toLong(); require(count <= maxBody)
        if (lines.first().split(' ').getOrNull(1)?.startsWith("${Limits.PREFIX}/pair/") == true) require(count <= 16_384) { "E_BAD_REQUEST" }
        val body = ByteArray(count.toInt())
        var position = 0
        while (position < body.size) {
            val read = input.read(body, position, body.size - position)
            if (read < 0) throw EOFException()
            position += read
        }
        return Frame(lines.first(), headers, body)
    }
    fun write(output: OutputStream, start: String, body: ByteArray = byteArrayOf(), headers: Map<String, String> = emptyMap()) {
        require(body.size <= Limits.CHUNK)
        output.write((start + "\r\n" + (headers + ("content-length" to body.size.toString())).entries.joinToString("") {
            require(it.key.none { c -> c == '\r' || c == '\n' } && it.value.none { c -> c == '\r' || c == '\n' })
            "${it.key}: ${it.value}\r\n"
        } + "\r\n").toByteArray(Charsets.US_ASCII))
        output.write(body); output.flush()
    }
    fun response(status: Int, value: Any): Frame = Frame("HTTP/1.1 $status Status", mapOf("content-type" to "application/json"), Json.bytes(value))
    fun error(code: String, status: Int = 400): Frame = response(status, mapOf("code" to code, "message" to code, "retryable" to false, "detail" to emptyMap<String, String>()))
}
