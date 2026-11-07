use pakery_cpace::{
    CpaceCiphersuite, CpaceError, CpaceInitiator, CpaceMode, CpaceResponder, InitiatorState,
};
use pakery_crypto::{Ristretto255Group, Sha512Hash};
use zeroize::Zeroize;

use crate::confirm::{ct_eq, derive_ticket, mac_key, mac_tag};
use crate::encoding::lv_cat;
use crate::error::CoreError;
use crate::rng::{Bridge, RngSource};

pub struct LimlinkSuite;

impl CpaceCiphersuite for LimlinkSuite {
    type Group = Ristretto255Group;
    type Hash = Sha512Hash;
    const DSI: &'static [u8] = b"CPaceRistretto255";
    const HASH_BLOCK_SIZE: usize = 128;
    const FIELD_SIZE_BYTES: usize = 32;
}

pub struct ResponderOutput {
    pub yb: [u8; 32],
    pub tb: [u8; 64],
    pub expected_ta: [u8; 64],
    pub ticket: [u8; 32],
}

pub struct InitiatorPending {
    state: InitiatorState<LimlinkSuite>,
    ya: [u8; 32],
    ada: Vec<u8>,
    adb: Vec<u8>,
    sid: Vec<u8>,
}

pub struct InitiatorDone {
    pub ta: [u8; 64],
    pub ticket: [u8; 32],
}

fn map_cpace(err: CpaceError) -> CoreError {
    match err {
        CpaceError::InvalidPoint | CpaceError::IdentityPoint => CoreError::InvalidPeerMessage,
    }
}

pub fn respond(
    rng: &mut RngSource,
    prs: &[u8],
    ci: &[u8],
    sid: &[u8],
    ada: &[u8],
    adb: &[u8],
    ya: &[u8],
) -> Result<ResponderOutput, CoreError> {
    let mut failed = false;
    let started = {
        let mut bridge = Bridge {
            source: rng,
            failed: &mut failed,
        };
        CpaceResponder::<LimlinkSuite>::respond(
            ya,
            prs,
            ci,
            sid,
            ada,
            adb,
            CpaceMode::InitiatorResponder,
            &mut bridge,
        )
    };
    if failed {
        return Err(CoreError::Rng);
    }
    let (yb_vec, output) = started.map_err(map_cpace)?;
    let yb: [u8; 32] = yb_vec
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidPeerMessage)?;
    let isk = output.isk.as_bytes();
    let mut key = mac_key(sid, isk);
    let tb = mac_tag(&key, &lv_cat(&[yb.as_slice(), adb]));
    let expected_ta = mac_tag(&key, &lv_cat(&[ya, ada]));
    let ticket = derive_ticket(isk, sid);
    key.zeroize();
    Ok(ResponderOutput {
        yb,
        tb,
        expected_ta,
        ticket,
    })
}

pub fn initiate(
    rng: &mut RngSource,
    prs: &[u8],
    ci: &[u8],
    sid: &[u8],
    ada: &[u8],
    adb: &[u8],
) -> Result<([u8; 32], InitiatorPending), CoreError> {
    let mut failed = false;
    let started = {
        let mut bridge = Bridge {
            source: rng,
            failed: &mut failed,
        };
        CpaceInitiator::<LimlinkSuite>::start(prs, ci, sid, ada, &mut bridge)
    };
    if failed {
        return Err(CoreError::Rng);
    }
    let (ya_vec, state) = started.map_err(map_cpace)?;
    let ya: [u8; 32] = ya_vec
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidPeerMessage)?;
    Ok((
        ya,
        InitiatorPending {
            state,
            ya,
            ada: ada.to_vec(),
            adb: adb.to_vec(),
            sid: sid.to_vec(),
        },
    ))
}

impl InitiatorPending {
    pub fn finish(self, yb: &[u8], tb: &[u8]) -> Result<InitiatorDone, CoreError> {
        if yb.len() != POINT || tb.len() != TAG {
            return Err(CoreError::InvalidPeerMessage);
        }
        let output = self
            .state
            .finish(yb, &self.adb, CpaceMode::InitiatorResponder)
            .map_err(map_cpace)?;
        let isk = output.isk.as_bytes();
        let mut key = mac_key(&self.sid, isk);
        let expect_tb = mac_tag(&key, &lv_cat(&[yb, self.adb.as_slice()]));
        let mut ta = mac_tag(&key, &lv_cat(&[self.ya.as_slice(), self.ada.as_slice()]));
        let mut ticket = derive_ticket(isk, &self.sid);
        key.zeroize();
        let ok = ct_eq(&expect_tb, tb);
        let mut expect_tb = expect_tb;
        expect_tb.zeroize();
        if !ok {
            ta.zeroize();
            ticket.zeroize();
            return Err(CoreError::TagMismatch);
        }
        Ok(InitiatorDone { ta, ticket })
    }
}

const POINT: usize = 32;
const TAG: usize = 64;

#[cfg(test)]
mod draft_b3 {
    use core::convert::Infallible;

    use pakery_core::crypto::CpaceGroup;
    use pakery_cpace::generator::{calculate_generator, generator_string};
    use pakery_cpace::{CpaceInitiator, CpaceMode, CpaceResponder};
    use pakery_crypto::Ristretto255Group;
    use rand_core::{TryCryptoRng, TryRng};
    use sha2::{Digest, Sha512};

    use super::LimlinkSuite;

    struct ScriptRng {
        data: Vec<u8>,
        pos: usize,
    }

    impl ScriptRng {
        fn new(data: Vec<u8>) -> Self {
            Self { data, pos: 0 }
        }
    }

    impl TryRng for ScriptRng {
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
            let end = self.pos + dst.len();
            assert!(end <= self.data.len(), "rng script exhausted");
            dst.copy_from_slice(&self.data[self.pos..end]);
            self.pos = end;
            Ok(())
        }
    }

    impl TryCryptoRng for ScriptRng {}

    fn vectors() -> serde_json::Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../vectors/limlink-core-vectors-v1.json"
        );
        let text = std::fs::read_to_string(path).expect("vector file");
        serde_json::from_str(&text).expect("vector json")
    }

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
            .collect()
    }

    fn hx(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn draft() -> serde_json::Value {
        vectors()["cpaceDraftB3"].clone()
    }

    #[test]
    fn ristretto255_matches_draft_appendix_b3() {
        let d = draft();
        let prs = unhex(d["prs"].as_str().unwrap());
        let ci = unhex(d["ci"].as_str().unwrap());
        let sid = unhex(d["sid"].as_str().unwrap());
        let ada = unhex(d["ada"].as_str().unwrap());
        let adb = unhex(d["adb"].as_str().unwrap());
        let ya_wide = unhex(d["yaWide"].as_str().unwrap());
        let yb_wide = unhex(d["ybWide"].as_str().unwrap());

        let gen = generator_string::<LimlinkSuite>(&prs, &ci, &sid);
        assert_eq!(hx(&gen), d["generatorString"].as_str().unwrap());
        let hash = Sha512::digest(&gen);
        assert_eq!(hx(&hash), d["hash"].as_str().unwrap());

        let g = calculate_generator::<LimlinkSuite>(&prs, &ci, &sid).expect("generator");
        assert_eq!(hx(&g.to_bytes()), d["generator"].as_str().unwrap());

        let ya_scalar = Ristretto255Group::scalar_from_wide_bytes(&ya_wide).unwrap();
        let yb_scalar = Ristretto255Group::scalar_from_wide_bytes(&yb_wide).unwrap();
        let ya_point = g.scalar_mul(&ya_scalar);
        let yb_point = g.scalar_mul(&yb_scalar);
        assert_eq!(hx(&ya_point.to_bytes()), d["ya"].as_str().unwrap());
        assert_eq!(hx(&yb_point.to_bytes()), d["yb"].as_str().unwrap());
        let k = ya_point.scalar_mul(&yb_scalar);
        assert_eq!(hx(&k.to_bytes()), d["k"].as_str().unwrap());

        let (ya, state) = CpaceInitiator::<LimlinkSuite>::start(
            &prs,
            &ci,
            &sid,
            &ada,
            &mut ScriptRng::new(ya_wide.clone()),
        )
        .unwrap();
        let (yb, responder) = CpaceResponder::<LimlinkSuite>::respond(
            &ya,
            &prs,
            &ci,
            &sid,
            &ada,
            &adb,
            CpaceMode::InitiatorResponder,
            &mut ScriptRng::new(yb_wide.clone()),
        )
        .unwrap();
        let initiator = state
            .finish(&yb, &adb, CpaceMode::InitiatorResponder)
            .unwrap();
        assert_eq!(hx(&ya), d["ya"].as_str().unwrap());
        assert_eq!(hx(&yb), d["yb"].as_str().unwrap());
        assert_eq!(hx(initiator.isk.as_bytes()), d["iskIr"].as_str().unwrap());
        assert_eq!(hx(responder.isk.as_bytes()), d["iskIr"].as_str().unwrap());
        assert_eq!(
            hx(&initiator.session_id),
            d["sidOutputIr"].as_str().unwrap()
        );
        assert_eq!(
            hx(&responder.session_id),
            d["sidOutputIr"].as_str().unwrap()
        );

        let (ya, state) = CpaceInitiator::<LimlinkSuite>::start(
            &prs,
            &ci,
            &sid,
            &ada,
            &mut ScriptRng::new(ya_wide),
        )
        .unwrap();
        let (yb, responder) = CpaceResponder::<LimlinkSuite>::respond(
            &ya,
            &prs,
            &ci,
            &sid,
            &ada,
            &adb,
            CpaceMode::Symmetric,
            &mut ScriptRng::new(yb_wide),
        )
        .unwrap();
        let initiator = state.finish(&yb, &adb, CpaceMode::Symmetric).unwrap();
        assert_eq!(hx(initiator.isk.as_bytes()), d["iskSy"].as_str().unwrap());
        assert_eq!(hx(responder.isk.as_bytes()), d["iskSy"].as_str().unwrap());
        assert_eq!(
            hx(&initiator.session_id),
            d["sidOutputOc"].as_str().unwrap()
        );

        let sm = &d["scalarMult"];
        let mut s_wide = vec![0u8; 64];
        let s = unhex(sm["s"].as_str().unwrap());
        s_wide[..32].copy_from_slice(&s);
        let scalar = Ristretto255Group::scalar_from_wide_bytes(&s_wide).unwrap();
        let point = Ristretto255Group::from_bytes(&unhex(sm["x"].as_str().unwrap())).unwrap();
        assert_eq!(
            hx(&point.scalar_mul(&scalar).to_bytes()),
            sm["out"].as_str().unwrap()
        );

        assert!(Ristretto255Group::from_bytes(&unhex(d["invalidYi1"].as_str().unwrap())).is_err());
        let identity =
            Ristretto255Group::from_bytes(&unhex(d["invalidYi2"].as_str().unwrap())).unwrap();
        assert!(identity.is_identity());
        let reject = CpaceResponder::<LimlinkSuite>::respond(
            &unhex(d["invalidYi1"].as_str().unwrap()),
            &prs,
            &ci,
            &sid,
            &ada,
            &adb,
            CpaceMode::InitiatorResponder,
            &mut ScriptRng::new(vec![]),
        );
        assert!(reject.is_err());
        let reject = CpaceResponder::<LimlinkSuite>::respond(
            &unhex(d["invalidYi2"].as_str().unwrap()),
            &prs,
            &ci,
            &sid,
            &ada,
            &adb,
            CpaceMode::InitiatorResponder,
            &mut ScriptRng::new(vec![]),
        );
        assert!(reject.is_err());
    }
}
