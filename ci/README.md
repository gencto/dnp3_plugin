# CI/CD patch

`0001-ci-add-GitHub-Actions-workflows.patch` adds the GitHub Actions workflows
(`.github/workflows/{ci,native-build,release,benchmark}.yml` and `.github/dependabot.yml`).
It is shipped as a patch so it can be reviewed and committed by someone with permission to
change workflows:

```sh
git am ci/0001-ci-add-GitHub-Actions-workflows.patch   # keeps author + message
# or
git apply ci/0001-ci-add-GitHub-Actions-workflows.patch # just the files
```

| workflow | trigger | what it does |
|---|---|---|
| `ci.yml` | push / PR | Rust fmt + clippy + tests; Dart analyze, format, tests and quick benchmark on Linux x64 / arm64, macOS, Windows; native libraries for all targets; Flutter example builds (APK, iOS no-codesign, macOS, Linux, Windows) |
| `native-build.yml` | reusable | 13 targets: Android ×4 (NDK, 16 KB pages), iOS ×3, macOS ×2, Linux ×2, Windows ×2 |
| `release.yml` | `v*` tag | builds everything and publishes `dnp3-native-prebuilt.zip` + SHA256SUMS |
| `benchmark.yml` | weekly / manual | full `benchmark/run_all.dart` on all desktop runners, tables in the job summary |
