use core::fmt;

/// Errors from the invite core. Discriminants 1–14 are the C ABI codes.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreError {
    CodeFormat = 1,
    SuiteUnsupported = 2,
    Expired = 3,
    Exhausted = 4,
    Busy = 5,
    NotActive = 6,
    UnknownAttempt = 7,
    InvalidPeerMessage = 8,
    ConfirmMismatch = 9,
    TagMismatch = 10,
    TicketMismatch = 11,
    BadState = 12,
    Rng = 13,
    /// Ticket and fingerprint match a ticket that was already consumed.
    TicketUsed = 14,
}

impl CoreError {
    pub const fn as_status(self) -> i32 {
        self as i32
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            CoreError::CodeFormat => "invite code format",
            CoreError::SuiteUnsupported => "pake suite unsupported",
            CoreError::Expired => "invite expired",
            CoreError::Exhausted => "invite exhausted",
            CoreError::Busy => "invite busy",
            CoreError::NotActive => "invite not active",
            CoreError::UnknownAttempt => "unknown invite attempt",
            CoreError::InvalidPeerMessage => "invalid peer message",
            CoreError::ConfirmMismatch => "confirm tag mismatch",
            CoreError::TagMismatch => "key confirmation mismatch",
            CoreError::TicketMismatch => "invite ticket mismatch",
            CoreError::TicketUsed => "invite ticket already used",
            CoreError::BadState => "bad invite state",
            CoreError::Rng => "rng failure",
        })
    }
}

impl std::error::Error for CoreError {}
