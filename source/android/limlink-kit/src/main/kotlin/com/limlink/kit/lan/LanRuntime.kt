package com.limlink.kit.lan

import java.io.Closeable
import java.io.File
import java.net.InetSocketAddress
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/** TLS transport, kept separate from the portable protocol for deterministic JVM tests. */
class LanRuntime(private val identity: AndroidIdentity, val binding: BindingService? = null, private val createReceiver: (Int, String) -> ReceiverConnection) : Closeable {
    private val server = (identity.context().serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
        enabledProtocols = arrayOf("TLSv1.3"); needClientAuth = true
        sslParameters = sslParameters.apply { applicationProtocols = arrayOf("http/1.1") }
    }
    val port: Int get() = server.localPort
    private val slots = Semaphore(4)
    private val workers = Executors.newFixedThreadPool(4)
    private val acceptor = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    // Binding ticks can wait on durable storage; control I/O needs an independent deadline.
    private val controlDeadlines = Executors.newSingleThreadScheduledExecutor()
    private val incoming = ConcurrentHashMap<SSLSocket, ReceiverConnection>()
    private val outgoing = ConcurrentHashMap.newKeySet<SSLSocket>()
    private val pairing = ConcurrentHashMap.newKeySet<SSLSocket>()
    @Volatile private var pairingOwner: Any? = null
    @Volatile private var closed = false
    fun start() {
        timer.scheduleAtFixedRate({ binding?.tick(); incoming.forEach { (socket, receiver) -> if (receiver.approvalExpired()) { runCatching { socket.close() }; receiver.close() } } }, 1, 1, TimeUnit.SECONDS)
        acceptor.execute {
            while (!closed) {
                val socket = try { server.accept() as SSLSocket } catch (_: Exception) { break }
                if (!slots.tryAcquire()) { socket.close(); continue }
                workers.execute {
                    var receiver: ReceiverConnection? = null
                    try {
                        socket.soTimeout = Limits.TIMEOUT_MS; socket.enabledProtocols = arrayOf("TLSv1.3"); socket.needClientAuth = true
                        socket.sslParameters = socket.sslParameters.apply { applicationProtocols = arrayOf("http/1.1") }
                        socket.startHandshake()
                        check(socket.session.protocol == "TLSv1.3" && socket.applicationProtocol in setOf(null, "", "http/1.1"))
                        check(Fingerprints.of(socket.session.peerCertificates.first() as X509Certificate) != identity.fingerprint)
                        receiver = createReceiver(port, Fingerprints.of(socket.session.peerCertificates.first() as X509Certificate)); incoming[socket] = receiver
                        val input = socket.inputStream.buffered(); val output = socket.outputStream.buffered()
                        while (!socket.isClosed) {
                            val request = Wire.read(input)
                            val response = receiver.handle(request)
                            Wire.write(output, response.start, response.body, response.headers)
                        }
                    } catch (_: Exception) {
                        // Closing the authenticated connection revokes all pending/session state.
                    } finally { incoming.remove(socket); receiver?.close(); runCatching { socket.close() }; slots.release() }
                }
            }
        }
    }
    fun send(peer: Peer, snapshot: Snapshot, alias: String, cancelled: () -> Boolean, progress: (Long) -> Unit): String {
        require(peer.fingerprint != identity.fingerprint)
        val socket = identity.context(peer.fingerprint).socketFactory.createSocket() as SSLSocket
        outgoing.add(socket)
        try {
            check(!cancelled())
            socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = Limits.TIMEOUT_MS
            socket.sslParameters = socket.sslParameters.apply { applicationProtocols = arrayOf("http/1.1") }
            socket.connect(InetSocketAddress(peer.address, peer.port), 15_000); socket.startHandshake()
            check(socket.session.protocol == "TLSv1.3" && socket.applicationProtocol in setOf(null, "", "http/1.1"))
            check(Fingerprints.of(socket.session.peerCertificates.first() as X509Certificate) == peer.fingerprint)
            val input = socket.inputStream.buffered(); val output = socket.outputStream.buffered()
            return FileSender(Exchange { method, path, body, headers ->
                socket.soTimeout = Limits.requestTimeoutMillis(method, path)
                Wire.write(output, "$method $path HTTP/1.1", body, mapOf("host" to peer.address.hostAddress.orEmpty(), "x-limlink-app" to "limlink", "content-type" to "application/json") + headers)
                Wire.read(input)
            }, binding?.store?.active(peer.fingerprint)?.bindingId).send(snapshot, alias, port, cancelled, progress)
        } finally { outgoing.remove(socket); runCatching { socket.close() } }
    }
    private fun <T> control(peer: Peer, action: (Exchange) -> T): T {
        require(!closed && peer.fingerprint != identity.fingerprint)
        val socket = identity.context(peer.fingerprint).socketFactory.createSocket() as SSLSocket
        pairing.add(socket)
        try {
            ControlSocketDeadline(socket, controlDeadlines).use {
                socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 15_000
                socket.sslParameters = socket.sslParameters.apply { applicationProtocols = arrayOf("http/1.1") }
                socket.connect(InetSocketAddress(peer.address, peer.port), 15_000); socket.startHandshake()
                check(!closed && socket.session.protocol == "TLSv1.3" && socket.applicationProtocol in setOf(null, "", "http/1.1"))
                check(Fingerprints.of(socket.session.peerCertificates.first() as X509Certificate) == peer.fingerprint)
                val input = socket.inputStream.buffered(); val output = socket.outputStream.buffered()
                return action(Exchange { method, path, body, headers ->
                    Wire.write(output, "$method $path HTTP/1.1", body, mapOf("host" to peer.address.hostAddress.orEmpty(), "x-limlink-app" to "limlink", "content-type" to "application/json") + headers)
                    Wire.read(input, 16_384)
                })
            }
        } finally { pairing.remove(socket); runCatching { socket.close() } }
    }
    fun bind(peer: Peer, alias: String, cancelled: () -> Boolean = { false }): DeviceBinding {
        val service = requireNotNull(binding); val owner = Any()
        service.beginOutgoing(owner, peer.fingerprint); pairingOwner = owner
        try { return control(peer) { BindingClient(service, it, peer.fingerprint).bind(owner, alias, cancelled) } }
        finally { service.finishOutgoing(owner); if (pairingOwner === owner) pairingOwner = null }
    }
    fun cancelPairing() {
        pairingOwner?.let { binding?.finishOutgoing(it) }; pairingOwner = null
        pairing.forEach { runCatching { it.close() } }
    }
    fun revoke(peer: Peer, bindingId: String) = control(peer) { exchange ->
        val result = exchange.request("POST", "${Limits.PREFIX}/pair/${BindingValidation.id(bindingId)}/revoke", Json.bytes(emptyMap<String, String>()), emptyMap())
        check(result.status == 200)
    }
    fun cancelTransfers() {
        outgoing.forEach { runCatching { it.close() } }
        cancelFileConnections(incoming)
    }
    override fun close() {
        closed = true; binding?.close(); cancelPairing(); runCatching { server.close() }; cancelTransfers(); incoming.keys.forEach { runCatching { it.close() } }
        timer.shutdownNow(); controlDeadlines.shutdownNow(); workers.shutdownNow(); acceptor.shutdownNow()
    }
}

/** A file action can close only connections already dispatched into the file protocol. */
internal fun cancelFileConnections(connections: Map<out Closeable, ReceiverConnection>) {
    connections.forEach { (socket, receiver) -> if (receiver.fileConnection) { runCatching { socket.close() }; receiver.close() } }
}
