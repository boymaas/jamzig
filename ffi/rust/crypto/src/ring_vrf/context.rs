use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_ec_vrfs::{prelude::ark_serialize, suites::bandersnatch::edwards::RingContext};
use ark_serialize::CanonicalDeserialize;
use lru::LruCache;
use std::sync::OnceLock;
use std::{num::NonZeroUsize, sync::Mutex};
use thiserror::Error;

// Include the binary data directly in the compiled binary
static ZCASH_SRS: &[u8] = include_bytes!("../../data/zcash-srs-2-11-uncompressed.bin");

static PCS_PARAMS: OnceLock<bandersnatch::PcsParams> = OnceLock::new();
static RING_CONTEXT_CACHE: OnceLock<Mutex<LruCache<usize, RingContext>>> = OnceLock::new();
const RING_CONTEXT_CACHE_CAPACITY: usize = 10;

#[derive(Error, Debug)]
pub enum RingContextError {
    #[error("Failed to create SRS")]
    SrsCreationError,
    #[error("Failed to lock cache")]
    CacheLockError,
}

fn init_pcs_params() -> bandersnatch::PcsParams {
    bandersnatch::PcsParams::deserialize_uncompressed_unchecked(ZCASH_SRS)
        .expect("Failed to deserialize Zcash SRS")
}

/// Creates or retrieves a cached RingContext for the specified ring size.
///
/// This function maintains a LRU cache of RingContexts to avoid expensive
/// recomputation. If a context for the given ring size exists in the cache,
/// it is returned. Otherwise, a new context is created, cached, and returned.
pub fn ring_context(ring_size: usize) -> Result<RingContext, RingContextError> {
    let pcs_params = PCS_PARAMS.get_or_init(init_pcs_params);

    let cache = RING_CONTEXT_CACHE.get_or_init(|| {
        Mutex::new(LruCache::new(
            NonZeroUsize::new(RING_CONTEXT_CACHE_CAPACITY)
                .expect("RING_CONTEXT_CACHE_CAPACITY must be non-zero"),
        ))
    });
    let mut cache = cache.lock().map_err(|_| RingContextError::CacheLockError)?;

    if let Some(ctx) = cache.get(&ring_size) {
        Ok(ctx.clone())
    } else {
        let ctx = RingContext::from_srs(ring_size, pcs_params.clone())
            .map_err(|_| RingContextError::SrsCreationError)?;
        cache.put(ring_size, ctx.clone());
        Ok(ctx)
    }
}
