package com.limlink.kit.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileNamesTest {
    @Test
    fun leavesAFreeNameAlone() {
        assertEquals("photo.jpg", FileNames.resolveUnique("photo.jpg", emptyList()))
    }

    @Test
    fun insertsTheSuffixBeforeTheLastExtension() {
        assertEquals("a.tar (1).gz", FileNames.withCollisionSuffix("a.tar.gz", 1))
        assertEquals(
            "a.tar (1).gz",
            FileNames.resolveUnique("a.tar.gz", listOf("a.tar.gz")),
        )
    }

    @Test
    fun skipsTakenSuffixes() {
        val existing = listOf("notes.txt", "notes (1).txt", "notes (2).txt")
        assertEquals("notes (3).txt", FileNames.resolveUnique("notes.txt", existing))
    }

    @Test
    fun comparesNamesWithoutCase() {
        assertEquals(
            "photo (1).jpg",
            FileNames.resolveUnique("photo.jpg", listOf("Photo.JPG")),
        )
    }

    @Test
    fun comparesNamesAfterNfc() {
        val composed = "caf\u00e9.txt"
        val decomposed = "cafe\u0301.txt"
        assertEquals(
            "caf\u00e9 (1).txt",
            FileNames.resolveUnique(decomposed, listOf(composed)),
        )
    }

    @Test
    fun neverReturnsAnExistingName() {
        val existing = listOf("Readme", "README (1)")
        val resolved = FileNames.resolveUnique("readme", existing)
        val keys = existing.map { FileNames.normalizeKey(it) }.toSet()
        assertFalse(FileNames.normalizeKey(resolved) in keys)
        assertEquals("readme (2)", resolved)
    }

    @Test
    fun sanitizesPathCharactersAndReservedNames() {
        assertEquals("a_b.txt", FileNames.sanitize("a/b.txt"))
        assertEquals("CON_.txt", FileNames.sanitize("CON.txt"))
        assertEquals("aux_", FileNames.sanitize("aux"))
        assertEquals("file", FileNames.sanitize("   "))
        assertEquals("report", FileNames.sanitize("report."))
    }

    @Test
    fun resolvedNameHasNoIllegalCharacters() {
        val resolved = FileNames.resolveUnique("a/b:c?.txt", listOf("a_b_c_.txt"))
        assertEquals("a_b_c_ (1).txt", resolved)
        assertTrue(resolved.none { it in "<>:\"/\\|?*" })
    }
}
