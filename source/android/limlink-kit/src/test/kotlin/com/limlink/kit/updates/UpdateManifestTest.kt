package com.limlink.kit.updates
import org.junit.Assert.*
import org.junit.Test
class UpdateManifestTest {
    private fun manifest(version: String="0.6.2", url: String="/download/android") =
        """{"android":{"version":"$version","url":"$url","size":12345,"sha256":"${"a".repeat(64)}"}}"""
    @Test fun newWebsiteSchemaOffersRelease() { assertEquals("https://limlink.floatmax-tech.com/download/android",UpdateManifest.parse(manifest(),"0.6.1")?.url) }
    @Test fun versionsCompareNumerically() {
        assertNull(UpdateManifest.parse(manifest("0.6.1"),"0.6.1"))
        assertNull(UpdateManifest.parse(manifest("0.6.0"),"0.6.1"))
        assertNotNull(UpdateManifest.parse(manifest("0.10.0"),"0.9.0"))
    }
    @Test fun firstReleaseTwoPartVersion() {
        assertNull(UpdateManifest.parse(manifest("1.0"),"1.0"))
        assertNull(UpdateManifest.parse(manifest("1.0.0"),"1.0"))
        assertNotNull(UpdateManifest.parse(manifest("1.0.1"),"1.0"))
        assertNotNull(UpdateManifest.parse(manifest("1.0"),"0.6.2"))
    }
    @Test fun emptyWebsiteHasNoRelease() { assertThrows(NoReleaseException::class.java) { UpdateManifest.parse("{}","0.6.1") } }
    @Test fun unsafeOrWrongChannelUrlsRejected() {
        listOf("//evil.example/file","https://evil.example/file","/download/android-cn","/download/../android","/download/android?device=123").forEach { url ->
            assertThrows(IllegalArgumentException::class.java) { UpdateManifest.parse(manifest(url=url),"0.6.1") }
        }
    }
    @Test fun malformedAndOversizedMetadataRejected() {
        assertThrows(IllegalArgumentException::class.java) { UpdateManifest.parse(manifest("oops"),"0.6.1") }
        assertThrows(IllegalArgumentException::class.java) { UpdateManifest.parse(" ".repeat(131073),"0.6.1") }
        assertThrows(IllegalArgumentException::class.java) { UpdateManifest.parse(manifest().replace("a".repeat(64),"bad"),"0.6.1") }
    }
}
