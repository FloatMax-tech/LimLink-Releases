#!/usr/bin/env python3
"""Run independent Python -> Apple SDK fixtures; requires Python with TLS 1.3."""
import argparse
import hashlib
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import time


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1048576):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer", type=Path, required=True)
    args = parser.parse_args()
    if not ssl.HAS_TLSv1_3:
        parser.error("Use a Python runtime built with OpenSSL supporting TLS 1.3")
    for size, decision in [(32 * 1048576 + 17, "accept"), (0, "accept"), (1024, "reject")]:
        with tempfile.TemporaryDirectory(prefix="limlink-interop-check-") as directory:
            root = Path(directory)
            source, ready, inbox = root / "跨端测试.bin", root / "ready.json", root / "inbox"
            with source.open("wb") as stream:
                remaining = size
                block = bytes(range(256)) * 4096
                while remaining:
                    count = min(remaining, len(block))
                    stream.write(block[:count])
                    remaining -= count
            with (root / "peer.log").open("w+") as log:
                peer = subprocess.Popen([str(args.peer), "--ready-file", str(ready), "--inbox",
                                         str(inbox), "--fixture-decision", decision], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 30
                    while not ready.exists():
                        if peer.poll() is not None or time.monotonic() >= deadline:
                            log.seek(0)
                            raise RuntimeError("Peer did not start: " + log.read())
                        time.sleep(0.1)
                    endpoint = json.loads(ready.read_text())
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name("lan_probe.py")),
                                             "--port", str(endpoint["port"]), "--fingerprint", endpoint["fingerprint"],
                                             "--file", str(source), "--name", "Python独立协议验证"],
                                            capture_output=True, text=True, timeout=180)
                    if decision == "accept" and result.returncode:
                        log.seek(0)
                        raise RuntimeError(result.stdout + result.stderr + log.read())
                    peer.wait(timeout=15)
                    log.seek(0)
                    peer_output = log.read()
                    if peer.returncode:
                        raise RuntimeError(peer_output)
                    if decision == "accept":
                        if result.returncode:
                            raise RuntimeError(result.stderr + peer_output)
                        saved = inbox / source.name
                        if saved.stat().st_size != size or digest(saved) != digest(source):
                            raise RuntimeError("Saved file does not match source")
                    elif result.returncode == 0 or "E_REJECTED" not in result.stderr or list(inbox.iterdir()):
                        raise RuntimeError("Rejection did not prevent publication: " + result.stdout + result.stderr + peer_output)
                    print(json.dumps({"event": "fixture_passed", "direction": "Python -> Swift",
                                      "bytes": size, "decision": decision}, ensure_ascii=False), flush=True)
                    if result.returncode == 0:
                        print(result.stdout.strip(), flush=True)
                finally:
                    if peer.poll() is None:
                        peer.terminate()
                        peer.wait(timeout=15)


if __name__ == "__main__":
    main()
