//! LimLink shared core for the invite-code handshake.
//!
//! Scope is CPace (`CPACE-RISTR255-SHA512`), key confirmation, the session
//! ticket, and invite-code state. Networking, TLS, HTTP, and file IO stay in
//! the platform apps. The core does not read a clock: callers pass `now_ms`.
//!
//! The Rust types are shaped so a UniFFI binding can be added later without
//! changing them. This crate does not depend on UniFFI. Windows (and any
//! platform that skips UniFFI) uses the C ABI in `include/limlink_core.h`.

#[cfg(all(feature = "test-rng", not(debug_assertions)))]
compile_error!(
    "feature `test-rng` is refused when debug assertions are off (release builds, spec 15.10.9)"
);

mod b64;
pub mod capi;
mod confirm;
mod encoding;
mod error;
mod filehash;
mod invite;
mod pake;
mod rng;
mod sas;
mod suite;

pub use error::CoreError;
pub use filehash::{parse_sha256_hex, sha256_hex, sha256_hex_chunks};
pub use invite::{
    ConfirmResult, HelloAccepted, InviteReceiver, InviteSender, InviteState, InviteStatus,
    PakeResponse, ReceiverAttempt, CODE_LEN, CONFIRM_TIMEOUT_MS, FP_LEN, INVITE_TTL_MS,
    MAX_FAILURES, MAX_PENDING_HELLOS, NONCE_LEN, POINT_LEN, SESSION_ID_LEN, TAG_LEN, TICKET_LEN,
};
pub use sas::{compute_sas, SasOutput};
pub use suite::SUITE_NAME;

pub const ABI_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreInfo {
    pub version: String,
    pub abi_version: u32,
    pub suites: Vec<String>,
}

pub fn core_version() -> &'static str {
    #[cfg(feature = "test-rng")]
    {
        concat!(env!("CARGO_PKG_VERSION"), "+testrng")
    }
    #[cfg(not(feature = "test-rng"))]
    {
        env!("CARGO_PKG_VERSION")
    }
}

pub fn core_info() -> CoreInfo {
    CoreInfo {
        version: core_version().to_string(),
        abi_version: ABI_VERSION,
        suites: vec![SUITE_NAME.to_string()],
    }
}
