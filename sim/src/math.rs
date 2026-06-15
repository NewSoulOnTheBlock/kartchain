//! Pure-Rust math wrappers. Everything here either uses `libm` (which
//! compiles to host-free deterministic WASM instructions) or is implemented
//! inline. **Do not** call `f32::sin`/`f32::cos`/etc. anywhere in this
//! crate — those go through host imports and break cross-runtime
//! determinism in WASM.

#[inline]
pub fn sin(x: f32) -> f32 { libm::sinf(x) }

#[inline]
pub fn cos(x: f32) -> f32 { libm::cosf(x) }

#[inline]
pub fn abs(x: f32) -> f32 { libm::fabsf(x) }

#[inline]
pub fn max(a: f32, b: f32) -> f32 {
    // Avoid f32::max because it dispatches through fmaxf which (per LLVM)
    // can pick a host implementation. libm::fmaxf is in-crate and
    // deterministic.
    libm::fmaxf(a, b)
}

#[inline]
pub fn min(a: f32, b: f32) -> f32 { libm::fminf(a, b) }

#[inline]
pub fn clamp(v: f32, lo: f32, hi: f32) -> f32 { max(lo, min(hi, v)) }

#[inline]
pub fn sign(v: f32) -> f32 { if v >= 0.0 { 1.0 } else { -1.0 } }
