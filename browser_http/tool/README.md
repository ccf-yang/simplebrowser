# Fingerprint verification

The whole point of this package is that the native transport's fingerprint
matches a real browser. That claim is only credible if it is measured, so every
profile change must be verified against a collector.

## Local collector (preferred, works offline)

Run a TLS server that records the ClientHello, then connect the app to it:

1. `python3 -m venv .venv && .venv/bin/pip install ja3`
2. Use a small TLS server that computes the JA3/JA4 of each connection and
   prints it. Keep this in `tool/` so CI can reuse it.
3. Point the example app at `https://<your-lan-ip>:8443` and compare the output
   with the same browser on the same platform.

## Public services (when network allows)

- `https://tls.peet.ws/api/all` — JA3, JA4, HTTP/2 settings, header order.
- `https://browserleaks.com/tls` — human-readable ClientHello.
- `https://ja3er.com/json` — JA3 only.

## Acceptance

For each profile, record the expected values in
`test/fixtures/fingerprints/<profile>.json` and assert equality in the
integration test. A profile without a fixture is considered unverified.
