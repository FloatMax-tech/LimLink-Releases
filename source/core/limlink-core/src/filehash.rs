use sha2::{Digest, Sha256};

/// Lowercase hex of `SHA-256(bytes)`. This is the on-wire `sha256` field (5.5).
///
/// Hashing a buffer here is for the format vectors. Large file IO stays on
/// the platform; this function is not in the C ABI.
pub fn sha256_hex(bytes: &[u8]) -> String {
    sha256_hex_chunks(std::iter::once(bytes))
}

/// SHA-256 over successive buffers. The concatenation is the hashed message.
/// Platforms hash a large file the same way, one read at a time.
pub fn sha256_hex_chunks<'a>(chunks: impl IntoIterator<Item = &'a [u8]>) -> String {
    let mut hasher = Sha256::new();
    for chunk in chunks {
        hasher.update(chunk);
    }
    hex_encode(&hasher.finalize())
}

/// Parse a 64-character hex digest. Case is ignored. Anything else is `None`.
pub fn parse_sha256_hex(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 {
        return None;
    }
    let bytes = text.as_bytes();
    let mut out = [0u8; 32];
    for i in 0..32 {
        let hi = hex_val(bytes[i * 2])?;
        let lo = hex_val(bytes[i * 2 + 1])?;
        out[i] = (hi << 4) | lo;
    }
    Some(out)
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn hex_encode(data: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(data.len() * 2);
    for b in data {
        s.push(H[(b >> 4) as usize] as char);
        s.push(H[(b & 0xf) as usize] as char);
    }
    s
}
