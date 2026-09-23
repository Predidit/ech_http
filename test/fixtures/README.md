# Test Fixtures Security Notice

The certificate (`localhost-cert.pem`) and private key (`localhost-key.pem`) in this directory are **public, test-only artifacts** used exclusively for offline unit testing of local mock TLS servers.

---

## Security Guarantees & Operational Context

1. **Non-Production Artifact**: This private key is public knowledge and has zero cryptographic confidentiality. It must **never** be deployed to any production, staging, or internet-facing service.
2. **Default Client Isolation**: The shipped `EchClient` uses the bundled Mozilla Root CA store and does **not** trust this test certificate.
3. **Explicit Test-Only Trust**: Offline unit tests (`test/client_test.dart`) explicitly pass `trustedRootsPem` to load `localhost-cert.pem` as an isolated trust anchor solely to verify custom PKI isolation and hostname verification behavior. The certificate's Subject Alternative Name (SAN) is valid only for `localhost` (not `127.0.0.1`).
4. **Secret Scanner Allowlisting (`false_secrets`)**: Because this key is intentionally checked into the repository, it is explicitly allowlisted under `false_secrets` in `pubspec.yaml`:
   ```yaml
   false_secrets:
     - /test/fixtures/localhost-key.pem
   ```
   This prevents automated vulnerability and secret scanning tools (such as pub.dev publication scanners and Git secret hooks) from raising false positives.
