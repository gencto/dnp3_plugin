## What and why

<!-- What does this change and why is it needed? Link the issue it fixes (e.g. "Fixes #123"). -->

## How was it tested?

<!-- New or changed tests, platforms you ran it on, devices you talked to. -->

## Checklist

- [ ] `dart analyze --fatal-infos` and `dart format -l 110` are clean
- [ ] `dart test` passes; new behavior is covered by a test
- [ ] Rust: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` (if `native/` changed)
- [ ] New public API has dartdoc comments
- [ ] `CHANGELOG.md` has an entry under `## Unreleased` (if users notice the change)
- [ ] Dart ↔ Rust interface changes: bindings, `protocol.dart` / `core.rs`, `doc/wire_format.md` and the ABI version updated (see CONTRIBUTING.md)
