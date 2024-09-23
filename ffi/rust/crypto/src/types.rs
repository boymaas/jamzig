use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
pub use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
pub use bandersnatch::{IetfProof, Input, Output, Public, RingProof, Secret};

// Construct VRF Input Point from arbitrary data (section 1.2)
pub fn vrf_input_point(vrf_input_data: &[u8]) -> Input {
    Input::new(vrf_input_data).unwrap()
}

pub type RingCommitment = ark_ec_vrfs::ring::RingCommitment<bandersnatch::BandersnatchSha512Ell2>;

// This is the IETF `Prove` procedure output as described in section 2.2
// of the Bandersnatch VRFs specification
#[derive(CanonicalSerialize, CanonicalDeserialize)]
pub struct IetfVrfSignature {
    pub output: Output,
    pub proof: IetfProof,
}

// This is the IETF `Prove` procedure output as described in section 4.2
// of the Bandersnatch VRFs specification
#[derive(CanonicalSerialize, CanonicalDeserialize)]
pub struct RingVrfSignature {
    pub output: Output,
    // This contains both the Pedersen proof and actual ring proof.
    pub proof: RingProof,
}
