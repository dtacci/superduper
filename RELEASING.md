# Releasing Superduper Dictation

There is intentionally no automatic public-release workflow in this fork.
Release signing is owner-specific and should not fall back silently to an ad-hoc
signature.

Before publishing a release:

1. Start from a clean, reviewed commit and locked dependencies.
2. Run `just build-unsigned` and `just test-unsigned`.
3. Build a Release archive with a Developer ID Application identity.
4. Confirm hardened runtime and expected entitlements with `codesign`.
5. Notarize the final app/DMG with `notarytool`, then staple the ticket.
6. Verify the stapled artifact on a separate Mac or clean user account.
7. Publish checksums and concise release notes.

Local self-signed builds are useful for development because they preserve
Accessibility approval. They are not suitable for a public release and should
never be described as Apple-notarized.

See [BUILD.md](BUILD.md) and [SECURITY.md](SECURITY.md).
