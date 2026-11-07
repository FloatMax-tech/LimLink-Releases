// Shared `llc_*` export bodies. `limlink-core` expands this for the release
// cdylib. The testvectors `bundled-llc` feature expands the same macro so a
// packaged test library can export `llc_*` and `llct_*` together.
// The default testvectors build does not expand it, and must not export `llc_*`.

#[doc(hidden)]
#[macro_export]
macro_rules! define_llc_exports {
    () => {
        #[no_mangle]
        pub extern "C" fn llc_abi_version() -> u32 {
            $crate::capi::export_u32($crate::capi::abi_version)
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_core_info(
            out_version: *mut std::ffi::c_char,
            out_version_len: usize,
            out_suites: *mut std::ffi::c_char,
            out_suites_len: usize,
        ) -> i32 {
            $crate::capi::export_status(|| {
                $crate::capi::core_info(
                    out_version.cast(),
                    out_version_len,
                    out_suites.cast(),
                    out_suites_len,
                )
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_new(
            now_ms: u64,
            out: *mut *mut $crate::capi::llc_sender,
        ) -> i32 {
            $crate::capi::export_status(|| $crate::capi::sender_new(now_ms, out))
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_free(sender: *mut $crate::capi::llc_sender) {
            $crate::capi::export_unit(|| $crate::capi::sender_free(sender));
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_code(
            sender: *mut $crate::capi::llc_sender,
            out: *mut std::ffi::c_char,
            out_len: usize,
        ) -> i32 {
            $crate::capi::export_sender(sender, || {
                $crate::capi::sender_code(sender, out.cast(), out_len)
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_status(
            sender: *mut $crate::capi::llc_sender,
            now_ms: u64,
            out: *mut $crate::capi::llc_invite_status,
        ) -> i32 {
            $crate::capi::export_sender(sender, || $crate::capi::sender_status(sender, now_ms, out))
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_accept_hello(
            sender: *mut $crate::capi::llc_sender,
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
            $crate::capi::export_sender(sender, || {
                $crate::capi::sender_accept_hello(
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
        pub unsafe extern "C" fn llc_sender_respond_pake(
            sender: *mut $crate::capi::llc_sender,
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
            $crate::capi::export_sender(sender, || {
                $crate::capi::sender_respond_pake(
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
        pub unsafe extern "C" fn llc_sender_verify_confirm(
            sender: *mut $crate::capi::llc_sender,
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
            $crate::capi::export_sender(sender, || {
                $crate::capi::sender_verify_confirm(
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
        pub unsafe extern "C" fn llc_sender_cancel_attempt(
            sender: *mut $crate::capi::llc_sender,
            session_id: *const std::ffi::c_char,
            session_id_len: usize,
        ) -> i32 {
            $crate::capi::export_sender(sender, || {
                $crate::capi::sender_cancel_attempt(sender, session_id.cast(), session_id_len)
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_sender_cancel(sender: *mut $crate::capi::llc_sender) -> i32 {
            $crate::capi::export_sender(sender, || $crate::capi::sender_cancel(sender))
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_receiver_new(
            code: *const u8,
            code_len: usize,
            out: *mut *mut $crate::capi::llc_receiver,
        ) -> i32 {
            $crate::capi::export_status(|| $crate::capi::receiver_new(code, code_len, out))
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_receiver_free(receiver: *mut $crate::capi::llc_receiver) {
            $crate::capi::export_unit(|| $crate::capi::receiver_free(receiver));
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_receiver_begin(
            receiver: *mut $crate::capi::llc_receiver,
            out: *mut *mut $crate::capi::llc_attempt,
        ) -> i32 {
            $crate::capi::export_receiver(receiver, || $crate::capi::receiver_begin(receiver, out))
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_attempt_free(attempt: *mut $crate::capi::llc_attempt) {
            $crate::capi::export_unit(|| $crate::capi::attempt_free(attempt));
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_attempt_nonce_r(
            attempt: *mut $crate::capi::llc_attempt,
            out: *mut u8,
            out_len: usize,
        ) -> i32 {
            $crate::capi::export_attempt(attempt, || {
                $crate::capi::attempt_nonce_r(attempt, out, out_len)
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_attempt_suites(
            attempt: *mut $crate::capi::llc_attempt,
            out: *mut std::ffi::c_char,
            out_len: usize,
        ) -> i32 {
            $crate::capi::export_attempt(attempt, || {
                $crate::capi::attempt_suites(attempt, out.cast(), out_len)
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_attempt_start(
            attempt: *mut $crate::capi::llc_attempt,
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
            $crate::capi::export_attempt(attempt, || {
                $crate::capi::attempt_start(
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
        pub unsafe extern "C" fn llc_attempt_finish(
            attempt: *mut $crate::capi::llc_attempt,
            yb: *const u8,
            yb_len: usize,
            tb: *const u8,
            tb_len: usize,
            out_ta: *mut u8,
            out_ta_len: usize,
        ) -> i32 {
            $crate::capi::export_attempt(attempt, || {
                $crate::capi::attempt_finish(
                    attempt, yb, yb_len, tb, tb_len, out_ta, out_ta_len,
                )
            })
        }

        #[no_mangle]
        pub unsafe extern "C" fn llc_attempt_verify_ticket(
            attempt: *mut $crate::capi::llc_attempt,
            ticket: *const u8,
            ticket_len: usize,
            fp_client: *const u8,
            fp_client_len: usize,
        ) -> i32 {
            $crate::capi::export_attempt(attempt, || {
                $crate::capi::attempt_verify_ticket(
                    attempt,
                    ticket,
                    ticket_len,
                    fp_client,
                    fp_client_len,
                )
            })
        }
    };
}
