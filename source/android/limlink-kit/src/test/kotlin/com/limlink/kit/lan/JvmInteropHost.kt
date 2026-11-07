package com.limlink.kit.lan

import com.limlink.kit.storage.DirectoryIncomingStore
import java.io.File
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.concurrent.CompletableFuture
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** Test-only JVM host. Explicitly auto-accepts; never included in the Android APK. */
object JvmInteropHost {
    @JvmStatic fun main(args: Array<String>) {
        require(args.size == 3) { "p12 file, destination directory, port JSON file" }
        val keys = KeyStore.getInstance("PKCS12").apply { File(args[0]).inputStream().use { load(it, "limlink-test".toCharArray()) } }
        val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, "limlink-test".toCharArray()) }
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers() = emptyArray<X509Certificate>()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) { require(!chain.isNullOrEmpty()) }
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) { require(!chain.isNullOrEmpty()) }
        }
        val context = SSLContext.getInstance("TLSv1.3").apply { init(managers.keyManagers, arrayOf(trust), null) }
        val server = (context.serverSocketFactory.createServerSocket(0, 8, java.net.InetAddress.getLoopbackAddress()) as SSLServerSocket).apply {
            enabledProtocols = arrayOf("TLSv1.3"); needClientAuth = true
            sslParameters = sslParameters.apply { applicationProtocols = arrayOf("http/1.1") }
        }
        val certificate = keys.getCertificate(keys.aliases().nextElement()) as X509Certificate
        val destination = File(args[1]).apply { mkdirs() }
        File(args[2]).writeText(String(Json.bytes(mapOf("port" to server.localPort, "fingerprint" to Fingerprints.of(certificate)))))
        println("JVM receiver listening on ${server.localPort}; test-only auto-accept")
        while (true) {
            val socket = server.accept() as SSLSocket
            Thread {
                socket.use {
                    try {
                        socket.soTimeout = Limits.TIMEOUT_MS; socket.startHandshake()
                        check(socket.applicationProtocol == "http/1.1")
                        ReceiverConnection(File(destination, ".staging"), { "Android JVM test" }, server.localPort,
                            { CompletableFuture.completedFuture(true) }, { DirectoryIncomingStore(destination) }).use { receiver ->
                            val input = socket.inputStream.buffered(); val output = socket.outputStream.buffered()
                            while (true) { val response = receiver.handle(Wire.read(input)); Wire.write(output, response.start, response.body, response.headers) }
                        }
                    } catch (_: java.io.EOFException) {} catch (error: Exception) { System.err.println(error.toString()) }
                }
            }.start()
        }
    }
}
