# Security policy

## Reporting a vulnerability

When enabled, use GitHub’s **Security → Report a vulnerability** flow so details
remain private. If that option is unavailable, ask the maintainer for a private
reporting channel without disclosing vulnerability details. Do not open a public
issue containing exploit steps, private recordings, transcripts, credentials, or
other sensitive data.

Include the affected commit/version, macOS version, reproduction steps, impact,
and any suggested mitigation. Please allow a reasonable coordinated-disclosure
window before publishing details.

## Supported code

Security fixes target the current default branch. Historical upstream release
notes and tags are retained for provenance but are not supported releases of
Superduper Dictation.

## Security boundaries

- External AI enhancement and MCP serving are disabled by the production policy.
  The MCP listener enforces that policy directly and specifies a loopback-only
  bind address as defense in depth. Its dormant HTTP implementation requires
  further parser and resource-limit review before any future re-enablement.
- Transcripts are data and are never intentionally executed as commands.
- Supported network surfaces include model downloads, HTTPS media and vocabulary
  imports, and the optional Google OAuth and Calendar connection.
- `yt-dlp` and `ffmpeg` are optional user-installed executables. They run without
  a shell, with fixed argument structure, discovered plugins disabled, and a
  reduced environment, but remain third-party native code processing hostile
  media.
- Media and vocabulary URL validation blocks insecure schemes, credentials,
  nonstandard ports, local host names (including trailing-dot spellings), legacy
  numeric IPv4 spellings, literal private addresses, and unsafe direct-download
  redirects. Vocabulary responses are limited to 8 MB each before loading them
  into memory. These checks do not resolve and pin public DNS addresses or provide
  a network sandbox, so DNS rebinding remains possible, including inside `yt-dlp`.
- The app is not App-Sandboxed. Accessibility permission is powerful: a
  compromised app build could synthesize input in other applications.
- Local databases and recordings use owner-only permissions but are not
  application-level encrypted. FileVault is recommended for data at rest.
- Failed and canceled dictation recovery audio remains on disk for manual retry;
  the ordinary saved-audio retention setting does not expire these spools. Only
  sessions interrupted while recording or processing resume automatically.

## Maintainer checklist

- Review Swift package lockfile changes, transitive native/binary dependencies,
  and GitHub Action commit changes. Routine builds, tests, and archives use the
  committed lockfile; resolve deliberate requirement changes with
  `just resolve-packages` before reviewing and testing the result.
- Run `just audit-dependencies` to query OSV for every committed source revision
  and SwiftURL package/version. CI runs it on each pull request and main push.
  Advisory matches and inconclusive requests fail the check. The scan sends only
  public dependency metadata and does not inspect embedded binaries.
- Run the unit suite and inspect signing entitlements before release.
- Use Developer ID signing plus notarization for public artifacts.
- Scan the complete Git history for secrets before the first public push.
- Keep GitHub token permissions read-only unless a job demonstrably needs more.
- Enable private vulnerability reporting, Dependabot alerts, secret scanning,
  and branch protection in the public repository settings.

## Latest review: 2026-11-12

The source review follows [OWASP MASVS](https://mas.owasp.org/MASVS/), adapted to
this native macOS app. It revisits storage and logs, credentials and OAuth,
network imports and redirects, process execution, disabled network features,
signing, and dependency integrity. This is an engineering review and advisory
scan, with the remaining boundaries above; it is not a penetration test or
certification.

- **Supply chain / MASVS-CODE:** OSV returned zero advisory matches for all 32
  locked source packages, queried by both revision and SwiftURL version. A live
  positive control using the older SwiftNIO 2.99.0 returned three advisories,
  confirming that the package coordinate reaches the advisory database. All 32
  local source checkouts match their committed revisions and have no tracked
  modifications. See the [dated inventory](docs/2026-11-12-dependency-inventory.json).
- **Dependency freshness:** WhisperKit 1.1.1 and FluidAudio 0.18.3 remain current.
  Newer MLX, HTTP client, logging, tracing, lifecycle, crypto, and Collections
  releases need Swift 6.2–6.4, beyond the installed Swift 6.1.2 toolchain, or fall
  outside the current upstream requirements. Transformers is constrained to 1.2.x
  by MLX LM; its graph constrains Hugging Face and Xet to pre-1.0, Jinja to 2.x,
  and yyjson to exactly 0.12.0. No package requirements or resolved pins changed.
  All four GitHub Actions already match their current official release commits.
- **Binary coverage:** FluidAudio's NeMo 0.3.1 binary target is SHA-256 pinned in
  its manifest, but its embedded Rust dependencies are outside this source-pin
  scan. Runtime model downloads and optional native media tools also require
  separate provenance and vulnerability review.
- **Repository protection:** Dependabot vulnerability alerts, automatic security
  update PRs, and private vulnerability reporting were enabled and read back
  through the GitHub API. Secret scanning and push protection were already
  enabled. Branch protection requires the strict `build-test` check and applies
  to admins, but requires zero approving reviews. No review-policy changes were
  made. CI now also audits the committed Swift lockfile with OSV.
- **Secrets / MASVS-STORAGE-2:** Gitleaks 8.30.1, downloaded from its official
  release and verified against the published SHA-256, scanned 717 commits across
  local refs (approximately 35 MB). Its seven matches were reviewed: all are
  generated localization identifiers, with no confirmed credentials. The current
  code diff and scripts scan returned no matches. Ignored local credentials were
  excluded from these scans.
- **Network boundary / MASVS-PLATFORM:** MCP could previously start directly
  without consulting the production policy and used a wildcard listener despite
  its localhost description. Startup now fails closed at the listener itself and
  specifies `127.0.0.1`. A regression test verifies that a direct start cannot
  activate the production-disabled server.
- **External tools:** The optional Homebrew FFmpeg installation on this Mac was
  8.1.1. [FFmpeg's security notes](https://ffmpeg.org/security.html) list fixes in
  8.1.2 for CVE-2026-8461 and CVE-2026-30999; [Homebrew](https://formulae.brew.sh/formula/ffmpeg)
  currently provides 9.0.2, or 8.1.3 through `ffmpeg@8`. With user approval, the
  shared FFmpeg and ffprobe tools were upgraded to 9.0.2 (Homebrew 9.0.2_1), along
  with their required native libraries. `brew linkage --test ffmpeg` and
  `brew missing ffmpeg` report no problems. A generated 48 kHz stereo AAC fixture
  converts successfully with the app's exact flags to two seconds of 16 kHz mono
  signed 16-bit PCM WAV; ffprobe confirms the output format. These checks validate
  tool operation, not the absence of undisclosed media-decoder vulnerabilities.
  Homebrew's follow-up attempt to reinstall the separate `pkgconf` build tool
  failed because it requires newer Xcode/Command Line Tools. The existing
  `pkgconf` 2.5.1 remains usable; no Xcode upgrade was performed. FFmpeg and its
  runtime dependencies were already installed successfully before that failure.

The prior review's remaining risks still apply: local audio and databases lack
application-level encryption; failed/canceled recovery audio has no automatic
expiration; network import checks do not pin DNS answers; and public distribution
requires Developer ID export and notarization. These are not resolved by a clean
dependency advisory scan.

Validation: `just build`, `just build-release`, `just test` (1,496 tests), `just audit-dependencies`
(seven scanner regression checks plus 32 live source-pin queries), and
`just l10n-lint` pass with the Xcode developer directory selected. No new warnings
were observed in the changed Swift files; existing deprecation and concurrency
warnings remain elsewhere. The local Release signature passes
`codesign --verify --deep --strict`; hardened runtime is enabled, and the only
entitlement is microphone input, with no debugger entitlement. This is an Apple
Development signature, not a notarized public distribution artifact.
