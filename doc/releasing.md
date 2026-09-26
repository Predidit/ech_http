# Testing, Maintenance, and Release Guide

[简体中文](releasing.zh-CN.md) | [English](releasing.md)

This handbook provides instructions for local testing, live network end-to-end verification, updating precompiled native SDKs, updating CA root certificates, and releasing `ech_http` to [pub.dev](https://pub.dev).

---

## 1. Local Code Quality Checks

Before committing or testing, ensure that code formatting, static analysis, offline unit tests, and packaging dry-runs pass cleanly:

```sh
# 1. Fetch dependencies
dart pub get

# 2. Check code formatting across all project directories
dart format --output=none --set-exit-if-changed lib hook test example tool

# 3. Strict static analysis (treat all warnings and infos as fatal)
dart analyze --fatal-infos

# 4. Run the offline test suite (37 unit and mock tests)
dart test -r expanded

# 5. Verify package publication readiness
dart pub publish --dry-run
```

> [!NOTE] Offline Test Scope
> The 37 offline tests run against in-process mock HTTP/TLS servers and synthetic DNS records. They validate:
> - Status codes, headers, and body streaming
> - Upload buffering and limits
> - Redirect policies, HTTPS downgrade refusal, and sensitive header stripping
> - Streaming pause/resume with bounded native queue backpressure
> - Request timeouts, concurrency queueing, and cancellation triggers
> - Client closure semantics
> - Custom PKI root isolation and hostname verification
> - ECH fail-closed enforcement and unusable public name rejection
> - Binary SDK cache verification, offline reuse, and file self-repair
> - Message-port delivery, bounded acknowledgements, and isolate-group teardown

---

## 2. Optional Live Network Checks

`test/live_ech_test.dart` performs end-to-end integration testing against real, live HTTPS endpoints on the public Internet. These tests are completely opt-in and are skipped unless configured via environment variables.

### Environment Variables

| Variable | Description |
| :--- | :--- |
| `ECH_TEST_URL` | Target HTTPS URL (must return HTTP 200). Enables the live ECH test. |
| `ECH_TEST_CONFIG` | Base64-encoded `ECHConfigList`. Can be an active config or a stale config to verify authenticated retry. **Required** when `ECH_TEST_URL` is set. |
| `ECH_TEST_ADDRESSES` | *(Optional)* Comma-separated list of target IP literals (e.g. `104.16.132.229,104.16.133.229`). If omitted, destination DNS resolves normally. |
| `ECH_TEST_PROXY` | *(Optional)* HTTP CONNECT proxy URL (e.g. `http://127.0.0.1:7890`). |
| `ECH_TEST_EXPECT_RETRY` | Set to `1` to require that the server performs an authenticated TLS retry. |
| `ECH_TEST_SHA256` | *(Optional)* Expected SHA-256 hex digest of the response body for integrity verification. |
| `ECH_TEST_BYTES` | *(Optional)* Expected exact byte length of the response body. |
| `ECH_TEST_TRUST_URL` | *(Optional)* Separate live check for custom-root isolation. Point to any public HTTPS server; the test asserts handshake failure when the root store is replaced by a localhost test anchor. |

### Running Live Tests

**PowerShell (Windows):**
```powershell
$env:ECH_TEST_URL = "https://crypto.cloudflare.com/cdn-cgi/trace"
$env:ECH_TEST_CONFIG = "AED+DQA85wAgACD...AAA="
$env:ECH_TEST_EXPECT_RETRY = "0"
dart test test/live_ech_test.dart -r expanded
```

**Bash / Zsh (Linux / macOS):**
```sh
export ECH_TEST_URL="https://crypto.cloudflare.com/cdn-cgi/trace"
export ECH_TEST_CONFIG="AED+DQA85wAgACD...AAA="
export ECH_TEST_EXPECT_RETRY="0"
dart test test/live_ech_test.dart -r expanded
```

### Discovery Example Runner

You can also test live discovery interactively with `example/ech_http_example.dart`:

```sh
dart run example/ech_http_example.dart https://crypto.cloudflare.com/cdn-cgi/trace https://cloudflare-dns.com/dns-query
```

Set `ECH_PROXY`, `ECH_CONFIG_DOMAIN`, or `ECH_ADDRESSES` in your environment to test proxy tunnels or shared CDN configurations.

---

## 3. Precompiled Dependency SDK Maintenance

`ech_http` pins versioned precompiled SDKs for 14 target architectures across four public build repositories:

- [libechhttp-win32-build](https://github.com/ech-research/libechhttp-win32-build/releases) (Windows: x64, arm64, ia32)
- [libechhttp-darwin-build](https://github.com/ech-research/libechhttp-darwin-build/releases) (macOS / iOS: x64, arm64)
- [libechhttp-android-build](https://github.com/ech-research/libechhttp-android-build/releases) (Android: arm64-v8a, armeabi-v7a, x86_64, x86)
- [libechhttp-linux-build](https://github.com/ech-research/libechhttp-linux-build/releases) (Linux: x64, arm64)

### Upgrading Precompiled SDKs

When dependency versions (such as libcurl or BoringSSL) or compiler flags change:

1. Trigger and publish new GitHub Releases in the four platform build repositories.
2. In the `ech_http` repository, run the maintainer automation tool with the new release tags:
   ```sh
   python tool/update_prebuilt.py win32=v0.1.1 darwin=v0.1.2 android=v0.1.1 linux=v0.1.1
   ```
   *(Requires Python 3.9+ and an authenticated GitHub CLI `gh`)*.
3. Review the modified pins and SHA-256 digests in `lib/src/build_support/dependencies.json`.
4. Trigger the multi-platform GitHub Actions CI matrix to test build hooks across all platforms.

> [!CAUTION] Immutability Requirement
> Never replace or overwrite an asset file under an existing GitHub Release tag. If an SDK must be modified, publish a new version tag (e.g. `v0.1.2`).

### Updating the Bundled Mozilla CA Roots

The built-in Mozilla CA certificate bundle is stored at `src/cacert.pem`.

To update it:
1. Download the latest official CA extract from [curl.se/docs/caextract.html](https://curl.se/docs/caextract.html).
2. Replace `src/cacert.pem`.
3. Compute the SHA-256 digest of the new file:
   ```sh
   sha256sum src/cacert.pem
   ```
4. Update the documented SHA-256 hash and snapshot date in:
   - `THIRD_PARTY_NOTICES.md`
   - `src/ca_bundle.h.in` (re-run CMake if testing locally)
5. Run `dart test` to verify TLS certificate validation passes.

---

## 4. Multi-Platform CI Matrix

The repository includes a GitHub Actions CI workflow (`.github/workflows/ci.yml`) covering:
- Windows desktop runners (MSVC x64, cross-compile arm64/ia32)
- Linux desktop runners (glibc x64 and arm64)
- macOS desktop runners (Intel x64 and Apple Silicon arm64)
- Android APK packaging (Flutter build across arm64, arm, x64, x86)
- iOS build targets (bridge build and Flutter release build with `--no-codesign`)

Run or verify the CI pipeline before publishing. See [doc/verification.md](verification.md) for detailed verification coverage.

---

## 5. Release Checklist & Publishing to pub.dev

When preparing an official release:

1. **Version Consistency**:
   - Update `version` in `pubspec.yaml` (following Semantic Versioning).
   - Document all changes under the corresponding version in `CHANGELOG.md`.
   - Update any illustrative version numbers in `README.md` and `README.zh-CN.md`.
2. **False Secrets Confirmation**:
   - `test/fixtures/localhost-key.pem` is a public, test-only RSA key used exclusively for local mock tests. Confirm it remains explicitly listed under `false_secrets` in `pubspec.yaml`.
3. **Artifact Verification (`dry-run`)**:
   - Execute:
     ```sh
     dart pub publish --dry-run
     ```
   - Carefully review the printed file list.
   - **Must include**: `lib/` (including `src/build_support/prebuilt.dart` and `src/build_support/dependencies.json`), `hook/build.dart`, `src/` (bridge sources, CMake files, `cacert.pem`, license files), `LICENSE`, `README.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`.
   - Keep helper scripts and data outside the reserved `hook/` directory; pub.dev validates hook filenames on upload.
   - **Must exclude**: `.dart_tool/`, local build caches, downloaded native ZIPs/binaries, logs, IDE files (`.vscode/`, `.idea/`).
4. **Publish**:
   - Once all approvals and checks pass, publish from the reviewed commit:
     ```sh
     dart pub publish
     ```
   *(Note: This repository's CI does not publish packages automatically; publication is an intentional manual action by authorized package maintainers).*
