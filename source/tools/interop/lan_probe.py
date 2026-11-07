#!/usr/bin/env python3
"""Independent, bounded-memory TLS sender for LimLink implementation verification.

This development probe has no device discovery or production auto-trust behavior.
Supply the receiver's observed SPKI fingerprint and explicitly accept its offer.
"""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import time
import uuid

MAX_FILE = 5_000_000_000
CHUNK = 1_048_576
PREFIX = "/limlink/v1"


def spki_fingerprint(certificate_der):
    pem = subprocess.run(["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"],
                         input=certificate_der, capture_output=True, check=True).stdout
    spki = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"],
                          input=pem, capture_output=True, check=True).stdout
    return base64.urlsafe_b64encode(hashlib.sha256(spki).digest()).decode().rstrip("=")


def make_identity(directory):
    key, cert = directory / "key.pem", directory / "cert.pem"
    subprocess.run(["openssl", "req", "-new", "-x509", "-newkey", "ec", "-pkeyopt",
                    "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve",
                    "-nodes", "-subj", "/CN=limlink", "-days", "1",
                    "-keyout", str(key), "-out", str(cert)], capture_output=True, check=True)
    os.chmod(key, 0o600)
    return cert, key


class PinnedConnection(http.client.HTTPSConnection):
    def __init__(self, host, port, context, fingerprint):
        super().__init__(host, port, context=context, timeout=120)
        self.fingerprint = fingerprint
        self.connection_count = 0

    def connect(self):
        if self.connection_count:
            raise RuntimeError("Peer closed the transfer connection; reconnection is not permitted")
        super().connect()
        self.connection_count += 1
        if self.sock.version() != "TLSv1.3":
            raise RuntimeError("TLS 1.3 required")
        if spki_fingerprint(self.sock.getpeercert(binary_form=True)) != self.fingerprint:
            self.close()
            raise RuntimeError("Peer certificate does not match the selected fingerprint")


def request(connection, method, path, body=b"", headers=None):
    # Final disk publication can outlast ordinary requests on a slow destination.
    if connection.sock is not None:
        connection.sock.settimeout(1800 if method == "POST" and path.endswith("/complete") else 120)
    fields = {"X-LimLink-App": "limlink", "Content-Length": str(len(body))}
    fields.update(headers or {})
    connection.request(method, PREFIX + path, body=body, headers=fields)
    response = connection.getresponse()
    if response.getheader("Transfer-Encoding"):
        raise RuntimeError("Unexpected chunked response; LimLink uses Content-Length")
    length = response.getheader("Content-Length")
    if length is None or not length.isascii() or not length.isdigit() or int(length) > 65536:
        raise RuntimeError("Invalid or unbounded response Content-Length")
    payload = response.read(65537)
    if len(payload) != int(length):
        raise RuntimeError("Truncated response")
    value = json.loads(payload)
    if not isinstance(value, dict):
        raise RuntimeError("Response must be an object")
    return response.status, value


def json_request(connection, method, path, value=None):
    body = b"" if value is None else json.dumps(value, ensure_ascii=False).encode()
    return request(connection, method, path, body, {"Content-Type": "application/json"})


def require(condition, description):
    if not condition:
        raise RuntimeError(description)


def send(args, certificate, key):
    size = args.file.stat().st_size
    require(args.file.is_file() and 0 <= size <= MAX_FILE, "Expected a regular file no larger than 5 GB")
    digest = hashlib.sha256()
    with args.file.open("rb") as source:
        while block := source.read(CHUNK):
            digest.update(block)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # Explicit SPKI pin is checked before any application request.
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["http/1.1"])
    context.load_cert_chain(str(certificate), str(key))
    connection = PinnedConnection(args.host, args.port, context, args.fingerprint)
    started = time.monotonic()
    try:
        hello_body = {
            "proto": ["1.0"], "app": "limlink", "alias": args.name, "devType": "mac", "port": 52470,
        }
        if getattr(args, "binding_id", None) is not None:
            hello_body["bindingId"] = args.binding_id
        status, hello = json_request(connection, "POST", "/hello", hello_body)
        require(status == 200 and hello.get("app", "limlink") == "limlink", f"Hello rejected: {hello}")
        file_id = uuid.uuid4().hex
        status, created = json_request(connection, "POST", "/sessions", {
            "clientSessionKey": uuid.uuid4().hex, "transport": "lan", "totalEntries": 1,
            "totalBytes": size, "entries": [{"id": file_id, "kind": "file",
                                            "relativePath": args.file.name, "size": size}],
        })
        require(status == 202 and isinstance(created.get("sessionId"), str), f"Create rejected: {created}")
        session = created["sessionId"]
        print(json.dumps({"event": "awaiting_consent", "sender": args.name, "file": args.file.name,
                          "size": size, "sessionId": session}), flush=True)
        deadline = time.monotonic() + 120
        while True:
            require(time.monotonic() < deadline, "Receive confirmation timed out")
            status, approved = request(connection, "GET", f"/sessions/{session}?wait=25")
            if status != 202:
                break
            time.sleep(0.1)
        require(status == 200 and approved.get("state") == "accepted", f"Not accepted: {approved}")
        offered = approved.get("files", {}).get(file_id, {})
        token = offered.get("token")
        require(isinstance(token, str) and token and offered.get("offset") == 0, "Invalid token/initial offset")
        offset, puts = 0, 0
        with args.file.open("rb") as source:
            while offset < size or puts == 0:
                block = source.read(min(CHUNK, size - offset))
                require(bool(block) or size == 0, "Source truncated during transfer")
                status, ack = request(connection, "PUT", f"/sessions/{session}/files/{file_id}", block, {
                    "Content-Type": "application/octet-stream", "X-LimLink-Token": token,
                    "X-LimLink-Offset": str(offset),
                })
                offset += len(block)
                puts += 1
                require(status == 200 and type(ack.get("committedBytes")) is int
                        and ack["committedBytes"] == offset, f"Incorrect chunk ACK: {ack}")
        status, completed = json_request(connection, "POST", f"/sessions/{session}/files/{file_id}/complete",
                                         {"sha256": digest.hexdigest()})
        require(status == 200 and completed.get("verified") is True
                and isinstance(completed.get("finalName"), str), f"Completion failed: {completed}")
        status, report = json_request(connection, "POST", f"/sessions/{session}/finish")
        files = report.get("files", [])
        require(status == 200 and report.get("sessionId") == session and report.get("state") == "finished"
                and len(files) == 1, f"Invalid final report: {report}")
        entry = files[0]
        require(entry.get("id") == file_id and entry.get("state") == "completed"
                and type(entry.get("size")) is int and entry["size"] == size
                and type(entry.get("bytesReceived")) is int and entry["bytesReceived"] == size
                and entry.get("sha256Match") is True and entry.get("finalName") == completed["finalName"],
                f"Final report does not match the sent file: {entry}")
        result = {"event": "passed", "bytes": offset, "puts": puts, "maximumChunk": CHUNK,
                  "sha256": digest.hexdigest(), "finalName": entry["finalName"],
                  "tlsConnections": connection.connection_count, "seconds": round(time.monotonic() - started, 3)}
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return result
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--name", default="Interop Python sender")
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--key", type=Path)
    args = parser.parse_args()
    parser.error("--certificate and --key must be supplied together") if bool(args.certificate) != bool(args.key) else None
    with tempfile.TemporaryDirectory(prefix="limlink-probe-identity-") as directory:
        certificate, key = (args.certificate, args.key) if args.certificate else make_identity(Path(directory))
        send(args, certificate, key)


if __name__ == "__main__":
    main()
