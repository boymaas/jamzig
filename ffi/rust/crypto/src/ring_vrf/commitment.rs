use ark_serialize::CanonicalDeserialize;
use ark_vrf::suites::bandersnatch::*;
use thiserror::Error;

use crate::ring_vrf::{
  context::{ring_context, RingContextError},
  types::{vrf_input_point, RingCommitment, RingVrfSignature},
};

/// Verify based on Commitment
///
/// This struct provides commitment-based verification without requiring
/// the full ring of public keys to be available.
pub struct Commitment {
  /// The commitment to verify against
  pub commitment: RingCommitment,
  /// Size of the ring that generated this commitment
  pub ring_size: usize,
}

#[derive(Error, Debug)]
pub enum Error {
  #[error("Signature verification failed")]
  SignatureVerificationFailed,
  #[error("Deserialization error")]
  DeserializationError,
  #[error("Invalid VRF input point")]
  VrfInputPointError,
  #[error(transparent)]
  RingContextError(#[from] RingContextError),
}

impl Commitment {
  /// Constructs a new Commitment verifier for Ring VRF signature validation.
  ///
  /// # Parameters
  /// * `commitment` - A pre-computed commitment representing the ring of public keys
  /// * `ring_size` - The number of public keys in the original ring
  ///
  /// This verifier enables efficient signature verification without requiring
  /// access to the complete set of public keys.
  pub fn new(commitment: RingCommitment, ring_size: usize) -> Self {
    Self {
      commitment,
      ring_size,
    }
  }

  /// Verifies a Ring VRF signature using a pre-computed commitment.
  ///
  /// # Parameters
  /// * `vrf_input_data` - The input data used to generate the VRF output
  /// * `aux_data` - Additional data that was bound to the signature
  /// * `signature` - The serialized Ring VRF signature to verify
  ///
  /// # Returns
  /// * `Ok([u8; 32])` - The VRF output hash if verification succeeds
  /// * `Err(Error)` - If signature verification fails or input is invalid
  ///
  /// # Performance
  /// This method is more efficient than full ring verification since it uses
  /// a cached commitment instead of processing the complete ring of public keys.
  pub fn ring_vrf_verify(
    &self,
    vrf_input_data: &[u8],
    aux_data: &[u8],
    signature: &[u8],
  ) -> Result<[u8; 32], Error> {
    use ark_vrf::ring::Verifier as _;

    let signature = RingVrfSignature::deserialize_compressed(signature)
      .map_err(|_| Error::DeserializationError)?;

    let input =
      vrf_input_point(vrf_input_data).ok_or(Error::VrfInputPointError)?;
    let output = signature.output;

    let ring_ctx = ring_context(self.ring_size)?;
    let verifier_key =
      ring_ctx.verifier_key_from_commitment(self.commitment.clone());
    let verifier = ring_ctx.verifier(verifier_key);

    if Public::verify(input, output, aux_data, &signature.proof, &verifier)
      .is_err()
    {
      return Err(Error::SignatureVerificationFailed);
    }

    let vrf_output_hash: [u8; 32] = output.hash()[..32]
      .try_into()
      .expect("VRF output hash should be 32 bytes");

    Ok(vrf_output_hash)
  }

  /// Returns a reference to the ring commitment used for verification.
  ///
  /// This commitment is a compressed representation of the public key ring,
  /// previously generated from the complete set of public keys.
  pub fn get_commitment(&self) -> &RingCommitment {
    &self.commitment
  }

  /// Returns the number of public keys in the ring that generated this commitment.
  ///
  /// This size determines the anonymity set for signatures verified against
  /// this commitment.
  pub fn get_ring_size(&self) -> usize {
    self.ring_size
  }
}
