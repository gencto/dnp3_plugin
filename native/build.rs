// Emits `cfg(has_serial)` on targets where the `serial` feature of `dnp3` is enabled
// (see the target-specific dependency in Cargo.toml).
fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_serial)");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let family = std::env::var("CARGO_CFG_TARGET_FAMILY").unwrap_or_default();
    let apple_mobile = matches!(os.as_str(), "ios" | "tvos" | "watchos" | "visionos");
    if !apple_mobile && family != "wasm" {
        println!("cargo::rustc-cfg=has_serial");
    }
}
