#!/usr/bin/env python3
"""Independent loopback mTLS binding/auto-receive check, never a device acceptance test."""
import argparse
import hashlib
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import time
from types import SimpleNamespace
import uuid

from lan_probe import PinnedConnection, json_request, make_identity, request, require, send


def connection(endpoint, identity):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # Full observed SPKI pin is verified before requests.
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["http/1.1"])
    context.load_cert_chain(str(identity[0]), str(identity[1]))
    return PinnedConnection("127.0.0.1", endpoint["port"], context, endpoint["fingerprint"])


def pair(endpoint, identity, accepted):
    client = connection(endpoint, identity)
    try:
        status, started = json_request(client, "POST", "/pair/start", {
            "version": 1, "requestId": str(uuid.uuid4()), "alias": "Python binding fixture", "deviceType": "mac",
        })
        require(status == 202 and started.get("state") == "pending", f"Binding start failed: {started}")
        identifier, token = started["pairId"], started["token"]
        require(str(uuid.UUID(identifier)) == identifier and len(token) == 43, "Malformed binding response")
        # An invalid token must never disclose/advance a pending handshake.
        status, denied = request(client, "GET", "/pair/" + identifier,
                                 headers={"X-LimLink-Pair-Token": "A" * 43 if token != "A" * 43 else "B" * 43})
        require(status == 403 and denied.get("code") == "E_PAIR_TOKEN_INVALID", "Wrong token was accepted")
        time.sleep(1)
        status, state = request(client, "GET", "/pair/" + identifier,
                                headers={"X-LimLink-Pair-Token": token})
        require(status == 200 and state.get("pairId") == identifier, "Binding poll failed")
        require(state.get("state") == ("accepted" if accepted else "rejected"), f"Consent state wrong: {state}")
        status, complete = request(client, "POST", f"/pair/{identifier}/complete", b"{}", {
            "X-LimLink-Pair-Token": token, "Content-Type": "application/json",
        })
        if accepted:
            require(status == 200 and complete.get("state") == "completed", f"Completion failed: {complete}")
        else:
            require(status != 200 and complete.get("code") == "E_PAIR_NOT_ACCEPTED", "Rejected request completed")
        return identifier
    finally:
        client.close()


def transfer(endpoint, identity, root, binding_id, accepted, name):
    source = root / name
    source.write_bytes(bytes(range(256)) * 4096 + b"binding integrity fixture")
    args = SimpleNamespace(file=source, host="127.0.0.1", port=endpoint["port"],
                           fingerprint=endpoint["fingerprint"], name="Python binding fixture", binding_id=binding_id)
    try:
        result = send(args, *identity)
    except RuntimeError as error:
        require(not accepted and "E_REJECTED" in str(error), f"Unexpected receive failure: {error}")
        require(not (root / "inbox" / name).exists(), "Rejected file was published")
        return
    require(accepted, "Unbound/revoked relationship bypassed receive confirmation")
    destination = root / "inbox" / result["finalName"]
    require(destination.stat().st_size == source.stat().st_size, "Saved length differs")
    require(hashlib.sha256(destination.read_bytes()).digest() == hashlib.sha256(source.read_bytes()).digest(),
            "Saved bytes differ")


def check(peer_path, decision):
    with tempfile.TemporaryDirectory(prefix="limlink-binding-interop-") as folder:
        root = Path(folder)
        identity = make_identity(root)
        ready, stop, inbox = root / "ready.json", root / "stop", root / "inbox"
        connections = 5 if decision == "accept" else 2
        with (root / "peer.log").open("w+") as log:
            peer = subprocess.Popen([str(peer_path), "--ready-file", str(ready), "--inbox", str(inbox),
                                     "--fixture-decision", "reject", "--fixture-binding-decision", decision,
                                     "--connections", str(connections), "--stop-file", str(stop)],
                                    stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while not ready.exists():
                    if peer.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Fixture did not start: " + log.read())
                    time.sleep(0.1)
                endpoint = json.loads(ready.read_text())
                identifier = pair(endpoint, identity, decision == "accept")
                if decision == "accept":
                    transfer(endpoint, identity, root, identifier, True, "bound.bin")
                    transfer(endpoint, identity, root, None, False, "unbound.bin")
                    client = connection(endpoint, identity)
                    try:
                        status, state = json_request(client, "POST", f"/pair/{identifier}/revoke", {})
                        require(status == 200 and state.get("state") == "revoked", "Revoke failed")
                    finally:
                        client.close()
                    transfer(endpoint, identity, root, identifier, False, "revoked.bin")
                else:
                    transfer(endpoint, identity, root, identifier, False, "rejected-binding.bin")
                peer.wait(timeout=15)
                require(peer.returncode == 0, "Fixture exited unsuccessfully")
                print(json.dumps({"event": "binding_fixture_passed", "direction": "Python -> Swift",
                                  "consent": decision, "tlsConnections": connections,
                                  "checks": "token,recipient-consent,hello-authorization,bytes,unbind"}), flush=True)
            except Exception:
                log.seek(0)
                print(log.read(), flush=True)
                raise
            finally:
                # Let the fixture stop normally so its ephemeral Keychain identity is removed.
                stop.touch()
                if peer.poll() is None:
                    try:
                        peer.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        peer.terminate()
                        peer.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer", type=Path, required=True)
    args = parser.parse_args()
    if not ssl.HAS_TLSv1_3:
        parser.error("Python with TLS1.3/OpenSSL required")
    for decision in ("accept", "reject"):
        check(args.peer.resolve(), decision)


if __name__ == "__main__":
    main()
