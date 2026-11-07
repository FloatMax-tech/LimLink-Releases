package com.limlink.app.preview

import java.io.File
import java.io.InputStream

object PreviewCacheCopy {
    fun copy(open: () -> InputStream, destination: File, limit: Long, checkActive: () -> Unit) {
        try {
            open().use { input -> destination.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var count = 0L
                while (true) {
                    checkActive()
                    val n = input.read(buffer)
                    checkActive()
                    if (n < 0) break
                    count += n; check(count <= limit)
                    output.write(buffer, 0, n)
                }
            } }
        } catch (error: Exception) { destination.delete(); throw error }
    }
}
