# Security policy

## Reporting a vulnerability

Use GitHub’s **Security → Report a vulnerability** flow so details remain
private. Do not open a public issue containing exploit steps, private recordings,
transcripts, credentials, or other sensitive data.

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
- Model downloads and HTTPS media imports are the supported network surfaces.
- `yt-dlp` and `ffmpeg` are optional user-installed executables. They run without
  a shell, with fixed argument structure, discovered plugins disabled, and a
  reduced environment, but remain third-party native code processing hostile
  media.
- URL validation blocks insecure schemes, credentials, nonstandard ports, local
  host names, literal private addresses, and unsafe direct-download redirects.
  It does not provide a network sandbox or a complete defense against DNS
  rebinding inside `yt-dlp`; do not import links you do not trust.
- The app is not App-Sandboxed. Accessibility permission is powerful: a
  compromised app build could synthesize input in other applications.
- Local databases and recordings use owner-only permissions but are not
  application-level encrypted. FileVault is recommended for data at rest.

## Maintainer checklist

- Review Swift package lockfile changes and GitHub Action commit changes.
- Run the unit suite and inspect signing entitlements before release.
- Use Developer ID signing plus notarization for public artifacts.
- Scan the complete Git history for secrets before the first public push.
- Keep GitHub token permissions read-only unless a job demonstrably needs more.
- Enable private vulnerability reporting, Dependabot alerts, secret scanning,
  and branch protection in the public repository settings.
