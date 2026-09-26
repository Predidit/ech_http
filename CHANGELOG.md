# Changelog

All notable changes to the `ech_http` package will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.3] - 2026-09-26

### Changed
- Replace the 10 ms response polling timer with native `Dart_PostCObject` events
  delivered through per-request receive ports, without `NativeCallable`.
- Preserve the 256 KiB streaming budget with body acknowledgements.
- Release request handles without joining network threads; retain worker state
  through cancellation and clean up abandoned handles with native finalizers.
- Update the internal C ABI and build hooks for Dart SDK message-port headers.

### Added
- Regression coverage for timer-free delivery, repeated stream pauses, bounded
  in-flight messages, closed ports, and isolate group shutdown during transfers.

---

## [0.1.2]

### Changed
- Update repository, issue tracker, dependency SDK download URLs, and maintainer tooling to the `ech-research` GitHub organization.
- Keep the existing SDK release versions and SHA-256 pins; no native dependency rebuild is required.

---

## [0.1.1]

### Added
- **Precompiled SDK Pipeline**: Added automated downloads of pinned, SHA-256-verified dependency SDKs from dedicated public GitHub Release repositories.
- **Offline Binary Caching**: Added reusable native binary cache via `hooks.user_defines.ech_http.binary_cache` with archive integrity validation, offline reuse, and automatic self-repair of damaged files.
- **Maintainer Automation**: Added `tool/update_prebuilt.py` for automated pinning and hash verification of new SDK release versions.
- **Live End-to-End Suite**: Added environment-variable-driven live network tests for ECH validation, authenticated retries, and proxy tunneling (`test/live_ech_test.dart`).

### Changed
- Move build helpers and dependency pins outside the reserved `hook/` directory for pub.dev upload compatibility.
- **Build Hook Acceleration**: Switched to compiling only the C++ bridge locally via CMake/Ninja (~15 s cold builds), eliminating local compilation of BoringSSL and libcurl from source.
- **Documentation Overhaul**: Restructured all project documentation, added comprehensive English and Chinese guides, Mermaid architecture diagrams, and multi-platform verification records.

### Removed
- Removed application-specific integration recipes in favor of generic, configurable discovery examples and resolvers.

---

## [0.1.0]

### Added
- **Core HTTP Client**: Initial release of `EchClient` implementing `package:http.Client`, backed by an in-process C++17 engine (libcurl + BoringSSL).
- **TLS Encrypted Client Hello (ECH)**: Full support for ECH negotiation, fail-closed security enforcement, and automated authenticated retries.
- **Routing & Resolvers**: Added `DohEchResolver` for DNS JSON HTTPS record (Type 65) discovery and `StaticEchResolver` for pre-configured routes.
- **Proxy & Physical Routing**: Supported HTTP CONNECT proxies, physical destination IP overrides (`addresses`), and custom PKI root injection (`trustedRootsPem`).
- **Native Assets Integration**: Supported cross-platform compilation and bundling for Android, iOS, Linux, macOS, and Windows via Dart build hooks.
