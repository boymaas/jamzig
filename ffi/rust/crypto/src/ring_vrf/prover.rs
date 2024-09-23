use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
pub use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
pub use bandersnatch::{IetfProof, Input, Output, Public, RingProof, Secret};

use thiserror::Error;

use crate::ring_vrf::{
    context::ring_context,
    types::{vrf_input_point, IetfVrfSignature, RingVrfSignature},
};

#[derive(Error, Debug)]
pub enum ProverError {
    #[error("Failed to serialize signature")]
    SerializationError,
    #[error("Invalid prover index")]
    InvalidProverIndex,
}

// Prover actor.
pub struct Prover {
    pub prover_idx: usize,
    pub secret: Secret,
    pub ring: Vec<Public>,
}

impl Prover {
    pub fn new(ring: Vec<Public>, prover_secret: Secret, prover_idx: usize) -> Self {
        Self {
            prover_idx,
            secret: prover_secret,
            ring,
        }
    }

    /// Anonymous VRF signature.
    ///
    /// Used for tickets submission.
    pub fn ring_vrf_sign(
        &self,
        vrf_input_data: &[u8],
        aux_data: &[u8],
    ) -> Result<Vec<u8>, ProverError> {
        use ark_ec_vrfs::ring::Prover as _;

        let input = vrf_input_point(vrf_input_data);
        let output = self.secret.output(input);

        // Backend currently requires the wrapped type (plain affine points)
        let pts: Vec<_> = self.ring.iter().map(|pk| pk.0).collect();

        // Proof construction
        let ring_ctx = ring_context(pts.len());
        let prover_key = ring_ctx.prover_key(&pts);
        let prover = ring_ctx.prover(prover_key, self.prover_idx);
        let proof = self.secret.prove(input, output, aux_data, &prover);

        // Output and Ring Proof bundled together (as per section 2.2)
        let signature = RingVrfSignature { output, proof };
        let mut buf = Vec::new();
        signature
            .serialize_compressed(&mut buf)
            .map_err(|_| ProverError::SerializationError)?;
        Ok(buf)
    }

    /// Non-Anonymous VRF signature.
    ///
    // Used for ticket claiming during block production.
    /// Not used with Safrole test vectors.
    pub fn ietf_vrf_sign(
        &self,
        vrf_input_data: &[u8],
        aux_data: &[u8],
    ) -> Result<Vec<u8>, ProverError> {
        use ark_ec_vrfs::ietf::Prover as _;

        let input = vrf_input_point(vrf_input_data);
        let output = self.secret.output(input);

        let proof = self.secret.prove(input, output, aux_data);

        // Output and IETF Proof bundled together (as per section 2.2)
        let signature = IetfVrfSignature { output, proof };
        let mut buf = Vec::new();
        signature
            .serialize_compressed(&mut buf)
            .map_err(|_| ProverError::SerializationError)?;
        Ok(buf)
    }
}
