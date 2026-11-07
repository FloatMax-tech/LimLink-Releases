//! SAS, file hash, header constants, OS-RNG handshake, and invite state machine.
//! Scripted vectors live in `limlink-core-testvectors` (they need `test-rng`).

use limlink_core::{
    compute_sas, core_version, parse_sha256_hex, sha256_hex, sha256_hex_chunks, CoreError,
    InviteReceiver, InviteSender, InviteState, CONFIRM_TIMEOUT_MS, INVITE_TTL_MS, MAX_FAILURES,
    SUITE_NAME,
};

fn vectors() -> serde_json::Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../vectors/limlink-core-vectors-v1.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

fn hx(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn sas_spec_vector_is_672029() {
    let sas = vectors()["sas"].clone();
    let out = compute_sas(
        &unhex(sas["fpA"].as_str().unwrap()),
        &unhex(sas["fpB"].as_str().unwrap()),
        &unhex(sas["nA"].as_str().unwrap()),
        &unhex(sas["nB"].as_str().unwrap()),
    )
    .unwrap();
    assert_eq!(out.sas, "672029");
    assert_eq!(out.sas, sas["sas"].as_str().unwrap());
    assert_eq!(hx(&out.commit), sas["commit"].as_str().unwrap());
    assert_eq!(out.commit_b64url, sas["commitB64Url"].as_str().unwrap());
    assert_eq!(hx(&out.digest), sas["sha256"].as_str().unwrap());
    assert!(compute_sas(&[0; 31], &[0; 32], &[0; 32], &[0; 32]).is_none());
}

fn pattern_byte(index: usize, mul: usize, add: usize) -> u8 {
    index.wrapping_mul(mul).wrapping_add(add) as u8
}

#[test]
fn file_hash_vectors_and_case_insensitive_parse() {
    for row in vectors()["fileHash"].as_array().unwrap() {
        let (bytes, chunked) = if let Some(text) = row.get("contentUtf8") {
            (text.as_str().unwrap().as_bytes().to_vec(), None)
        } else if let Some(hex) = row.get("contentHex") {
            (unhex(hex.as_str().unwrap()), None)
        } else {
            let length = row["length"].as_u64().unwrap() as usize;
            let mul = row["generatorMul"].as_u64().unwrap() as usize;
            let add = row["generatorAdd"].as_u64().unwrap() as usize;
            let chunk = row["chunkSize"].as_u64().unwrap() as usize;
            let bytes: Vec<u8> = (0..length).map(|i| pattern_byte(i, mul, add)).collect();
            (bytes, Some(chunk))
        };
        let hex = if let Some(chunk) = chunked {
            let parts: Vec<&[u8]> = bytes.chunks(chunk).collect();
            let chunked_hex = sha256_hex_chunks(parts);
            assert_eq!(chunked_hex, sha256_hex(&bytes));
            chunked_hex
        } else {
            sha256_hex(&bytes)
        };
        assert_eq!(hex, row["sha256"].as_str().unwrap(), "{}", row["name"]);
        let parsed = parse_sha256_hex(&hex.to_ascii_uppercase()).unwrap();
        assert_eq!(hx(&parsed), hex);
    }
    assert!(parse_sha256_hex("abc").is_none());
    assert!(parse_sha256_hex(&"g".repeat(64)).is_none());
}

#[test]
fn header_constants_match_the_rust_abi() {
    let header = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../include/limlink_core.h"
    ))
    .unwrap();
    let define = |name: &str| -> i64 {
        let needle = format!("#define {name}");
        let line = header
            .lines()
            .find(|line| line.trim_start().starts_with(&needle))
            .unwrap_or_else(|| panic!("missing {name}"));
        let value = line
            .split_whitespace()
            .nth(2)
            .unwrap()
            .trim_end_matches('u');
        value.parse().unwrap()
    };
    assert_eq!(define("LLC_ABI_VERSION"), 1);
    assert_eq!(define("LLC_ERR_CODE_FORMAT"), CoreError::CodeFormat as i64);
    assert_eq!(
        define("LLC_ERR_SUITE_UNSUPPORTED"),
        CoreError::SuiteUnsupported as i64
    );
    assert_eq!(define("LLC_ERR_EXPIRED"), CoreError::Expired as i64);
    assert_eq!(define("LLC_ERR_EXHAUSTED"), CoreError::Exhausted as i64);
    assert_eq!(define("LLC_ERR_BUSY"), CoreError::Busy as i64);
    assert_eq!(define("LLC_ERR_NOT_ACTIVE"), CoreError::NotActive as i64);
    assert_eq!(
        define("LLC_ERR_UNKNOWN_ATTEMPT"),
        CoreError::UnknownAttempt as i64
    );
    assert_eq!(
        define("LLC_ERR_INVALID_PEER_MESSAGE"),
        CoreError::InvalidPeerMessage as i64
    );
    assert_eq!(
        define("LLC_ERR_CONFIRM_MISMATCH"),
        CoreError::ConfirmMismatch as i64
    );
    assert_eq!(
        define("LLC_ERR_TAG_MISMATCH"),
        CoreError::TagMismatch as i64
    );
    assert_eq!(
        define("LLC_ERR_TICKET_MISMATCH"),
        CoreError::TicketMismatch as i64
    );
    assert_eq!(define("LLC_ERR_BAD_STATE"), CoreError::BadState as i64);
    assert_eq!(define("LLC_ERR_RNG"), CoreError::Rng as i64);
    assert_eq!(define("LLC_ERR_TICKET_USED"), CoreError::TicketUsed as i64);
    assert_eq!(
        define("LLC_STATE_WAITING"),
        InviteState::Waiting.as_c() as i64
    );
    assert_eq!(
        define("LLC_STATE_IN_PROGRESS"),
        InviteState::InProgress.as_c() as i64
    );
    assert_eq!(
        define("LLC_STATE_SUCCEEDED"),
        InviteState::Succeeded.as_c() as i64
    );
    assert_eq!(
        define("LLC_STATE_EXHAUSTED"),
        InviteState::Exhausted.as_c() as i64
    );
    assert_eq!(
        define("LLC_STATE_EXPIRED"),
        InviteState::Expired.as_c() as i64
    );
    assert_eq!(
        define("LLC_STATE_CANCELLED"),
        InviteState::Cancelled.as_c() as i64
    );
    assert_eq!(define("LLC_FP_LEN"), 32);
    assert_eq!(define("LLC_TAG_LEN"), 64);
    assert_eq!(define("LLC_TICKET_LEN"), 32);
}

#[cfg(not(feature = "test-rng"))]
#[test]
fn release_version_has_no_testrng_suffix() {
    assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    assert!(!core_version().contains("+testrng"));
}

#[cfg(feature = "test-rng")]
#[test]
fn test_rng_version_has_suffix() {
    assert!(core_version().ends_with("+testrng"));
}

fn suite_list() -> Vec<String> {
    vec![SUITE_NAME.to_string()]
}

fn handshake(
    now: u64,
) -> (
    InviteSender,
    limlink_core::ReceiverAttempt,
    String,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
) {
    let sender = InviteSender::new(now).unwrap();
    let code = sender.code().unwrap();
    assert_eq!(code.len(), 6);
    let receiver = InviteReceiver::new(&code).unwrap();
    let attempt = receiver.begin().unwrap();
    let nonce_r = attempt.nonce_r().unwrap();
    let hello = sender.accept_hello(&nonce_r, suite_list(), now).unwrap();
    let fp_r = vec![0x11u8; 32];
    let fp_s = vec![0x22u8; 32];
    let ya = attempt
        .start(&hello.nonce_s, &hello.suite, &fp_r, &fp_s)
        .unwrap();
    let resp = sender
        .respond_pake(&hello.invite_session_id, &fp_s, &fp_r, &ya, now)
        .unwrap();
    let ta = attempt.finish(&resp.yb, &resp.tb).unwrap();
    (sender, attempt, hello.invite_session_id, ta, fp_r, fp_s)
}

#[test]
fn os_rng_handshake_agrees() {
    let now = 1_700_000_000_000;
    let (sender, attempt, sid, ta, fp_r, fp_s) = handshake(now);
    let confirm = sender.verify_confirm(&sid, &ta, now).unwrap();
    assert_eq!(confirm.peer_fp, fp_r);
    assert_eq!(
        attempt.verify_ticket(&confirm.ticket, &fp_r).unwrap_err(),
        CoreError::TicketMismatch
    );
    attempt.verify_ticket(&confirm.ticket, &fp_s).unwrap();
    assert_eq!(
        attempt.verify_ticket(&confirm.ticket, &fp_s).unwrap_err(),
        CoreError::TicketUsed
    );
    assert_eq!(
        attempt.verify_ticket(&confirm.ticket, &fp_r).unwrap_err(),
        CoreError::TicketMismatch
    );
    let mut other_ticket = confirm.ticket.clone();
    other_ticket[0] ^= 0xff;
    assert_eq!(
        attempt.verify_ticket(&other_ticket, &fp_s).unwrap_err(),
        CoreError::TicketMismatch
    );
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::Succeeded);
    assert_eq!(status.failures, 0);
    assert_eq!(status.attempts_left, MAX_FAILURES - 1);
    assert_eq!(sender.code().unwrap(), "");
    assert_eq!(sender.cancel().unwrap_err(), CoreError::NotActive);
    // The attempt outlives the invite's succeeded state and the confirm timer.
    let later = now + CONFIRM_TIMEOUT_MS;
    assert_eq!(sender.status(later).unwrap().state, InviteState::Succeeded);
    assert_eq!(
        attempt.verify_ticket(&confirm.ticket, &fp_s).unwrap_err(),
        CoreError::TicketUsed
    );
    assert_eq!(
        attempt.verify_ticket(&other_ticket, &fp_s).unwrap_err(),
        CoreError::TicketMismatch
    );
}

#[test]
fn three_confirm_mismatches_exhaust_the_code() {
    let now = 50_000;
    let sender = InviteSender::new(now).unwrap();
    let code = sender.code().unwrap();
    for _ in 0..3 {
        let receiver = InviteReceiver::new(&code).unwrap();
        let attempt = receiver.begin().unwrap();
        let hello = sender
            .accept_hello(&attempt.nonce_r().unwrap(), suite_list(), now)
            .unwrap();
        let fp_r = [0x11u8; 32];
        let fp_s = [0x22u8; 32];
        let ya = attempt
            .start(&hello.nonce_s, &hello.suite, &fp_r, &fp_s)
            .unwrap();
        let resp = sender
            .respond_pake(&hello.invite_session_id, &fp_s, &fp_r, &ya, now)
            .unwrap();
        let _ = attempt.finish(&resp.yb, &resp.tb).unwrap();
        let bad = [0u8; 64];
        assert_eq!(
            sender
                .verify_confirm(&hello.invite_session_id, &bad, now)
                .unwrap_err(),
            CoreError::ConfirmMismatch
        );
    }
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::Exhausted);
    assert_eq!(status.failures, 3);
    assert_eq!(status.attempts_left, 0);
    assert_eq!(status.expires_in_ms, 0);
    assert_eq!(sender.code().unwrap(), "");
}

#[test]
fn expiry_and_confirm_timeout_use_caller_clock() {
    let sender = InviteSender::new(0).unwrap();
    let early = sender.status(INVITE_TTL_MS - 1).unwrap();
    assert_eq!(early.state, InviteState::Waiting);
    assert_eq!(early.expires_in_ms, 1);
    let expired = sender.status(INVITE_TTL_MS).unwrap();
    assert_eq!(expired.state, InviteState::Expired);
    assert_eq!(
        sender
            .accept_hello(&[7u8; 16], suite_list(), INVITE_TTL_MS)
            .unwrap_err(),
        CoreError::Expired
    );

    let now = 1_000u64;
    let (sender, _attempt, sid, ta, _, _) = handshake(now);
    let still = sender.status(now + CONFIRM_TIMEOUT_MS - 1).unwrap();
    assert_eq!(still.state, InviteState::InProgress);
    assert_eq!(still.failures, 0);
    assert_eq!(still.attempts_left, MAX_FAILURES - 1);
    let closed = sender
        .verify_confirm(&sid, &ta, now + CONFIRM_TIMEOUT_MS)
        .unwrap_err();
    assert_eq!(closed, CoreError::UnknownAttempt);
    let after = sender.status(now + CONFIRM_TIMEOUT_MS).unwrap();
    assert_eq!(after.state, InviteState::Waiting);
    assert_eq!(after.failures, 1);
    assert_eq!(after.attempts_left, MAX_FAILURES - 1);
}

#[test]
fn busy_does_not_deduct_and_pending_hellos_drop_the_oldest() {
    let now = 10u64;
    let sender = InviteSender::new(now).unwrap();
    let code = sender.code().unwrap();
    let receiver = InviteReceiver::new(&code).unwrap();
    let attempt = receiver.begin().unwrap();
    let first = sender
        .accept_hello(&attempt.nonce_r().unwrap(), suite_list(), now)
        .unwrap();
    let fp_r = [0x11u8; 32];
    let fp_s = [0x22u8; 32];
    let ya = attempt
        .start(&first.nonce_s, &first.suite, &fp_r, &fp_s)
        .unwrap();
    sender
        .respond_pake(&first.invite_session_id, &fp_s, &fp_r, &ya, now)
        .unwrap();
    let second = sender.accept_hello(&[9u8; 16], suite_list(), now).unwrap();
    assert_eq!(
        sender
            .respond_pake(&second.invite_session_id, &fp_s, &fp_r, &ya, now)
            .unwrap_err(),
        CoreError::Busy
    );
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::InProgress);
    assert_eq!(status.failures, 0);
    assert_eq!(status.attempts_left, MAX_FAILURES - 1);

    let fresh = InviteSender::new(now).unwrap();
    let mut ids = Vec::new();
    for i in 0..9u8 {
        let hello = fresh.accept_hello(&[i; 16], suite_list(), now).unwrap();
        ids.push(hello.invite_session_id);
    }
    assert_eq!(
        fresh.cancel_attempt(&ids[0]).unwrap_err(),
        CoreError::UnknownAttempt
    );
    fresh.cancel_attempt(&ids[1]).unwrap();
    let status = fresh.status(now).unwrap();
    assert_eq!(status.failures, 0);
    assert_eq!(status.attempts_left, MAX_FAILURES);
    assert_eq!(status.state, InviteState::Waiting);
}

#[test]
fn cancel_attempt_and_cancel() {
    let now = 20u64;
    let sender = InviteSender::new(now).unwrap();
    let hello = sender.accept_hello(&[1u8; 16], suite_list(), now).unwrap();
    sender.cancel_attempt(&hello.invite_session_id).unwrap();
    let status = sender.status(now).unwrap();
    assert_eq!(status.failures, 0);
    assert_eq!(status.attempts_left, MAX_FAILURES);

    let (sender, _attempt, sid, _ta, _, _) = handshake(now);
    sender.cancel_attempt(&sid).unwrap();
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::Waiting);
    assert_eq!(status.failures, 1);
    assert_eq!(status.attempts_left, MAX_FAILURES - 1);

    let sender = InviteSender::new(now).unwrap();
    sender.cancel().unwrap();
    sender.cancel().unwrap();
    assert_eq!(sender.code().unwrap(), "");
    assert_eq!(sender.status(now).unwrap().state, InviteState::Cancelled);
    assert_eq!(
        sender
            .accept_hello(&[2u8; 16], suite_list(), now + INVITE_TTL_MS)
            .unwrap_err(),
        CoreError::NotActive
    );
}

#[test]
fn invalid_points_count_as_finished_failures() {
    let now = 30u64;
    let draft = vectors()["cpaceDraftB3"].clone();
    let bad = [
        unhex(draft["invalidYi1"].as_str().unwrap()),
        unhex(draft["invalidYi2"].as_str().unwrap()),
        vec![0u8; 31],
    ];
    let sender = InviteSender::new(now).unwrap();
    for ya in bad {
        let hello = sender.accept_hello(&[4u8; 16], suite_list(), now).unwrap();
        let err = sender
            .respond_pake(
                &hello.invite_session_id,
                &[0x22u8; 32],
                &[0x11u8; 32],
                &ya,
                now,
            )
            .unwrap_err();
        assert_eq!(err, CoreError::InvalidPeerMessage);
    }
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::Exhausted);
    assert_eq!(status.failures, 3);
    assert_eq!(status.attempts_left, 0);
}

#[test]
fn code_and_suite_grammar() {
    assert!(matches!(
        InviteReceiver::new("12345"),
        Err(CoreError::CodeFormat)
    ));
    assert!(matches!(
        InviteReceiver::new("１２３４５６"),
        Err(CoreError::CodeFormat)
    ));
    let sender = InviteSender::new(1).unwrap();
    assert_eq!(
        sender
            .accept_hello(&[1u8; 16], vec!["NOT-A-SUITE".into()], 1)
            .unwrap_err(),
        CoreError::SuiteUnsupported
    );
}

extern "C" {
    fn llc_abi_version() -> u32;
    fn llc_sender_new(now_ms: u64, out: *mut *mut std::ffi::c_void) -> i32;
    fn llc_sender_free(sender: *mut std::ffi::c_void);
    fn llc_sender_accept_hello(
        sender: *mut std::ffi::c_void,
        nonce_r: *const u8,
        nonce_r_len: usize,
        peer_suites: *const u8,
        peer_suites_len: usize,
        now_ms: u64,
        out_session_id: *mut u8,
        out_session_id_len: usize,
        out_nonce_s: *mut u8,
        out_nonce_s_len: usize,
        out_suite: *mut u8,
        out_suite_len: usize,
    ) -> i32;
}

#[test]
fn c_abi_null_out_does_not_require_a_buffer() {
    assert_eq!(unsafe { llc_abi_version() }, 1);
    let status = unsafe { llc_sender_new(0, std::ptr::null_mut()) };
    assert_eq!(status, 100);
}

#[test]
fn c_abi_rejects_overlong_and_malformed_peer_suites() {
    let mut sender = std::ptr::null_mut();
    assert_eq!(unsafe { llc_sender_new(0, &mut sender) }, 0);
    let nonce = [1u8; 16];
    let mut session = [0xABu8; 23];
    let mut nonce_s = [0xABu8; 16];
    let mut suite = [0xABu8; 64];
    let too_long = vec![b'A'; 256];
    let status = unsafe {
        llc_sender_accept_hello(
            sender,
            nonce.as_ptr(),
            nonce.len(),
            too_long.as_ptr(),
            too_long.len(),
            0,
            session.as_mut_ptr(),
            session.len(),
            nonce_s.as_mut_ptr(),
            nonce_s.len(),
            suite.as_mut_ptr(),
            suite.len(),
        )
    };
    assert_eq!(status, CoreError::SuiteUnsupported as i32);
    assert_eq!(session, [0u8; 23]);

    let bad = format!("{SUITE_NAME}, ");
    session = [0xABu8; 23];
    let status = unsafe {
        llc_sender_accept_hello(
            sender,
            nonce.as_ptr(),
            nonce.len(),
            bad.as_ptr(),
            bad.len(),
            0,
            session.as_mut_ptr(),
            session.len(),
            nonce_s.as_mut_ptr(),
            nonce_s.len(),
            suite.as_mut_ptr(),
            suite.len(),
        )
    };
    assert_eq!(status, CoreError::SuiteUnsupported as i32);
    unsafe { llc_sender_free(sender) };
}
