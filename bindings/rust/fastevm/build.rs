//! Links libfastevm.so from `FASTEVM_LIB_DIR` (default: the fastevm CMake build directory).
//!
//! The library is copied into `OUT_DIR` and linked from there: Cargo adds native search paths
//! inside the target directory to the loader path of `cargo test` / `cargo run`, which also
//! covers dependents (an rpath link argument would only apply to this package's own targets).
//! Installed binaries need `LD_LIBRARY_PATH` or the library on the system path.

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=FASTEVM_LIB_DIR");
    let dir = std::env::var_os("FASTEVM_LIB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../build"));
    let lib = dir.join("libfastevm.so");
    println!("cargo:rerun-if-changed={}", lib.display());
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"));
    std::fs::copy(&lib, out.join("libfastevm.so"))
        .unwrap_or_else(|e| panic!("copy {}: {e} (build fastevm or set FASTEVM_LIB_DIR)", lib.display()));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=dylib=fastevm");
}
