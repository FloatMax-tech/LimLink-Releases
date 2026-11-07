package com.limlink.kit.lan

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class WireTest {
    @Test fun onlyFileCompletionGetsTheBoundedPublicationBudget() {
        val complete = "${Limits.PREFIX}/sessions/session-1/files/file_1/complete"
        assertEquals(1_800_000, Limits.requestTimeoutMillis("POST", complete))
        for ((method, path) in listOf("GET" to complete, "PUT" to complete, "POST" to "$complete/other",
            "POST" to "${Limits.PREFIX}/sessions/session-1/finish", "GET" to "${Limits.PREFIX}/sessions/session-1?wait=25",
            "PUT" to "${Limits.PREFIX}/sessions/session-1/files/file_1", "POST" to "${Limits.PREFIX}/hello")) {
            assertEquals(120_000, Limits.requestTimeoutMillis(method, path))
        }
    }
    @Test fun rejectsAmbiguousAndOversizedHttpFrames() {
        for (headers in listOf("Content-Length: 0\r\nContent-Length: 0", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 1048577")) {
            assertThrows(Exception::class.java) { Wire.read(ByteArrayInputStream("PUT / HTTP/1.1\r\n$headers\r\n\r\n".toByteArray())) }
        }
        assertThrows(Exception::class.java) { Wire.read(ByteArrayInputStream("PUT / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx".toByteArray())) }
    }
    @Test fun exactNumbersDoNotRoundOrCoerce() {
        assertEquals(5_000_000_000L, Json.long(Json.parse("{\"size\":5000000000}".toByteArray()), "size"))
        for (token in listOf("true", "\"1\"", "1.0000000000000000001", "5000000000.1", "9223372036854775808")) {
            assertThrows(Exception::class.java) { Json.long(Json.parse("{\"size\":$token}".toByteArray()), "size") }
        }
    }
    @Test fun validatesSingleFileBoundaryAndPaths() {
        assertEquals(5_000_000_000L, Limits.size(5_000_000_000L))
        for (size in listOf(-1L, 5_000_000_001L)) assertThrows(Exception::class.java) { Limits.size(size) }
        for (name in listOf("../x", "a/b", "a\\b", ".", "..", "x\u0000", "")) assertThrows(Exception::class.java) { Limits.name(name) }
    }
    @Test fun validatesCanonicalFingerprints() {
        assertTrue(Fingerprints.valid("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        assertFalse(Fingerprints.valid("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"))
        assertFalse(Fingerprints.valid("not-a-fingerprint"))
    }
}
