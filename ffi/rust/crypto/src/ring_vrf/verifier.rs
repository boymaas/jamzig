use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_serialize::CanonicalDeserialize;
use bandersnatch::Public;
use thiserror::Error;

use super::{
    context::{ring_context, RingContextError},
    types::{vrf_input_point, IetfVrfSignature, RingCommitment, RingVrfSignature},
};

#[derive(Error, Debug)]
pub enum VerifierError {
    #[error("Failed to deserialize signature")]
    DeserializationError,
    #[error("Signature verification failed")]
    VerificationFailed,
    #[error("Invalid signer key index")]
    InvalidSignerKeyIndex,
    #[error(transparent)]
    RingContextError(#[from] RingContextError),
    #[error("Invalid VRF input point")]
    VrfInputPointError,
}

/// Verifier actor.
///
/// Used to verify both anonymous ring VRF signatures and non-anonymous IETF VRF signatures.
pub struct Verifier {
    /// Ring commitment for anonymous verification
    pub commitment: RingCommitment,
    /// Ring of public keys
    pub ring: Vec<Public>,
}

impl Verifier {
    /// Creates a new Verifier with the given ring of public keys
    pub fn new(ring: Vec<Public>) -> Result<Self, VerifierError> {
        // Backend currently requires the wrapped type (plain affine points)
        let pts: Vec<_> = ring.iter().map(|pk| pk.0).collect();
        let verifier_key = ring_context(ring.len())?.verifier_key(&pts);
        let commitment = verifier_key.commitment();
        Ok(Self { ring, commitment })
    }

    /// Non-Anonymous VRF signature verification.
    ///
    /// Used for ticket claim verification during block import.
    /// Not used with Safrole test vectors.
    ///
    /// On success returns the VRF output hash.
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

        let input = vrf_input_point(vrf_input_data).ok_or(VerifierError::VrfInputPointError)?;
        let output = signature.output;

        let public = self
            .ring
            .get(signer_key_index)
            .ok_or(VerifierError::InvalidSignerKeyIndex)?;

        public
            .verify(input, output, aux_data, &signature.proof)
            .map_err(|_| VerifierError::VerificationFailed)?;

        // This is the actual value used as ticket-id/score
        // NOTE: as far as vrf_input_data is the same, this matches the one produced
        // using the ring-vrf (regardless of aux_data).
        let vrf_output_hash: [u8; 32] = output.hash()[..32]
            .try_into()
            .expect("VRF output hash should be 32 bytes");
        // println!(" vrf-output-hash: {}", hex::encode(vrf_output_hash));
        Ok(vrf_output_hash)
    }

    /// Verifies an anonymous ring VRF signature.
    ///
    /// This method verifies that a signature was created by one of the public keys in the ring,
    /// while maintaining the anonymity of the actual signer. Used primarily for validating lottery
    /// tickets where the winner's identity should remain hidden.
    pub fn ring_vrf_verify(
        &self,
        vrf_input_data: &[u8],
        aux_data: &[u8],
        signature: &[u8],
    ) -> Result<[u8; 32], VerifierError> {
        use ark_ec_vrfs::ring::Verifier as _;

        let signature = RingVrfSignature::deserialize_compressed(signature)
            .map_err(|_| VerifierError::DeserializationError)?;

        let input = vrf_input_point(vrf_input_data).ok_or(VerifierError::VrfInputPointError)?;
        let output = signature.output;

        let ring_ctx = ring_context(self.ring.len())?;

        // Reconstruct verifier key from cached commitment for efficiency.
        // This is faster than regenerating it via RingContext::verifier_key()
        // since we only need to recompute the commitment when the keyset changes.
        let verifier_key = ring_ctx.verifier_key_from_commitment(self.commitment.clone());
        let verifier = ring_ctx.verifier(verifier_key);

        Public::verify(input, output, aux_data, &signature.proof, &verifier)
            .map_err(|_| VerifierError::VerificationFailed)?;

        let vrf_output_hash: [u8; 32] = output.hash()[..32]
            .try_into()
            .expect("VRF output hash should be 32 bytes");

        Ok(vrf_output_hash)
    }

    /// Returns the commitment for this verifier
    pub fn get_commitment(&self) -> RingCommitment {
        self.commitment.clone()
    }
}
