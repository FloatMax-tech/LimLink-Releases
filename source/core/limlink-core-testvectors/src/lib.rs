//! Test-only C ABI (`llct_*`). Release builds of this crate fail because
//! `limlink-core`'s `test-rng` feature is refused without debug assertions.
//!
//! Each export's body is only `capi::export_*`, so argument decoding inside
//! the callee is inside `catch_unwind`.

#![allow(clippy::missing_safety_doc, clippy::too_many_arguments)]

use limlink_core::capi;
pub use limlink_core::capi::{llc_attempt, llc_invite_status, llc_receiver, llc_sender};

#[no_mangle]
pub extern "C" fn llct_abi_version() -> u32 {
    capi::export_u32(capi::abi_version)
}

#[no_mangle]
pub unsafe extern "C" fn llct_core_info(
    out_version: *mut std::ffi::c_char,
    out_version_len: usize,
    out_suites: *mut std::ffi::c_char,
    out_suites_len: usize,
) -> i32 {
    capi::export_status(|| {
        capi::core_info(
            out_version.cast(),
            out_version_len,
            out_suites.cast(),
            out_suites_len,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_new(
    now_ms: u64,
    rng_script: *const u8,
    rng_script_len: usize,
    out: *mut *mut llc_sender,
) -> i32 {
    capi::export_status(|| capi::sender_new_script(now_ms, rng_script, rng_script_len, out))
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_free(sender: *mut llc_sender) {
    capi::export_unit(|| capi::sender_free(sender));
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_code(
    sender: *mut llc_sender,
    out: *mut std::ffi::c_char,
    out_len: usize,
) -> i32 {
    capi::export_sender(sender, || capi::sender_code(sender, out.cast(), out_len))
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_status(
    sender: *mut llc_sender,
    now_ms: u64,
    out: *mut llc_invite_status,
) -> i32 {
    capi::export_sender(sender, || capi::sender_status(sender, now_ms, out))
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_accept_hello(
    sender: *mut llc_sender,
    nonce_r: *const u8,
    nonce_r_len: usize,
    peer_suites: *const std::ffi::c_char,
    peer_suites_len: usize,
    now_ms: u64,
    out_session_id: *mut std::ffi::c_char,
    out_session_id_len: usize,
    out_nonce_s: *mut u8,
    out_nonce_s_len: usize,
    out_suite: *mut std::ffi::c_char,
    out_suite_len: usize,
) -> i32 {
    capi::export_sender(sender, || {
        capi::sender_accept_hello(
            sender,
            nonce_r,
            nonce_r_len,
            peer_suites.cast(),
            peer_suites_len,
            now_ms,
            out_session_id.cast(),
            out_session_id_len,
            out_nonce_s,
            out_nonce_s_len,
            out_suite.cast(),
            out_suite_len,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_respond_pake(
    sender: *mut llc_sender,
    session_id: *const std::ffi::c_char,
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
    capi::export_sender(sender, || {
        capi::sender_respond_pake(
            sender,
            session_id.cast(),
            session_id_len,
            fp_self,
            fp_self_len,
            fp_peer,
            fp_peer_len,
            ya,
            ya_len,
            now_ms,
            out_yb,
            out_yb_len,
            out_tb,
            out_tb_len,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_verify_confirm(
    sender: *mut llc_sender,
    session_id: *const std::ffi::c_char,
    session_id_len: usize,
    ta: *const u8,
    ta_len: usize,
    now_ms: u64,
    out_ticket: *mut u8,
    out_ticket_len: usize,
    out_peer_fp: *mut u8,
    out_peer_fp_len: usize,
) -> i32 {
    capi::export_sender(sender, || {
        capi::sender_verify_confirm(
            sender,
            session_id.cast(),
            session_id_len,
            ta,
            ta_len,
            now_ms,
            out_ticket,
            out_ticket_len,
            out_peer_fp,
            out_peer_fp_len,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_cancel_attempt(
    sender: *mut llc_sender,
    session_id: *const std::ffi::c_char,
    session_id_len: usize,
) -> i32 {
    capi::export_sender(sender, || {
        capi::sender_cancel_attempt(sender, session_id.cast(), session_id_len)
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_sender_cancel(sender: *mut llc_sender) -> i32 {
    capi::export_sender(sender, || capi::sender_cancel(sender))
}

#[no_mangle]
pub unsafe extern "C" fn llct_receiver_new(
    code: *const u8,
    code_len: usize,
    rng_script: *const u8,
    rng_script_len: usize,
    out: *mut *mut llc_receiver,
) -> i32 {
    capi::export_status(|| {
        capi::receiver_new_script(code, code_len, rng_script, rng_script_len, out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_receiver_free(receiver: *mut llc_receiver) {
    capi::export_unit(|| capi::receiver_free(receiver));
}

#[no_mangle]
pub unsafe extern "C" fn llct_receiver_begin(
    receiver: *mut llc_receiver,
    out: *mut *mut llc_attempt,
) -> i32 {
    capi::export_receiver(receiver, || capi::receiver_begin(receiver, out))
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_free(attempt: *mut llc_attempt) {
    capi::export_unit(|| capi::attempt_free(attempt));
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_nonce_r(
    attempt: *mut llc_attempt,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    capi::export_attempt(attempt, || capi::attempt_nonce_r(attempt, out, out_len))
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_suites(
    attempt: *mut llc_attempt,
    out: *mut std::ffi::c_char,
    out_len: usize,
) -> i32 {
    capi::export_attempt(attempt, || {
        capi::attempt_suites(attempt, out.cast(), out_len)
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_start(
    attempt: *mut llc_attempt,
    nonce_s: *const u8,
    nonce_s_len: usize,
    suite: *const std::ffi::c_char,
    suite_len: usize,
    fp_self: *const u8,
    fp_self_len: usize,
    fp_peer: *const u8,
    fp_peer_len: usize,
    out_ya: *mut u8,
    out_ya_len: usize,
) -> i32 {
    capi::export_attempt(attempt, || {
        capi::attempt_start(
            attempt,
            nonce_s,
            nonce_s_len,
            suite.cast(),
            suite_len,
            fp_self,
            fp_self_len,
            fp_peer,
            fp_peer_len,
            out_ya,
            out_ya_len,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_finish(
    attempt: *mut llc_attempt,
    yb: *const u8,
    yb_len: usize,
    tb: *const u8,
    tb_len: usize,
    out_ta: *mut u8,
    out_ta_len: usize,
) -> i32 {
    capi::export_attempt(attempt, || {
        capi::attempt_finish(attempt, yb, yb_len, tb, tb_len, out_ta, out_ta_len)
    })
}

#[no_mangle]
pub unsafe extern "C" fn llct_attempt_verify_ticket(
    attempt: *mut llc_attempt,
    ticket: *const u8,
    ticket_len: usize,
    fp_client: *const u8,
    fp_client_len: usize,
) -> i32 {
    capi::export_attempt(attempt, || {
        capi::attempt_verify_ticket(attempt, ticket, ticket_len, fp_client, fp_client_len)
    })
}

/// Production `llc_*` symbols for the packaged test library only.
/// The dependency is built without `c-api`, so these are the only `llc_*`
/// definitions in this cdylib. Drop the feature and the names disappear.
#[cfg(feature = "bundled-llc")]
mod bundled_llc {
    limlink_core::define_llc_exports!();
}

/// Not in `limlink_core_testvectors.h`. Exists so tests can force `LLC_ERR_PANIC`.
#[cfg(test)]
#[no_mangle]
pub unsafe extern "C" fn llct_debug_panic(sender: *mut llc_sender) -> i32 {
    capi::export_sender(sender, || panic!("deliberate test panic"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use limlink_core::capi::LLC_ERR_PANIC;
    use limlink_core::CoreError;

    #[test]
    fn deliberate_panic_returns_102_and_poisons_the_sender() {
        assert_eq!(
            unsafe { llct_debug_panic(std::ptr::null_mut()) },
            LLC_ERR_PANIC
        );
        assert_eq!(LLC_ERR_PANIC, 102);

        let script = [0u8, 0, 0, 42];
        let mut sender: *mut llc_sender = std::ptr::null_mut();
        assert_eq!(
            unsafe { llct_sender_new(1, script.as_ptr(), script.len(), &mut sender) },
            0
        );
        let mut code = [0u8; 7];
        assert_eq!(
            unsafe { llct_sender_code(sender, code.as_mut_ptr().cast(), code.len()) },
            0
        );
        assert_eq!(unsafe { llct_debug_panic(sender) }, LLC_ERR_PANIC);
        assert_eq!(
            unsafe { llct_sender_code(sender, code.as_mut_ptr().cast(), code.len()) },
            CoreError::BadState.as_status()
        );
        unsafe { llct_sender_free(sender) };
    }
}
