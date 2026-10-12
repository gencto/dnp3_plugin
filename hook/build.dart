// Build hook: compiles the Rust bridge (native/) for the requested target and bundles it
// as a dynamically loaded code asset. Works for `dart run`, `dart test`, `dart build` and
// every Flutter target (Android, iOS, macOS, Linux, Windows).
//
// Resolution order for the native library:
//   1. user-define `prebuilt_dir` (pubspec `hooks: user_defines: dnp3: prebuilt_dir: ...`)
//      or env `DNP3_PREBUILT_DIR`: `<dir>/<rust-triple>/<library file>`
//   2. `native/prebuilt/<rust-triple>/<library file>` inside this package (CI artifacts)
//   3. `cargo build --release --target <rust-triple>` (requires a Rust toolchain)

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'src/native/bindings.dart';
const _crate = 'dnp3_dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final triple = rustTriple(code);
    final fileName = libraryFileName(code.targetOS);
    final packageRoot = input.packageRoot;

    final prebuilt = _findPrebuilt(input, triple, fileName);
    final Uri library;
    if (prebuilt != null) {
      library = prebuilt;
      output.dependencies.add(prebuilt);
    } else {
      library = await _cargoBuild(input, code, triple, fileName);
      final nativeDir = packageRoot.resolve('native/');
      for (final f in ['Cargo.toml', 'Cargo.lock', 'build.rs']) {
        output.dependencies.add(nativeDir.resolve(f));
      }
      final src = Directory.fromUri(nativeDir.resolve('src/'));
      for (final e in src.listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.rs')) output.dependencies.add(e.uri);
      }
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
  });
}

Uri? _findPrebuilt(BuildInput input, String triple, String fileName) {
  final candidates = <Uri>[];
  final define = input.userDefines.path('prebuilt_dir');
  if (define != null) candidates.add(define);
  final env = Platform.environment['DNP3_PREBUILT_DIR'];
  if (env != null && env.isNotEmpty) candidates.add(Directory(env).absolute.uri);
  candidates.add(input.packageRoot.resolve('native/prebuilt/'));
  for (final dir in candidates) {
    final base = dir.path.endsWith('/') ? dir : Uri.directory(dir.toFilePath());
    final file = File.fromUri(base.resolve('$triple/$fileName'));
    if (file.existsSync()) return file.uri;
  }
  return null;
}

String libraryFileName(OS os) => switch (os) {
  OS.windows => '$_crate.dll',
  OS.macOS || OS.iOS => 'lib$_crate.dylib',
  _ => 'lib$_crate.so',
};

String rustTriple(CodeConfig code) {
  final os = code.targetOS;
  final arch = code.targetArchitecture;
  switch (os) {
    case OS.android:
      return switch (arch) {
        Architecture.arm => 'armv7-linux-androideabi',
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.ia32 => 'i686-linux-android',
        Architecture.x64 => 'x86_64-linux-android',
        Architecture.riscv64 => 'riscv64-linux-android',
        _ => throw UnsupportedError('Android/$arch is not supported'),
      };
    case OS.iOS:
      final simulator = code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      return switch (arch) {
        Architecture.arm64 => simulator ? 'aarch64-apple-ios-sim' : 'aarch64-apple-ios',
        Architecture.x64 => 'x86_64-apple-ios',
        _ => throw UnsupportedError('iOS/$arch is not supported'),
      };
    case OS.macOS:
      return switch (arch) {
        Architecture.arm64 => 'aarch64-apple-darwin',
        Architecture.x64 => 'x86_64-apple-darwin',
        _ => throw UnsupportedError('macOS/$arch is not supported'),
      };
    case OS.linux:
      return switch (arch) {
        Architecture.x64 => 'x86_64-unknown-linux-gnu',
        Architecture.arm64 => 'aarch64-unknown-linux-gnu',
        Architecture.arm => 'armv7-unknown-linux-gnueabihf',
        Architecture.ia32 => 'i686-unknown-linux-gnu',
        Architecture.riscv64 => 'riscv64gc-unknown-linux-gnu',
        _ => throw UnsupportedError('Linux/$arch is not supported'),
      };
    case OS.windows:
      return switch (arch) {
        Architecture.x64 => 'x86_64-pc-windows-msvc',
        Architecture.arm64 => 'aarch64-pc-windows-msvc',
        Architecture.ia32 => 'i686-pc-windows-msvc',
        _ => throw UnsupportedError('Windows/$arch is not supported'),
      };
  }
  throw UnsupportedError('$os is not supported by package:dnp3');
}

String _findCargo() {
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final env = Platform.environment;
  final cargoHome = env['CARGO_HOME'];
  final home = env['HOME'] ?? env['USERPROFILE'];
  final candidates = [
    if (cargoHome != null) '$cargoHome/bin/$exe',
    if (home != null) '$home/.cargo/bin/$exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return exe; // rely on PATH
}

Future<Uri> _cargoBuild(BuildInput input, CodeConfig code, String triple, String fileName) async {
  final cargo = _findCargo();
  final manifest = input.packageRoot.resolve('native/Cargo.toml').toFilePath();
  final targetDir = input.outputDirectoryShared.resolve('cargo-target/').toFilePath();
  final env = <String, String>{};
  final envTriple = triple.toUpperCase().replaceAll('-', '_');

  if (code.targetOS == OS.android) {
    final cc = code.cCompiler;
    if (cc == null) {
      throw StateError('Android builds require the NDK C compiler from the Flutter tool');
    }
    final api = code.android.targetNdkApi;
    final bin = File.fromUri(cc.compiler).parent.path;
    final clangTriple = triple == 'armv7-linux-androideabi' ? 'armv7a-linux-androideabi' : triple;
    final suffix = Platform.isWindows ? '.cmd' : '';
    final clang = '$bin/$clangTriple$api-clang$suffix';
    final ar = File.fromUri(cc.archiver).path;
    env['CARGO_TARGET_${envTriple}_LINKER'] = clang;
    env['CC_${triple.replaceAll('-', '_')}'] = clang;
    env['AR_${triple.replaceAll('-', '_')}'] = ar;
    // 16 KB page size support (required for Android 15+)
    env['CARGO_TARGET_${envTriple}_RUSTFLAGS'] = '-C link-arg=-Wl,-z,max-page-size=16384';
  } else if (code.targetOS == OS.iOS) {
    env['IPHONEOS_DEPLOYMENT_TARGET'] = '${code.iOS.targetVersion}.0';
  } else if (code.targetOS == OS.macOS) {
    env['MACOSX_DEPLOYMENT_TARGET'] = '${code.macOS.targetVersion}.0';
    env['CARGO_TARGET_${envTriple}_RUSTFLAGS'] = '-C link-arg=-Wl,-install_name,@rpath/$fileName';
  }

  // make sure the std library for the target is installed (no-op without rustup)
  final rustup = cargo.replaceAll(RegExp(r'cargo(\.exe)?$'), Platform.isWindows ? 'rustup.exe' : 'rustup');
  if (File(rustup).existsSync()) {
    await Process.run(rustup, ['target', 'add', triple], environment: env);
  }

  final result = await Process.run(cargo, [
    'build',
    '--release',
    '--locked',
    '--manifest-path',
    manifest,
    '--target',
    triple,
    '--target-dir',
    targetDir,
  ], environment: env);
  if (result.exitCode != 0) {
    throw ProcessException(
      cargo,
      ['build', '--target', triple],
      'cargo build failed (is the Rust toolchain installed? https://rustup.rs)\n'
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  final built = File('$targetDir$triple/release/$fileName');
  // copy into the per-config output directory so concurrent builds never share a file
  final out = File.fromUri(input.outputDirectory.resolve(fileName));
  await built.copy(out.path);
  return out.uri;
}
