package com.limlink.app.preview

/** Recovery enrollment is separate from durable published-asset references. */
class PhotoAttemptJournal(
    private val read: () -> Map<String, *>,
    private val write: (String, String?) -> Boolean,
) {
    companion object { const val PREFIX = "attempt:" }
    fun enrolled(): Map<String, String> = read().mapNotNull { (key, value) ->
        if (key.startsWith(PREFIX) && value is String) key.removePrefix(PREFIX) to value else null
    }.toMap()
    fun enroll(key: String, metadata: String) { check(write(PREFIX + key, metadata)) }
    /** Never removes the separate key -> published Gallery URI, or touches the media asset. */
    fun forget(key: String) { check(write(PREFIX + key, null)) }
}
