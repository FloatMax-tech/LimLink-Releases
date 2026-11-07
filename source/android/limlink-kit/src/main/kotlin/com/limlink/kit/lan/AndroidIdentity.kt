package com.limlink.kit.lan

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.SSLContext
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

/** Persistent, non-exportable device key. No CA trust or hostname dialog is used in LAN mode. */
class AndroidIdentity {
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    init {
        // v1 keys lacked DIGEST_NONE, so every TLS handshake failed with INCOMPATIBLE_DIGEST; key authorizations are fixed at creation.
        if (keyStore.containsAlias(LEGACY_ALIAS)) runCatching { keyStore.deleteEntry(LEGACY_ALIAS) }
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                // Conscrypt signs TLS handshakes with NONEwithECDSA over a pre-computed hash.
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(X500Principal("CN=LimLink Android"))
                .setCertificateSerialNumber(BigInteger(128, SecureRandom()).abs().add(BigInteger.ONE))
                .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000))
                .setCertificateNotAfter(Date(System.currentTimeMillis() + 20L * 365 * 86_400_000))
                .build())
            generator.generateKeyPair()
        }
    }
    val certificate: X509Certificate get() = keyStore.getCertificate(KEY_ALIAS) as X509Certificate
    val fingerprint: String get() = Fingerprints.of(certificate)

    fun context(expectedFingerprint: String? = null): SSLContext {
        if (expectedFingerprint != null) require(Fingerprints.valid(expectedFingerprint))
        val keyManager = object : X509ExtendedKeyManager() {
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = if (keyType == "EC") arrayOf(KEY_ALIAS) else null
            override fun chooseClientAlias(keyTypes: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? = if (keyTypes?.any { it == "EC" } == true) KEY_ALIAS else null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = getClientAliases(keyType, issuers)
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = if (keyType == "EC") KEY_ALIAS else null
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == KEY_ALIAS) arrayOf(certificate) else null
            override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == KEY_ALIAS) keyStore.getKey(KEY_ALIAS, null) as PrivateKey else null
        }
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            private fun verify(chain: Array<out X509Certificate>?) {
                val peer = chain?.firstOrNull() ?: throw CertificateException("Missing peer certificate")
                peer.checkValidity()
                if (expectedFingerprint != null && Fingerprints.of(peer) != expectedFingerprint) throw CertificateException("Selected device identity changed")
            }
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = verify(chain)
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = verify(chain)
        }
        return SSLContext.getInstance("TLSv1.3").apply { init(arrayOf(keyManager), arrayOf(trust), SecureRandom()) }
    }
    companion object {
        private const val KEY_ALIAS = "limlink-device-v2"
        private const val LEGACY_ALIAS = "limlink-device-v1"
    }
}
