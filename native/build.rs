// - Emits `cfg(has_serial)` on targets where the `serial` feature of `dnp3` is enabled
//   (see the target-specific dependency in Cargo.toml).
// - On Apple targets, links the dylib with an `@rpath` install name and enough header
//   padding for the Dart / Flutter tooling to rewrite install names (`install_name_tool`).
fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_serial)");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let family = std::env::var("CARGO_CFG_TARGET_FAMILY").unwrap_or_default();
    let vendor = std::env::var("CARGO_CFG_TARGET_VENDOR").unwrap_or_default();
    let apple_mobile = matches!(os.as_str(), "ios" | "tvos" | "watchos" | "visionos");
    if !apple_mobile && family != "wasm" {
        println!("cargo::rustc-cfg=has_serial");
    }
    if vendor == "apple" {
        println!("cargo::rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
        println!("cargo::rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdnp3_dart.dylib");
    }
}
