use ark_ec_vrfs::suites::bandersnatch::edwards as bandersnatch;
use ark_ec_vrfs::{prelude::ark_serialize, suites::bandersnatch::edwards::RingContext};
use ark_serialize::CanonicalDeserialize;

// Include the binary data directly in the compiled binary
static ZCASH_SRS: &[u8] = include_bytes!("../../data/zcash-srs-2-11-uncompressed.bin");

use lru::LruCache;
use std::sync::OnceLock;
use std::{num::NonZeroUsize, sync::Mutex};

static PCS_PARAMS: OnceLock<bandersnatch::PcsParams> = OnceLock::new();
static RING_CONTEXT_CACHE: OnceLock<Mutex<LruCache<usize, RingContext>>> = OnceLock::new();
const RING_CONTEXT_CACHE_CAPACITY: usize = 10; // Adjust this value as needed

fn init_pcs_params() -> bandersnatch::PcsParams {
    bandersnatch::PcsParams::deserialize_uncompressed_unchecked(ZCASH_SRS).expect("Failed to deserialize PcsParams from ZCASH_SRS")
}
// "Static" ring context data
pub fn ring_context(ring_size: usize) -> RingContext {
    let pcs_params = PCS_PARAMS.get_or_init(init_pcs_params);

    let cache = RING_CONTEXT_CACHE.get_or_init(|| {
        Mutex::new(LruCache::new(
            NonZeroUsize::new(RING_CONTEXT_CACHE_CAPACITY).unwrap(),
        ))
    });
    let mut cache = cache.lock().unwrap();

    if let Some(ctx) = cache.get(&ring_size) {
        ctx.clone()
    } else {
        let ctx = RingContext::from_srs(ring_size, pcs_params.clone()).unwrap();
        cache.put(ring_size, ctx.clone());
        ctx
    }
}
