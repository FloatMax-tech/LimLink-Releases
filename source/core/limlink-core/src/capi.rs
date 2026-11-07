//! C ABI glue. Production exports are `llc_*` (feature `c-api`).
//! The testvectors crate calls the same functions and exports `llct_*`.
#![allow(clippy::missing_safety_doc, clippy::too_many_arguments)]

use std::panic::{catch_unwind, AssertUnwindSafe};

#[cfg(feature = "test-rng")]
use zeroize::Zeroizing;

use crate::error::CoreError;
use crate::invite::{
    InviteReceiver, InviteSender, CODE_LEN, FP_LEN, NONCE_LEN, POINT_LEN, SESSION_ID_LEN, TAG_LEN,
    TICKET_LEN,
};
use crate::ABI_VERSION;

pub const LLC_OK: i32 = 0;
pub const LLC_ERR_NULL_ARG: i32 = 100;
pub const LLC_ERR_BUFFER_LEN: i32 = 101;
pub const LLC_ERR_PANIC: i32 = 102;
pub const RNG_SCRIPT_MAX: usize = 65_536;

pub const CODE_BUF_LEN: usize = 7;
pub const SESSION_ID_BUF_LEN: usize = 23;
pub const SUITE_BUF_LEN: usize = 64;
pub const SUITES_BUF_LEN: usize = 256;
pub const VERSION_BUF_LEN: usize = 64;

#[repr(C)]
#[allow(non_camel_case_types)]
pub struct llc_invite_status {
    pub state: i32,
    pub failures: u32,
    pub attempts_left: u32,
    pub reserved: u32,
    pub expires_in_ms: u64,
}

const _: () = assert!(core::mem::size_of::<llc_invite_status>() == 24);

#[allow(non_camel_case_types)]
pub struct llc_sender {
    inner: InviteSender,
}
#[allow(non_camel_case_types)]
pub struct llc_receiver {
    inner: InviteReceiver,
}
#[allow(non_camel_case_types)]
pub struct llc_attempt {
    inner: crate::invite::ReceiverAttempt,
}

unsafe fn wipe(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        std::ptr::write_bytes(ptr, 0, len);
    }
}

unsafe fn write_text(dst: *mut u8, dst_len: usize, text: &str) -> i32 {
    let bytes = text.as_bytes();
    if dst.is_null() || dst_len < bytes.len() + 1 {
        return LLC_ERR_BUFFER_LEN;
    }
    wipe(dst, dst_len);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), dst, bytes.len());
    LLC_OK
}

unsafe fn write_exact(dst: *mut u8, dst_len: usize, src: &[u8]) -> i32 {
    if dst.is_null() || dst_len != src.len() {
        return LLC_ERR_BUFFER_LEN;
    }
    std::ptr::copy_nonoverlapping(src.as_ptr(), dst, src.len());
    LLC_OK
}

unsafe fn read_exact<'a>(ptr: *const u8, len: usize, expect: usize) -> Result<&'a [u8], i32> {
    if ptr.is_null() {
        return Err(LLC_ERR_NULL_ARG);
    }
    if len != expect {
        return Err(LLC_ERR_BUFFER_LEN);
    }
    Ok(std::slice::from_raw_parts(ptr, len))
}

unsafe fn read_text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    if len == 0 {
        return Ok("");
    }
    if ptr.is_null() {
        return Err(LLC_ERR_NULL_ARG);
    }
    let bytes = std::slice::from_raw_parts(ptr, len);
    std::str::from_utf8(bytes).map_err(|_| CoreError::SuiteUnsupported.as_status())
}

#[cfg(feature = "test-rng")]
unsafe fn read_script(ptr: *const u8, len: usize) -> Result<Zeroizing<Vec<u8>>, i32> {
    if len > RNG_SCRIPT_MAX {
        return Err(LLC_ERR_BUFFER_LEN);
    }
    if len == 0 {
        return Ok(Zeroizing::new(Vec::new()));
    }
    if ptr.is_null() {
        return Err(LLC_ERR_NULL_ARG);
    }
    Ok(Zeroizing::new(
        std::slice::from_raw_parts(ptr, len).to_vec(),
    ))
}

fn status_of(err: CoreError) -> i32 {
    err.as_status()
}

pub fn abi_version() -> u32 {
    catch_unwind(|| ABI_VERSION).unwrap_or(0)
}

/// Every `extern "C"` export must call one of these and do nothing else.
/// `LLC_ERR_PANIC` is only reachable while the profile keeps `panic = "unwind"`.
pub fn export_status(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(LLC_ERR_PANIC)
}

pub fn export_unit(body: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(body));
}

pub fn export_u32(body: impl FnOnce() -> u32) -> u32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(0)
}

struct PoisonSender(*mut llc_sender);
struct PoisonReceiver(*mut llc_receiver);
struct PoisonAttempt(*mut llc_attempt);

impl Drop for PoisonSender {
    fn drop(&mut self) {
        if std::thread::panicking() && !self.0.is_null() {
            unsafe { (*self.0).inner.mark_poisoned() }
        }
    }
}

impl Drop for PoisonReceiver {
    fn drop(&mut self) {
        if std::thread::panicking() && !self.0.is_null() {
            unsafe { (*self.0).inner.mark_poisoned() }
        }
    }
}

impl Drop for PoisonAttempt {
    fn drop(&mut self) {
        if std::thread::panicking() && !self.0.is_null() {
            unsafe { (*self.0).inner.mark_poisoned() }
        }
    }
}

/// Run `body` inside [`export_status`]. A panic poisons `sender` when it is non-null.
pub unsafe fn export_sender(sender: *mut llc_sender, body: impl FnOnce() -> i32) -> i32 {
    export_status(|| {
        let _poison = PoisonSender(sender);
        body()
    })
}

pub unsafe fn export_receiver(receiver: *mut llc_receiver, body: impl FnOnce() -> i32) -> i32 {
    export_status(|| {
        let _poison = PoisonReceiver(receiver);
        body()
    })
}

pub unsafe fn export_attempt(attempt: *mut llc_attempt, body: impl FnOnce() -> i32) -> i32 {
    export_status(|| {
        let _poison = PoisonAttempt(attempt);
        body()
    })
}

pub unsafe fn core_info(
    out_version: *mut u8,
    out_version_len: usize,
    out_suites: *mut u8,
    out_suites_len: usize,
) -> i32 {
    if out_version.is_null() || out_suites.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if out_version_len < VERSION_BUF_LEN || out_suites_len < SUITES_BUF_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    match catch_unwind(crate::core_info) {
        Ok(info) => {
            let suites = info.suites.join(",");
            if write_text(out_version, out_version_len, &info.version) != LLC_OK
                || write_text(out_suites, out_suites_len, &suites) != LLC_OK
            {
                wipe(out_version, out_version_len);
                wipe(out_suites, out_suites_len);
                return LLC_ERR_BUFFER_LEN;
            }
            LLC_OK
        }
        Err(_) => {
            wipe(out_version, out_version_len);
            wipe(out_suites, out_suites_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_new(now_ms: u64, out: *mut *mut llc_sender) -> i32 {
    if out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    *out = std::ptr::null_mut();
    match catch_unwind(AssertUnwindSafe(|| InviteSender::new(now_ms))) {
        Ok(Ok(sender)) => {
            *out = Box::into_raw(Box::new(llc_sender { inner: sender }));
            LLC_OK
        }
        Ok(Err(err)) => status_of(err),
        Err(_) => LLC_ERR_PANIC,
    }
}

#[cfg(feature = "test-rng")]
pub unsafe fn sender_new_script(
    now_ms: u64,
    script: *const u8,
    script_len: usize,
    out: *mut *mut llc_sender,
) -> i32 {
    if out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    *out = std::ptr::null_mut();
    let script = match read_script(script, script_len) {
        Ok(script) => script,
        Err(code) => return code,
    };
    match catch_unwind(AssertUnwindSafe(|| {
        InviteSender::new_with_rng_script(now_ms, &script)
    })) {
        Ok(Ok(sender)) => {
            *out = Box::into_raw(Box::new(llc_sender { inner: sender }));
            LLC_OK
        }
        Ok(Err(err)) => status_of(err),
        Err(_) => LLC_ERR_PANIC,
    }
}

pub unsafe fn sender_free(sender: *mut llc_sender) {
    if sender.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(sender));
    }));
}

pub unsafe fn sender_code(sender: *mut llc_sender, out: *mut u8, out_len: usize) -> i32 {
    if sender.is_null() || out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if out_len < CODE_BUF_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let sender = &*sender;
    match catch_unwind(AssertUnwindSafe(|| sender.inner.code())) {
        Ok(Ok(text)) => write_text(out, out_len, &text),
        Ok(Err(err)) => {
            wipe(out, out_len);
            status_of(err)
        }
        Err(_) => {
            sender.inner.mark_poisoned();
            wipe(out, out_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_status(
    sender: *mut llc_sender,
    now_ms: u64,
    out: *mut llc_invite_status,
) -> i32 {
    if sender.is_null() || out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    let sender = &*sender;
    match catch_unwind(AssertUnwindSafe(|| sender.inner.status(now_ms))) {
        Ok(Ok(status)) => {
            *out = llc_invite_status {
                state: status.state.as_c(),
                failures: status.failures,
                attempts_left: status.attempts_left,
                reserved: 0,
                expires_in_ms: status.expires_in_ms,
            };
            LLC_OK
        }
        Ok(Err(err)) => {
            wipe(out as *mut u8, core::mem::size_of::<llc_invite_status>());
            status_of(err)
        }
        Err(_) => {
            sender.inner.mark_poisoned();
            wipe(out as *mut u8, core::mem::size_of::<llc_invite_status>());
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_accept_hello(
    sender: *mut llc_sender,
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
) -> i32 {
    if sender.is_null()
        || nonce_r.is_null()
        || out_session_id.is_null()
        || out_nonce_s.is_null()
        || out_suite.is_null()
    {
        return LLC_ERR_NULL_ARG;
    }
    if nonce_r_len != NONCE_LEN
        || out_session_id_len < SESSION_ID_BUF_LEN
        || out_nonce_s_len != NONCE_LEN
        || out_suite_len < SUITE_BUF_LEN
    {
        return LLC_ERR_BUFFER_LEN;
    }
    if peer_suites_len > 0 && peer_suites.is_null() {
        wipe_hello(
            out_session_id,
            out_session_id_len,
            out_nonce_s,
            out_nonce_s_len,
            out_suite,
            out_suite_len,
        );
        return LLC_ERR_NULL_ARG;
    }
    // Reject an over-long list before it is split into tokens.
    if peer_suites_len > crate::suite::MAX_SUITES_JOINED {
        wipe_hello(
            out_session_id,
            out_session_id_len,
            out_nonce_s,
            out_nonce_s_len,
            out_suite,
            out_suite_len,
        );
        return CoreError::SuiteUnsupported.as_status();
    }
    let suites = match read_text(peer_suites, peer_suites_len) {
        Ok(text) => text,
        Err(code) => {
            wipe_hello(
                out_session_id,
                out_session_id_len,
                out_nonce_s,
                out_nonce_s_len,
                out_suite,
                out_suite_len,
            );
            return code;
        }
    };
    let nonce = match read_exact(nonce_r, nonce_r_len, NONCE_LEN) {
        Ok(bytes) => bytes,
        Err(code) => return code,
    };
    let sender = &*sender;
    let parsed = crate::suite::parse_suite_csv(suites).map(|list| (nonce.to_vec(), list));
    let result = catch_unwind(AssertUnwindSafe(|| {
        let (nonce, list) = parsed?;
        sender.inner.accept_hello(&nonce, list, now_ms)
    }));
    match result {
        Ok(Ok(hello)) => {
            let id = write_text(out_session_id, out_session_id_len, &hello.invite_session_id);
            let ns = write_exact(out_nonce_s, out_nonce_s_len, &hello.nonce_s);
            let suite = write_text(out_suite, out_suite_len, &hello.suite);
            if id != LLC_OK || ns != LLC_OK || suite != LLC_OK {
                wipe_hello(
                    out_session_id,
                    out_session_id_len,
                    out_nonce_s,
                    out_nonce_s_len,
                    out_suite,
                    out_suite_len,
                );
                LLC_ERR_BUFFER_LEN
            } else {
                LLC_OK
            }
        }
        Ok(Err(err)) => {
            wipe_hello(
                out_session_id,
                out_session_id_len,
                out_nonce_s,
                out_nonce_s_len,
                out_suite,
                out_suite_len,
            );
            status_of(err)
        }
        Err(_) => {
            sender.inner.mark_poisoned();
            wipe_hello(
                out_session_id,
                out_session_id_len,
                out_nonce_s,
                out_nonce_s_len,
                out_suite,
                out_suite_len,
            );
            LLC_ERR_PANIC
        }
    }
}

unsafe fn wipe_hello(
    out_session_id: *mut u8,
    out_session_id_len: usize,
    out_nonce_s: *mut u8,
    out_nonce_s_len: usize,
    out_suite: *mut u8,
    out_suite_len: usize,
) {
    wipe(out_session_id, out_session_id_len);
    wipe(out_nonce_s, out_nonce_s_len);
    wipe(out_suite, out_suite_len);
}

pub unsafe fn sender_respond_pake(
    sender: *mut llc_sender,
    session_id: *const u8,
    session_id_len: usize,
    fp_self: *const u8,
    fp_self_len: usize,
    fp_peer: *const u8,
    fp_peer_len: usize,
    ya: *const u8,
    ya_len: usize,
    now_ms: u64,
    out_yb: *mut u8,
    out_yb_len: usize,
    out_tb: *mut u8,
    out_tb_len: usize,
) -> i32 {
    if sender.is_null()
        || session_id.is_null()
        || fp_self.is_null()
        || fp_peer.is_null()
        || ya.is_null()
        || out_yb.is_null()
        || out_tb.is_null()
    {
        return LLC_ERR_NULL_ARG;
    }
    if session_id_len != SESSION_ID_LEN
        || fp_self_len != FP_LEN
        || fp_peer_len != FP_LEN
        || ya_len != POINT_LEN
        || out_yb_len != POINT_LEN
        || out_tb_len != TAG_LEN
    {
        return LLC_ERR_BUFFER_LEN;
    }
    let sid = match std::str::from_utf8(std::slice::from_raw_parts(session_id, session_id_len)) {
        Ok(text) => text.to_string(),
        Err(_) => {
            wipe(out_yb, out_yb_len);
            wipe(out_tb, out_tb_len);
            return CoreError::UnknownAttempt.as_status();
        }
    };
    let fp_self = std::slice::from_raw_parts(fp_self, fp_self_len).to_vec();
    let fp_peer = std::slice::from_raw_parts(fp_peer, fp_peer_len).to_vec();
    let ya = std::slice::from_raw_parts(ya, ya_len).to_vec();
    let sender = &*sender;
    let result = catch_unwind(AssertUnwindSafe(|| {
        sender
            .inner
            .respond_pake(&sid, &fp_self, &fp_peer, &ya, now_ms)
    }));
    match result {
        Ok(Ok(resp)) => {
            let yb = write_exact(out_yb, out_yb_len, &resp.yb);
            let tb = write_exact(out_tb, out_tb_len, &resp.tb);
            if yb != LLC_OK || tb != LLC_OK {
                wipe(out_yb, out_yb_len);
                wipe(out_tb, out_tb_len);
                LLC_ERR_BUFFER_LEN
            } else {
                LLC_OK
            }
        }
        Ok(Err(err)) => {
            wipe(out_yb, out_yb_len);
            wipe(out_tb, out_tb_len);
            status_of(err)
        }
        Err(_) => {
            sender.inner.mark_poisoned();
            wipe(out_yb, out_yb_len);
            wipe(out_tb, out_tb_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_verify_confirm(
    sender: *mut llc_sender,
    session_id: *const u8,
    session_id_len: usize,
    ta: *const u8,
    ta_len: usize,
    now_ms: u64,
    out_ticket: *mut u8,
    out_ticket_len: usize,
    out_peer_fp: *mut u8,
    out_peer_fp_len: usize,
) -> i32 {
    if sender.is_null()
        || session_id.is_null()
        || ta.is_null()
        || out_ticket.is_null()
        || out_peer_fp.is_null()
    {
        return LLC_ERR_NULL_ARG;
    }
    if session_id_len != SESSION_ID_LEN
        || ta_len != TAG_LEN
        || out_ticket_len != TICKET_LEN
        || out_peer_fp_len != FP_LEN
    {
        return LLC_ERR_BUFFER_LEN;
    }
    let sid = match std::str::from_utf8(std::slice::from_raw_parts(session_id, session_id_len)) {
        Ok(text) => text.to_string(),
        Err(_) => {
            wipe(out_ticket, out_ticket_len);
            wipe(out_peer_fp, out_peer_fp_len);
            return CoreError::UnknownAttempt.as_status();
        }
    };
    let ta = std::slice::from_raw_parts(ta, ta_len).to_vec();
    let sender = &*sender;
    let result = catch_unwind(AssertUnwindSafe(|| {
        sender.inner.verify_confirm(&sid, &ta, now_ms)
    }));
    match result {
        Ok(Ok(done)) => {
            let t = write_exact(out_ticket, out_ticket_len, &done.ticket);
            let fp = write_exact(out_peer_fp, out_peer_fp_len, &done.peer_fp);
            if t != LLC_OK || fp != LLC_OK {
                wipe(out_ticket, out_ticket_len);
                wipe(out_peer_fp, out_peer_fp_len);
                LLC_ERR_BUFFER_LEN
            } else {
                LLC_OK
            }
        }
        Ok(Err(err)) => {
            wipe(out_ticket, out_ticket_len);
            wipe(out_peer_fp, out_peer_fp_len);
            status_of(err)
        }
        Err(_) => {
            sender.inner.mark_poisoned();
            wipe(out_ticket, out_ticket_len);
            wipe(out_peer_fp, out_peer_fp_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_cancel_attempt(
    sender: *mut llc_sender,
    session_id: *const u8,
    session_id_len: usize,
) -> i32 {
    if sender.is_null() || session_id.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if session_id_len != SESSION_ID_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let sid = match std::str::from_utf8(std::slice::from_raw_parts(session_id, session_id_len)) {
        Ok(text) => text.to_string(),
        Err(_) => return CoreError::UnknownAttempt.as_status(),
    };
    let sender = &*sender;
    match catch_unwind(AssertUnwindSafe(|| sender.inner.cancel_attempt(&sid))) {
        Ok(Ok(())) => LLC_OK,
        Ok(Err(err)) => status_of(err),
        Err(_) => {
            sender.inner.mark_poisoned();
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn sender_cancel(sender: *mut llc_sender) -> i32 {
    if sender.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    let sender = &*sender;
    match catch_unwind(AssertUnwindSafe(|| sender.inner.cancel())) {
        Ok(Ok(())) => LLC_OK,
        Ok(Err(err)) => status_of(err),
        Err(_) => {
            sender.inner.mark_poisoned();
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn receiver_new(code: *const u8, code_len: usize, out: *mut *mut llc_receiver) -> i32 {
    if out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    *out = std::ptr::null_mut();
    if code.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if code_len != CODE_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let bytes = std::slice::from_raw_parts(code, code_len);
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => return CoreError::CodeFormat.as_status(),
    };
    match catch_unwind(AssertUnwindSafe(|| InviteReceiver::new(&text))) {
        Ok(Ok(receiver)) => {
            *out = Box::into_raw(Box::new(llc_receiver { inner: receiver }));
            LLC_OK
        }
        Ok(Err(err)) => status_of(err),
        Err(_) => LLC_ERR_PANIC,
    }
}

#[cfg(feature = "test-rng")]
pub unsafe fn receiver_new_script(
    code: *const u8,
    code_len: usize,
    script: *const u8,
    script_len: usize,
    out: *mut *mut llc_receiver,
) -> i32 {
    if out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    *out = std::ptr::null_mut();
    if code.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if code_len != CODE_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let script = match read_script(script, script_len) {
        Ok(script) => script,
        Err(code) => return code,
    };
    let bytes = std::slice::from_raw_parts(code, code_len);
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => return CoreError::CodeFormat.as_status(),
    };
    match catch_unwind(AssertUnwindSafe(|| {
        InviteReceiver::new_with_rng_script(&text, &script)
    })) {
        Ok(Ok(receiver)) => {
            *out = Box::into_raw(Box::new(llc_receiver { inner: receiver }));
            LLC_OK
        }
        Ok(Err(err)) => status_of(err),
        Err(_) => LLC_ERR_PANIC,
    }
}

pub unsafe fn receiver_free(receiver: *mut llc_receiver) {
    if receiver.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(receiver));
    }));
}

pub unsafe fn receiver_begin(receiver: *mut llc_receiver, out: *mut *mut llc_attempt) -> i32 {
    if receiver.is_null() || out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    *out = std::ptr::null_mut();
    let receiver = &*receiver;
    match catch_unwind(AssertUnwindSafe(|| receiver.inner.begin())) {
        Ok(Ok(attempt)) => {
            *out = Box::into_raw(Box::new(llc_attempt { inner: attempt }));
            LLC_OK
        }
        Ok(Err(err)) => status_of(err),
        Err(_) => {
            receiver.inner.mark_poisoned();
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn attempt_free(attempt: *mut llc_attempt) {
    if attempt.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(attempt));
    }));
}

pub unsafe fn attempt_nonce_r(attempt: *mut llc_attempt, out: *mut u8, out_len: usize) -> i32 {
    if attempt.is_null() || out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if out_len != NONCE_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let attempt = &*attempt;
    match catch_unwind(AssertUnwindSafe(|| attempt.inner.nonce_r())) {
        Ok(Ok(nonce)) => write_exact(out, out_len, &nonce),
        Ok(Err(err)) => {
            wipe(out, out_len);
            status_of(err)
        }
        Err(_) => {
            attempt.inner.mark_poisoned();
            wipe(out, out_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn attempt_suites(attempt: *mut llc_attempt, out: *mut u8, out_len: usize) -> i32 {
    if attempt.is_null() || out.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if out_len < SUITES_BUF_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let attempt = &*attempt;
    match catch_unwind(AssertUnwindSafe(|| attempt.inner.suites())) {
        Ok(Ok(list)) => write_text(out, out_len, &list.join(",")),
        Ok(Err(err)) => {
            wipe(out, out_len);
            status_of(err)
        }
        Err(_) => {
            attempt.inner.mark_poisoned();
            wipe(out, out_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn attempt_start(
    attempt: *mut llc_attempt,
    nonce_s: *const u8,
    nonce_s_len: usize,
    suite: *const u8,
    suite_len: usize,
    fp_self: *const u8,
    fp_self_len: usize,
    fp_peer: *const u8,
    fp_peer_len: usize,
    out_ya: *mut u8,
    out_ya_len: usize,
) -> i32 {
    if attempt.is_null()
        || nonce_s.is_null()
        || suite.is_null()
        || fp_self.is_null()
        || fp_peer.is_null()
        || out_ya.is_null()
    {
        return LLC_ERR_NULL_ARG;
    }
    if nonce_s_len != NONCE_LEN
        || fp_self_len != FP_LEN
        || fp_peer_len != FP_LEN
        || out_ya_len != POINT_LEN
    {
        return LLC_ERR_BUFFER_LEN;
    }
    let suite = match read_text(suite, suite_len) {
        Ok(text) => text.to_string(),
        Err(code) => {
            wipe(out_ya, out_ya_len);
            return code;
        }
    };
    let nonce_s = std::slice::from_raw_parts(nonce_s, nonce_s_len).to_vec();
    let fp_self = std::slice::from_raw_parts(fp_self, fp_self_len).to_vec();
    let fp_peer = std::slice::from_raw_parts(fp_peer, fp_peer_len).to_vec();
    let attempt = &*attempt;
    let result = catch_unwind(AssertUnwindSafe(|| {
        attempt.inner.start(&nonce_s, &suite, &fp_self, &fp_peer)
    }));
    match result {
        Ok(Ok(ya)) => write_exact(out_ya, out_ya_len, &ya),
        Ok(Err(err)) => {
            wipe(out_ya, out_ya_len);
            status_of(err)
        }
        Err(_) => {
            attempt.inner.mark_poisoned();
            wipe(out_ya, out_ya_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn attempt_finish(
    attempt: *mut llc_attempt,
    yb: *const u8,
    yb_len: usize,
    tb: *const u8,
    tb_len: usize,
    out_ta: *mut u8,
    out_ta_len: usize,
) -> i32 {
    if attempt.is_null() || yb.is_null() || tb.is_null() || out_ta.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if yb_len != POINT_LEN || tb_len != TAG_LEN || out_ta_len != TAG_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let yb = std::slice::from_raw_parts(yb, yb_len).to_vec();
    let tb = std::slice::from_raw_parts(tb, tb_len).to_vec();
    let attempt = &*attempt;
    let result = catch_unwind(AssertUnwindSafe(|| attempt.inner.finish(&yb, &tb)));
    match result {
        Ok(Ok(ta)) => write_exact(out_ta, out_ta_len, &ta),
        Ok(Err(err)) => {
            wipe(out_ta, out_ta_len);
            status_of(err)
        }
        Err(_) => {
            attempt.inner.mark_poisoned();
            wipe(out_ta, out_ta_len);
            LLC_ERR_PANIC
        }
    }
}

pub unsafe fn attempt_verify_ticket(
    attempt: *mut llc_attempt,
    ticket: *const u8,
    ticket_len: usize,
    fp_client: *const u8,
    fp_client_len: usize,
) -> i32 {
    if attempt.is_null() || ticket.is_null() || fp_client.is_null() {
        return LLC_ERR_NULL_ARG;
    }
    if ticket_len != TICKET_LEN || fp_client_len != FP_LEN {
        return LLC_ERR_BUFFER_LEN;
    }
    let ticket = std::slice::from_raw_parts(ticket, ticket_len).to_vec();
    let fp_client = std::slice::from_raw_parts(fp_client, fp_client_len).to_vec();
    let attempt = &*attempt;
    match catch_unwind(AssertUnwindSafe(|| {
        attempt.inner.verify_ticket(&ticket, &fp_client)
    })) {
        Ok(Ok(())) => LLC_OK,
        Ok(Err(err)) => status_of(err),
        Err(_) => {
            attempt.inner.mark_poisoned();
            LLC_ERR_PANIC
        }
    }
}

include!("llc_exports.inc.rs");

#[cfg(feature = "c-api")]
mod export {
    define_llc_exports!();
}
