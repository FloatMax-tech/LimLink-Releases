package com.limlink.app.ui
import com.limlink.kit.updates.*
import java.net.URI
import javax.net.ssl.HttpsURLConnection
class UpdateRequest {
    @Volatile private var cancelled = false
    private var connection: HttpsURLConnection? = null
    @Synchronized fun attach(value: HttpsURLConnection) {
        ensureActive()
        connection = value
    }
    @Synchronized fun cancel() {
        cancelled = true
        connection?.disconnect()
    }
    fun ensureActive() {
        if (cancelled || Thread.currentThread().isInterrupted) throw java.util.concurrent.CancellationException()
    }
    @Synchronized fun detach() { connection = null }
}
object UpdateClient {
    const val ENDPOINT = "https://limlink.floatmax-tech.com/version.json"
    const val MAX_BYTES = UpdateManifest.MAX_BYTES
    // Call on Dispatchers.IO; no request is made until the user taps Check for updates.
    fun check(installed: String, request: UpdateRequest = UpdateRequest()): AvailableUpdate? {
        val started = System.nanoTime()
        fun remaining(): Int {
            request.ensureActive()
            val millis = 20000 - (System.nanoTime() - started) / 1000000
            if (millis <= 0) throw java.net.SocketTimeoutException()
            return millis.toInt()
        }
        val connection = URI(ENDPOINT).toURL().openConnection() as HttpsURLConnection
        try {
            request.attach(connection)
            connection.connectTimeout = minOf(10000, remaining())
            connection.readTimeout = remaining()
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("User-Agent", "LimLink/$installed (Android)")
            connection.connect()
            connection.readTimeout = remaining()
            if (connection.responseCode == 404) throw NoReleaseException()
            require(connection.responseCode == 200)
            require(connection.contentLengthLong <= MAX_BYTES)
            val bytes = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    connection.readTimeout = remaining()
                    val count = input.read(buffer)
                    if (count == -1) break
                    require(output.size() + count <= MAX_BYTES)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            remaining()
            return UpdateManifest.parse(bytes.toString(Charsets.UTF_8), installed)
        } finally { connection.disconnect(); request.detach() }
    }
}
