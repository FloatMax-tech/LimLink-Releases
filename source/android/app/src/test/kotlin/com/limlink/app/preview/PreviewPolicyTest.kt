package com.limlink.app.preview

import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class PreviewPolicyTest {
    @Test fun originalNameClassifiesSnapshotsWithoutTheirPartExtension() {
        assertEquals(PreviewKind.IMAGE, PreviewPolicy.kind("旅行.HEIC", "application/octet-stream"))
        assertEquals(PreviewKind.PDF, PreviewPolicy.kind("report.pdf", null))
        assertEquals(PreviewKind.VIDEO, PreviewPolicy.kind("movie.mp4", null))
        assertEquals(PreviewKind.AUDIO, PreviewPolicy.kind("voice.m4a", null))
        assertEquals(PreviewKind.TEXT, PreviewPolicy.kind("notes.md", null))
    }

    @Test fun officeAndExecutablesNeverBecomeNativePreviewsFromSpoofedMime() {
        assertEquals(PreviewKind.UNSUPPORTED, PreviewPolicy.kind("budget.xlsx", "text/plain"))
        assertEquals(PreviewKind.UNSUPPORTED, PreviewPolicy.kind("run.apk", "image/png"))
        assertEquals(PreviewKind.UNSUPPORTED, PreviewPolicy.kind("run.exe", "video/mp4"))
    }

    @Test fun textReadIsBoundedAndReportsTruncation() {
        val input = ByteArrayInputStream("123456789".toByteArray())
        val result = PreviewPolicy.readText(input, 5)
        assertEquals("12345", result.text)
        assertTrue(result.truncated)
        assertEquals(3, input.available()) // Reads only the limit plus one sentinel byte.
    }

    @Test fun utf16BomIsDecodedAndBinaryIsRejected() {
        assertEquals("你好", PreviewPolicy.readText(ByteArrayInputStream(byteArrayOf(-1, -2) + "你好".toByteArray(Charsets.UTF_16LE))).text)
        assertThrows(IllegalArgumentException::class.java) {
            PreviewPolicy.readText(ByteArrayInputStream(byteArrayOf(1, 0, 2, 0)))
        }
    }

    @Test fun remoteAndExpiredLocatorsAreRejected() {
        assertFalse(PreviewPolicy.localLocator("https://example.com/document.pdf"))
        assertFalse(PreviewPolicy.localLocator("content:///missing-authority"))
        assertTrue(PreviewPolicy.localLocator("content://downloads/document/42"))
        val missing = File(System.getProperty("java.io.tmpdir"), "limlink-missing-${System.nanoTime()}")
        assertFalse(PreviewPolicy.fileAvailable(missing.absolutePath))
    }

    @Test fun renderingBoundsPreserveAspectAndCapPixels() {
        val (width, height) = PreviewPolicy.renderSize(50_000, 40_000)
        assertTrue(width <= 2048 && height <= 2048)
        assertTrue(width.toLong() * height <= 4_194_304)
        assertEquals(1.25, width.toDouble() / height, 0.01)
    }

    @Test fun unnamedReceivedImagesCanBeRecognizedWithoutTrustingOctetStream() {
        assertEquals("image/png", PreviewPolicy.sniff(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)))
        assertEquals("application/pdf", PreviewPolicy.sniff("%PDF-1.7".toByteArray()))
        assertNull(PreviewPolicy.sniff("not an image".toByteArray()))
        assertEquals(PreviewKind.UNSUPPORTED, PreviewPolicy.kind("payload.exe", PreviewPolicy.sniff(byteArrayOf(-1, -40, -1))))
    }
}
