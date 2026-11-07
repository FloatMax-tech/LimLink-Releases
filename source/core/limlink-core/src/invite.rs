use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

use crate::b64::b64url_encode;
use crate::confirm::ct_eq;
use crate::error::CoreError;
use crate::pake::{self, InitiatorPending};
use crate::rng::{self, RngSource};
use crate::suite::{self, SUITE_NAME};

pub const INVITE_TTL_MS: u64 = 10 * 60 * 1000;
pub const CONFIRM_TIMEOUT_MS: u64 = 30 * 1000;
pub const MAX_FAILURES: u32 = 3;
pub const MAX_PENDING_HELLOS: usize = 8;

pub const FP_LEN: usize = 32;
pub const NONCE_LEN: usize = 16;
pub const POINT_LEN: usize = 32;
pub const TAG_LEN: usize = 64;
pub const TICKET_LEN: usize = 32;
pub const CODE_LEN: usize = 6;
pub const SESSION_ID_LEN: usize = 22;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InviteState {
    Waiting,
    InProgress,
    Succeeded,
    Exhausted,
    Expired,
    Cancelled,
}

impl InviteState {
    pub const fn as_c(self) -> i32 {
        match self {
            InviteState::Waiting => 0,
            InviteState::InProgress => 1,
            InviteState::Succeeded => 2,
            InviteState::Exhausted => 3,
            InviteState::Expired => 4,
            InviteState::Cancelled => 5,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteStatus {
    pub state: InviteState,
    pub failures: u32,
    pub attempts_left: u32,
    pub expires_in_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelloAccepted {
    pub invite_session_id: String,
    pub nonce_s: Vec<u8>,
    pub suite: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PakeResponse {
    pub yb: Vec<u8>,
    pub tb: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ConfirmResult {
    pub ticket: Vec<u8>,
    pub peer_fp: Vec<u8>,
}

impl std::fmt::Debug for ConfirmResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConfirmResult")
            .field("ticket", &"[redacted]")
            .field("peer_fp", &self.peer_fp)
            .finish()
    }
}

struct HelloSlot {
    id_text: String,
    nonce_s: [u8; NONCE_LEN],
    nonce_r: [u8; NONCE_LEN],
    peer_suites: Vec<String>,
}

#[derive(Zeroize)]
struct ActiveSecrets {
    expected_ta: [u8; TAG_LEN],
    ticket: [u8; TICKET_LEN],
}

struct ActivePake {
    id_text: String,
    secrets: Zeroizing<ActiveSecrets>,
    fp_peer: [u8; FP_LEN],
    started_ms: u64,
}

struct SenderInner {
    created_ms: u64,
    code: Zeroizing<[u8; CODE_LEN]>,
    code_live: bool,
    state: InviteState,
    failures: u32,
    deducted: u32,
    hellos: VecDeque<HelloSlot>,
    active: Option<ActivePake>,
    rng: RngSource,
}

/// Sender showing the invite code. CPace responder. Methods take `&self`
/// and serialize on an internal lock so a later UniFFI binding can wrap
/// the type without changing it.
pub struct InviteSender {
    inner: Mutex<SenderInner>,
    poisoned: std::sync::atomic::AtomicBool,
}

impl InviteSender {
    pub fn new(now_ms: u64) -> Result<Self, CoreError> {
        Self::from_rng(now_ms, RngSource::os())
    }

    /// Test-build constructor. `script` is consumed in call order:
    /// code (4-byte rejection samples), then each `accept_hello` draws
    /// 16-byte `nonceS` and 16-byte session id, then each `respond_pake`
    /// draws a 64-byte CPace scalar.
    #[cfg(feature = "test-rng")]
    pub fn new_with_rng_script(now_ms: u64, script: &[u8]) -> Result<Self, CoreError> {
        Self::from_rng(now_ms, RngSource::script(script.to_vec()))
    }

    fn from_rng(now_ms: u64, mut rng: RngSource) -> Result<Self, CoreError> {
        let code = rng::draw_code(&mut rng)?;
        Ok(Self {
            inner: Mutex::new(SenderInner {
                created_ms: now_ms,
                code: Zeroizing::new(code),
                code_live: true,
                state: InviteState::Waiting,
                failures: 0,
                deducted: 0,
                hellos: VecDeque::new(),
                active: None,
                rng,
            }),
            poisoned: std::sync::atomic::AtomicBool::new(false),
        })
    }

    pub(crate) fn mark_poisoned(&self) {
        self.poisoned
            .store(true, std::sync::atomic::Ordering::Release);
    }

    fn lock(&self) -> Result<MutexGuard<'_, SenderInner>, CoreError> {
        if self.poisoned.load(std::sync::atomic::Ordering::Acquire) {
            return Err(CoreError::BadState);
        }
        self.inner.lock().map_err(|_| {
            self.mark_poisoned();
            CoreError::BadState
        })
    }

    pub fn code(&self) -> Result<String, CoreError> {
        let g = self.lock()?;
        if g.code_live {
            Ok(String::from_utf8(g.code.to_vec()).unwrap_or_default())
        } else {
            Ok(String::new())
        }
    }

    pub fn status(&self, now_ms: u64) -> Result<InviteStatus, CoreError> {
        let mut g = self.lock()?;
        g.refresh(now_ms);
        Ok(g.snapshot(now_ms))
    }

    pub fn accept_hello(
        &self,
        nonce_r: &[u8],
        peer_suites: Vec<String>,
        now_ms: u64,
    ) -> Result<HelloAccepted, CoreError> {
        let mut g = self.lock()?;
        g.refresh(now_ms);
        g.ensure_open()?;
        if nonce_r.len() != NONCE_LEN {
            return Err(CoreError::InvalidPeerMessage);
        }
        let suites = suite::parse_suite_list(&peer_suites)?;
        let mut nonce_s = [0u8; NONCE_LEN];
        let mut raw_id = [0u8; NONCE_LEN];
        g.rng.fill(&mut nonce_s)?;
        g.rng.fill(&mut raw_id)?;
        let id_text = b64url_encode(&raw_id);
        debug_assert_eq!(id_text.len(), SESSION_ID_LEN);
        if g.hellos.len() >= MAX_PENDING_HELLOS {
            g.hellos.pop_front();
        }
        let mut nonce_r_arr = [0u8; NONCE_LEN];
        nonce_r_arr.copy_from_slice(nonce_r);
        g.hellos.push_back(HelloSlot {
            id_text: id_text.clone(),
            nonce_s,
            nonce_r: nonce_r_arr,
            peer_suites: suites,
        });
        Ok(HelloAccepted {
            invite_session_id: id_text,
            nonce_s: nonce_s.to_vec(),
            suite: SUITE_NAME.to_string(),
        })
    }

    pub fn respond_pake(
        &self,
        invite_session_id: &str,
        fp_self: &[u8],
        fp_peer: &[u8],
        ya: &[u8],
        now_ms: u64,
    ) -> Result<PakeResponse, CoreError> {
        let mut g = self.lock()?;
        g.refresh(now_ms);
        g.ensure_open()?;
        if g.state == InviteState::InProgress {
            return Err(CoreError::Busy);
        }
        let idx = g
            .hellos
            .iter()
            .position(|h| h.id_text == invite_session_id)
            .ok_or(CoreError::UnknownAttempt)?;
        if g.deducted >= MAX_FAILURES {
            g.enter_terminal(InviteState::Exhausted);
            return Err(CoreError::Exhausted);
        }
        g.deducted = g.deducted.saturating_add(1);
        let hello = g.hellos.remove(idx).expect("index was present");
        if ya.len() != POINT_LEN || fp_self.len() != FP_LEN || fp_peer.len() != FP_LEN {
            g.fail_finished();
            return Err(CoreError::InvalidPeerMessage);
        }
        let joined = suite::join_suites(&hello.peer_suites);
        let ci = suite::channel_id(fp_peer, fp_self);
        let sid = suite::session_sid(&hello.nonce_r, &hello.nonce_s);
        let ada = suite::ada(&joined);
        let adb = suite::adb(SUITE_NAME);
        let code = Zeroizing::new(*g.code);
        let computed = pake::respond(&mut g.rng, code.as_slice(), &ci, &sid, &ada, &adb, ya);
        match computed {
            Err(CoreError::Rng) => {
                g.deducted = g.deducted.saturating_sub(1);
                g.hellos.insert(idx, hello);
                Err(CoreError::Rng)
            }
            Err(err) => {
                g.fail_finished();
                Err(err)
            }
            Ok(out) => {
                let mut fp_peer_arr = [0u8; FP_LEN];
                fp_peer_arr.copy_from_slice(fp_peer);
                g.active = Some(ActivePake {
                    id_text: hello.id_text,
                    secrets: Zeroizing::new(ActiveSecrets {
                        expected_ta: out.expected_ta,
                        ticket: out.ticket,
                    }),
                    fp_peer: fp_peer_arr,
                    started_ms: now_ms,
                });
                g.state = InviteState::InProgress;
                Ok(PakeResponse {
                    yb: out.yb.to_vec(),
                    tb: out.tb.to_vec(),
                })
            }
        }
    }

    pub fn verify_confirm(
        &self,
        invite_session_id: &str,
        ta: &[u8],
        now_ms: u64,
    ) -> Result<ConfirmResult, CoreError> {
        let mut g = self.lock()?;
        g.refresh(now_ms);
        match g.state {
            InviteState::Succeeded | InviteState::Cancelled => return Err(CoreError::NotActive),
            InviteState::Exhausted => return Err(CoreError::Exhausted),
            InviteState::Expired => return Err(CoreError::Expired),
            InviteState::Waiting => return Err(CoreError::UnknownAttempt),
            InviteState::InProgress => {}
        }
        let active_id = g
            .active
            .as_ref()
            .map(|a| a.id_text.clone())
            .ok_or(CoreError::UnknownAttempt)?;
        if active_id != invite_session_id {
            return Err(CoreError::UnknownAttempt);
        }
        if ta.len() != TAG_LEN {
            g.fail_finished();
            return Err(CoreError::InvalidPeerMessage);
        }
        let expected = g
            .active
            .as_ref()
            .map(|a| a.secrets.expected_ta)
            .ok_or(CoreError::UnknownAttempt)?;
        if !ct_eq(ta, &expected) {
            g.fail_finished();
            return Err(CoreError::ConfirmMismatch);
        }
        let active = g.active.take().ok_or(CoreError::UnknownAttempt)?;
        let ticket = active.secrets.ticket;
        let peer_fp = active.fp_peer;
        g.enter_terminal(InviteState::Succeeded);
        Ok(ConfirmResult {
            ticket: ticket.to_vec(),
            peer_fp: peer_fp.to_vec(),
        })
    }

    pub fn cancel_attempt(&self, invite_session_id: &str) -> Result<(), CoreError> {
        let mut g = self.lock()?;
        match g.state {
            InviteState::Succeeded | InviteState::Cancelled => return Err(CoreError::NotActive),
            InviteState::Exhausted => return Err(CoreError::Exhausted),
            InviteState::Expired => return Err(CoreError::Expired),
            InviteState::Waiting | InviteState::InProgress => {}
        }
        if g.active
            .as_ref()
            .is_some_and(|a| a.id_text == invite_session_id)
        {
            g.fail_finished();
            return Ok(());
        }
        if let Some(idx) = g.hellos.iter().position(|h| h.id_text == invite_session_id) {
            g.hellos.remove(idx);
            return Ok(());
        }
        Err(CoreError::UnknownAttempt)
    }

    pub fn cancel(&self) -> Result<(), CoreError> {
        let mut g = self.lock()?;
        match g.state {
            InviteState::Cancelled => Ok(()),
            InviteState::Succeeded | InviteState::Exhausted | InviteState::Expired => {
                Err(CoreError::NotActive)
            }
            InviteState::Waiting | InviteState::InProgress => {
                g.enter_terminal(InviteState::Cancelled);
                Ok(())
            }
        }
    }
}

impl SenderInner {
    fn refresh(&mut self, now_ms: u64) {
        if self.is_terminal() {
            return;
        }
        if now_ms.saturating_sub(self.created_ms) >= INVITE_TTL_MS {
            self.enter_terminal(InviteState::Expired);
            return;
        }
        if self.state == InviteState::InProgress {
            let timed_out = self
                .active
                .as_ref()
                .is_some_and(|a| now_ms.saturating_sub(a.started_ms) >= CONFIRM_TIMEOUT_MS);
            if timed_out {
                self.fail_finished();
            }
        }
    }

    fn is_terminal(&self) -> bool {
        matches!(
            self.state,
            InviteState::Succeeded
                | InviteState::Exhausted
                | InviteState::Expired
                | InviteState::Cancelled
        )
    }

    fn ensure_open(&self) -> Result<(), CoreError> {
        match self.state {
            InviteState::Succeeded | InviteState::Cancelled => Err(CoreError::NotActive),
            InviteState::Exhausted => Err(CoreError::Exhausted),
            InviteState::Expired => Err(CoreError::Expired),
            InviteState::Waiting | InviteState::InProgress => Ok(()),
        }
    }

    fn fail_finished(&mut self) {
        self.active = None;
        self.failures = self.failures.saturating_add(1);
        if self.failures >= MAX_FAILURES || self.deducted >= MAX_FAILURES {
            self.enter_terminal(InviteState::Exhausted);
        } else {
            self.state = InviteState::Waiting;
        }
    }

    fn enter_terminal(&mut self, state: InviteState) {
        self.state = state;
        self.code.zeroize();
        self.code_live = false;
        self.hellos.clear();
        self.active = None;
    }

    fn snapshot(&self, now_ms: u64) -> InviteStatus {
        let expires_in_ms = if self.is_terminal() {
            0
        } else {
            INVITE_TTL_MS.saturating_sub(now_ms.saturating_sub(self.created_ms))
        };
        InviteStatus {
            state: self.state,
            failures: self.failures,
            attempts_left: MAX_FAILURES.saturating_sub(self.deducted),
            expires_in_ms,
        }
    }
}

struct ReceiverInner {
    code: Zeroizing<[u8; CODE_LEN]>,
    rng: RngSource,
}

enum AttemptPhase {
    Fresh,
    Started {
        pending: InitiatorPending,
        fp_peer: [u8; FP_LEN],
    },
    Finished {
        ticket: [u8; TICKET_LEN],
        fp_peer: [u8; FP_LEN],
        /// Set after the first successful `verify_ticket`. A later call
        /// with the same ticket and fingerprint returns `TicketUsed`.
        consumed: bool,
    },
    Failed,
}

struct AttemptLocal {
    nonce_r: [u8; NONCE_LEN],
    phase: AttemptPhase,
}

/// Receiver that was given an invite code. Shared with each attempt via `Arc`.
pub struct InviteReceiver {
    inner: Arc<Mutex<ReceiverInner>>,
    poisoned: Arc<std::sync::atomic::AtomicBool>,
}

/// One handshake against one candidate sender.
pub struct ReceiverAttempt {
    shared: Arc<Mutex<ReceiverInner>>,
    shared_poison: Arc<std::sync::atomic::AtomicBool>,
    local: Mutex<AttemptLocal>,
    poisoned: std::sync::atomic::AtomicBool,
}

impl InviteReceiver {
    pub fn new(code: &str) -> Result<Self, CoreError> {
        Self::from_rng(code, RngSource::os())
    }

    #[cfg(feature = "test-rng")]
    pub fn new_with_rng_script(code: &str, script: &[u8]) -> Result<Self, CoreError> {
        Self::from_rng(code, RngSource::script(script.to_vec()))
    }

    fn from_rng(code: &str, rng: RngSource) -> Result<Self, CoreError> {
        let digits = parse_code(code)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(ReceiverInner {
                code: Zeroizing::new(digits),
                rng,
            })),
            poisoned: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    pub(crate) fn mark_poisoned(&self) {
        self.poisoned
            .store(true, std::sync::atomic::Ordering::Release);
    }

    pub fn begin(&self) -> Result<ReceiverAttempt, CoreError> {
        if self.poisoned.load(std::sync::atomic::Ordering::Acquire) {
            return Err(CoreError::BadState);
        }
        let mut g = self.inner.lock().map_err(|_| {
            self.mark_poisoned();
            CoreError::BadState
        })?;
        let mut nonce_r = [0u8; NONCE_LEN];
        g.rng.fill(&mut nonce_r)?;
        Ok(ReceiverAttempt {
            shared: Arc::clone(&self.inner),
            shared_poison: Arc::clone(&self.poisoned),
            local: Mutex::new(AttemptLocal {
                nonce_r,
                phase: AttemptPhase::Fresh,
            }),
            poisoned: std::sync::atomic::AtomicBool::new(false),
        })
    }
}

impl ReceiverAttempt {
    pub(crate) fn mark_poisoned(&self) {
        self.poisoned
            .store(true, std::sync::atomic::Ordering::Release);
        self.shared_poison
            .store(true, std::sync::atomic::Ordering::Release);
    }

    fn lock_local(&self) -> Result<MutexGuard<'_, AttemptLocal>, CoreError> {
        if self.poisoned.load(std::sync::atomic::Ordering::Acquire)
            || self
                .shared_poison
                .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(CoreError::BadState);
        }
        self.local.lock().map_err(|_| {
            self.mark_poisoned();
            CoreError::BadState
        })
    }

    pub fn nonce_r(&self) -> Result<Vec<u8>, CoreError> {
        let g = self.lock_local()?;
        Ok(g.nonce_r.to_vec())
    }

    pub fn suites(&self) -> Result<Vec<String>, CoreError> {
        let _g = self.lock_local()?;
        Ok(suite::receiver_suites())
    }

    pub fn start(
        &self,
        nonce_s: &[u8],
        suite: &str,
        fp_self: &[u8],
        fp_peer: &[u8],
    ) -> Result<Vec<u8>, CoreError> {
        let mut local = self.lock_local()?;
        if !matches!(local.phase, AttemptPhase::Fresh) {
            return Err(CoreError::BadState);
        }
        if nonce_s.len() != NONCE_LEN || fp_self.len() != FP_LEN || fp_peer.len() != FP_LEN {
            return Err(CoreError::InvalidPeerMessage);
        }
        suite::parse_selected_suite(suite)?;
        if self
            .shared_poison
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(CoreError::BadState);
        }
        let mut shared = self.shared.lock().map_err(|_| {
            self.mark_poisoned();
            CoreError::BadState
        })?;
        let mut nonce_s_arr = [0u8; NONCE_LEN];
        nonce_s_arr.copy_from_slice(nonce_s);
        let sid = suite::session_sid(&local.nonce_r, &nonce_s_arr);
        let joined = suite::join_suites(&suite::receiver_suites());
        let ci = suite::channel_id(fp_self, fp_peer);
        let ada = suite::ada(&joined);
        let adb = suite::adb(SUITE_NAME);
        let code = Zeroizing::new(*shared.code);
        let (ya, pending) =
            pake::initiate(&mut shared.rng, code.as_slice(), &ci, &sid, &ada, &adb)?;
        let mut fp_peer_arr = [0u8; FP_LEN];
        fp_peer_arr.copy_from_slice(fp_peer);
        local.phase = AttemptPhase::Started {
            pending,
            fp_peer: fp_peer_arr,
        };
        Ok(ya.to_vec())
    }

    pub fn finish(&self, yb: &[u8], tb: &[u8]) -> Result<Vec<u8>, CoreError> {
        let mut local = self.lock_local()?;
        let (pending, fp_peer) = match std::mem::replace(&mut local.phase, AttemptPhase::Failed) {
            AttemptPhase::Started { pending, fp_peer } => (pending, fp_peer),
            other => {
                local.phase = other;
                return Err(CoreError::BadState);
            }
        };
        match pending.finish(yb, tb) {
            Ok(done) => {
                let ta = done.ta;
                local.phase = AttemptPhase::Finished {
                    ticket: done.ticket,
                    fp_peer,
                    consumed: false,
                };
                Ok(ta.to_vec())
            }
            Err(err) => Err(err),
        }
    }

    /// Compare `ticket` and `fp_client` with the pair stored at `finish`.
    ///
    /// Platforms keep the attempt until the first session ends. After a
    /// successful finish this keeps returning `Ok`, `TicketUsed`, or
    /// `TicketMismatch` even when the sender invite is already `succeeded`
    /// and even after the 30s confirm window. It does not become
    /// `BadState` or `UnknownAttempt` for that reason. Dropping the attempt
    /// is the end of the check; the core keeps nothing after that.
    /// A mismatch does not consume the ticket.
    pub fn verify_ticket(&self, ticket: &[u8], fp_client: &[u8]) -> Result<(), CoreError> {
        let mut local = self.lock_local()?;
        match &mut local.phase {
            AttemptPhase::Finished {
                ticket: expect,
                fp_peer,
                consumed,
            } => {
                if ticket.len() != TICKET_LEN || fp_client.len() != FP_LEN {
                    return Err(CoreError::TicketMismatch);
                }
                let ok_t: subtle::Choice = expect.ct_eq(ticket);
                let ok_f: subtle::Choice = fp_peer.ct_eq(fp_client);
                let both = bool::from(ok_t & ok_f);
                // A mismatch does not consume the ticket. After a success,
                // the same pair is TicketUsed; any other pair is TicketMismatch.
                if *consumed {
                    if both {
                        Err(CoreError::TicketUsed)
                    } else {
                        Err(CoreError::TicketMismatch)
                    }
                } else if both {
                    *consumed = true;
                    Ok(())
                } else {
                    Err(CoreError::TicketMismatch)
                }
            }
            _ => Err(CoreError::BadState),
        }
    }
}

fn parse_code(code: &str) -> Result<[u8; CODE_LEN], CoreError> {
    let bytes = code.as_bytes();
    if bytes.len() != CODE_LEN || !bytes.iter().all(|b| b.is_ascii_digit()) {
        return Err(CoreError::CodeFormat);
    }
    let mut out = [0u8; CODE_LEN];
    out.copy_from_slice(bytes);
    Ok(out)
}
