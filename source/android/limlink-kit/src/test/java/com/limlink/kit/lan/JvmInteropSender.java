package com.limlink.kit.lan;

import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.security.KeyStore;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.HashMap;
import java.util.Map;
import javax.net.ssl.*;
import kotlin.Unit;

/** Test-only transport adapter around the real Kotlin FileSender. Never compiled into the APK. */
public final class JvmInteropSender {
    public static void main(String[] args) throws Exception {
        if (args.length != 5) throw new IllegalArgumentException("p12, host, port, fingerprint, source file");
        String pin = args[3];
        if (!Fingerprints.INSTANCE.valid(pin)) throw new IllegalArgumentException("Invalid fingerprint");
        KeyStore keys = KeyStore.getInstance("PKCS12");
        try (InputStream input = Files.newInputStream(new File(args[0]).toPath())) { keys.load(input, "limlink-test".toCharArray()); }
        KeyManagerFactory managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        managers.init(keys, "limlink-test".toCharArray());
        X509TrustManager trust = new X509TrustManager() {
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                if (chain == null || chain.length == 0) throw new CertificateException("Missing certificate");
            }
            public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                checkClientTrusted(chain, authType);
                if (!Fingerprints.INSTANCE.of(chain[0]).equals(pin)) throw new CertificateException("Selected peer mismatch");
            }
        };
        SSLContext context = SSLContext.getInstance("TLSv1.3");
        context.init(managers.getKeyManagers(), new TrustManager[] { trust }, null);
        try (SSLSocket socket = (SSLSocket) context.getSocketFactory().createSocket()) {
            socket.setEnabledProtocols(new String[] { "TLSv1.3" });
            SSLParameters parameters = socket.getSSLParameters(); parameters.setApplicationProtocols(new String[] { "http/1.1" }); socket.setSSLParameters(parameters);
            socket.setSoTimeout(Limits.TIMEOUT_MS);
            socket.connect(new InetSocketAddress(args[1], Integer.parseInt(args[2])), 15000);
            socket.startHandshake();
            String alpn = socket.getApplicationProtocol();
            if (!socket.getSession().getProtocol().equals("TLSv1.3") || (alpn != null && !alpn.isEmpty() && !alpn.equals("http/1.1"))) throw new CertificateException("Unexpected protocol");
            if (!Fingerprints.INSTANCE.of((X509Certificate) socket.getSession().getPeerCertificates()[0]).equals(pin)) throw new CertificateException("Selected peer mismatch");
            InputStream input = new java.io.BufferedInputStream(socket.getInputStream());
            OutputStream output = new java.io.BufferedOutputStream(socket.getOutputStream());
            File source = new File(args[4]); File staging = Files.createTempDirectory("limlink-jvm-send-").toFile();
            try (Snapshot snapshot = Snapshot.Companion.capture(Files.newInputStream(source.toPath()), source.getName(), staging, () -> false)) {
                FileSender sender = new FileSender((method, path, body, headers) -> {
                    try { socket.setSoTimeout(Limits.INSTANCE.requestTimeoutMillis(method, path)); }
                    catch (java.net.SocketException error) { throw new IllegalStateException(error); }
                    Map<String, String> fields = new HashMap<>(); fields.put("host", args[1]); fields.put("x-limlink-app", "limlink"); fields.put("content-type", "application/json"); fields.putAll(headers);
                    Wire.INSTANCE.write(output, method + " " + path + " HTTP/1.1", body, fields);
                    return Wire.INSTANCE.read(input);
                });
                String name = sender.send(snapshot, "Android JVM sender", 52470, () -> false, ignored -> Unit.INSTANCE);
                System.out.println(new String(Json.INSTANCE.bytes(Map.of("finalName", name, "bytes", snapshot.getSize(), "sha256", snapshot.getSha256())), java.nio.charset.StandardCharsets.UTF_8));
            } finally { staging.delete(); }
        }
    }
}
