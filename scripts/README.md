# Scripts

Build and packaging helpers for Superduper Dictation. The Xcode target and
Swift module are named `SuperduperDictation`; the built application is
`Superduper Dictation.app`.

## Dependency security

Run `just audit-dependencies` to check every source pin in the committed Xcode
SwiftPM lockfile against OSV using both its Git revision and SwiftURL version.
The recipe tests the scanner, then performs live queries; CI uses the same check.
Matches return exit status 1; inconclusive scans return 2. This does not audit
binary internals, model files, or optional user-installed executables.

To keep a dated inventory, run
`python3 scripts/audit_dependencies.py --output docs/YYYY-MM-DD-dependency-inventory.json`.

## Local signing

`sign-app-bundle.sh` signs nested code before the main bundle, enables hardened
runtime, and applies `SuperduperDictation/SuperduperDictation.entitlements`. Pass `local` to use the
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
