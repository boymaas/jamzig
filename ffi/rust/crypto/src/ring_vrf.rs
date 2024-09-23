use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
pub use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
pub use bandersnatch::{IetfProof, Input, Output, Public, RingProof, Secret};
use thiserror::Error;

use crate::{
    ring_context::ring_context,
    types::{vrf_input_point, IetfVrfSignature, RingVrfSignature},
};

#[derive(Error, Debug)]
pub enum ProverError {
    #[error("Failed to serialize signature")]
    SerializationError,
    #[error("Invalid prover index")]
    InvalidProverIndex,
}

#[derive(Error, Debug)]
pub enum VerifierError {
    #[error("Failed to deserialize signature")]
    DeserializationError,
    #[error("Signature verification failed")]
    VerificationFailed,
    #[error("Invalid signer key index")]
    InvalidSignerKeyIndex,
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

pub type RingCommitment = ark_ec_vrfs::ring::RingCommitment<bandersnatch::BandersnatchSha512Ell2>;

// Verifier actor.
pub struct Verifier {
    pub commitment: RingCommitment,
    pub ring: Vec<Public>,
}

impl Verifier {
    pub fn new(ring: Vec<Public>) -> Self {
        // Backend currently requires the wrapped type (plain affine points)
        let pts: Vec<_> = ring.iter().map(|pk| pk.0).collect();
        let verifier_key = ring_context(ring.len()).verifier_key(&pts);
        let commitment = verifier_key.commitment();
        Self { ring, commitment }
    }

    /// Anonymous VRF signature verification.
    ///
    /// Used for tickets verification.
    ///
    /// On success returns the VRF output hash.
    pub fn ring_vrf_verify(
        &self,
        vrf_input_data: &[u8],
        aux_data: &[u8],
        signature: &[u8],
    ) -> Result<[u8; 32], VerifierError> {
        use ark_ec_vrfs::ring::Verifier as _;

        let signature = RingVrfSignature::deserialize_compressed(signature)
            .map_err(|_| VerifierError::DeserializationError)?;

        let input = vrf_input_point(vrf_input_data);
        let output = signature.output;

        let ring_ctx = ring_context(self.ring.len());
        //
        // The verifier key is reconstructed from the commitment and the constant
        // verifier key component of the SRS in order to verify some proof.
        // As an alternative we can construct the verifier key using the
        // RingContext::verifier_key() method, but is more expensive.
        // In other words, we prefer computing the commitment once, when the keyset changes.
        let verifier_key = ring_ctx.verifier_key_from_commitment(self.commitment.clone());
        let verifier = ring_ctx.verifier(verifier_key);
        Public::verify(input, output, aux_data, &signature.proof, &verifier)
            .map_err(|_| VerifierError::VerificationFailed)?;

        // This truncated hash is the actual value used as ticket-id/score in JAM
        let vrf_output_hash: [u8; 32] = output.hash()[..32].try_into().unwrap();
        Ok(vrf_output_hash)
    }

    /// Non-Anonymous VRF signature verification.
    ///
    /// Used for ticket claim verification during block import.
    /// Not used with Safrole test vectors.
    ///
    /// On success returns the VRF output hash.
    #[allow(dead_code)]
    pub fn ietf_vrf_verify(
        &self,
        vrf_input_data: &[u8],
        aux_data: &[u8],
        signature: &[u8],
        signer_key_index: usize,
    ) -> Result<[u8; 32], VerifierError> {
        use ark_ec_vrfs::ietf::Verifier as _;

        let signature = IetfVrfSignature::deserialize_compressed(signature)
            .map_err(|_| VerifierError::DeserializationError)?;

        let input = vrf_input_point(vrf_input_data);
        let output = signature.output;

        let public = self
            .ring
            .get(signer_key_index)
            .ok_or(VerifierError::InvalidSignerKeyIndex)?;
        public
            .verify(input, output, aux_data, &signature.proof)
            .map_err(|_| VerifierError::VerificationFailed)?;

        println!("Ietf signature verified");

        // This is the actual value used as ticket-id/score
        // NOTE: as far as vrf_input_data is the same, this matches the one produced
        // using the ring-vrf (regardless of aux_data).
        let vrf_output_hash: [u8; 32] = output.hash()[..32].try_into().unwrap();
        println!(" vrf-output-hash: {}", hex::encode(vrf_output_hash));
        Ok(vrf_output_hash)
    }
}
