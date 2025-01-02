use ark_ec_vrfs::prelude::ark_serialize;
use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use bandersnatch::{IetfProof, Input, Output, Public, Secret};
use libc::{c_int, size_t};
use std::ptr;
use std::slice;

// Constants defined according to section G of the whitepaper
// "The singly-contextualized Bandersnatch Schnorr-like signatures"
const SECRET_LENGTH: usize = 32; // Secret key length in bytes
const PUBLIC_LENGTH: usize = 32; // Public key length in bytes
const SIGNATURE_LENGTH: usize = 96; // F_m_k<c> ⊂ Y_96 signature length from equation G.1
const OUTPUT_LENGTH: usize = 32; // VRF output hash length Y(s ∈ F_m_k<c>) ∈ H from equation G.2

/// Represents a complete VRF signature according to equation G.1 in the whitepaper
#[derive(CanonicalSerialize, CanonicalDeserialize, Clone)]
pub struct BandersnatchSignature {
  output: Output,   // VRF output component
  proof: IetfProof, // Proof component
}

/// Creates the VRF input point from input data
/// This is used as part of the input to F_m_k<c> as defined in equation G.1
fn create_vrf_input(input_data: &[u8]) -> Input {
  Input::new(input_data).unwrap()
}

/// Creates a non-anonymous VRF signature as defined in equation G.1
///
/// Used for ticket claiming during block production
/// Only vrf_input_data affects the VRF output according to equation G.2
fn bandersnatch_sign_impl(
  secret: Secret,
  vrf_input_data: &[u8],
  context_data: &[u8],
) -> BandersnatchSignature {
  use ark_ec_vrfs::ietf::Prover as _;

  let input = create_vrf_input(vrf_input_data);
  let output = secret.output(input);
  let proof = secret.prove(input, output, context_data);

  BandersnatchSignature { output, proof }
}

/// Verifies a non-anonymous VRF signature according to equation G.1
///
/// Used for ticket claim verification during block import
/// Returns the VRF output hash Y(s) as defined in equation G.2 on success
fn bandersnatch_verify_impl(
  public: Public,
  vrf_input_data: &[u8],
  context_data: &[u8],
  signature: BandersnatchSignature,
) -> Result<[u8; 32], ()> {
  use ark_ec_vrfs::ietf::Verifier as _;

  let input = create_vrf_input(vrf_input_data);
  let output = signature.output;

  // Verify according to equation G.1
  public
    .verify(input, output, context_data, &signature.proof)
    .map_err(|_| ())?;

  // Extract VRF output hash according to equation G.2
  let mut vrf_output_hash = [0u8; OUTPUT_LENGTH];
  vrf_output_hash.copy_from_slice(&output.hash()[..OUTPUT_LENGTH]);
  Ok(vrf_output_hash)
}

/// Creates a new Bandersnatch secret key from a seed
///
/// Writes the secret to secret_out which must be BANDERSNATCH_SECRET_LENGTH bytes
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn bandersnatch_new_secret(
  seed: *const u8,
  seed_len: size_t,
  secret_out: *mut u8,
) -> c_int {
  if seed.is_null() || secret_out.is_null() {
    return -1;
  }

  let seed_slice = std::slice::from_raw_parts(seed, seed_len);
  let secret = Secret::from_seed(seed_slice);
  let mut secret_buf = [0u8; SECRET_LENGTH];

  if secret.serialize_compressed(&mut secret_buf[..]).is_err() {
    return -1;
  }

  ptr::copy_nonoverlapping(secret_buf.as_ptr(), secret_out, SECRET_LENGTH);

  0
}

/// Derives the public key from a Bandersnatch secret key
///
/// Writes the public key to public_out which must be BANDERSNATCH_PUBLIC_LENGTH bytes
/// Returns 0 on success, -1 on error  
#[no_mangle]
pub unsafe extern "C" fn bandersnatch_derive_public(
  secret: *const u8,
  public_out: *mut u8,
) -> c_int {
  if secret.is_null() || public_out.is_null() {
    return -1;
  }

  let secret_slice = std::slice::from_raw_parts(secret, SECRET_LENGTH);

  let secret = if let Ok(s) = Secret::deserialize_compressed(secret_slice) {
    s
  } else {
    return -1;
  };

  let public = secret.public();

  let mut public_buf = [0u8; PUBLIC_LENGTH];
  if public.serialize_compressed(&mut public_buf[..]).is_err() {
    return -1;
  }

  ptr::copy_nonoverlapping(public_buf.as_ptr(), public_out, PUBLIC_LENGTH);

  0
}

/// Creates a VRF signature according to equation G.1
///
/// Writes signature to signature_out which must be BANDERSNATCH_SIGNATURE_LENGTH bytes
/// The secret key must be BANDERSNATCH_SECRET_LENGTH bytes
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn bandersnatch_sign(
  secret: *const u8,
  vrf_input_data: *const u8,
  vrf_input_len: size_t,
  context_data: *const u8,
  context_len: size_t,
  signature_out: *mut u8,
) -> c_int {
  if secret.is_null()
    || vrf_input_data.is_null()
    || context_data.is_null()
    || signature_out.is_null()
  {
    return -1;
  }

  let secret_slice = slice::from_raw_parts(secret, SECRET_LENGTH);
  let vrf_input = slice::from_raw_parts(vrf_input_data, vrf_input_len);
  let context = slice::from_raw_parts(context_data, context_len);

  let secret = if let Ok(s) = Secret::deserialize_compressed(secret_slice) {
    s
  } else {
    return -1;
  };

  let signature = bandersnatch_sign_impl(secret, vrf_input, context);

  let mut signature_buf = [0u8; SIGNATURE_LENGTH];
  if signature
    .serialize_compressed(&mut signature_buf[..])
    .is_err()
  {
    return -1;
  }

  ptr::copy_nonoverlapping(
    signature_buf.as_ptr(),
    signature_out,
    signature_buf.len(),
  );

  0
}

/// Verifies a VRF signature according to equation G.1
///
/// On success, writes the VRF output hash Y(s) defined in equation G.2 to output_hash_out
/// which must be BANDERSNATCH_OUTPUT_LENGTH bytes
///
/// The public key must be BANDERSNATCH_PUBLIC_LENGTH bytes
/// The signature must be BANDERSNATCH_SIGNATURE_LENGTH bytes
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn bandersnatch_verify(
  public_key: *const u8,
  vrf_input_data: *const u8,
  vrf_input_len: size_t,
  context_data: *const u8,
  context_len: size_t,
  signature: *const u8,
  output_hash_out: *mut u8,
) -> c_int {
  if public_key.is_null()
    || vrf_input_data.is_null()
    || context_data.is_null()
    || signature.is_null()
    || output_hash_out.is_null()
  {
    return -1;
  }

  let public_key = std::slice::from_raw_parts(public_key, PUBLIC_LENGTH);
  let vrf_input = std::slice::from_raw_parts(vrf_input_data, vrf_input_len);
  let context = std::slice::from_raw_parts(context_data, context_len);
  let signature = std::slice::from_raw_parts(signature, SIGNATURE_LENGTH);

  let public = if let Ok(p) = Public::deserialize_compressed(public_key) {
    p
  } else {
    return -1;
  };

  let signature =
    if let Ok(s) = BandersnatchSignature::deserialize_compressed(signature) {
      s
    } else {
      return -1;
    };

  if let Ok(vrf_hash) =
    bandersnatch_verify_impl(public, vrf_input, context, signature)
  {
    std::ptr::copy_nonoverlapping(
      vrf_hash.as_ptr(),
      output_hash_out,
      OUTPUT_LENGTH,
    );
    0
  } else {
    -1
  }
}

/// Extracts the VRF output hash Y(s) from a signature according to equation G.2
///
/// Writes the output hash to output_hash_out which must be BANDERSNATCH_OUTPUT_LENGTH bytes
/// The signature must be BANDERSNATCH_SIGNATURE_LENGTH bytes
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn bandersnatch_output_hash(
  signature: *const u8,
  output_hash_out: *mut u8,
) -> c_int {
  if signature.is_null() || output_hash_out.is_null() {
    return -1;
  }

  let signature = std::slice::from_raw_parts(signature, SIGNATURE_LENGTH);

  let signature =
    if let Ok(s) = BandersnatchSignature::deserialize_compressed(signature) {
      s
    } else {
      return -1;
    };

  let output_hash = signature.output.hash();
  std::ptr::copy_nonoverlapping(
    output_hash.as_ptr(),
    output_hash_out,
    OUTPUT_LENGTH,
  );

  0
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn test_bandersnatch_signatures() {
    let secret = Secret::from_seed(&42_usize.to_le_bytes());

    // Create and verify a non-anonymous VRF signature
    let signature = bandersnatch_sign_impl(
      secret.clone(),
      "message".as_bytes(),
      "context".as_bytes(),
    );

    // Verify signature against known signer identity
    bandersnatch_verify_impl(
      secret.public(),
      "message".as_bytes(),
      "context".as_bytes(),
      signature,
    )
    .unwrap();
  }
}
