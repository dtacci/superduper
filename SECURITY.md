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
- Run the unit suite and inspect signing entitlements before release.
- Use Developer ID signing plus notarization for public artifacts.
- Scan the complete Git history for secrets before the first public push.
- Keep GitHub token permissions read-only unless a job demonstrably needs more.
- Enable private vulnerability reporting, Dependabot alerts, secret scanning,
  and branch protection in the public repository settings.
