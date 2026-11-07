package com.limlink.kit.updates
import com.google.gson.JsonParser

class NoReleaseException : Exception()
data class AvailableUpdate(val version: String, val url: String, val notes: String)
object UpdateManifest {
    const val MAX_BYTES = 131072
    private fun version(value: String): List<Int> {
        require(Regex("[0-9]{1,5}\\.[0-9]{1,5}(\\.[0-9]{1,5})?").matches(value))
        val parts = value.split('.').map { it.toInt() }
        return if (parts.size == 2) parts + 0 else parts
    }
    fun parse(json: String, installed: String): AvailableUpdate? {
        require(json.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        val root = JsonParser.parseString(json).asJsonObject
        val item = root["android"]?.takeUnless { it.isJsonNull }?.asJsonObject ?: throw NoReleaseException()
        val next = item["version"].asString
        val parts = version(next)
        val current = version(installed)
        // Only this platform's official download route is allowed. In particular,
        // protocol-relative URLs, backslashes and encoded path tricks cannot change the origin.
        require(item["url"].asString == "/download/android")
        require(item["size"].asString.matches(Regex("[1-9][0-9]{0,14}")))
        require(item["sha256"].asString.matches(Regex("[0-9a-fA-F]{64}")))
        val notes = item["notes"]?.asString ?: ""
        require(notes.length <= 8000)
        val newer = parts.zip(current).firstOrNull { it.first != it.second }?.let { it.first > it.second } ?: false
        return if (newer) AvailableUpdate(next, "https://limlink.floatmax-tech.com/download/android", notes) else null
    }
}
