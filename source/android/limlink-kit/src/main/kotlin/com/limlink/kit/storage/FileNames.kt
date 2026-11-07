package com.limlink.kit.storage

import java.text.Normalizer

/**
 * Display-name rules shared by every save backend.
 * Collisions become "name (1).ext" and never overwrite.
 */
object FileNames {
    private val illegal = Regex("""[<>:"/\\|?*\u0000-\u001F]""")
    private val reserved = Regex(
        """^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)""",
        RegexOption.IGNORE_CASE,
    )

    fun sanitize(raw: String): String {
        var name = illegal.replace(raw, "_").trim().trimEnd('.', ' ')
        if (name.isEmpty() || name == "." || name == "..") {
            name = "file"
        }
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        val stemReserved = reserved.matches(stem)
        val wholeReserved = reserved.matches(name)
        if (stemReserved || wholeReserved) {
            name = if (dot > 0) "${stem}_$extension" else "${name}_"
        }
        return name
    }

    fun normalizeKey(name: String): String {
        return Normalizer.normalize(name, Normalizer.Form.NFC).lowercase()
    }

    fun withCollisionSuffix(name: String, index: Int): String {
        require(index >= 1) { "suffix index starts at 1" }
        val (base, extension) = splitExtension(name)
        return "$base ($index)$extension"
    }

    fun resolveUnique(desired: String, existing: Collection<String>): String {
        val cleaned = Normalizer.normalize(sanitize(desired), Normalizer.Form.NFC)
        val taken = existing.mapTo(HashSet()) { normalizeKey(it) }
        if (normalizeKey(cleaned) !in taken) return cleaned
        var index = 1
        while (index <= MAX_SUFFIX) {
            val candidate = withCollisionSuffix(cleaned, index)
            if (normalizeKey(candidate) !in taken) return candidate
            index++
        }
        error("No free name for $cleaned")
    }

    private fun splitExtension(name: String): Pair<String, String> {
        val dot = name.lastIndexOf('.')
        if (dot <= 0) return name to ""
        return name.substring(0, dot) to name.substring(dot)
    }

    private const val MAX_SUFFIX = 10_000
}
