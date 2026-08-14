# Contributing

Thanks for helping improve Superduper Dictation.

## Before opening a pull request

- Keep the supported product local-only. New cloud, telemetry, listening-server,
  or command-execution behavior requires an explicit threat model and maintainer
  approval.
- Treat transcripts, recordings, clipboard contents, filenames, URLs, media
  metadata, and model output as untrusted data.
- Never log transcript contents, secrets, clipboard data, or full private paths.
- Keep public-facing strings in the localization pipeline.
- Add focused tests for behavior and security boundaries.

## Setup and verification

```sh
brew install just
just build-unsigned
just test-unsigned
```

Use Swift Testing (`@Suite`, `@Test`, `#expect`) for unit tests and XCTest for
macOS UI tests. Prefer protocol-backed test doubles over hardware or network
access. Do not make the default unit suite download models or contact services.

Run `just lint` and `just format` when SwiftLint and SwiftFormat are installed.
See `AGENTS.md` for the repository’s detailed engineering conventions.

## Pull requests

Describe what changed, why it is safe, how it was tested, and whether it changes
permissions, data retention, network access, subprocesses, dependencies, or
code signing. Include screenshots for visible UI changes.

Do not include generated build products, recordings, transcripts, API keys,
certificates, profiles, or machine-specific Xcode user data.

By contributing, you agree that your contribution is licensed under the MIT
License in `LICENSE`.
