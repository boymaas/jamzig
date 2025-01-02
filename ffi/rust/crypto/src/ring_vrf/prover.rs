use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_serialize::CanonicalSerialize;
use bandersnatch::{Public, Secret};
use thiserror::Error;

use crate::ring_vrf::{
  context::{ring_context, RingContextError},
  types::{vrf_input_point, IetfVrfSignature, RingVrfSignature},
};

#[derive(Error, Debug)]
pub enum ProverError {
  #[error("Failed to serialize signature")]
  SerializationError,
  #[error("Invalid prover index")]
  InvalidProverIndex,
  #[error(transparent)]
  RingContextError(#[from] RingContextError),
  #[error("Invalid VRF input point")]
  VrfInputPointError,
}

/// Ring VRF Prover.
///
/// Used to create anonymous ring VRF signatures.
pub struct Prover {
  /// Prover's secret key
  pub secret: Secret,
  /// Ring of public keys
  pub ring: Vec<Public>,
  /// Position of the corresponding Prover's public key in the ring
  pub prover_idx: usize,
}

impl Prover {
  /// Constructs a new Ring VRF Prover instance.
  ///
  /// # Parameters
  /// * `ring` - Vector of public keys forming the anonymity set
  /// * `prover_secret` - The prover's secret key
  /// * `prover_idx` - Zero-based index where the prover's public key appears in the ring
  ///
  /// The prover's public key (derived from `prover_secret`) must match the public key
  /// at position `prover_idx` in the ring for signatures to be valid.
  pub fn new(
    ring: Vec<Public>,
    prover_secret: Secret,
    prover_idx: usize,
  ) -> Self {
    Self {
      prover_idx,
      secret: prover_secret,
      ring,
    }
  }

  /// Non-Anonymous VRF signature.
  ///
  /// Used for ticket claiming during block production.
  /// Only vrf_input_data affects the VRF output.
  pub fn ietf_vrf_sign(
    &self,
    vrf_input_data: &[u8],
    aux_data: &[u8],
  ) -> Result<Vec<u8>, ProverError> {
    use ark_ec_vrfs::ietf::Prover as _;

    let input =
      vrf_input_point(vrf_input_data).ok_or(ProverError::VrfInputPointError)?;
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

  /// Creates an anonymous VRF signature that provides ring signature anonymity.
  ///
  /// # Parameters
  /// * `vrf_input_data` - Primary input that determines the VRF output
  /// * `aux_data` - Additional data to bind to the signature (does not affect VRF output)
  ///
  /// # Anonymity
  /// The resulting signature is cryptographically indistinguishable from one produced
  /// by any other member of the ring, providing k-anonymity where k is the ring size.
  ///
  /// # Returns
  /// A serialized signature containing both the VRF output and ring proof.
  pub fn ring_vrf_sign(
    &self,
    vrf_input_data: &[u8],
    aux_data: &[u8],
  ) -> Result<Vec<u8>, ProverError> {
    use ark_ec_vrfs::ring::Prover as _;

    let input =
      vrf_input_point(vrf_input_data).ok_or(ProverError::VrfInputPointError)?;
    let output = self.secret.output(input);

    // Backend currently requires the wrapped type (plain affine points)
    let pts: Vec<_> = self.ring.iter().map(|pk| pk.0).collect();

    // Proof construction
    let ring_ctx = ring_context(pts.len())?;
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
}

/// Deterministically derives a VRF secret key from the provided seed bytes.
///
/// The seed should be cryptographically secure random bytes to ensure the
/// generated secret key is secure. The same seed will always produce the
/// same secret key.
pub fn new_secret_from_seed(seed: &[u8]) -> Secret {
  Secret::from_seed(seed)
}

/// Derives the corresponding public key from a VRF secret key.
///
/// This is a deterministic operation - the same secret key will always
/// produce the same public key.
pub fn secret_to_public(secret: &Secret) -> Public {
  secret.public()
}
