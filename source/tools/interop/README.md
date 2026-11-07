# Independent LAN protocol checks

These are development fixtures, not application discovery, trust, or automatic receive settings. They do not enable remote links. The production clients still ask the receiver to accept each file.

`lan-single-file-v1.json` describes the common one-file wire contract. Size limits are 5,000,000,000 bytes per file and 1,048,576 bytes per PUT; offsets must stay 64-bit. A session stays on one mutually authenticated TLS 1.3 connection. Sender names come from that connection's hello. Bonjour TXT uses `pv=1.0`, `fp`, `dt`, `app`.

Clients allow a separate 30-minute wait for final verification and publication (`POST .../files/.../complete`), since a 5 GB copy into an external volume or document provider can take longer than the ordinary 120-second request budget. User cancellation remains available. A completed transfer is reported only after successful publication.

## Python sender

Use Python 3.9+ with **TLS 1.3 support** (OpenSSL). Apple's bundled Python may use an older LibreSSL without TLS 1.3. This probe generates an ephemeral P-256 certificate with a **named curve**; LibreSSL's default explicit EC parameters are incompatible with Apple's TLS stack.

```sh
python3 lan_probe.py --host 127.0.0.1 --port PORT --fingerprint SPKI_BASE64URL --file /path/to/file --name 'Protocol verification'
```

The supplied pin is checked before any application request. Response length, chunk ACK, final name, byte count and final digest result are checked. Reconnection is forbidden. For a production receiver, accept the request on its screen; for automated checks, use the explicitly consenting fixture below.

## Apple SDK receiver fixture

```sh
swift build --package-path apple-peer --scratch-path /tmp/limlink-interop-apple-build
# Locate the resulting LimLinkInteropPeer executable in the build output.
python3 check_apple_peer.py --peer /absolute/path/to/LimLinkInteropPeer
```

The fixture binds loopback only, creates and removes a temporary Keychain identity, and requires `--fixture-decision accept|reject`. The runner checks 32 MiB + 17 bytes, an empty file, and rejection without publication. Accepted destination files are independently hashed and compared with the source.

For Kotlin receiver/sender fixtures, see `android/README.md` and the test-only `JvmInteropHost` / `JvmInteropSender`. For .NET, use the explicit `--ephemeral-probe` harness mode in `windows/README.md`. .NET on this macOS host cannot negotiate TLS 1.3; Windows live TLS tests must run on Windows, without lowering protocol requirements.

A passing loopback test proves the tested protocol/storage path. It does not prove physical-device discovery, AndroidKeyStore, Windows DPAPI, local network permissions, or 5 GB device-to-device performance.
