//! FFI bindings for ChaCha8Rng, enabling Ruby to use the exact same PRNG
//! as the Rust combat engine for deterministic parity testing.

use rand::Rng;
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;

/// Create a new ChaCha8Rng seeded with the given u64 value.
/// Returns an opaque pointer that must be freed with `chacha8_free`.
#[no_mangle]
pub extern "C" fn chacha8_new(seed: u64) -> *mut ChaCha8Rng {
    let rng = Box::new(ChaCha8Rng::seed_from_u64(seed));
    Box::into_raw(rng)
}

/// Free a ChaCha8Rng previously created with `chacha8_new`.
///
/// # Safety
/// `ptr` must be a valid pointer returned by `chacha8_new` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn chacha8_free(ptr: *mut ChaCha8Rng) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

/// Generate a random u32 in [0, upper_exclusive).
/// If upper_exclusive is 0, returns a full-range u32.
///
/// # Safety
/// `ptr` must be a valid pointer returned by `chacha8_new`.
#[no_mangle]
pub unsafe extern "C" fn chacha8_rand_u32(ptr: *mut ChaCha8Rng, upper_exclusive: u32) -> u32 {
    let rng = &mut *ptr;
    if upper_exclusive == 0 {
        rng.gen()
    } else {
        rng.gen_range(0..upper_exclusive)
    }
}

/// Generate a random i32 in [low, high] (inclusive both ends).
///
/// # Safety
/// `ptr` must be a valid pointer returned by `chacha8_new`.
#[no_mangle]
pub unsafe extern "C" fn chacha8_rand_range(ptr: *mut ChaCha8Rng, low: i32, high: i32) -> i32 {
    let rng = &mut *ptr;
    if low >= high {
        return low;
    }
    rng.gen_range(low..=high)
}

/// Generate a random f64 in [0.0, 1.0).
///
/// # Safety
/// `ptr` must be a valid pointer returned by `chacha8_new`.
#[no_mangle]
pub unsafe extern "C" fn chacha8_rand_float(ptr: *mut ChaCha8Rng) -> f64 {
    let rng = &mut *ptr;
    rng.gen::<f64>()
}
