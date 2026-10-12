# Contributing to dnp3

Thanks for helping! This document explains how the project is organized, how to build and
test it, and what a pull request needs to be merged. By participating you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report bugs** with the [bug report form](https://github.com/gencto/dnp3_plugin/issues/new/choose).
  A minimal program that reproduces the problem (an outstation + master in one file, like
  [`example/example.dart`](example/example.dart)) is the most useful thing you can attach.
- **Test on your platform / device** — especially targets marked "untested" in the README,
  real serial hardware and third-party DNP3 devices — and report what works.
- **Improve documentation** (README, `doc/`, dartdoc comments, examples).
- **Fix bugs or add features.** For anything larger than a small fix, open an issue first so
  the design can be agreed on before you spend time on it.

Protocol behavior of the DNP3 stack itself (what the master or outstation sends on the
wire) comes from the [`dnp3`](https://github.com/stepfunc/dnp3) Rust library; issues there
belong upstream. This repository is the Dart API and the FFI bridge around it.

## Development setup

You need:

- Dart SDK ≥ 3.10 (or Flutter ≥ 3.38 for the Flutter example)
- Rust stable via [rustup](https://rustup.rs) (the minimum supported Rust version is 1.85)
- Linux only, for the serial test: `python3` (it creates a pseudo-terminal null-modem)
- Optional, for the TLS test: `openssl`

```sh
git clone https://github.com/gencto/dnp3_plugin && cd dnp3_plugin
dart pub get
dart test                     # the build hook compiles native/ on first run
```

The first `dart test` / `dart run` compiles the Rust crate in release mode with LTO and takes
a few minutes; later runs reuse the build.

## Repository layout

```
lib/dnp3.dart              public API (exports)
lib/src/                   Dart implementation
lib/src/native/            @Native bindings, per-isolate dispatcher, binary writer
native/                    Rust crate `dnp3_dart`: C ABI over the dnp3 crate
hook/build.dart            build hook: cargo build per target, or prebuilt libraries
test/                      integration tests (real master/outstation pairs)
example/                   CLI examples and a Flutter app
benchmark/                 benchmark suite and recorded results
doc/                       guides and the wire format between Dart and Rust
tool/                      code generators (variation tables) and small checks
```

[`doc/architecture.md`](doc/architecture.md) explains how calls, events and callbacks
travel between Dart and Rust; read it before changing the bridge.

## Checks (what CI runs)

Run these before opening a pull request; CI fails on any of them.

```sh
# Dart
dart analyze --fatal-infos
dart format -l 110 --output=none --set-exit-if-changed lib test hook benchmark \
  example/example.dart example/master.dart example/outstation.dart example/worker_isolate.dart
dart test --timeout 2x

# Rust
cd native
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

CI additionally runs the Dart tests on Linux x64/arm64, macOS and Windows, builds every
native target and builds the Flutter example for all five platforms.

## Coding guidelines

- **Format:** `dart format -l 110` and `cargo fmt`.
- **Documentation:** every public Dart member needs a `///` comment (`public_member_api_docs`
  is enforced). Say what the member does in DNP3 terms, units, ranges and what is thrown.
- **Validate in Dart:** values that would be truncated on the wire (indices, `u8` / `u16` /
  `u32` fields) must throw `RangeError` instead of wrapping.
- **No panics across FFI:** every `extern "C"` function goes through `run()` / `guard()` in
  `native/src/core.rs`, which catch panics and turn errors into return codes.
- **Hot paths stay binary:** measurements, database ops, commands and read requests use the
  formats in [`doc/wire_format.md`](doc/wire_format.md). JSON is only for configuration.
- **Tests:** add a test for every fix or feature. Test files run concurrently in one process,
  so do not assert on process-wide state such as `Dnp3.objectCounts`; check your own handles
  instead. Wait for asynchronous events with `eventually(...)` from `test/test_utils.dart`
  instead of fixed delays.

## Changing the Dart ↔ Rust interface

The Dart bindings and the native library must always match:

1. Add or change the function in `native/src/lib.rs` and its declaration in
   `lib/src/native/bindings.dart`. Leaf calls (`isLeaf: true`) must never block or call back
   into Dart.
2. Keep message kinds, error codes and constants in sync between `native/src/core.rs` and
   `lib/src/native/protocol.dart`.
3. Update [`doc/wire_format.md`](doc/wire_format.md) for any binary format change.
4. If the change is incompatible (a removed or changed function, a changed format), bump
   `ABI_VERSION` in `core.rs` **and** `abiVersion` in `protocol.dart`. The Dart side refuses
   to load a library with a different ABI version, which protects users of prebuilt
   libraries.

### Generated code

`lib/src/variation.dart` and `native/src/variation.rs` are generated from the dnp3 crate:

```sh
python3 tool/extract_variations.py ~/.cargo/registry/src/*/dnp3-1.7.0/src/app/variations.rs vars.json
python3 tool/gen_variations_rs.py vars.json native/src/variation.rs
python3 tool/gen_variations_dart.py vars.json lib/src/variation.dart
dart format -l 110 lib/src/variation.dart
```

Edit the generators, not the generated files.

### Upgrading the dnp3 crate

The crate is pinned (`=1.7.0`) on purpose. An upgrade means: bump it in `native/Cargo.toml`,
regenerate the variation tables, fix the bridge for API changes, run the full test suite and
the benchmarks, and update the version mentioned in the README and `doc/`.

## Pull requests

- Keep a pull request focused on one topic; small PRs are reviewed faster.
- Add an entry under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) for anything users
  notice (fixes, features, API or behavior changes, ABI bumps).
- Describe *why* in the PR description and how you tested it (platforms, devices).
- All CI checks must be green before merging.

Commit messages follow a light [Conventional Commits](https://www.conventionalcommits.org/)
style: `fix: ...`, `feat: ...`, `docs: ...`, `test: ...`, `build: ...`, `chore: ...`, with an
optional scope such as `fix(native): ...`.

## Benchmarks

Changes to hot paths (measurement encoding / decoding, database transactions, the port
dispatcher) should come with before / after numbers:

```sh
dart run benchmark/run_all.dart --quick --out /tmp/before.md   # on main
dart run benchmark/run_all.dart --quick --out /tmp/after.md    # on your branch
```

## Releasing (maintainers)

1. Move the `## Unreleased` entries in `CHANGELOG.md` under a new version heading.
2. Bump `version` in `pubspec.yaml` and `native/Cargo.toml`, then `(cd native && cargo update -p dnp3_dart)`.
3. Run the checks above and `dart pub publish --dry-run`.
4. Merge, then `dart pub publish`.
5. Tag `vX.Y.Z` and push the tag: the `release` workflow builds every native target and
   attaches `dnp3-native-prebuilt.zip` to a GitHub release.

Versions follow [semantic versioning](https://semver.org/); while the version is `0.x`, a
minor bump may contain breaking changes, which are called out in the changelog.
