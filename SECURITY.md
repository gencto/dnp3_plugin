# Security policy

## Supported versions

Security fixes are made for the latest released version on
[pub.dev](https://pub.dev/packages/dnp3). Please upgrade before reporting.

## Reporting a vulnerability

**Do not open a public issue for security problems.** Report them privately through GitHub:
go to the repository's **Security** tab and choose
[**Report a vulnerability**](https://github.com/gencto/dnp3_plugin/security/advisories/new).

Please include:

- the affected version and platform,
- what an attacker can do (e.g. crash or hang the process, read or corrupt memory, bypass an
  address filter or TLS verification),
- a minimal reproduction (for example a DNP3 frame sequence or a small Dart program).

You will get an acknowledgement within a few days. Once a fix is available it is released
and the advisory is published, crediting you unless you prefer otherwise.

## Scope

In scope: this package's Dart code, the FFI bridge in `native/` (memory safety, handle
lifetimes, data passed between Dart and Rust) and the build hook.

Vulnerabilities in the DNP3 protocol implementation itself (parsing, TLS handling in the
stack) belong to the upstream [`dnp3`](https://github.com/stepfunc/dnp3) library by Step
Function I/O; please report those to them as well. We will update the pinned version once a
fix is released.

DNP3 without TLS (or Secure Authentication) is not encrypted or authenticated by design. Use
TLS channels, network segmentation and the outstation address filters for untrusted
networks.
