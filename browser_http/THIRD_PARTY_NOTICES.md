# Third-party notices

`browser_http` itself is MIT licensed (see `LICENSE`).

Distributed builds include the following Apache-2.0 components. Their license
texts must be bundled when shipping an iOS app built from source or from the
prebuilt xcframework.

| Component | Version | License | Use |
|---|---|---|---|
| wreq | 0.16.x | Apache-2.0 | Native HTTP transport |
| wreq-util | 0.2.x (pending) | Apache-2.0 (verify) | Emulation profiles |
| netty / netty-proto (transitive) | 0.2.x | Apache-2.0 | HTTP/1, HTTP/2 protocol layer |
| btls / btls-sys | 0.5.x | Apache-2.0 + BoringSSL license | TLS stack |
| BoringSSL | pinned by btls | BoringSSL/OpenSSL licenses | Cryptography |

TODO(stage-6): copy the upstream `LICENSE` files into
`third_party/<crate>/LICENSE` and generate this file at release time.
