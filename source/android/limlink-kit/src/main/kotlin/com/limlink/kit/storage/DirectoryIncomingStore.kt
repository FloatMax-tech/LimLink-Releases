package com.limlink.kit.storage

import java.io.File
import java.util.UUID

/**
 * Filesystem stand-in for the pending-then-publish flow.
 * Unit tests use it. The app uses MediaStore or SAF on a device.
 */
class DirectoryIncomingStore(
    private val root: File,
) : IncomingStore {
    private val pendingDir = File(root, PENDING_DIR)

    override fun begin(desiredName: String, mimeType: String): PendingFile {
        root.mkdirs()
        pendingDir.mkdirs()
        val finalName = FileNames.resolveUnique(desiredName, publishedNames())
        val id = UUID.randomUUID().toString()
        val pending = File(pendingDir, id)
        check(pending.createNewFile()) { "could not create pending file" }
        return PendingFile(id = id, finalName = finalName, locator = pending.absolutePath)
    }

    override fun write(pending: PendingFile, bytes: ByteArray) {
        java.io.FileOutputStream(File(pending.locator), true).use { it.write(bytes); it.fd.sync() }
    }

    override fun publish(pending: PendingFile): PublishedFile {
        val source = File(pending.locator)
        check(source.isFile) { "pending file is missing" }
        // A hard link publishes the complete inode atomically and fails if the destination exists.
        // Both paths are in this store's filesystem. Never copy into a public final pathname.
        while (true) {
            val name = freeName(pending.finalName)
            val destination = File(root, name)
            try {
                java.nio.file.Files.createLink(destination.toPath(), source.toPath())
                source.delete()
                return PublishedFile(displayName = name, locator = destination.absolutePath)
            } catch (_: java.nio.file.FileAlreadyExistsException) { continue }
        }
    }

    override fun discard(pending: PendingFile) {
        File(pending.locator).delete()
    }

    private fun freeName(preferred: String): String {
        if (!File(root, preferred).exists()) return preferred
        return FileNames.resolveUnique(preferred, publishedNames())
    }

    private fun publishedNames(): List<String> {
        return root.listFiles()
            ?.filter { it.isFile }
            ?.map { it.name }
            .orEmpty()
    }

    companion object {
        const val PENDING_DIR = ".limlink-pending"
    }
}
