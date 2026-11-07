use crate::encoding::lv_cat;
use crate::error::CoreError;

pub const SUITE_NAME: &str = "CPACE-RISTR255-SHA512";
pub const MAX_SUITE_LEN: usize = 63;
pub const MAX_SUITES_JOINED: usize = 255;

pub fn receiver_suites() -> Vec<String> {
    vec![SUITE_NAME.to_string()]
}

pub fn join_suites(items: &[String]) -> String {
    items.join(",")
}

/// Accept a peer suite list. Our suite must be present. Unknown names that
/// match the token grammar are kept, in order, so they are bound into ADa.
pub fn parse_suite_list(items: &[String]) -> Result<Vec<String>, CoreError> {
    if items.is_empty() {
        return Err(CoreError::SuiteUnsupported);
    }
    let mut joined = 0usize;
    for (i, item) in items.iter().enumerate() {
        if !token_ok(item) {
            return Err(CoreError::SuiteUnsupported);
        }
        joined = joined.saturating_add(item.len());
        if i > 0 {
            joined = joined.saturating_add(1);
        }
        if joined > MAX_SUITES_JOINED {
            return Err(CoreError::SuiteUnsupported);
        }
    }
    if !items.iter().any(|s| s == SUITE_NAME) {
        return Err(CoreError::SuiteUnsupported);
    }
    Ok(items.to_vec())
}

/// Network form of a suite list: comma-separated, no spaces.
///
/// The raw byte length is checked before the string is split. A list longer
/// than [`MAX_SUITES_JOINED`] bytes is `SuiteUnsupported` and is not tokenized.
pub fn parse_suite_csv(text: &str) -> Result<Vec<String>, CoreError> {
    if text.is_empty() || text.len() > MAX_SUITES_JOINED || !text.is_ascii() {
        return Err(CoreError::SuiteUnsupported);
    }
    let items: Vec<String> = text.split(',').map(str::to_string).collect();
    parse_suite_list(&items)
}

pub fn parse_selected_suite(text: &str) -> Result<(), CoreError> {
    if text == SUITE_NAME {
        Ok(())
    } else {
        Err(CoreError::SuiteUnsupported)
    }
}

fn token_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_SUITE_LEN
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'+' | b'-'))
}

pub fn channel_id(fp_receiver: &[u8], fp_sender: &[u8]) -> Vec<u8> {
    lv_cat(&[b"limlink-invite-v1", fp_receiver, fp_sender])
}

pub fn ada(peer_suites_joined: &str) -> Vec<u8> {
    lv_cat(&[b"limlink/1", b"recv", peer_suites_joined.as_bytes()])
}

pub fn adb(selected_suite: &str) -> Vec<u8> {
    lv_cat(&[b"limlink/1", b"send", selected_suite.as_bytes()])
}

pub fn session_sid(nonce_r: &[u8], nonce_s: &[u8]) -> [u8; 32] {
    let mut sid = [0u8; 32];
    sid[..16].copy_from_slice(nonce_r);
    sid[16..].copy_from_slice(nonce_s);
    sid
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_list_rejects_length_before_split_and_malformed_tokens() {
        let suite = SUITE_NAME;
        let mut exact = String::from(suite);
        while exact.len() + 2 <= MAX_SUITES_JOINED {
            exact.push_str(",X");
        }
        assert_eq!(exact.len(), MAX_SUITES_JOINED);
        assert!(parse_suite_csv(&exact).is_ok());

        let mut too_long = exact.clone();
        too_long.push('Y');
        assert!(too_long.len() > MAX_SUITES_JOINED);
        assert_eq!(
            parse_suite_csv(&too_long).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&"A".repeat(MAX_SUITES_JOINED + 1)).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&format!("{suite},")).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&format!("{suite}, ")).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&format!("{suite},FOO BAR")).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&format!("{suite},套件")).unwrap_err(),
            CoreError::SuiteUnsupported
        );
        assert_eq!(
            parse_suite_csv(&format!("{suite},bad/token")).unwrap_err(),
            CoreError::SuiteUnsupported
        );
    }
}
