//! ZIP-215 compliant Ed25519 signature verification
//!
//! This module provides FFI bindings for ed25519-consensus, ensuring consistent
//! signature validation across all JAM implementations per ZIP-215 specification.

use ed25519_consensus::{Signature, VerificationKey};
use libc::c_int;
use std::convert::TryFrom;

const PUBLIC_KEY_LENGTH: usize = 32;
const SIGNATURE_LENGTH: usize = 64;

/// Verify an Ed25519 signature using ZIP-215 compliant validation rules.
///
/// ZIP-215 ensures deterministic validation that is consistent with batch
/// verification and backwards-compatible with all existing Ed25519 signatures.
///
/// # Arguments
/// * `public_key` - 32-byte Ed25519 public key
/// * `signature` - 64-byte Ed25519 signature
/// * `message` - Message bytes that were signed
/// * `message_len` - Length of message in bytes
///
/// # Returns
/// * `0` - Signature is valid
/// * `-1` - Signature is invalid or inputs are malformed
///
/// # Safety
/// Caller must ensure all pointers are valid and point to appropriately sized buffers.
#[no_mangle]
pub unsafe extern "C" fn ed25519_verify(
  public_key: *const u8,
  signature: *const u8,
  message: *const u8,
  message_len: usize,
) -> c_int {
  if public_key.is_null() || signature.is_null() {
    return -1;
  }

  // Allow null message only if length is 0
  if message.is_null() && message_len > 0 {
    return -1;
  }

  let pk_bytes: [u8; PUBLIC_KEY_LENGTH] =
    match std::slice::from_raw_parts(public_key, PUBLIC_KEY_LENGTH).try_into() {
      Ok(bytes) => bytes,
      Err(_) => return -1,
    };

  let sig_bytes: [u8; SIGNATURE_LENGTH] =
    match std::slice::from_raw_parts(signature, SIGNATURE_LENGTH).try_into() {
      Ok(bytes) => bytes,
      Err(_) => return -1,
    };

  let msg = if message_len == 0 {
    &[]
  } else {
    std::slice::from_raw_parts(message, message_len)
  };

  // ZIP-215 compliant verification
  let vk = match VerificationKey::try_from(pk_bytes) {
    Ok(k) => k,
    Err(_) => return -1,
  };

  let sig = Signature::from(sig_bytes);

  match vk.verify(&sig, msg) {
    Ok(()) => 0,
    Err(_) => -1,
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use ed25519_consensus::SigningKey;
  use rand::thread_rng;

  #[test]
  fn test_corrupted_signature_fails() {
    // Generate a valid keypair and sign a message
    let sk = SigningKey::new(thread_rng());
    let vk = VerificationKey::from(&sk);
    let msg = b"test message";
    let sig = sk.sign(msg);

    let vk_bytes: [u8; 32] = vk.into();
    let mut sig_bytes: [u8; 64] = sig.into();

    // Corrupt the signature
    sig_bytes[32] ^= 0xff;

    // Verification should fail for corrupted signature
    let ffi_result = unsafe {
      ed25519_verify(
        vk_bytes.as_ptr(),
        sig_bytes.as_ptr(),
        msg.as_ptr(),
        msg.len(),
      )
    };
    assert_eq!(ffi_result, -1, "FFI should reject corrupted signature");
  }

  #[test]
  fn test_invalid_public_key_encoding() {
    // A public key with the high bit set in the wrong way is invalid
    let mut invalid_pk: [u8; 32] = [0xff; 32];
    invalid_pk[31] = 0xff; // Invalid encoding
    let zero_sig: [u8; 64] = [0u8; 64];
    let msg = b"test message";

    // Test via FFI - should reject invalid public key encoding
    let ffi_result = unsafe {
      ed25519_verify(
        invalid_pk.as_ptr(),
        zero_sig.as_ptr(),
        msg.as_ptr(),
        msg.len(),
      )
    };
    assert_eq!(ffi_result, -1, "FFI should reject invalid public key encoding");
  }

  #[test]
  fn test_sign_and_verify() {
    let sk = SigningKey::new(thread_rng());
    let vk = VerificationKey::from(&sk);
    let msg = b"test message for ed25519-consensus";

    let sig = sk.sign(msg);

    let vk_bytes: [u8; 32] = vk.into();
    let sig_bytes: [u8; 64] = sig.into();

    // Test via FFI
    let result = unsafe {
      ed25519_verify(
        vk_bytes.as_ptr(),
        sig_bytes.as_ptr(),
        msg.as_ptr(),
        msg.len(),
      )
    };

    assert_eq!(result, 0, "Valid signature should verify");
  }

  #[test]
  fn test_invalid_signature() {
    let sk = SigningKey::new(thread_rng());
    let vk = VerificationKey::from(&sk);
    let msg = b"test message";

    let sig = sk.sign(msg);

    let vk_bytes: [u8; 32] = vk.into();
    let mut sig_bytes: [u8; 64] = sig.into();

    // Corrupt the signature
    sig_bytes[0] ^= 0xff;

    let result = unsafe {
      ed25519_verify(
        vk_bytes.as_ptr(),
        sig_bytes.as_ptr(),
        msg.as_ptr(),
        msg.len(),
      )
    };

    assert_eq!(result, -1, "Invalid signature should fail verification");
  }

  #[test]
  fn test_wrong_message() {
    let sk = SigningKey::new(thread_rng());
    let vk = VerificationKey::from(&sk);
    let msg = b"original message";
    let wrong_msg = b"different message";

    let sig = sk.sign(msg);

    let vk_bytes: [u8; 32] = vk.into();
    let sig_bytes: [u8; 64] = sig.into();

    let result = unsafe {
      ed25519_verify(
        vk_bytes.as_ptr(),
        sig_bytes.as_ptr(),
        wrong_msg.as_ptr(),
        wrong_msg.len(),
      )
    };

    assert_eq!(result, -1, "Signature for different message should fail");
  }

  #[test]
  fn test_empty_message() {
    let sk = SigningKey::new(thread_rng());
    let vk = VerificationKey::from(&sk);
    let msg: &[u8] = b"";

    let sig = sk.sign(msg);

    let vk_bytes: [u8; 32] = vk.into();
    let sig_bytes: [u8; 64] = sig.into();

    let result = unsafe {
      ed25519_verify(
        vk_bytes.as_ptr(),
        sig_bytes.as_ptr(),
        msg.as_ptr(),
        msg.len(),
      )
    };

    assert_eq!(result, 0, "Empty message signature should verify");
  }
}
