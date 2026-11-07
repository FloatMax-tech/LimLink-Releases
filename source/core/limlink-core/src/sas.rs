use sha2::{Digest, Sha256};

use crate::b64::b64url_encode;

/// Result of the section 4.3 confirmation-code calculation.
///
/// Not part of the frozen C ABI. Platforms may reimplement this; the shared
/// vector file is the byte contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SasOutput {
    pub commit: [u8; 32],
    pub commit_b64url: String,
    pub digest: [u8; 32],
    pub sas: String,
}

/// `SAS = SHA-256("limlink-sas-v1" || fpA || fpB || nA || nB)`, first 4 bytes
/// big-endian, mod 10^6, zero-padded to 6 digits.
///
/// All four inputs must be 32 bytes. `commit` is `SHA-256(nA)`.
pub fn compute_sas(fp_a: &[u8], fp_b: &[u8], n_a: &[u8], n_b: &[u8]) -> Option<SasOutput> {
    if fp_a.len() != 32 || fp_b.len() != 32 || n_a.len() != 32 || n_b.len() != 32 {
        return None;
    }
    let commit: [u8; 32] = Sha256::digest(n_a).into();
    let mut hasher = Sha256::new();
    hasher.update(b"limlink-sas-v1");
    hasher.update(fp_a);
    hasher.update(fp_b);
    hasher.update(n_a);
    hasher.update(n_b);
    let digest: [u8; 32] = hasher.finalize().into();
    let v = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
    let sas = format!("{:06}", v % 1_000_000);
    Some(SasOutput {
        commit_b64url: b64url_encode(&commit),
        commit,
        digest,
        sas,
    })
}
