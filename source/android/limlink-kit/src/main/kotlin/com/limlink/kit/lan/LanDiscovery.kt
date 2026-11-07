package com.limlink.kit.lan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.io.Closeable
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

/** [deviceType] is the advertised `dt` TXT value (iphone, ipad, mac, windows, android) and only drives icons. */
data class Peer(val id: String, val name: String, val address: InetAddress, val port: Int, val fingerprint: String, val deviceType: String = "device")

@Suppress("DEPRECATION")
class LanDiscovery(context: Context, private val ownFingerprint: String, private val changed: (List<Peer>) -> Unit, private val failed: () -> Unit) : Closeable {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val multicast = context.applicationContext.getSystemService(WifiManager::class.java).createMulticastLock("limlink-discovery").apply { setReferenceCounted(false) }
    private val peers = ConcurrentHashMap<String, Peer>()
    private val present = ConcurrentHashMap.newKeySet<String>()
    private val queue = java.util.ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var registration: NsdManager.RegistrationListener? = null
    @Volatile private var closed = false
    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) = Unit
        override fun onDiscoveryStopped(type: String) = Unit
        override fun onStartDiscoveryFailed(type: String, code: Int) { failed() }
        override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
        override fun onServiceFound(info: NsdServiceInfo) {
            if (closed || info.serviceType.trimEnd('.') != TYPE.trimEnd('.')) return
            present.add(info.serviceName)
            synchronized(queue) { queue.add(info); resolveNext() }
        }
        override fun onServiceLost(info: NsdServiceInfo) { present.remove(info.serviceName); peers.remove(info.serviceName); emit() }
    }
    fun start(name: String, port: Int) {
        multicast.acquire()
        advertise(name, port)
        nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }
    fun advertise(name: String, port: Int) {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { failed() }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }
        registration = listener
        val info = NsdServiceInfo().apply {
            serviceName = serviceLabel(name); serviceType = TYPE; setPort(port)
            setAttribute("pv", "1.0"); setAttribute("fp", ownFingerprint); setAttribute("dt", "android"); setAttribute("app", "limlink"); setAttribute("caps", "binding-v1")
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }
    private fun resolveNext() {
        if (closed || resolving || queue.isEmpty()) return
        resolving = true
        val info = queue.removeFirst()
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(service: NsdServiceInfo, code: Int) = done()
            override fun onServiceResolved(service: NsdServiceInfo) {
                val attributes = service.attributes.mapValues { String(it.value, Charsets.UTF_8) }
                val fp = attributes["fp"].orEmpty(); val address = service.host
                if (!closed && present.contains(service.serviceName) && attributes["app"] == "limlink" &&
                    attributes["pv"]?.split(',')?.any { it == "1" || it == "1.0" } == true &&
                    Fingerprints.valid(fp) && fp != ownFingerprint && address != null && !address.isLoopbackAddress && service.port in 1..65535) {
                    peers[service.serviceName] = Peer(service.serviceName, service.serviceName, address, service.port, fp, attributes["dt"]?.lowercase() ?: "device"); emit()
                }
                done()
            }
            private fun done() { synchronized(queue) { resolving = false; resolveNext() } }
        })
    }
    private fun serviceLabel(name: String): String {
        val label = StringBuilder()
        for (point in name.codePoints().toArray()) {
            val next = String(Character.toChars(point))
            if ((label.toString() + next).toByteArray(Charsets.UTF_8).size > 63) break
            label.append(next)
        }
        return label.toString().ifBlank { "LimLink" }
    }
    private fun emit() = changed(peers.values.distinctBy { it.fingerprint }.sortedBy { it.name })
    override fun close() {
        closed = true
        registration?.let { runCatching { nsd.unregisterService(it) } }
        runCatching { nsd.stopServiceDiscovery(discovery) }
        if (multicast.isHeld) multicast.release()
        peers.clear(); present.clear(); emit()
    }
    companion object { const val TYPE = "_limlink._tcp." }
}
