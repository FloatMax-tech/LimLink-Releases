package com.limlink.app.preview

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class PreviewCacheCopyTest {
    @Test fun cancellationStopsTheStreamAndDeletesOnlyUnfinishedCopy() {
        val root = Files.createTempDirectory("limlink-copy").toFile()
        try {
            val original = File(root, "original").apply { writeBytes(ByteArray(256 * 1024)) }
            val copy = File(root, "copy")
            var checks = 0
            assertThrows(CancellationException::class.java) {
                PreviewCacheCopy.copy(original::inputStream, copy, 512L * 1024 * 1024) {
                    if (++checks > 2) throw CancellationException()
                }
            }
            assertFalse(copy.exists())
            assertTrue(original.exists())
            assertTrue(checks <= 4)
        } finally { root.deleteRecursively() }
    }
}
