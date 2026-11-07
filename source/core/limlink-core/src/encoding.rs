//! LEB128 and `lv_cat` from draft-irtf-cfrg-cpace-21 appendix A.1.

pub fn leb128(mut value: usize) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
    out
}

pub fn prepend_len(data: &[u8]) -> Vec<u8> {
    let mut out = leb128(data.len());
    out.extend_from_slice(data);
    out
}

pub fn lv_cat(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in parts {
        out.extend_from_slice(&prepend_len(part));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draft_lv_cat_vector() {
        let got = lv_cat(&[b"1234", b"5", b"", b"678"]);
        assert_eq!(hex::encode(&got), "043132333401350003363738");
    }

    mod hex {
        pub fn encode(data: &[u8]) -> String {
            const H: &[u8; 16] = b"0123456789abcdef";
            let mut s = String::with_capacity(data.len() * 2);
            for b in data {
                s.push(H[(b >> 4) as usize] as char);
                s.push(H[(b & 0xf) as usize] as char);
            }
            s
        }
    }
}
