# dnp3 Flutter example

Platform folders are not committed; generate them once:

```sh
cd example/flutter_app
flutter create --project-name dnp3_flutter_example --platforms android,ios,linux,macos,windows .
flutter run
```

The app starts an outstation on `127.0.0.1:20000` inside the app (demo mode) or connects
a master to any outstation endpoint. Values are decoded zero-copy from the native buffers
and controls (CROB / analog output) can be issued from the UI.

The native library is compiled by the package's build hook (`hook/build.dart`), so a Rust
toolchain with the target of your device must be installed (`rustup target add ...`), or
prebuilt libraries must be provided through `DNP3_PREBUILT_DIR`.
