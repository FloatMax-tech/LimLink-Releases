use core::convert::Infallible;

use rand_core::{TryCryptoRng, TryRng};
#[cfg(feature = "test-rng")]
use zeroize::Zeroizing;

use crate::error::CoreError;

/// Bytes the core draws, in call order. Production uses the OS CSPRNG.
/// The script source exists only in the test-rng build.
pub(crate) enum RngSource {
    Os,
    #[cfg(feature = "test-rng")]
    Script {
        data: Zeroizing<Vec<u8>>,
        pos: usize,
    },
}

impl RngSource {
    pub(crate) fn os() -> Self {
        Self::Os
    }

    #[cfg(feature = "test-rng")]
    pub(crate) fn script(bytes: Vec<u8>) -> Self {
        Self::Script {
            data: Zeroizing::new(bytes),
            pos: 0,
        }
    }

    pub(crate) fn fill(&mut self, dst: &mut [u8]) -> Result<(), CoreError> {
        match self {
            Self::Os => getrandom::fill(dst).map_err(|_| CoreError::Rng),
            #[cfg(feature = "test-rng")]
            Self::Script { data, pos } => {
                let end = pos.checked_add(dst.len()).ok_or(CoreError::Rng)?;
                if end > data.len() {
                    return Err(CoreError::Rng);
                }
                dst.copy_from_slice(&data[*pos..end]);
                *pos = end;
                Ok(())
            }
        }
    }
}

/// Adapts [`RngSource`] to pakery's infallible `CryptoRng`. On failure the
/// destination is wiped and `failed` is set; the caller must discard the
/// protocol output.
pub(crate) struct Bridge<'a> {
    pub(crate) source: &'a mut RngSource,
    pub(crate) failed: &'a mut bool,
}

impl TryRng for Bridge<'_> {
    type Error = Infallible;

    fn try_next_u32(&mut self) -> Result<u32, Infallible> {
        let mut buf = [0u8; 4];
        self.try_fill_bytes(&mut buf)?;
        Ok(u32::from_le_bytes(buf))
    }

    fn try_next_u64(&mut self) -> Result<u64, Infallible> {
        let mut buf = [0u8; 8];
        self.try_fill_bytes(&mut buf)?;
        Ok(u64::from_le_bytes(buf))
    }

    fn try_fill_bytes(&mut self, dst: &mut [u8]) -> Result<(), Infallible> {
        if self.source.fill(dst).is_err() {
            dst.fill(0);
            *self.failed = true;
        }
        Ok(())
    }
}

impl TryCryptoRng for Bridge<'_> {}

/// Uniform code in `000000`–`999999`.
///
/// Draws 4 bytes as a big-endian `u32` and rejects values at or above
/// `floor(2^32 / 1_000_000) * 1_000_000` so the reduction is unbiased.
pub(crate) fn draw_code(rng: &mut RngSource) -> Result<[u8; 6], CoreError> {
    const SPACE: u32 = 1_000_000;
    const LIMIT: u32 = u32::MAX - (u32::MAX % SPACE);
    for _ in 0..1024 {
        let mut buf = [0u8; 4];
        rng.fill(&mut buf)?;
        let v = u32::from_be_bytes(buf);
        if v < LIMIT {
            let n = v % SPACE;
            let text = format!("{n:06}");
            let bytes: [u8; 6] = text.as_bytes().try_into().expect("6 digits");
            return Ok(bytes);
        }
    }
    Err(CoreError::Rng)
}
