//! Replay `stateMachine` rows from the vector file against the real core.
//! `nowMs` on each step is the only clock. Every platform can do the same.

use limlink_core::{
    CoreError, InviteReceiver, InviteSender, InviteState, ReceiverAttempt, SUITE_NAME,
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

fn error_name(err: CoreError) -> &'static str {
    match err {
        CoreError::CodeFormat => "codeFormat",
        CoreError::SuiteUnsupported => "suiteUnsupported",
        CoreError::Expired => "expired",
        CoreError::Exhausted => "exhausted",
        CoreError::Busy => "busy",
        CoreError::NotActive => "notActive",
        CoreError::UnknownAttempt => "unknownAttempt",
        CoreError::InvalidPeerMessage => "invalidPeerMessage",
        CoreError::ConfirmMismatch => "confirmMismatch",
        CoreError::TagMismatch => "tagMismatch",
        CoreError::TicketMismatch => "ticketMismatch",
        CoreError::BadState => "badState",
        CoreError::Rng => "rng",
        CoreError::TicketUsed => "ticketUsed",
    }
}

fn state_name(state: InviteState) -> &'static str {
    match state {
        InviteState::Waiting => "waiting",
        InviteState::InProgress => "in_progress",
        InviteState::Succeeded => "succeeded",
        InviteState::Exhausted => "exhausted",
        InviteState::Expired => "expired",
        InviteState::Cancelled => "cancelled",
    }
}

fn assert_result<T>(actual: Result<T, CoreError>, expected: &str, ctx: &str) -> Option<T> {
    match (expected, actual) {
        ("ok", Ok(value)) => Some(value),
        ("ok", Err(err)) => panic!("{ctx}: expected ok, got {}", error_name(err)),
        (_, Ok(_)) => panic!("{ctx}: expected {expected}, got ok"),
        (_, Err(err)) => {
            assert_eq!(error_name(err), expected, "{ctx}");
            None
        }
    }
}

struct Replay {
    rng_script: Vec<u8>,
    sender: Option<InviteSender>,
    receiver: Option<InviteReceiver>,
    attempt: Option<ReceiverAttempt>,
    session_id: String,
    nonce_s: Vec<u8>,
    ya: Vec<u8>,
    yb: Vec<u8>,
    tb: Vec<u8>,
    last_ta: Vec<u8>,
    suite: String,
    fp_r: Vec<u8>,
    fp_s: Vec<u8>,
}

impl Replay {
    fn sender(&self) -> &InviteSender {
        self.sender.as_ref().expect("senderNew")
    }

    fn play(&mut self, step: &serde_json::Value, ctx: &str) {
        let op = step["op"].as_str().unwrap();
        let expected = step["result"].as_str().unwrap();
        match op {
            "senderNew" => {
                let now = step["nowMs"].as_u64().unwrap();
                let sender = InviteSender::new_with_rng_script(now, &self.rng_script).unwrap();
                assert_eq!(expected, "ok", "{ctx}");
                self.sender = Some(sender);
            }
            "code" => {
                let code = self.sender().code().unwrap();
                assert_eq!(expected, "ok", "{ctx}");
                assert_eq!(code, step["code"].as_str().unwrap(), "{ctx}");
            }
            "status" => {
                let now = step["nowMs"].as_u64().unwrap();
                let status = self.sender().status(now).unwrap();
                assert_eq!(expected, "ok", "{ctx}");
                assert_eq!(
                    state_name(status.state),
                    step["state"].as_str().unwrap(),
                    "{ctx}"
                );
                assert_eq!(
                    status.failures,
                    step["failures"].as_u64().unwrap() as u32,
                    "{ctx}"
                );
                assert_eq!(
                    status.attempts_left,
                    step["attemptsLeft"].as_u64().unwrap() as u32,
                    "{ctx}"
                );
                assert_eq!(
                    status.expires_in_ms,
                    step["expiresInMs"].as_u64().unwrap(),
                    "{ctx}"
                );
            }
            "receiverNew" => {
                let code = self.sender().code().unwrap();
                let script = unhex(step["rngScript"].as_str().unwrap());
                let receiver = InviteReceiver::new_with_rng_script(&code, &script).unwrap();
                assert_eq!(expected, "ok", "{ctx}");
                self.receiver = Some(receiver);
                self.attempt = None;
            }
            "begin" => {
                let attempt = self.receiver.as_ref().unwrap().begin().unwrap();
                assert_eq!(expected, "ok", "{ctx}");
                assert_eq!(
                    hx(&attempt.nonce_r().unwrap()),
                    step["nonceR"].as_str().unwrap(),
                    "{ctx}"
                );
                self.attempt = Some(attempt);
            }
            "acceptHello" => {
                let now = step["nowMs"].as_u64().unwrap();
                let suites: Vec<String> = step["peerSuites"]
                    .as_str()
                    .unwrap()
                    .split(',')
                    .map(str::to_string)
                    .collect();
                let nonce_r = match step.get("nonceR").and_then(|value| value.as_str()) {
                    Some(text) => unhex(text),
                    None => vec![0u8; 16],
                };
                let accepted = self.sender().accept_hello(&nonce_r, suites, now);
                if let Some(hello) = assert_result(accepted, expected, ctx) {
                    assert_eq!(
                        hello.invite_session_id,
                        step["sessionId"].as_str().unwrap(),
                        "{ctx}"
                    );
                    assert_eq!(
                        hx(&hello.nonce_s),
                        step["nonceS"].as_str().unwrap(),
                        "{ctx}"
                    );
                    assert_eq!(hello.suite, step["suite"].as_str().unwrap(), "{ctx}");
                    assert_eq!(hello.suite, SUITE_NAME);
                    self.session_id = hello.invite_session_id;
                    self.nonce_s = hello.nonce_s;
                    self.suite = hello.suite;
                }
            }
            "start" => {
                let ya = self.attempt.as_ref().unwrap().start(
                    &self.nonce_s,
                    &self.suite,
                    &self.fp_r,
                    &self.fp_s,
                );
                if let Some(ya) = assert_result(ya, expected, ctx) {
                    assert_eq!(hx(&ya), step["ya"].as_str().unwrap(), "{ctx}");
                    self.ya = ya;
                }
            }
            "respondPake" => {
                let now = step["nowMs"].as_u64().unwrap();
                let ya = if self.ya.is_empty() {
                    vec![0u8; 32]
                } else {
                    self.ya.clone()
                };
                let resp =
                    self.sender()
                        .respond_pake(&self.session_id, &self.fp_s, &self.fp_r, &ya, now);
                if let Some(resp) = assert_result(resp, expected, ctx) {
                    assert_eq!(hx(&resp.yb), step["yb"].as_str().unwrap(), "{ctx}");
                    assert_eq!(hx(&resp.tb), step["tb"].as_str().unwrap(), "{ctx}");
                    self.yb = resp.yb;
                    self.tb = resp.tb;
                }
            }
            "finish" => {
                let ta = self.attempt.as_ref().unwrap().finish(&self.yb, &self.tb);
                if let Some(ta) = assert_result(ta, expected, ctx) {
                    assert_eq!(hx(&ta), step["ta"].as_str().unwrap(), "{ctx}");
                    self.last_ta = ta;
                }
            }
            "verifyConfirm" => {
                let now = step["nowMs"].as_u64().unwrap();
                let presented = presented_ta(step, expected, &self.last_ta);
                let confirm = self
                    .sender()
                    .verify_confirm(&self.session_id, &presented, now);
                if let Some(confirm) = assert_result(confirm, expected, ctx) {
                    assert_eq!(
                        hx(&confirm.ticket),
                        step["ticket"].as_str().unwrap(),
                        "{ctx}"
                    );
                    assert_eq!(
                        hx(&confirm.peer_fp),
                        step["peerFp"].as_str().unwrap(),
                        "{ctx}"
                    );
                }
            }
            "verifyTicket" => {
                let ticket = unhex(step["ticket"].as_str().unwrap());
                let fp = unhex(step["fp"].as_str().unwrap());
                let result = self.attempt.as_ref().unwrap().verify_ticket(&ticket, &fp);
                assert_result(result, expected, ctx);
            }
            "cancelAttempt" => {
                let result = self.sender().cancel_attempt(&self.session_id);
                assert_result(result, expected, ctx);
            }
            "cancel" => {
                let result = self.sender().cancel();
                assert_result(result, expected, ctx);
            }
            other => panic!("{ctx}: unknown op {other}"),
        }
    }
}

/// Success steps carry Ta. These cases use 64 zero bytes for a mismatch.
/// A timeout step omits Ta; the driver passed the tag from `finish`.
fn presented_ta(step: &serde_json::Value, expected: &str, last_ta: &[u8]) -> Vec<u8> {
    if let Some(text) = step.get("ta").and_then(|value| value.as_str()) {
        return unhex(text);
    }
    if expected == "confirmMismatch" {
        return vec![0u8; 64];
    }
    last_ta.to_vec()
}

#[test]
fn state_machine_vectors_replay_on_the_core() {
    let doc = vectors();
    let cases = doc["stateMachine"].as_array().expect("stateMachine");
    assert!(cases.len() >= 7);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let mut replay = Replay {
            rng_script: unhex(case["rngScriptSender"].as_str().unwrap()),
            sender: None,
            receiver: None,
            attempt: None,
            session_id: String::new(),
            nonce_s: Vec::new(),
            ya: Vec::new(),
            yb: Vec::new(),
            tb: Vec::new(),
            last_ta: Vec::new(),
            suite: String::new(),
            fp_r: unhex(case["fpReceiver"].as_str().unwrap()),
            fp_s: unhex(case["fpSender"].as_str().unwrap()),
        };
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            replay.play(step, &format!("{name} step {index} {}", step["op"]));
        }
    }
}
