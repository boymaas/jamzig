use crate::ring_vrf::*;

// Function to generate a ring signature
/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - All input pointers are valid and point to memory regions of at least their respective lengths.
/// - `output` points to a memory region of at least `*output_len` bytes.
/// - The memory regions do not overlap.
/// - The lifetimes of the input data outlive the function call.
#[no_mangle]
pub unsafe extern "C" fn generate_ring_signature(
    public_keys: *const u8,
    public_keys_len: usize,
    vrf_input_data: *const u8,
    vrf_input_len: usize,
    aux_data: *const u8,
    aux_data_len: usize,
    prover_idx: usize,
    prover_key: *const u8,
    output: *mut u8,
) -> bool {
    let public_keys_slice = std::slice::from_raw_parts(public_keys, public_keys_len * 32);

    let ring: Vec<Public> = public_keys_slice
        .chunks(32)
        .map(|chunk| Public::deserialize_compressed(chunk).unwrap())
        .collect();

    let prover_key_slice = std::slice::from_raw_parts(prover_key, 64);

    let prover_secret = Secret::deserialize_compressed(prover_key_slice).unwrap();
    let prover = Prover::new(ring.clone(), prover_secret, prover_idx);

    let vrf_input = std::slice::from_raw_parts(vrf_input_data, vrf_input_len);
    let aux = std::slice::from_raw_parts(aux_data, aux_data_len);

    let signature = prover.ring_vrf_sign(vrf_input, aux);
    assert!(signature.len() == 784);

    std::ptr::copy_nonoverlapping(signature.as_ptr(), output, 784);

    true
}

// Function to verify a ring signature
//
/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - All input pointers are valid and point to memory regions of at least their respective lengths.
/// - `vrf_output` points to a memory region of at least 32 bytes.
/// - The memory regions do not overlap.
/// - The lifetimes of the input data outlive the function call.
#[no_mangle]
pub unsafe extern "C" fn verify_ring_signature(
    public_keys: *const u8,
    public_keys_len: usize,
    vrf_input_data: *const u8,
    vrf_input_len: usize,
    aux_data: *const u8,
    aux_data_len: usize,
    signature: *const u8,
    vrf_output: *mut u8,
) -> bool {
    let public_keys_slice = std::slice::from_raw_parts(public_keys, public_keys_len * 32);
    let ring: Vec<Public> = public_keys_slice
        .chunks(32)
        .map(|chunk| Public::deserialize_compressed(chunk).unwrap())
        .collect();

    let verifier = Verifier::new(ring);

    let vrf_input = std::slice::from_raw_parts(vrf_input_data, vrf_input_len);
    let aux = std::slice::from_raw_parts(aux_data, aux_data_len);

    let sig = std::slice::from_raw_parts(signature, 784);

    match verifier.ring_vrf_verify(vrf_input, aux, sig) {
        Ok(output) => {
            std::ptr::copy_nonoverlapping(output.as_ptr(), vrf_output, 32);
            true
        }
        Err(_) => false,
    }
}

/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - All input pointers are valid and point to memory regions of at least their respective lengths.
/// - The memory regions do not overlap.
/// - The lifetimes of the input data outlive the function call.
#[no_mangle]
pub unsafe extern "C" fn verify_ring_signature_against_commitment(
    commitment: *const u8,
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

    // TODO: Clean this up, remove unwraps, and implement more fine-grained error handling.
    let verifier =
        CommitmentVerifier::new(RingCommitment::deserialize_compressed(commitment_slice).unwrap());

    match verifier.ring_vrf_verify(vrf_input, aux, sig) {
        Ok(output) => {
            std::ptr::copy_nonoverlapping(output.as_ptr(), vrf_output, 32);
            true
        }
        Err(_) => false,
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

/// # Safety
#[no_mangle]
pub unsafe extern "C" fn get_padding_point(output: *mut u8) -> bool {
    let padding_point = Public::from(ring_context().padding_point());
    let mut serialized = Vec::new();
    if padding_point.serialize_compressed(&mut serialized).is_err() {
        return false;
    }

    unsafe {
        std::ptr::copy_nonoverlapping(serialized.as_ptr(), output, 32);
    }

    true
}

/// # Safety
///
/// This function is unsafe because it dereferences raw pointers.
/// The caller must ensure that:
/// - `output` points to a memory region of at exactly 144 bytes.
/// - The lifetime of the output data outlives the function call.
#[no_mangle]
pub unsafe extern "C" fn get_verifier_commitment(
    public_keys: *const u8,
    public_keys_len: usize,
    output: *mut u8,
) -> bool {
    let public_keys_slice = std::slice::from_raw_parts(public_keys, public_keys_len * 32);
    let ring: Vec<Public> = public_keys_slice
        .chunks(32)
        .map(|chunk| Public::deserialize_compressed(chunk).unwrap())
        .collect();

    let verifier = Verifier::new(ring);
    let commitment = verifier.commitment;

    // Serialize and print the commitment as a hexstring
    let mut commitment_bytes = Vec::new();
    commitment
        .serialize_compressed(&mut commitment_bytes)
        .unwrap();

    std::ptr::copy_nonoverlapping(commitment_bytes.as_ptr(), output, 144);
    true
}

/// # Safety
///
/// This function is unsafe because it triggers the initialization of the ring context.
/// It should be called before any other operations that require the ring context.
#[no_mangle]
pub unsafe extern "C" fn initialize_ring_context() {
    ring_context();
}
