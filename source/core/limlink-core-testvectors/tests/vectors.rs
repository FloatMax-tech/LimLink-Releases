//! Scripted invite vectors and the `llct_*` C ABI.

use limlink_core::{
    CoreError, InviteReceiver, InviteSender, InviteState, MAX_FAILURES, SUITE_NAME,
};
use limlink_core_testvectors::{
    llc_attempt, llc_receiver, llc_sender, llct_abi_version, llct_attempt_finish,
    llct_attempt_free, llct_attempt_nonce_r, llct_attempt_start, llct_attempt_suites,
    llct_attempt_verify_ticket, llct_core_info, llct_receiver_begin, llct_receiver_free,
    llct_receiver_new, llct_sender_accept_hello, llct_sender_code, llct_sender_free,
    llct_sender_new, llct_sender_respond_pake, llct_sender_verify_confirm,
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

fn strings(value: &serde_json::Value) -> Vec<String> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn limlink_rows_match_the_python_reference() {
    for case in vectors()["limlink"].as_array().unwrap() {
        let now = case["nowMs"].as_u64().unwrap();
        let sender = InviteSender::new_with_rng_script(
            now,
            &unhex(case["rngScriptSender"].as_str().unwrap()),
        )
        .unwrap();
        assert_eq!(sender.code().unwrap(), case["code"].as_str().unwrap());
        let receiver = InviteReceiver::new_with_rng_script(
            case["receiverCode"].as_str().unwrap(),
            &unhex(case["rngScriptReceiver"].as_str().unwrap()),
        )
        .unwrap();
        let attempt = receiver.begin().unwrap();
        let nonce_r = attempt.nonce_r().unwrap();
        assert_eq!(hx(&nonce_r), case["nonceR"].as_str().unwrap());
        assert_eq!(attempt.suites().unwrap(), strings(&case["receiverSuites"]));
        let hello = sender
            .accept_hello(&nonce_r, strings(&case["peerSuites"]), now)
            .unwrap();
        assert_eq!(hello.invite_session_id, case["sessionId"].as_str().unwrap());
        assert_eq!(hx(&hello.nonce_s), case["nonceS"].as_str().unwrap());
        assert_eq!(hello.suite, case["selectedSuite"].as_str().unwrap());
        let fp_r = unhex(case["fpReceiver"].as_str().unwrap());
        let fp_s = unhex(case["fpSender"].as_str().unwrap());
        let fp_peer = unhex(case["receiverFpPeer"].as_str().unwrap());
        let ya = attempt
            .start(&hello.nonce_s, &hello.suite, &fp_r, &fp_peer)
            .unwrap();
        assert_eq!(hx(&ya), case["ya"].as_str().unwrap(), "{}", case["name"]);
        let resp = sender
            .respond_pake(&hello.invite_session_id, &fp_s, &fp_r, &ya, now)
            .unwrap();
        assert_eq!(
            hx(&resp.yb),
            case["yb"].as_str().unwrap(),
            "{}",
            case["name"]
        );
        assert_eq!(
            hx(&resp.tb),
            case["tb"].as_str().unwrap(),
            "{}",
            case["name"]
        );
        let finished = attempt.finish(&resp.yb, &resp.tb);
        if case["result"].as_str() == Some("ok") {
            let ta = finished.unwrap();
            assert_eq!(hx(&ta), case["ta"].as_str().unwrap());
            let confirm = sender
                .verify_confirm(&hello.invite_session_id, &ta, now)
                .unwrap();
            assert_eq!(hx(&confirm.ticket), case["ticket"].as_str().unwrap());
            assert_eq!(confirm.peer_fp, fp_r);
            attempt.verify_ticket(&confirm.ticket, &fp_s).unwrap();
            let status = sender.status(now).unwrap();
            assert_eq!(status.state, InviteState::Succeeded);
        } else {
            assert_eq!(finished.unwrap_err(), CoreError::TagMismatch);
            assert_eq!(case["result"].as_str(), Some("tagMismatch"));
        }
    }
}

#[test]
fn rng_failure_before_yb_rolls_the_deduction_back() {
    let now = 80u64;
    // code sample + nonceS + session id, and no 64-byte scalar.
    let mut script = vec![0u8; 4 + 16 + 16];
    script[2] = 1;
    let sender = InviteSender::new_with_rng_script(now, &script).unwrap();
    let hello = sender
        .accept_hello(&[3u8; 16], vec![SUITE_NAME.to_string()], now)
        .unwrap();
    // Draft B.3 Ya is a valid non-identity point, so the failure is the
    // missing scalar rather than point decoding.
    let ya = unhex("d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157");
    let err = sender
        .respond_pake(&hello.invite_session_id, &[0x22; 32], &[0x11; 32], &ya, now)
        .unwrap_err();
    assert_eq!(err, CoreError::Rng);
    let status = sender.status(now).unwrap();
    assert_eq!(status.state, InviteState::Waiting);
    assert_eq!(status.failures, 0);
    assert_eq!(status.attempts_left, MAX_FAILURES);
    let again = sender
        .respond_pake(&hello.invite_session_id, &[0x22; 32], &[0x11; 32], &ya, now)
        .unwrap_err();
    assert_eq!(again, CoreError::Rng);
    assert_eq!(sender.status(now).unwrap().attempts_left, MAX_FAILURES);
}

#[test]
fn empty_script_fails_when_the_code_is_drawn() {
    assert!(matches!(
        InviteSender::new_with_rng_script(1, &[]),
        Err(CoreError::Rng)
    ));
}

#[test]
fn c_abi_happy_path_and_short_buffer() {
    let case = &vectors()["limlink"][0];
    assert_eq!(case["name"].as_str(), Some("happy-path"));
    assert_eq!(llct_abi_version(), 1);

    let mut version = [0u8; 64];
    let mut suites = [0u8; 256];
    let info = unsafe {
        llct_core_info(
            version.as_mut_ptr().cast(),
            version.len(),
            suites.as_mut_ptr().cast(),
            suites.len(),
        )
    };
    assert_eq!(info, 0);
    let version = cstr(&version);
    assert!(version.ends_with("+testrng"), "{version}");
    assert_eq!(cstr(&suites), SUITE_NAME);

    let script = unhex(case["rngScriptSender"].as_str().unwrap());
    let mut sender: *mut llc_sender = std::ptr::null_mut();
    let rc = unsafe {
        llct_sender_new(
            case["nowMs"].as_u64().unwrap(),
            script.as_ptr(),
            script.len(),
            &mut sender,
        )
    };
    assert_eq!(rc, 0);
    assert!(!sender.is_null());

    let mut code_buf = [0xABu8; 7];
    let rc = unsafe { llct_sender_code(sender, code_buf.as_mut_ptr().cast(), 6) };
    assert_eq!(rc, 101);
    assert_eq!(code_buf, [0xAB; 7]);

    let mut code_buf = [0u8; 7];
    let rc = unsafe { llct_sender_code(sender, code_buf.as_mut_ptr().cast(), code_buf.len()) };
    assert_eq!(rc, 0);
    assert_eq!(cstr(&code_buf), case["code"].as_str().unwrap());

    let null = unsafe { llct_sender_new(0, std::ptr::null(), 0, std::ptr::null_mut()) };
    assert_eq!(null, 100);

    let recv_script = unhex(case["rngScriptReceiver"].as_str().unwrap());
    let code = case["receiverCode"].as_str().unwrap().as_bytes();
    let mut receiver: *mut llc_receiver = std::ptr::null_mut();
    let rc = unsafe {
        llct_receiver_new(
            code.as_ptr(),
            code.len(),
            recv_script.as_ptr(),
            recv_script.len(),
            &mut receiver,
        )
    };
    assert_eq!(rc, 0);
    let mut attempt: *mut llc_attempt = std::ptr::null_mut();
    assert_eq!(unsafe { llct_receiver_begin(receiver, &mut attempt) }, 0);
    let mut nonce_r = [0u8; 16];
    assert_eq!(
        unsafe { llct_attempt_nonce_r(attempt, nonce_r.as_mut_ptr(), nonce_r.len()) },
        0
    );
    let mut suite_buf = [0u8; 256];
    assert_eq!(
        unsafe { llct_attempt_suites(attempt, suite_buf.as_mut_ptr().cast(), suite_buf.len()) },
        0
    );
    assert_eq!(cstr(&suite_buf), SUITE_NAME);

    let peer = SUITE_NAME.as_bytes();
    let mut session = [0u8; 23];
    let mut nonce_s = [0u8; 16];
    let mut suite = [0u8; 64];
    let now = case["nowMs"].as_u64().unwrap();
    let rc = unsafe {
        llct_sender_accept_hello(
            sender,
            nonce_r.as_ptr(),
            nonce_r.len(),
            peer.as_ptr().cast(),
            peer.len(),
            now,
            session.as_mut_ptr().cast(),
            session.len(),
            nonce_s.as_mut_ptr(),
            nonce_s.len(),
            suite.as_mut_ptr().cast(),
            suite.len(),
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(cstr(&session), case["sessionId"].as_str().unwrap());
    assert_eq!(hx(&nonce_s), case["nonceS"].as_str().unwrap());

    let fp_r = unhex(case["fpReceiver"].as_str().unwrap());
    let fp_s = unhex(case["fpSender"].as_str().unwrap());
    let mut ya = [0u8; 32];
    let rc = unsafe {
        llct_attempt_start(
            attempt,
            nonce_s.as_ptr(),
            nonce_s.len(),
            suite.as_ptr().cast(),
            cstr(&suite).len(),
            fp_r.as_ptr(),
            fp_r.len(),
            fp_s.as_ptr(),
            fp_s.len(),
            ya.as_mut_ptr(),
            ya.len(),
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(hx(&ya), case["ya"].as_str().unwrap());

    let sid = case["sessionId"].as_str().unwrap();
    let mut yb = [0u8; 32];
    let mut tb = [0u8; 64];
    let rc = unsafe {
        llct_sender_respond_pake(
            sender,
            sid.as_ptr().cast(),
            sid.len(),
            fp_s.as_ptr(),
            fp_s.len(),
            fp_r.as_ptr(),
            fp_r.len(),
            ya.as_ptr(),
            ya.len(),
            now,
            yb.as_mut_ptr(),
            yb.len(),
            tb.as_mut_ptr(),
            tb.len(),
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(hx(&yb), case["yb"].as_str().unwrap());
    assert_eq!(hx(&tb), case["tb"].as_str().unwrap());

    let mut ta = [0u8; 64];
    let rc = unsafe {
        llct_attempt_finish(
            attempt,
            yb.as_ptr(),
            yb.len(),
            tb.as_ptr(),
            tb.len(),
            ta.as_mut_ptr(),
            ta.len(),
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(hx(&ta), case["ta"].as_str().unwrap());

    let mut ticket = [0u8; 32];
    let mut peer_fp = [0u8; 32];
    let rc = unsafe {
        llct_sender_verify_confirm(
            sender,
            sid.as_ptr().cast(),
            sid.len(),
            ta.as_ptr(),
            ta.len(),
            now,
            ticket.as_mut_ptr(),
            ticket.len(),
            peer_fp.as_mut_ptr(),
            peer_fp.len(),
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(hx(&ticket), case["ticket"].as_str().unwrap());
    assert_eq!(peer_fp.as_slice(), fp_r.as_slice());
    let rc = unsafe {
        llct_attempt_verify_ticket(
            attempt,
            ticket.as_ptr(),
            ticket.len(),
            fp_s.as_ptr(),
            fp_s.len(),
        )
    };
    assert_eq!(rc, 0);

    unsafe {
        llct_attempt_free(attempt);
        llct_receiver_free(receiver);
        llct_sender_free(sender);
        llct_sender_free(std::ptr::null_mut());
    }
}

fn cstr(buf: &[u8]) -> &str {
    let end = buf.iter().position(|b| *b == 0).unwrap();
    std::str::from_utf8(&buf[..end]).unwrap()
}
