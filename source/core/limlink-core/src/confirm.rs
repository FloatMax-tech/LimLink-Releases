use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha512};
use subtle::ConstantTimeEq;

type HmacSha512 = Hmac<Sha512>;

pub fn mac_key(sid: &[u8], isk: &[u8]) -> [u8; 64] {
    let mut hasher = Sha512::new();
    hasher.update(b"CPaceMac");
    hasher.update(sid);
    hasher.update(isk);
    hasher.finalize().into()
}

pub fn mac_tag(key: &[u8], message: &[u8]) -> [u8; 64] {
    let mut mac = HmacSha512::new_from_slice(key).expect("hmac accepts any key length");
    mac.update(message);
    let tag = mac.finalize().into_bytes();
    let mut out = [0u8; 64];
    out.copy_from_slice(&tag);
    out
}

/// HKDF-SHA512, salt = sid, IKM = ISK, info = `limlink invite v1 ticket`, L = 32.
pub fn derive_ticket(isk: &[u8], sid: &[u8]) -> [u8; 32] {
    let hk = hkdf::Hkdf::<Sha512>::new(Some(sid), isk);
    let mut okm = [0u8; 32];
    hk.expand(b"limlink invite v1 ticket", &mut okm)
        .expect("32-byte HKDF output is within the limit");
    okm
}

pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    bool::from(a.ct_eq(b))
}
