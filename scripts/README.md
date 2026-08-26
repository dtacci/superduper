# Scripts

Build and packaging helpers for Superduper Dictation. The Xcode target and
Swift module retain the inherited `Pindrop` name internally, while the built
application is `Superduper Dictation.app`.

## Local signing

`sign-app-bundle.sh` signs nested code before the main bundle, enables hardened
runtime, and applies `Pindrop/Pindrop.entitlements`. Pass `local` to use the
login-keychain certificate named `Superduper Dictation Local Signing`:

```sh
./scripts/sign-app-bundle.sh "/path/to/Superduper Dictation.app" local
```

If that certificate is missing, the script falls back to ad-hoc signing and
warns that Accessibility approval may not survive a rebuild. A local
self-signed identity is for development only; a public release needs Developer
ID signing and Apple notarization.

## Release helpers

Legacy upstream appcast and website-sync scripts remain in the tree for
provenance but their `just` entry points are disabled. Configure and review an
owner-specific release process before re-enabling any command that tags, pushes,
uploads, downloads build tooling, or publishes an artifact.

See `BUILD.md`, `RELEASING.md`, and `SECURITY.md` at the repository root.
