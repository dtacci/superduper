# Build guide

The Xcode project, scheme, and Swift module retain the inherited name `Pindrop`;
the built application is `Superduper Dictation.app`.

## Prerequisites

- macOS 14+
- Regular Xcode 16.4+
- `just` (`brew install just`) for command-line recipes

## Development

```sh
just build             # Xcode-managed Debug signing
just build-unsigned    # compile without a signing identity
just test
just test-unsigned
just xcode
```

If the system `xcode-select` still points to Command Line Tools, either select
Xcode in **Xcode → Settings → Locations** or run commands with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just test-unsigned
```

## Stable local signing

Accessibility approval follows an app’s code-signing identity. The
`build-self-signed` recipe uses a certificate named
`Superduper Dictation Local Signing` from the login keychain and preserves the
hardened-runtime flag plus the app entitlements.

```sh
just build-self-signed
```

That certificate is for local development only. Never export or commit its
private key, and never distribute it as proof of publisher identity.

## Public distribution

A public release should use:

1. An Apple Developer Program account.
2. A Developer ID Application certificate.
3. Hardened runtime and the minimal entitlements in `Pindrop/Pindrop.entitlements`.
4. Apple notarization and ticket stapling.
5. Signature verification on the exact artifact being uploaded.

Useful local recipes are listed by `just --list`. Review every release script
and generated artifact before use; this fork intentionally has no automated
GitHub release workflow until an owner-specific signing/notarization process is
configured.

Never store certificates, private keys, provisioning profiles, notarytool
passwords, or App Store Connect credentials in the repository or GitHub Actions
logs. Prefer Keychain/notarytool credential profiles and least-privilege GitHub
environment secrets.
