use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_ec_vrfs::{prelude::ark_serialize, suites::bandersnatch::edwards::RingContext};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use bandersnatch::{IetfProof, Input, Output, Public, RingProof, Secret};

const RING_SIZE: usize = 1023;

// This is the IETF `Prove` procedure output as described in section 2.2
// of the Bandersnatch VRFs specification
#[derive(CanonicalSerialize, CanonicalDeserialize)]
struct IetfVrfSignature {
    output: Output,
    proof: IetfProof,
}

// This is the IETF `Prove` procedure output as described in section 4.2
// of the Bandersnatch VRFs specification
#[derive(CanonicalSerialize, CanonicalDeserialize)]
struct RingVrfSignature {
    output: Output,
    // This contains both the Pedersen proof and actual ring proof.
    proof: RingProof,
}

// Include the binary data directly in the compiled binary
static ZCASH_SRS: &[u8] = include_bytes!("../data/zcash-srs-2-11-uncompressed.bin");

// "Static" ring context data
fn ring_context() -> &'static RingContext {
    use std::sync::OnceLock;
    static RING_CTX: OnceLock<RingContext> = OnceLock::new();
    RING_CTX.get_or_init(|| {
        use bandersnatch::PcsParams;
        let pcs_params = PcsParams::deserialize_uncompressed_unchecked(ZCASH_SRS).unwrap();
        RingContext::from_srs(RING_SIZE, pcs_params).unwrap()
    })
}

// Construct VRF Input Point from arbitrary data (section 1.2)
fn vrf_input_point(vrf_input_data: &[u8]) -> Input {
    Input::new(vrf_input_data).unwrap()
}

// Prover actor.
struct Prover {
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
    pub fn ring_vrf_sign(&self, vrf_input_data: &[u8], aux_data: &[u8]) -> Vec<u8> {
        use ark_ec_vrfs::ring::Prover as _;

        let input = vrf_input_point(vrf_input_data);
        let output = self.secret.output(input);

        // Backend currently requires the wrapped type (plain affine points)
        let pts: Vec<_> = self.ring.iter().map(|pk| pk.0).collect();

        // Proof construction
        let ring_ctx = ring_context();
        let prover_key = ring_ctx.prover_key(&pts);
        let prover = ring_ctx.prover(prover_key, self.prover_idx);
        let proof = self.secret.prove(input, output, aux_data, &prover);

        // Output and Ring Proof bundled together (as per section 2.2)
        let signature = RingVrfSignature { output, proof };
        let mut buf = Vec::new();
        signature.serialize_compressed(&mut buf).unwrap();
        buf
    }

    /// Non-Anonymous VRF signature.
    ///
    /// Used for ticket claiming during block production.
    /// Not used with Safrole test vectors.
    pub fn ietf_vrf_sign(&self, vrf_input_data: &[u8], aux_data: &[u8]) -> Vec<u8> {
        use ark_ec_vrfs::ietf::Prover as _;

        let input = vrf_input_point(vrf_input_data);
        let output = self.secret.output(input);

        let proof = self.secret.prove(input, output, aux_data);

        // Output and IETF Proof bundled together (as per section 2.2)
        let signature = IetfVrfSignature { output, proof };
        let mut buf = Vec::new();
        signature.serialize_compressed(&mut buf).unwrap();
        buf
    }
}

type RingCommitment = ark_ec_vrfs::ring::RingCommitment<bandersnatch::BandersnatchSha512Ell2>;

// Verifier actor.
struct Verifier {
    pub commitment: RingCommitment,
    pub ring: Vec<Public>,
}

impl Verifier {
    fn new(ring: Vec<Public>) -> Self {
        // Backend currently requires the wrapped type (plain affine points)
        let pts: Vec<_> = ring.iter().map(|pk| pk.0).collect();
        let verifier_key = ring_context().verifier_key(&pts);
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
    ) -> Result<[u8; 32], ()> {
        use ark_ec_vrfs::ring::Verifier as _;

        let signature = RingVrfSignature::deserialize_compressed(signature).unwrap();

        let input = vrf_input_point(vrf_input_data);
        let output = signature.output;

        let ring_ctx = ring_context();
        //
        // The verifier key is reconstructed from the commitment and the constant
        // verifier key component of the SRS in order to verify some proof.
        // As an alternative we can construct the verifier key using the
        // RingContext::verifier_key() method, but is more expensive.
        // In other words, we prefer computing the commitment once, when the keyset changes.
        let verifier_key = ring_ctx.verifier_key_from_commitment(self.commitment.clone());
        let verifier = ring_ctx.verifier(verifier_key);
        if Public::verify(input, output, aux_data, &signature.proof, &verifier).is_err() {
            return Err(());
        }
        //
        // // This truncated hash is the actual value used as ticket-id/score in JAM
        let vrf_output_hash: [u8; 32] = output.hash()[..32].try_into().unwrap();
        Ok(vrf_output_hash)
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
    ) -> Result<[u8; 32], ()> {
        use ark_ec_vrfs::ietf::Verifier as _;

        let signature = IetfVrfSignature::deserialize_compressed(signature).unwrap();

        let input = vrf_input_point(vrf_input_data);
        let output = signature.output;

        let public = &self.ring[signer_key_index];
        if public
            .verify(input, output, aux_data, &signature.proof)
            .is_err()
        {
            println!("Ring signature verification failure");
            return Err(());
        }
        println!("Ietf signature verified");

        // This is the actual value used as ticket-id/score
        // NOTE: as far as vrf_input_data is the same, this matches the one produced
        // using the ring-vrf (regardless of aux_data).
        let vrf_output_hash: [u8; 32] = output.hash()[..32].try_into().unwrap();
        println!(" vrf-output-hash: {}", hex::encode(vrf_output_hash));
        Ok(vrf_output_hash)
    }
}

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
/// This function is unsafe because it triggers the initialization of the ring context.
/// It should be called before any other operations that require the ring context.
#[no_mangle]
pub unsafe extern "C" fn initialize_ring_context() {
    ring_context();
}
