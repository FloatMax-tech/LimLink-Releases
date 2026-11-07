#!/usr/bin/env python3
"""Independent LimLink / CPace reference (libsodium ristretto255, not pakery).

Regenerates and checks core/vectors/limlink-core-vectors-v1.json.
CPace scalar sampling matches pakery-cpace 0.6.0: 64 little-endian bytes
reduced mod the ristretto255 order (libsodium crypto_core_ristretto255_scalar_reduce).
Draft appendix B.3 scalars are reproduced by appending 32 zero bytes.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import hmac
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
VECTOR_PATH = ROOT / "limlink-core-vectors-v1.json"

CODE_SPACE = 1_000_000
CODE_LIMIT = 2**32 - (2**32 % CODE_SPACE)  # 4_294_000_000, reject v >= LIMIT
SUITE = "CPACE-RISTR255-SHA512"
DSI = b"CPaceRistretto255"

# draft-irtf-cfrg-cpace-21 appendix B.3, hardcoded so this file is the anchor.
DRAFT = {
    "prs": "50617373776f7264",
    "ci": "0b415f696e69746961746f720b425f726573706f6e646572",
    "sid": "7e4b4791d6a8ef019b936c79fb7f2c57",
    "generatorString": (
        "11435061636552697374726574746f3235350850617373776f726464"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000180b415f696e69746961746f"
        "720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f"
        "2c57"
    ),
    "hash": (
        "da6d3ddc8802fca9058755ffd3ebde08a9c2c74945901a258482a288"
        "b6663af06bf645c93cd1c51512307199c80e84908916d983b34af772"
        "05f90851a657ee27"
    ),
    "generator": "222b6b195fe84b1652badb6f6a3ae3d24341e7306967f0b8115b40d5698c7e56",
    "yaScalar": "da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08",
    "ybScalar": "d2316b454718c35362d83d69df6320f38578ed5984651435e2949762d900b80d",
    "ada": "414461",
    "adb": "414462",
    "ya": "d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157",
    "yb": "3ea7e0b19560d7c0b0f5734f63b955286dfa8232b5ebe63324e2d9e7433f7258",
    "k": "80b69a8a76457ab6a4d7f887a4bf6b55a2f80ac19c333f917a05fc9887c8b40f",
    "iskIr": (
        "b69effbf61b51d56401c0f65601abe428de8206feaaf0e32198896dc"
        "ae7b35cd2b38950a39dfd5d4a79164614c2984f7daa460b588c1e80c"
        "3fa2068af7900447"
    ),
    "iskSy": (
        "544199d71f62f8d9a1fee55727e24fe4a45844593c2b6013c4fa3969"
        "d0e5debb2244675c0b43397cbb68d342b01fc0f98fc961469a25134d"
        "e9f0f813c1a57476"
    ),
    "sidOutputIr": (
        "bb1c449b35f0ea79a65c209f329a693d475e0ce2387bed9fe4b78f60"
        "b2a27c219813fb2cfe175ef40d2222d9261e66da7d78f7c55a303b1b"
        "8611dcdfab880c47"
    ),
    "sidOutputOc": (
        "10d5941d4933497fe31b9188d690b84465e2a2d158332a7267284a07"
        "1a8d0876fc5c8c329dc735d59a9f8ef6623ee23924704a2f929dd631"
        "ca981227ee82fff2"
    ),
    "scalarMult": {
        "s": "7cd0e075fa7955ba52c02759a6c90dbbfc10e6d40aea8d283e407d88cf538a05",
        "x": "2c3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c",
        "out": "7c13645fe790a468f62c39beb7388e541d8405d1ade69d1778c5fe3e7f6b600e",
    },
    "invalidYi1": "2b3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c",
    "invalidYi2": "00" * 32,
}

SAS = {
    "label": "limlink-sas-v1",
    "fpA": "01" * 32,
    "fpB": "02" * 32,
    "nA": "03" * 32,
    "nB": "04" * 32,
    "commit": "648aa5c579fb30f38af744d97d6ec840c7a91277a499a0d780f3e7314eca090b",
    "commitB64Url": "ZIqlxXn7MPOK90TZfW7IQMepEnekmaDXgPPnMU7KCQs",
    "sha256": "50cde9ddb28a54e2ca71689387ea9c3ddf31971dcefce8f92a5d3097a5f76ec7",
    "valueBe": 1355672029,
    "sas": "672029",
}


def hx(data: bytes) -> str:
    return data.hex()


def unhex(text: str) -> bytes:
    return bytes.fromhex(text)


def leb128(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            break
    return bytes(out)


def prepend_len(data: bytes) -> bytes:
    return leb128(len(data)) + data


def lv_cat(*parts: bytes) -> bytes:
    return b"".join(prepend_len(p) for p in parts)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def generator_string(dsi: bytes, prs: bytes, ci: bytes, sid: bytes, block: int = 128) -> bytes:
    zpad = max(0, block - 1 - len(prepend_len(prs)) - len(prepend_len(dsi)))
    return lv_cat(dsi, prs, bytes(zpad), ci, sid)


def o_cat(a: bytes, b: bytes) -> bytes:
    if a > b:
        return b"oc" + a + b
    return b"oc" + b + a


def transcript_ir(ya: bytes, ada: bytes, yb: bytes, adb: bytes) -> bytes:
    return lv_cat(ya, ada) + lv_cat(yb, adb)


def transcript_oc(ya: bytes, ada: bytes, yb: bytes, adb: bytes) -> bytes:
    return o_cat(lv_cat(ya, ada), lv_cat(yb, adb))


def isk(sid: bytes, k: bytes, transcript: bytes) -> bytes:
    return hashlib.sha512(lv_cat(DSI + b"_ISK", sid, k) + transcript).digest()


def mac_key(sid: bytes, isk_bytes: bytes) -> bytes:
    return hashlib.sha512(b"CPaceMac" + sid + isk_bytes).digest()


def mac_tag(key: bytes, message: bytes) -> bytes:
    return hmac.new(key, message, hashlib.sha512).digest()


def ticket(isk_bytes: bytes, sid: bytes) -> bytes:
    prk = hmac.new(sid, isk_bytes, hashlib.sha512).digest()
    block = hmac.new(prk, b"limlink invite v1 ticket" + bytes([1]), hashlib.sha512).digest()
    return block[:32]


def draw_code(script: bytes, pos: int) -> tuple[str, int]:
    for _ in range(1024):
        chunk = script[pos : pos + 4]
        if len(chunk) != 4:
            raise RuntimeError("rng script exhausted while drawing a code")
        pos += 4
        value = int.from_bytes(chunk, "big")
        if value < CODE_LIMIT:
            return f"{value % CODE_SPACE:06d}", pos
    raise RuntimeError("too many code rejections")


def take(script: bytes, pos: int, n: int) -> tuple[bytes, int]:
    chunk = script[pos : pos + n]
    if len(chunk) != n:
        raise RuntimeError(f"rng script exhausted, needed {n}")
    return chunk, pos + n


class Sodium:
    def __init__(self) -> None:
        self.lib = ctypes.CDLL("libsodium.so.23")
        self.lib.sodium_init.restype = ctypes.c_int
        if self.lib.sodium_init() < 0:
            raise RuntimeError("sodium_init failed")
        self.lib.crypto_core_ristretto255_from_hash.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        self.lib.crypto_core_ristretto255_from_hash.restype = ctypes.c_int
        self.lib.crypto_core_ristretto255_is_valid_point.argtypes = [ctypes.c_char_p]
        self.lib.crypto_core_ristretto255_is_valid_point.restype = ctypes.c_int
        self.lib.crypto_core_ristretto255_scalar_reduce.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        self.lib.crypto_core_ristretto255_scalar_reduce.restype = None
        self.lib.crypto_scalarmult_ristretto255.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        self.lib.crypto_scalarmult_ristretto255.restype = ctypes.c_int

    def from_hash(self, uniform: bytes) -> bytes:
        if len(uniform) != 64:
            raise ValueError("from_hash wants 64 bytes")
        out = ctypes.create_string_buffer(32)
        if self.lib.crypto_core_ristretto255_from_hash(out, uniform) != 0:
            raise RuntimeError("from_hash failed")
        return out.raw

    def valid(self, point: bytes) -> bool:
        return bool(self.lib.crypto_core_ristretto255_is_valid_point(point))

    def reduce(self, wide: bytes) -> bytes:
        if len(wide) != 64:
            raise ValueError("scalar_reduce wants 64 bytes")
        out = ctypes.create_string_buffer(32)
        self.lib.crypto_core_ristretto255_scalar_reduce(out, wide)
        return out.raw

    def scalarmult(self, scalar32: bytes, point: bytes) -> bytes | None:
        if not self.valid(point) or point == bytes(32) or scalar32 == bytes(32):
            return None
        out = ctypes.create_string_buffer(32)
        rc = self.lib.crypto_scalarmult_ristretto255(out, scalar32, point)
        if rc != 0 or out.raw == bytes(32):
            return None
        return out.raw


SODIUM = Sodium()


def generator_point(prs: bytes, ci: bytes, sid: bytes) -> bytes:
    gen = generator_string(DSI, prs, ci, sid)
    digest = hashlib.sha512(gen).digest()
    point = SODIUM.from_hash(digest)
    if point == bytes(32):
        raise RuntimeError("identity generator")
    return point


def message(wide_scalar: bytes, prs: bytes, ci: bytes, sid: bytes) -> tuple[bytes, bytes]:
    scalar = SODIUM.reduce(wide_scalar)
    point = SODIUM.scalarmult(scalar, generator_point(prs, ci, sid))
    if point is None:
        raise RuntimeError("message point rejected")
    return point, scalar


def shared_k(wide_scalar: bytes, peer: bytes, prs: bytes, ci: bytes, sid: bytes) -> bytes:
    scalar = SODIUM.reduce(wide_scalar)
    # Touch the generator so a mismatched password cannot skip it. The DH
    # result only needs the scalar and the peer point.
    _ = generator_point(prs, ci, sid)
    k = SODIUM.scalarmult(scalar, peer)
    if k is None:
        raise RuntimeError("peer point rejected")
    return k


def cpace_ir(
    ya_wide: bytes,
    yb_wide: bytes,
    prs: bytes,
    ci: bytes,
    sid: bytes,
    ada: bytes,
    adb: bytes,
) -> dict[str, bytes]:
    ya, _ = message(ya_wide, prs, ci, sid)
    yb, _ = message(yb_wide, prs, ci, sid)
    k_a = shared_k(ya_wide, yb, prs, ci, sid)
    k_b = shared_k(yb_wide, ya, prs, ci, sid)
    if k_a != k_b:
        raise RuntimeError("K mismatch")
    tr = transcript_ir(ya, ada, yb, adb)
    key = mac_key(sid, isk(sid, k_a, tr))
    return {
        "ya": ya,
        "yb": yb,
        "k": k_a,
        "isk": isk(sid, k_a, tr),
        "ta": mac_tag(key, lv_cat(ya, ada)),
        "tb": mac_tag(key, lv_cat(yb, adb)),
        "ticket": ticket(isk(sid, k_a, tr), sid),
    }


def recompute_draft() -> dict[str, object]:
    prs = unhex(DRAFT["prs"])
    ci = unhex(DRAFT["ci"])
    sid = unhex(DRAFT["sid"])
    ada = unhex(DRAFT["ada"])
    adb = unhex(DRAFT["adb"])
    gen = generator_string(DSI, prs, ci, sid)
    digest = hashlib.sha512(gen).digest()
    g = SODIUM.from_hash(digest)
    ya_wide = unhex(DRAFT["yaScalar"]) + bytes(32)
    yb_wide = unhex(DRAFT["ybScalar"]) + bytes(32)
    run = cpace_ir(ya_wide, yb_wide, prs, ci, sid, ada, adb)
    tr_ir = transcript_ir(run["ya"], ada, run["yb"], adb)
    tr_oc = transcript_oc(run["ya"], ada, run["yb"], adb)
    s = unhex(DRAFT["scalarMult"]["s"])
    x = unhex(DRAFT["scalarMult"]["x"])
    sm = SODIUM.scalarmult(s, x)
    if sm is None:
        raise RuntimeError("scalar_mult rejected a valid point")
    if SODIUM.valid(unhex(DRAFT["invalidYi1"])):
        raise RuntimeError("Yi1 should be an invalid encoding")
    if not SODIUM.valid(unhex(DRAFT["invalidYi2"])):
        raise RuntimeError("identity encoding should decode")
    got = {
        "generatorString": hx(gen),
        "hash": hx(digest),
        "generator": hx(g),
        "ya": hx(run["ya"]),
        "yb": hx(run["yb"]),
        "k": hx(run["k"]),
        "iskIr": hx(isk(sid, run["k"], tr_ir)),
        "iskSy": hx(isk(sid, run["k"], tr_oc)),
        "sidOutputIr": hx(hashlib.sha512(b"CPaceSidOutput" + tr_ir).digest()),
        "sidOutputOc": hx(hashlib.sha512(b"CPaceSidOutput" + tr_oc).digest()),
        "scalarMultOut": hx(sm),
    }
    expect = {
        "generatorString": DRAFT["generatorString"],
        "hash": DRAFT["hash"],
        "generator": DRAFT["generator"],
        "ya": DRAFT["ya"],
        "yb": DRAFT["yb"],
        "k": DRAFT["k"],
        "iskIr": DRAFT["iskIr"],
        "iskSy": DRAFT["iskSy"],
        "sidOutputIr": DRAFT["sidOutputIr"],
        "sidOutputOc": DRAFT["sidOutputOc"],
        "scalarMultOut": DRAFT["scalarMult"]["out"],
    }
    if got != expect:
        raise SystemExit(f"draft B.3 mismatch:\n{got}\n!=\n{expect}")
    return {
        "prs": DRAFT["prs"],
        "ci": DRAFT["ci"],
        "sid": DRAFT["sid"],
        "ada": DRAFT["ada"],
        "adb": DRAFT["adb"],
        "generatorString": DRAFT["generatorString"],
        "hash": DRAFT["hash"],
        "generator": DRAFT["generator"],
        "yaScalar": DRAFT["yaScalar"],
        "ybScalar": DRAFT["ybScalar"],
        "yaWide": hx(ya_wide),
        "ybWide": hx(yb_wide),
        "ya": DRAFT["ya"],
        "yb": DRAFT["yb"],
        "k": DRAFT["k"],
        "iskIr": DRAFT["iskIr"],
        "iskSy": DRAFT["iskSy"],
        "sidOutputIr": DRAFT["sidOutputIr"],
        "sidOutputOc": DRAFT["sidOutputOc"],
        "scalarMult": DRAFT["scalarMult"],
        "invalidYi1": DRAFT["invalidYi1"],
        "invalidYi2": DRAFT["invalidYi2"],
        "note": (
            "yaWide/ybWide are the 32-byte draft scalars padded with 32 zero bytes. "
            "pakery-cpace 0.6.0 reduces 64 bytes mod L; that padding reproduces the draft scalars."
        ),
    }


def recompute_sas() -> dict[str, object]:
    fp_a = unhex(SAS["fpA"])
    fp_b = unhex(SAS["fpB"])
    n_a = unhex(SAS["nA"])
    n_b = unhex(SAS["nB"])
    commit = hashlib.sha256(n_a).digest()
    digest = hashlib.sha256(b"limlink-sas-v1" + fp_a + fp_b + n_a + n_b).digest()
    value = int.from_bytes(digest[:4], "big")
    sas = f"{value % 1_000_000:06d}"
    got = {
        "commit": hx(commit),
        "commitB64Url": b64url(commit),
        "sha256": hx(digest),
        "valueBe": value,
        "sas": sas,
    }
    for key, value_ in got.items():
        if SAS[key] != value_:
            raise SystemExit(f"SAS mismatch on {key}: {value_} != {SAS[key]}")
    return dict(SAS)


def pattern_bytes(length: int, mul: int, add: int) -> bytes:
    return bytes(((i * mul + add) & 0xFF) for i in range(length))


def sha256_chunks(data: bytes, chunk_size: int) -> str:
    hasher = hashlib.sha256()
    for offset in range(0, len(data), chunk_size):
        hasher.update(data[offset : offset + chunk_size])
    one_shot = hashlib.sha256(data).hexdigest()
    chunked = hasher.hexdigest()
    if one_shot != chunked:
        raise SystemExit("chunked SHA-256 diverged from the one-shot digest")
    return chunked


def recompute_file_hash() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = [
        {
            "name": "empty",
            "contentHex": "",
            "sha256": hashlib.sha256(b"").hexdigest(),
        },
        {
            "name": "abc",
            "contentUtf8": "abc",
            "sha256": hashlib.sha256(b"abc").hexdigest(),
        },
    ]
    expect = {
        "empty": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    }
    for row in rows:
        if row["sha256"] != expect[str(row["name"])]:
            raise SystemExit(f"file hash mismatch for {row['name']}")
    length = 1 << 20
    chunk_size = 4096
    mul = 131
    add = 17
    body = pattern_bytes(length, mul, add)
    rows.append(
        {
            "name": "one-mib-pattern",
            "length": length,
            "chunkSize": chunk_size,
            "generatorMul": mul,
            "generatorAdd": add,
            "generator": (
                "byte i is (i * generatorMul + generatorAdd) mod 256, i from 0 inclusive "
                "to length exclusive. Hash by updating SHA-256 on successive chunkSize "
                "slices. The raw bytes are not stored in this file."
            ),
            "sha256": sha256_chunks(body, chunk_size),
        }
    )
    return rows


def limlink_context(
    code: str, fp_r: bytes, fp_s: bytes, nonce_r: bytes, nonce_s: bytes, peer_suites: list[str]
) -> dict[str, bytes]:
    joined = ",".join(peer_suites).encode("ascii")
    return {
        "ci": lv_cat(b"limlink-invite-v1", fp_r, fp_s),
        "sid": nonce_r + nonce_s,
        "ada": lv_cat(b"limlink/1", b"recv", joined),
        "adb": lv_cat(b"limlink/1", b"send", SUITE.encode("ascii")),
        "prs": code.encode("ascii"),
    }


def run_sender_hello(script: bytes, pos: int) -> tuple[str, bytes, bytes, str, int]:
    code, pos = draw_code(script, pos)
    nonce_s, pos = take(script, pos, 16)
    raw_id, pos = take(script, pos, 16)
    return code, nonce_s, raw_id, b64url(raw_id), pos


def limlink_case(
    name: str,
    description: str,
    sender_script: bytes,
    receiver_script: bytes,
    fp_r: bytes,
    fp_s: bytes,
    receiver_code: str | None,
    sender_suites: list[str],
    receiver_suites: list[str],
    receiver_fp_peer: bytes | None = None,
) -> dict[str, object]:
    code, nonce_s, raw_id, session_id, pos_s = run_sender_hello(sender_script, 0)
    if receiver_code is None:
        receiver_code = code
    nonce_r, pos_r = take(receiver_script, 0, 16)
    ya_wide, pos_r = take(receiver_script, pos_r, 64)
    yb_wide, pos_s = take(sender_script, pos_s, 64)
    if pos_s != len(sender_script) or pos_r != len(receiver_script):
        raise RuntimeError(f"{name}: script was not fully consumed")
    sender_ctx = limlink_context(code, fp_r, fp_s, nonce_r, nonce_s, sender_suites)
    peer_fp = fp_s if receiver_fp_peer is None else receiver_fp_peer
    receiver_ctx = limlink_context(
        receiver_code, fp_r, peer_fp, nonce_r, nonce_s, receiver_suites
    )
    # Ya on the wire is the receiver's point (its password, CI, and scalar).
    # The sender answers that point with its own password and CI.
    recv_ya, _ = message(
        ya_wide, receiver_ctx["prs"], receiver_ctx["ci"], receiver_ctx["sid"]
    )
    sender = sender_reply(
        yb_wide,
        recv_ya,
        sender_ctx["prs"],
        sender_ctx["ci"],
        sender_ctx["sid"],
        sender_ctx["ada"],
        sender_ctx["adb"],
    )
    recv_view = receiver_expect(
        ya_wide,
        sender["yb"],
        receiver_ctx["prs"],
        receiver_ctx["ci"],
        receiver_ctx["sid"],
        receiver_ctx["ada"],
        receiver_ctx["adb"],
    )
    if recv_view["ya"] != recv_ya:
        raise RuntimeError(f"{name}: receiver point changed")
    tags_equal = recv_view["expectTb"] == sender["tb"]
    result = "ok" if tags_equal else "tagMismatch"
    return {
        "name": name,
        "description": description,
        "nowMs": 1700000000000,
        "rngScriptSender": hx(sender_script),
        "rngScriptReceiver": hx(receiver_script),
        "code": code,
        "receiverCode": receiver_code,
        "fpReceiver": hx(fp_r),
        "fpSender": hx(fp_s),
        "receiverFpPeer": hx(peer_fp),
        "peerSuites": sender_suites,
        "receiverSuites": receiver_suites,
        "selectedSuite": SUITE,
        "nonceR": hx(nonce_r),
        "nonceS": hx(nonce_s),
        "sessionIdRaw": hx(raw_id),
        "sessionId": session_id,
        "ci": hx(sender_ctx["ci"]),
        "ada": hx(sender_ctx["ada"]),
        "adb": hx(sender_ctx["adb"]),
        "sid": hx(sender_ctx["sid"]),
        "ya": hx(recv_ya),
        "yb": hx(sender["yb"]),
        "ta": hx(sender["ta"]),
        "tb": hx(sender["tb"]),
        "ticket": hx(sender["ticket"]),
        "receiverExpectTb": hx(recv_view["expectTb"]),
        "result": result,
    }


def sender_reply(
    yb_wide: bytes,
    ya: bytes,
    prs: bytes,
    ci: bytes,
    sid: bytes,
    ada: bytes,
    adb: bytes,
) -> dict[str, bytes]:
    yb, scalar = message(yb_wide, prs, ci, sid)
    k = SODIUM.scalarmult(scalar, ya)
    if k is None:
        raise RuntimeError("sender rejected Ya")
    shared = isk(sid, k, transcript_ir(ya, ada, yb, adb))
    key = mac_key(sid, shared)
    return {
        "yb": yb,
        "k": k,
        "isk": shared,
        "ta": mac_tag(key, lv_cat(ya, ada)),
        "tb": mac_tag(key, lv_cat(yb, adb)),
        "ticket": ticket(shared, sid),
    }


def receiver_expect(
    ya_wide: bytes,
    yb: bytes,
    prs: bytes,
    ci: bytes,
    sid: bytes,
    ada: bytes,
    adb: bytes,
) -> dict[str, bytes]:
    ya, scalar = message(ya_wide, prs, ci, sid)
    k = SODIUM.scalarmult(scalar, yb)
    if k is None:
        return {"ya": ya, "expectTb": b""}
    shared = isk(sid, k, transcript_ir(ya, ada, yb, adb))
    key = mac_key(sid, shared)
    return {
        "ya": ya,
        "expectTb": mac_tag(key, lv_cat(yb, adb)),
        "ta": mac_tag(key, lv_cat(ya, ada)),
        "ticket": ticket(shared, sid),
    }


def build_limlink() -> list[dict[str, object]]:
    fp_r = bytes([0x11]) * 32
    fp_s = bytes([0x22]) * 32
    ya_wide = unhex(DRAFT["yaScalar"]) + bytes(32)
    yb_wide = unhex(DRAFT["ybScalar"]) + bytes(32)
    nonce_r = bytes(range(16))
    nonce_s = bytes(range(16, 32))
    raw_id = bytes(range(32, 48))
    code_bytes = (482915).to_bytes(4, "big")

    def sender_script(code: bytes = code_bytes, n_s: bytes = nonce_s, sid: bytes = raw_id, scalar: bytes = yb_wide) -> bytes:
        return code + n_s + sid + scalar

    def receiver_script(n_r: bytes = nonce_r, scalar: bytes = ya_wide) -> bytes:
        return n_r + scalar

    suites = [SUITE]
    cases = [
        limlink_case(
            "happy-path",
            "码对，指纹对，套件列表对。发送方脚本先出码 482915，再 nonceS、session id、64 字节标量。",
            sender_script(),
            receiver_script(),
            fp_r,
            fp_s,
            None,
            suites,
            suites,
        ),
        limlink_case(
            "code-rejection",
            "第一个 u32 是 0xFFFFFFFF，被拒绝采样丢掉；第二个 u32 是 42，码为 000042。",
            sender_script(code=bytes.fromhex("ffffffff") + (42).to_bytes(4, "big")),
            receiver_script(n_r=bytes([0xA0]) * 16, scalar=bytes([0x5A]) * 32 + bytes(32)),
            fp_r,
            fp_s,
            None,
            suites,
            suites,
        ),
        limlink_case(
            "wrong-code",
            "接收方输入的码和发送方生成的码差 1。Tb 对不上。",
            sender_script(),
            receiver_script(n_r=bytes([0xB0]) * 16),
            fp_r,
            fp_s,
            "482916",
            suites,
            suites,
        ),
        limlink_case(
            "fingerprint-mismatch",
            "接收方 start 用了另一个发送方指纹，CI 对不上。",
            sender_script(n_s=bytes([0x31]) * 16, sid=bytes([0x32]) * 16),
            receiver_script(n_r=bytes([0x33]) * 16),
            fp_r,
            fp_s,
            None,
            suites,
            suites,
            receiver_fp_peer=bytes([0x44]) * 32,
        ),
        limlink_case(
            "suite-list-mismatch",
            "发送方把套件列表多写了一项，ADa 变了，模拟降级。",
            sender_script(n_s=bytes([0x51]) * 16, sid=bytes([0x52]) * 16),
            receiver_script(n_r=bytes([0x53]) * 16),
            fp_r,
            fp_s,
            None,
            [SUITE, "CPACE-FUTURE"],
            suites,
        ),
    ]
    if cases[0]["result"] != "ok" or cases[0]["code"] != "482915":
        raise SystemExit("happy-path did not succeed")
    if cases[1]["code"] != "000042" or cases[1]["result"] != "ok":
        raise SystemExit("code-rejection vector is wrong")
    for case in cases[2:]:
        if case["result"] != "tagMismatch":
            raise SystemExit(f"{case['name']} should be tagMismatch")
    return cases


TTL_MS = 600_000
CONFIRM_MS = 30_000
TERMINAL = {"succeeded", "exhausted", "expired", "cancelled"}


class _Sender:
    def __init__(self, script: bytes, now: int) -> None:
        self.script = script
        self.pos = 0
        self.code, self.pos = draw_code(script, 0)
        self.created = now
        self.state = "waiting"
        self.failures = 0
        self.deducted = 0
        self.code_live = True
        self.hellos: list[dict[str, object]] = []
        self.active: dict[str, object] | None = None

    def _elapsed(self, now: int) -> int:
        if now < self.created:
            return 0
        return now - self.created

    def refresh(self, now: int) -> None:
        if self.state in TERMINAL:
            return
        if self._elapsed(now) >= TTL_MS:
            self._terminal("expired")
            return
        if self.state == "in_progress" and self.active is not None:
            started = int(self.active["started"])
            if now >= started and now - started >= CONFIRM_MS:
                self._fail()

    def _fail(self) -> None:
        self.active = None
        self.failures += 1
        if self.failures >= 3 or self.deducted >= 3:
            self._terminal("exhausted")
        else:
            self.state = "waiting"

    def _terminal(self, state: str) -> None:
        self.state = state
        self.code_live = False
        self.hellos.clear()
        self.active = None

    def _open(self) -> str | None:
        if self.state in {"succeeded", "cancelled"}:
            return "notActive"
        if self.state == "exhausted":
            return "exhausted"
        if self.state == "expired":
            return "expired"
        return None

    def status(self, now: int) -> dict[str, object]:
        self.refresh(now)
        expires = 0 if self.state in TERMINAL else TTL_MS - self._elapsed(now)
        return {
            "op": "status",
            "nowMs": now,
            "result": "ok",
            "state": self.state,
            "failures": self.failures,
            "attemptsLeft": 3 - self.deducted,
            "expiresInMs": expires,
        }

    def code_step(self) -> dict[str, object]:
        return {"op": "code", "result": "ok", "code": self.code if self.code_live else ""}

    def accept_hello(self, nonce_r: bytes, peer_suites: str, now: int) -> dict[str, object]:
        self.refresh(now)
        err = self._open()
        if err:
            return {"op": "acceptHello", "nowMs": now, "peerSuites": peer_suites, "result": err}
        suites = peer_suites.split(",")
        nonce_s, self.pos = take(self.script, self.pos, 16)
        raw, self.pos = take(self.script, self.pos, 16)
        session_id = b64url(raw)
        if len(self.hellos) >= 8:
            self.hellos.pop(0)
        self.hellos.append(
            {
                "id": session_id,
                "nonceS": nonce_s,
                "nonceR": nonce_r,
                "suites": suites,
            }
        )
        return {
            "op": "acceptHello",
            "nowMs": now,
            "peerSuites": peer_suites,
            "nonceR": hx(nonce_r),
            "result": "ok",
            "sessionId": session_id,
            "nonceS": hx(nonce_s),
            "suite": SUITE,
        }

    def respond(
        self, session_id: str, fp_r: bytes, fp_s: bytes, ya: bytes, now: int
    ) -> dict[str, object]:
        self.refresh(now)
        err = self._open()
        if err:
            return {"op": "respondPake", "nowMs": now, "result": err}
        if self.state == "in_progress":
            return {"op": "respondPake", "nowMs": now, "result": "busy"}
        idx = next((i for i, h in enumerate(self.hellos) if h["id"] == session_id), None)
        if idx is None:
            return {"op": "respondPake", "nowMs": now, "result": "unknownAttempt"}
        if self.deducted >= 3:
            self._terminal("exhausted")
            return {"op": "respondPake", "nowMs": now, "result": "exhausted"}
        self.deducted += 1
        hello = self.hellos.pop(idx)
        yb_wide, self.pos = take(self.script, self.pos, 64)
        ctx = limlink_context(
            self.code,
            fp_r,
            fp_s,
            hello["nonceR"],  # type: ignore[arg-type]
            hello["nonceS"],  # type: ignore[arg-type]
            hello["suites"],  # type: ignore[arg-type]
        )
        reply = sender_reply(yb_wide, ya, ctx["prs"], ctx["ci"], ctx["sid"], ctx["ada"], ctx["adb"])
        self.active = {
            "id": session_id,
            "ta": reply["ta"],
            "ticket": reply["ticket"],
            "fpPeer": fp_r,
            "started": now,
        }
        self.state = "in_progress"
        return {
            "op": "respondPake",
            "nowMs": now,
            "result": "ok",
            "yb": hx(reply["yb"]),
            "tb": hx(reply["tb"]),
        }

    def verify_confirm(self, session_id: str, ta: bytes, now: int) -> dict[str, object]:
        self.refresh(now)
        base = {"op": "verifyConfirm", "nowMs": now}
        if self.state in {"succeeded", "cancelled"}:
            return {**base, "result": "notActive"}
        if self.state == "exhausted":
            return {**base, "result": "exhausted"}
        if self.state == "expired":
            return {**base, "result": "expired"}
        if self.state == "waiting":
            return {**base, "result": "unknownAttempt"}
        assert self.active is not None
        if self.active["id"] != session_id:
            return {**base, "result": "unknownAttempt"}
        if ta != self.active["ta"]:
            self._fail()
            return {**base, "result": "confirmMismatch"}
        ticket_bytes = self.active["ticket"]
        peer = self.active["fpPeer"]
        self._terminal("succeeded")
        return {
            **base,
            "result": "ok",
            "ticket": hx(ticket_bytes),  # type: ignore[arg-type]
            "peerFp": hx(peer),  # type: ignore[arg-type]
        }

    def cancel_attempt(self, session_id: str) -> dict[str, object]:
        if self.state in {"succeeded", "cancelled"}:
            return {"op": "cancelAttempt", "result": "notActive"}
        if self.state == "exhausted":
            return {"op": "cancelAttempt", "result": "exhausted"}
        if self.state == "expired":
            return {"op": "cancelAttempt", "result": "expired"}
        if self.active is not None and self.active["id"] == session_id:
            self._fail()
            return {"op": "cancelAttempt", "result": "ok"}
        idx = next((i for i, h in enumerate(self.hellos) if h["id"] == session_id), None)
        if idx is None:
            return {"op": "cancelAttempt", "result": "unknownAttempt"}
        self.hellos.pop(idx)
        return {"op": "cancelAttempt", "result": "ok"}

    def cancel(self) -> dict[str, object]:
        if self.state == "cancelled":
            return {"op": "cancel", "result": "ok"}
        if self.state in {"succeeded", "exhausted", "expired"}:
            return {"op": "cancel", "result": "notActive"}
        self._terminal("cancelled")
        return {"op": "cancel", "result": "ok"}


class _Attempt:
    def __init__(self, code: str, script: bytes) -> None:
        self.code = code
        self.script = script
        self.pos = 0
        self.nonce_r, self.pos = take(script, 0, 16)
        self.phase = "fresh"
        self.consumed = False
        self.ya_wide = b""
        self.ctx: dict[str, bytes] = {}
        self.fp_peer = b""
        self.ticket = b""
        self.ya = b""

    def start(self, nonce_s: bytes, fp_self: bytes, fp_peer: bytes, peer_suites: list[str]) -> dict[str, object]:
        self.ya_wide, self.pos = take(self.script, self.pos, 64)
        self.ctx = limlink_context(self.code, fp_self, fp_peer, self.nonce_r, nonce_s, peer_suites)
        self.ya, _ = message(self.ya_wide, self.ctx["prs"], self.ctx["ci"], self.ctx["sid"])
        self.fp_peer = fp_peer
        self.phase = "started"
        return {"op": "start", "result": "ok", "ya": hx(self.ya)}

    def finish(self, yb: bytes, tb: bytes) -> dict[str, object]:
        view = receiver_expect(
            self.ya_wide, yb, self.ctx["prs"], self.ctx["ci"], self.ctx["sid"], self.ctx["ada"], self.ctx["adb"]
        )
        if view["expectTb"] != tb:
            self.phase = "failed"
            return {"op": "finish", "result": "tagMismatch"}
        self.ticket = view["ticket"]
        self.phase = "finished"
        return {"op": "finish", "result": "ok", "ta": hx(view["ta"])}

    def verify(self, presented: bytes, fp: bytes) -> dict[str, object]:
        if self.phase != "finished":
            return {"op": "verifyTicket", "result": "badState"}
        both = presented == self.ticket and fp == self.fp_peer
        if self.consumed:
            result = "ticketUsed" if both else "ticketMismatch"
        elif both:
            self.consumed = True
            result = "ok"
        else:
            result = "ticketMismatch"
        return {
            "op": "verifyTicket",
            "result": result,
            "ticket": hx(presented),
            "fp": hx(fp),
        }


def _wide(fill: int) -> bytes:
    return bytes([fill]) * 32 + bytes(32)


def _sender_script(n_pakes: int, code: int = 7) -> bytes:
    parts = [code.to_bytes(4, "big")]
    for i in range(n_pakes):
        parts.append(bytes([0x10 + i]) * 16)
        parts.append(bytes([0x40 + i]) * 16)
        parts.append(_wide(0x80 + i))
    return b"".join(parts)


def _receiver_script(fill: int) -> bytes:
    return bytes([fill]) * 16 + _wide(fill)


def _case(name: str, description: str, script: bytes, steps: list[dict[str, object]]) -> dict[str, object]:
    return {
        "name": name,
        "description": description,
        "fpReceiver": hx(bytes([0x11]) * 32),
        "fpSender": hx(bytes([0x22]) * 32),
        "rngScriptSender": hx(script),
        "steps": steps,
    }


def _handshake(
    sender: _Sender,
    steps: list[dict[str, object]],
    now: int,
    fp_r: bytes,
    fp_s: bytes,
    recv_script: bytes,
    peer_suites: str = SUITE,
) -> tuple[_Attempt, str, bytes]:
    attempt = _Attempt(sender.code, recv_script)
    steps.append({"op": "receiverNew", "rngScript": hx(recv_script), "result": "ok"})
    steps.append({"op": "begin", "result": "ok", "nonceR": hx(attempt.nonce_r)})
    accepted = sender.accept_hello(attempt.nonce_r, peer_suites, now)
    steps.append(accepted)
    if accepted["result"] != "ok":
        raise RuntimeError(accepted)
    started = attempt.start(unhex(str(accepted["nonceS"])), fp_r, fp_s, peer_suites.split(","))
    steps.append(started)
    responded = sender.respond(str(accepted["sessionId"]), fp_r, fp_s, attempt.ya, now)
    steps.append(responded)
    if responded["result"] != "ok":
        raise RuntimeError(responded)
    finished = attempt.finish(unhex(str(responded["yb"])), unhex(str(responded["tb"])))
    steps.append(finished)
    if finished["result"] != "ok":
        raise RuntimeError(finished)
    return attempt, str(accepted["sessionId"]), unhex(str(finished["ta"]))


def build_state_machine() -> list[dict[str, object]]:
    fp_r = bytes([0x11]) * 32
    fp_s = bytes([0x22]) * 32
    cases: list[dict[str, object]] = []

    script = _sender_script(0)
    sender = _Sender(script, 0)
    steps = [{"op": "senderNew", "nowMs": 0, "result": "ok"}, sender.code_step()]
    steps.append(sender.status(TTL_MS - 1))
    steps.append(sender.status(TTL_MS))
    steps.append(sender.accept_hello(bytes(16), SUITE, TTL_MS))
    steps.append(sender.code_step())
    cases.append(_case("expiry", "nowMs 到达 600000 时过期；之后的 accept_hello 返回 expired。", script, steps))

    script = _sender_script(3)
    sender = _Sender(script, 5_000)
    steps = [{"op": "senderNew", "nowMs": 5000, "result": "ok"}]
    for i in range(3):
        _attempt, sid, _ta = _handshake(sender, steps, 5_000, fp_r, fp_s, _receiver_script(0xA0 + i))
        bad = bytes(64)
        steps.append(sender.verify_confirm(sid, bad, 5_000))
    steps.append(sender.status(5_000))
    steps.append(sender.code_step())
    cases.append(
        _case(
            "three-confirm-mismatches",
            "三次确认失败后码耗尽。第三次返回的仍是 confirmMismatch，状态变成 exhausted。",
            script,
            steps,
        )
    )

    script = _sender_script(1)
    # second hello needs another nonceS+sid but no second scalar if busy returns first
    # accept_hello of the second session DOES draw nonceS and sid. respond does not draw.
    script = _sender_script(1) + bytes([0x51]) * 16 + bytes([0x52]) * 16
    sender = _Sender(script, 8_000)
    steps = [{"op": "senderNew", "nowMs": 8000, "result": "ok"}]
    _attempt, sid, _ta = _handshake(sender, steps, 8_000, fp_r, fp_s, _receiver_script(0xB1))
    second = sender.accept_hello(bytes([0xB2]) * 16, SUITE, 8_000)
    steps.append(second)
    steps.append(
        sender.respond(str(second["sessionId"]), fp_r, fp_s, bytes(32), 8_000)
    )
    steps.append(sender.status(8_000))
    cases.append(_case("busy", "已经有一次 pake 在进行时，再 respond_pake 返回 busy，不扣次。", script, steps))

    # First hello is cancelled before respond_pake, so it draws nonceS+sid
    # and no scalar. The later handshake draws another nonceS+sid and one scalar.
    script = (
        (7).to_bytes(4, "big")
        + bytes([0x10]) * 16
        + bytes([0x40]) * 16
        + bytes([0x11]) * 16
        + bytes([0x41]) * 16
        + _wide(0x80)
    )
    sender = _Sender(script, 9_000)
    steps = [{"op": "senderNew", "nowMs": 9000, "result": "ok"}]
    attempt = _Attempt(sender.code, _receiver_script(0xC1))
    steps.append({"op": "receiverNew", "rngScript": hx(_receiver_script(0xC1)), "result": "ok"})
    steps.append({"op": "begin", "result": "ok", "nonceR": hx(attempt.nonce_r)})
    accepted = sender.accept_hello(attempt.nonce_r, SUITE, 9_000)
    steps.append(accepted)
    steps.append(sender.cancel_attempt(str(accepted["sessionId"])))
    steps.append(sender.status(9_000))
    _attempt, sid, _ta = _handshake(sender, steps, 9_000, fp_r, fp_s, _receiver_script(0xC2))
    steps.append(sender.cancel_attempt(sid))
    steps.append(sender.status(9_000))
    cases.append(
        _case(
            "cancel-attempt",
            "取消还没进入 pake 的 hello 不计失败；取消进行中的 pake 计一次失败，扣次保留。",
            script,
            steps,
        )
    )

    script = _sender_script(0)
    sender = _Sender(script, 1)
    steps = [
        {"op": "senderNew", "nowMs": 1, "result": "ok"},
        sender.cancel(),
        sender.cancel(),
        sender.code_step(),
        sender.status(1),
        sender.accept_hello(bytes(16), SUITE, 1),
    ]
    cases.append(_case("cancel", "cancel 可以重复调用。终态是 cancelled，之后 accept_hello 返回 notActive。", script, steps))

    script = _sender_script(1)
    sender = _Sender(script, 1_000)
    steps = [{"op": "senderNew", "nowMs": 1000, "result": "ok"}]
    _attempt, sid, ta = _handshake(sender, steps, 1_000, fp_r, fp_s, _receiver_script(0xD1))
    steps.append(sender.verify_confirm(sid, ta, 1_000 + CONFIRM_MS))
    steps.append(sender.status(1_000 + CONFIRM_MS))
    cases.append(
        _case(
            "confirm-timeout",
            "respond_pake 之后满 30000ms，迟到的正确 Ta 被拒绝，返回 unknownAttempt。",
            script,
            steps,
        )
    )

    script = _sender_script(1)
    sender = _Sender(script, 1_700_000_000_000)
    steps = [{"op": "senderNew", "nowMs": 1700000000000, "result": "ok"}]
    attempt, sid, ta = _handshake(
        sender, steps, 1_700_000_000_000, fp_r, fp_s, _receiver_script(0xE1)
    )
    confirmed = sender.verify_confirm(sid, ta, 1_700_000_000_000)
    steps.append(confirmed)
    # Sender is succeeded, including after the confirm window. The attempt
    # still answers verify_ticket; those calls do not read the invite timer.
    steps.append(sender.status(1_700_000_000_000))
    steps.append(sender.status(1_700_000_000_000 + CONFIRM_MS))
    ticket_bytes = unhex(str(confirmed["ticket"]))
    wrong_fp = bytes([0x33]) * 32
    other = bytearray(ticket_bytes)
    other[0] ^= 0xFF
    steps.append(attempt.verify(ticket_bytes, wrong_fp))
    steps.append(attempt.verify(ticket_bytes, fp_s))
    steps.append(attempt.verify(ticket_bytes, fp_s))
    steps.append(attempt.verify(ticket_bytes, wrong_fp))
    steps.append(attempt.verify(bytes(other), fp_s))
    cases.append(
        _case(
            "ticket-single-use",
            "失败不消费。邀请已经 succeeded、确认窗口过了之后，同一票据和指纹仍是 ticketUsed；换指纹或换票据是 ticketMismatch。",
            script,
            steps,
        )
    )

    names = [case["name"] for case in cases]
    if len(names) != len(set(names)):
        raise SystemExit("duplicate state-machine case name")
    ticket_steps = cases[-1]["steps"]
    if ticket_steps[-3]["result"] != "ticketUsed":  # type: ignore[index]
        raise SystemExit("ticket replay did not return ticketUsed")
    if ticket_steps[-2]["result"] != "ticketMismatch":  # type: ignore[index]
        raise SystemExit("different fingerprint after use should be ticketMismatch")
    if ticket_steps[-1]["result"] != "ticketMismatch":  # type: ignore[index]
        raise SystemExit("different ticket after use should be ticketMismatch")
    late = next(
        step
        for step in ticket_steps  # type: ignore[union-attr]
        if step.get("op") == "status" and step.get("nowMs") == 1_700_000_000_000 + CONFIRM_MS
    )
    if late["state"] != "succeeded":
        raise SystemExit("confirm timer must not move a succeeded invite")
    if cases[0]["steps"][3]["state"] != "expired":  # type: ignore[index]
        raise SystemExit("expiry case did not expire")
    if cases[0]["steps"][4]["result"] != "expired":  # type: ignore[index]
        raise SystemExit("accept after expiry was not expired")
    return cases


def document() -> dict[str, object]:
    draft = recompute_draft()
    return {
        "version": 1,
        "file": "limlink-core-vectors-v1",
        "cpaceDraft": "draft-irtf-cfrg-cpace-21",
        "cpaceDraftSection": "B.3",
        "pakeryCpace": "0.6.0",
        "suite": SUITE,
        "notes": [
            "SAS and file-hash rows are the spec 4.3 / 5.5 vectors.",
            "cpaceDraftB3 is draft-irtf-cfrg-cpace-21 appendix B.3, checked with libsodium.",
            "LimLink rows are cross-checked by this Python reference and the Rust core.",
            "Invite codes use 4-byte big-endian rejection sampling below 4294000000.",
            "CPace ephemeral scalars in rng scripts are 64 bytes, matching pakery-cpace 0.6.0.",
            "stateMachine replays the invite state machine with the nowMs on each step.",
            "fileHash one-mib-pattern is generated, then hashed in chunkSize slices. Raw bytes are not stored.",
            "verify_ticket stays on the receiver attempt after the invite is succeeded and after the confirm timer.",
        ],
        "sas": recompute_sas(),
        "fileHash": recompute_file_hash(),
        "cpaceDraftB3": draft,
        "limlink": build_limlink(),
        "stateMachine": build_state_machine(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.write == args.check:
        parser.error("pass exactly one of --write or --check")
    doc = document()
    if args.write:
        VECTOR_PATH.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"wrote {VECTOR_PATH}")
        return
    on_disk = json.loads(VECTOR_PATH.read_text(encoding="utf-8"))
    if on_disk != doc:
        raise SystemExit("vector file does not match the Python reference; run --write")
    print("vectors match the Python reference")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"ref_impl: {exc}", file=sys.stderr)
        raise
