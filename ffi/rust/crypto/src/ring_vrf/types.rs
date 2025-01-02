use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
pub use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
pub use bandersnatch::{IetfProof, Input, Output, Public, RingProof, Secret};

pub const DEFAULT_RING_SIZE: usize = 1023;
pub const SECRET_KEY_SIZE: usize = 32;
pub const PUBLIC_KEY_SIZE: usize = 32;

// Construct VRF Input Point from arbitrary data (section 1.2)
pub fn vrf_input_point(vrf_input_data: &[u8]) -> Option<Input> {
  Input::new(vrf_input_data)
}

pub type RingCommitment =
  ark_ec_vrfs::ring::RingCommitment<bandersnatch::BandersnatchSha512Ell2>;

/// Represents the output of the standard (non-anonymous) IETF VRF `Prove` operation. This
/// implementation follows section 2.2 of the Bandersnatch VRF specification. The signature
/// combines both the VRF output and its corresponding proof.
#[derive(CanonicalSerialize, CanonicalDeserialize, Clone)]
pub struct IetfVrfSignature {
  /// VRF output.
  pub output: Output,
  /// Proof.
  pub proof: IetfProof,
}

/// Output from the IETF standard VRF `Prove` procedure (anonymous ring variant). Contains both the
/// VRF output and its ring proof, as specified in section 4.2 of the Bandersnatch VRF spec.
#[derive(CanonicalSerialize, CanonicalDeserialize, Clone)]
pub struct RingVrfSignature {
  /// VRF output.
  pub output: Output,
  /// This contains both the Pedersen proof and actual ring proof.
  pub proof: RingProof,
}
