use super::commitment::Commitment;
use super::context::ring_context;
use super::prover::Prover;
use super::types::*;
use super::verifier::Verifier;
use libc::size_t;
use std::ptr;

/// Create a new Ring VRF Verifier.
///
/// The ring size is determined by the number of public keys passed (public_keys_len / PUBLIC_KEY_SIZE).
/// If any public key in the array is invalid or zeroed out, it will be replaced with a padding point
/// in the ring.
///
/// # Safety
/// - `public_keys` must point to a contiguous array of serialized public keys
#[no_mangle]
pub unsafe extern "C" fn new_ring_vrf_verifier(
  public_keys: *const u8,
  public_keys_len: size_t,
) -> *mut Verifier {
  debug_assert!(
    !public_keys.is_null(),
    "public_keys pointer must not be null"
  );
  debug_assert!(
    public_keys_len % PUBLIC_KEY_SIZE == 0,
    "public_keys_len must be a multiple of PUBLIC_KEY_SIZE"
  );

  let public_keys_slice =
    std::slice::from_raw_parts(public_keys, public_keys_len);
  let num_keys = public_keys_len / PUBLIC_KEY_SIZE;

  let padding_point = match ring_context(num_keys) {
    Ok(ctx) => ctx.padding_point(),
    Err(_) => return std::ptr::null_mut(),
  };
  let ring: Vec<Public> = public_keys_slice
    .chunks(PUBLIC_KEY_SIZE)
    .map(|chunk| {
      Public::deserialize_compressed(chunk)
        .unwrap_or(Public::from(padding_point))
    })
    .collect();

  if ring.len() != num_keys {
    return std::ptr::null_mut();
  }

  match Verifier::new(ring) {
    Ok(verifier) => Box::into_raw(Box::new(verifier)),
    Err(_) => std::ptr::null_mut(),
  }
}

/// Free a Ring VRF Verifier.
///
/// # Safety
/// - `verifier` must be a valid pointer returned by new_ring_vrf_verifier
#[no_mangle]
pub unsafe extern "C" fn free_ring_vrf_verifier(verifier: *mut Verifier) {
  debug_assert!(!verifier.is_null(), "verifier pointer must not be null");
  drop(Box::from_raw(verifier));
}

/// Create a new Ring VRF Prover.
///
/// # Safety
/// - All pointers must be valid and point to sufficient memory
#[no_mangle]
pub unsafe extern "C" fn new_ring_vrf_prover(
  secret: *const u8,
  public_keys: *const u8,
  public_keys_len: size_t,
  prover_idx: size_t,
) -> *mut Prover {
  debug_assert!(!secret.is_null(), "secret pointer must not be null");
  debug_assert!(
    !public_keys.is_null(),
    "public_keys pointer must not be null"
  );
  debug_assert!(
    public_keys_len % PUBLIC_KEY_SIZE == 0,
    "public_keys_len must be a multiple of PUBLIC_KEY_SIZE"
  );

  let secret_slice = std::slice::from_raw_parts(secret, SECRET_KEY_SIZE);
  let public_keys_slice =
    std::slice::from_raw_parts(public_keys, public_keys_len);

  let secret = if let Ok(s) = Secret::deserialize_compressed(secret_slice) {
    s
  } else {
    return std::ptr::null_mut();
  };

  let padding_point = match ring_context(public_keys_len / PUBLIC_KEY_SIZE) {
    Ok(ctx) => ctx.padding_point(),
    Err(_) => return std::ptr::null_mut(),
  };
  let ring: Vec<Public> = public_keys_slice
    .chunks(PUBLIC_KEY_SIZE)
    .map(|chunk| {
      Public::deserialize_compressed(chunk)
        .unwrap_or(Public::from(padding_point))
    })
    .collect();

  Box::into_raw(Box::new(Prover::new(ring, secret, prover_idx)))
}

/// Free a Ring VRF Prover.
///
/// # Safety
/// - `prover` must be a valid pointer returned by new_ring_vrf_prover
#[no_mangle]
pub unsafe extern "C" fn free_ring_vrf_prover(prover: *mut Prover) {
  debug_assert!(!prover.is_null(), "prover pointer must not be null");
  drop(Box::from_raw(prover));
}

/// Sign using a prover (either IETF or Ring VRF).
///
/// # Safety
/// - All pointers must be valid and point to sufficient memory
/// - `signature_out` must point to enough space for the signature
/// - `signature_size_out` will be set to the actual size written
#[no_mangle]
pub unsafe extern "C" fn vrf_sign(
  prover: *const Prover,
  vrf_input_data: *const u8,
  vrf_input_data_len: size_t,
  aux_data: *const u8,
  aux_data_len: size_t,
  signature_out: *mut u8,
  signature_size_out: *mut size_t,
) -> bool {
  debug_assert!(!prover.is_null(), "prover pointer must not be null");
  debug_assert!(
    !vrf_input_data.is_null(),
    "vrf_input_data pointer must not be null"
  );
  debug_assert!(!aux_data.is_null(), "aux_data pointer must not be null");
  debug_assert!(
    !signature_out.is_null(),
    "signature_out pointer must not be null"
  );
  debug_assert!(
    !signature_size_out.is_null(),
    "signature_size_out pointer must not be null"
  );

  let prover = &*prover;
  let vrf_input_data =
    std::slice::from_raw_parts(vrf_input_data, vrf_input_data_len);
  let aux_data = std::slice::from_raw_parts(aux_data, aux_data_len);

  let result = prover.ring_vrf_sign(vrf_input_data, aux_data);

  match result {
    Ok(signature) => {
      let size = signature.len();
      ptr::copy_nonoverlapping(signature.as_ptr(), signature_out, size);
      *signature_size_out = size;
      true
    }
    Err(_) => false,
  }
}

/// Verify using a verifier (either IETF or Ring VRF).
///
/// # Safety
/// - All pointers must be valid and point to sufficient memory
/// - `output_hash_out` must point to `VRF_HASH_OUTPUT_SIZE` bytes
#[no_mangle]
pub unsafe extern "C" fn vrf_verify(
  verifier: *const Verifier,
  vrf_input_data: *const u8,
  vrf_input_data_len: size_t,
  aux_data: *const u8,
  aux_data_len: size_t,
  signature: *const u8,
  signature_len: size_t,
  output_hash_out: *mut u8,
) -> bool {
  debug_assert!(!verifier.is_null(), "verifier pointer must not be null");
  debug_assert!(
    !vrf_input_data.is_null(),
    "vrf_input_data pointer must not be null"
  );
  debug_assert!(!aux_data.is_null(), "aux_data pointer must not be null");
  debug_assert!(!signature.is_null(), "signature pointer must not be null");
  debug_assert!(
    !output_hash_out.is_null(),
    "output_hash_out pointer must not be null"
  );

  let verifier = &*verifier;
  let vrf_input_data =
    std::slice::from_raw_parts(vrf_input_data, vrf_input_data_len);
  let aux_data = std::slice::from_raw_parts(aux_data, aux_data_len);
  let signature = std::slice::from_raw_parts(signature, signature_len);

  let result = verifier.ring_vrf_verify(vrf_input_data, aux_data, signature);

  match result {
    Ok(output_hash) => {
      ptr::copy_nonoverlapping(
        output_hash.as_ptr(),
        output_hash_out,
        output_hash.len(),
      );
      true
    }
    Err(_) => false,
  }
}

#[no_mangle]
pub unsafe extern "C" fn ietf_vrf_verify(
  verifier: *const Verifier,
  vrf_input_data: *const u8,
  vrf_input_data_len: size_t,
  aux_data: *const u8,
  aux_data_len: size_t,
  signature: *const u8,
  signature_len: size_t,
  signer_key_index: size_t,
  output: *mut u8,
  output_len: *mut size_t,
) -> bool {
  debug_assert!(!verifier.is_null(), "verifier pointer must not be null");
  debug_assert!(
    !vrf_input_data.is_null(),
    "vrf_input_data pointer must not be null"
  );
  debug_assert!(!aux_data.is_null(), "aux_data pointer must not be null");
  debug_assert!(!signature.is_null(), "signature pointer must not be null");
  debug_assert!(!output.is_null(), "output pointer must not be null");
  debug_assert!(!output_len.is_null(), "output_len pointer must not be null");

  let verifier = &*verifier;
  let vrf_input_slice =
    std::slice::from_raw_parts(vrf_input_data, vrf_input_data_len);
  let aux_data_slice = std::slice::from_raw_parts(aux_data, aux_data_len);
  let signature_slice = std::slice::from_raw_parts(signature, signature_len);

  match verifier.ietf_vrf_verify(
    vrf_input_slice,
    aux_data_slice,
    signature_slice,
    signer_key_index,
  ) {
    Ok(result) => {
      ptr::copy_nonoverlapping(result.as_ptr(), output, 32);
      *output_len = 32;
      true
    }
    Err(_) => false,
  }
}

/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - `output` points to a memory region of at exactly 144 bytes.
/// - The lifetime of the output data outlives the function call.
#[no_mangle]
pub unsafe extern "C" fn vrf_get_commitment(
  verifier: *const Verifier,
  output: *mut u8,
) -> bool {
  let verifier = &*verifier;
  let commitment = verifier.get_commitment();

  // Serialize and print the commitment as a hexstring
  let mut commitment_bytes = Vec::new();
  if commitment
    .serialize_compressed(&mut commitment_bytes)
    .is_err()
  {
    return false;
  }

  std::ptr::copy_nonoverlapping(commitment_bytes.as_ptr(), output, 144);
  true
}

/// Verify against commitment

/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - All input pointers are valid and point to memory regions of at least their respective lengths.
/// - The memory regions do not overlap.
/// - The lifetimes of the input data outlive the function call.
#[no_mangle]
pub unsafe extern "C" fn vrf_verify_ring_signature_against_commitment(
  commitment: *const u8,
  ring_size: usize,
  vrf_input_data: *const u8,
  vrf_input_len: usize,
  aux_data: *const u8,
  aux_data_len: usize,
  signature: *const u8,
  vrf_output: *mut u8,
) -> bool {
  let commitment_slice = std::slice::from_raw_parts(commitment, 144);

  let vrf_input = std::slice::from_raw_parts(vrf_input_data, vrf_input_len);
  let aux = std::slice::from_raw_parts(aux_data, aux_data_len);
  let sig = std::slice::from_raw_parts(signature, 784);

  let verifier = Commitment::new(
    match RingCommitment::deserialize_compressed(commitment_slice) {
      Ok(commitment) => commitment,
      Err(_) => return false,
    },
    ring_size,
  );

  match verifier.ring_vrf_verify(vrf_input, aux, sig) {
    Ok(output) => {
      std::ptr::copy_nonoverlapping(output.as_ptr(), vrf_output, 32);
      true
    }
    Err(_) => false,
  }
}

/// IETF VRF Sign (non-anonymous).
///
/// Creates a deterministic VRF signature from the Prover's secret key on the given input data.
/// The output VRF hash can be recovered by verifying the signature.
///
/// # Safety
/// - `prover` must be a valid pointer to a `Prover` created elsewhere.
/// - `vrf_input_data` must point to valid memory of length `vrf_input_data_len`.
/// - `aux_data` must point to valid memory of length `aux_data_len`.
/// - `signature_out` must point to enough space to hold the resulting signature.
/// - `signature_size_out` must point to a valid `size_t` that will be overwritten with the actual signature length.
#[no_mangle]
pub unsafe extern "C" fn ietf_vrf_sign(
  prover: *const Prover,
  vrf_input_data: *const u8,
  vrf_input_data_len: size_t,
  aux_data: *const u8,
  aux_data_len: size_t,
  signature_out: *mut u8,
  signature_size_out: *mut size_t,
) -> bool {
  debug_assert!(!prover.is_null(), "prover pointer must not be null");
  debug_assert!(
    !vrf_input_data.is_null(),
    "vrf_input_data pointer must not be null"
  );
  debug_assert!(!aux_data.is_null(), "aux_data pointer must not be null");
  debug_assert!(
    !signature_out.is_null(),
    "signature_out pointer must not be null"
  );
  debug_assert!(
    !signature_size_out.is_null(),
    "signature_size_out pointer must not be null"
  );

  let prover = &*prover;
  let vrf_input_slice =
    std::slice::from_raw_parts(vrf_input_data, vrf_input_data_len);
  let aux_data_slice = std::slice::from_raw_parts(aux_data, aux_data_len);

  let result = prover.ietf_vrf_sign(vrf_input_slice, aux_data_slice);

  match result {
    Ok(signature) => {
      let size = signature.len();
      ptr::copy_nonoverlapping(signature.as_ptr(), signature_out, size);
      *signature_size_out = size;
      true
    }
    Err(_) => false,
  }
}

/// Creates a new VRF key pair from a provided seed.
///
/// The function generates a deterministic key pair and serializes both the secret
/// and public keys into a single contiguous buffer.
///
/// # Parameters
/// * `seed` - Pointer to seed bytes used for key generation
/// * `seed_len` - Length of the seed in bytes
/// * `output` - Pointer to a buffer that will receive the serialized key pair
///             (must have space for SECRET_KEY_SIZE + PUBLIC_KEY_SIZE bytes)
///
/// # Returns
/// `true` if key pair generation and serialization succeeded, `false` otherwise
///
/// # Safety
/// - `seed` must point to valid memory of `seed_len` bytes
/// - `output` must point to valid memory of at least 64 bytes (SECRET_KEY_SIZE + PUBLIC_KEY_SIZE)
/// - Memory pointed to by `output` must be properly aligned and not overlap with `seed`
#[no_mangle]
pub unsafe extern "C" fn create_key_pair_from_seed(
  seed: *const u8,
  seed_len: usize,
  output: *mut u8,
) -> bool {
  let seed_slice = std::slice::from_raw_parts(seed, seed_len);
  let secret = Secret::from_seed(seed_slice);
  let public_key = secret.public();

  match serialize_key_pair(&secret, &public_key) {
    Some(serialized) => {
      std::ptr::copy_nonoverlapping(serialized.as_ptr(), output, 64);
      true
    }
    None => false,
  }
}

fn serialize_key_pair(secret: &Secret, public_key: &Public) -> Option<Vec<u8>> {
  let mut serialized = Vec::new();

  if secret.serialize_compressed(&mut serialized).is_err() {
    return None;
  }

  if public_key.serialize_compressed(&mut serialized).is_err() {
    return None;
  }

  Some(serialized)
}

/// # Safety
#[no_mangle]
pub unsafe extern "C" fn get_padding_point(
  ring_size: usize,
  output: *mut u8,
) -> bool {
  let padding_point = match ring_context(ring_size) {
    Ok(ctx) => Public::from(ctx.padding_point()),
    Err(_) => return false,
  };
  let mut serialized = Vec::new();
  if padding_point.serialize_compressed(&mut serialized).is_err() {
    return false;
  }

  unsafe {
    std::ptr::copy_nonoverlapping(serialized.as_ptr(), output, 32);
  }

  true
}
