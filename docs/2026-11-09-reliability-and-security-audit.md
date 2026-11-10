# Startup reliability and security audit

Date: 2026-11-09, America/Los_Angeles. Baseline: `ca1b752`.

The recurring startup warning came from automatic retries of old failed recordings, plus a reminder for canceled recordings on every launch. The fixes preserve that audio, stop repeating completed recovery attempts, and make manual recovery available in the menu bar. The sweep also fixed sensitive diagnostic logging, unsafe URL spellings, vocabulary download restrictions, and a Google sign-in cancellation race.

The review covered startup and recording recovery, transcription integrations, persistence and retention boundaries, secrets, logging, external processes, network imports, OAuth, package requirements, and GitHub security settings. The security mapping uses [OWASP MASVS](https://mas.owasp.org/MASVS/) as guidance adapted to a native macOS app, alongside [OWASP software supply chain guidance](https://top10.owasp.org/2025/A03_2025-Software_Supply_Chain_Failures/). This is a source and test review, not a certification or proof that dependencies contain no malicious code.

## Fixes

### Repeated recovery warnings

Startup previously treated every non-canceled recovery file as interrupted, including `.failed` sessions. Local diagnostics showed six old recordings repeatedly failing with “No speech was detected in the recovered audio.” Separately, the most recent canceled recording always produced a persistent retry reminder.

`DictationRecoveryStore.interruptedSessions()` now selects only `.recording` and `.processing`. Failed and canceled recordings remain available under **Retry Transcription** in the menu bar, identified by their recording date. Retry actions are disabled while recording or processing. Startup no longer presents canceled-recording reminders. Missing models do not produce a background recovery toast.

References: [recovery store](../SuperduperDictation/Services/DictationAudioRetentionService.swift), [startup orchestration](../SuperduperDictation/AppCoordinator.swift), [menu](../SuperduperDictation/UI/StatusBarController.swift). Regression tests cover restart selection, preservation of failed audio, manual selection, localization, and busy-state admission.

### Sensitive diagnostic logging

Dictionary-learning diagnostics embedded dictated words and surrounding editor text in visible log messages. Some were logged at info level; debug messages also reached the unified system log. Diagnostics now use text lengths, and persistence errors use the normal redaction path. The logging-only meeting notifier no longer logs meeting titles and bodies.

Reference: [dictionary learning](../SuperduperDictation/Services/AutomaticDictionaryLearningService.swift). A regression test checks that dictation, prefix, and suffix text never appear in the generated diagnostics. Existing logs are not retroactively scrubbed.

OWASP mapping: MASVS-STORAGE-2 and MASVS-PRIVACY.

### URL validation and vocabulary downloads

Trailing-dot DNS names and legacy octal, hexadecimal, integer, or shortened IPv4 forms could bypass local-address checks. Validation now normalizes a final DNS dot and requires canonical dotted-decimal IPv4 before checking address ranges.

Vocabulary imports and documentation fetching previously accepted HTTP and used unrestricted `URLSession.data` downloads. They now reuse the media downloader's redirect checks and enforce an 8 MB limit per response while downloading, before reading text into memory. Requests have bounded timeouts and disable cookie, credential, and URL-cache storage. Linked documentation indexes must stay on the same HTTPS origin.

References: [URL policy and download delegate](../SuperduperDictation/Services/MediaIngestionService.swift), [vocabulary downloads](../SuperduperDictation/Services/VocabularyPackStore.swift). Tests cover unsafe addresses, blocked redirects, streaming size limits, unsafe vocabulary URLs, and linked-index origins. Existing localized copy is reused; localization lint passes.

OWASP mapping: MASVS-NETWORK, MASVS-CODE-4, and MASVS-PRIVACY.

### Google sign-in cancellation

Cancellation could complete `OAuthCallbackGate` before its continuation was installed. The gate discarded that completion and could leave sign-in suspended indefinitely. It now retains the first result and delivers it even when installation happens later. Tests cover cancellation before installation and duplicate completion.

Reference: [OAuth implementation](../SuperduperDictation/Services/GoogleCalendarService.swift). Existing PKCE, random state, loopback binding, and Keychain storage remain the authentication controls.

### Test isolation and model cache fixtures

Several Parakeet unit tests loaded actual models, swallowed load errors, or left unawaited loading tasks running. A SenseVoice routing test also loaded a real model. Parakeet model checks now live in a serialized, opt-in integration suite; the routing test uses the existing mock engine. The integration plan now includes the Parakeet and WhisperKit model suites.

FluidAudio now rejects incomplete compiled bundles, including bundles with remaining partial downloads. The Parakeet fixture includes compiled-model metadata, and a regression assertion checks that a partial weights file makes the cache unusable. Its new `invalidSpan` diarization error maps into the app's existing processing error.

### Release debugger entitlement

Xcode injected `com.apple.security.get-task-allow` into the local Release app despite its minimal source entitlement file. The Release configuration now disables base-entitlement injection. Debug builds retain their normal debugging support. Public distribution still requires Developer ID export and notarization.

## Dependencies

Updates preserve macOS 14 and the installed Xcode 16.4 / Swift 6.1.2 toolchain. Direct requirements remain exact, and the full resolved graph is committed. Routine builds, tests, and archives now use `-onlyUsePackageVersionsFromResolvedFile`; deliberate requirement changes use `just resolve-packages` followed by lockfile review and validation.

| Component | Before | After | Update boundary |
| --- | --- | --- | --- |
| WhisperKit | 1.1.0 | 1.1.1 | Current release; includes crash, cancellation, and download fixes |
| FluidAudio | 0.15.6 | 0.18.3 | Current release |
| MLX Swift LM | 2.30.6 | 2.31.3 | Current 3.32.3 requires Swift 6.2 |
| MLX Swift | 0.30.6 | 0.31.4 | Compatible with MLX LM; 0.31.5 and 0.31.6 require Swift 6.3 |
| Swift Transformers | 1.1.6 | 1.2.1 | MLX LM 2.31.3 constrains this to the 1.2 series; current is 1.4.0 |
| Swift Argument Parser | 1.7.0 | 1.8.2 | Current release |
| Swift Jinja | 2.4.2 | 2.5.2 | Compatible 2.x; current 3.1.0 is outside Transformers' requirement |
| Swift Collections | 1.6.0 | 1.6.0 | Current 1.7.5 requires Swift 6.4 and has no Swift 6.0 compatibility manifest |
| Swift Numerics | 1.1.1 | 1.1.1 | Current release |
| GitHub cache action | 4.3.0 | 6.1.0 | Pinned to the official tag's full commit |

Primary release references: [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.1), [FluidAudio](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.3), [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3), [Swift Transformers](https://github.com/huggingface/swift-transformers/releases/tag/1.4.0), [Swift Collections](https://github.com/apple/swift-collections/releases/tag/1.7.5), and [cache action](https://github.com/actions/cache/releases/tag/v6.1.0).

The updated Hugging Face stack expands the resolved graph from 9 to 32 source packages. [The dependency inventory](2026-11-09-dependency-inventory.json) records every version, Git revision, and OSV result. Both commit queries and SwiftURL package/version queries returned zero advisory matches for all 32 pins. Advisory coverage is incomplete and does not establish the absence of vulnerabilities or malicious code. The query formats follow the [OSV API documentation](https://github.com/google/osv.dev/blob/master/docs/api/post-v1-query.md).

FluidAudio additionally includes the checksum-pinned NeMo text-processing binary, version 0.3.1. Its archive SHA-256 is `5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa`. Its embedded Rust components are outside the source-pin OSV query; a checksum verifies archive integrity, not its internal code. The legacy Sparkle 2.8.1 tooling downloader remains behind disabled release commands and is not a shipped runtime dependency. Review and replace that downloader before re-enabling release automation.

## Security controls and remaining work

| Area | Observed state | Remaining action |
| --- | --- | --- |
| Repository alerts | GitHub reports Dependabot alerts disabled; automatic security-update PRs are disabled | Enable both in repository security settings. The current CLI token lacks the administrative scope needed for the alerts API |
| Private reporting | GitHub private vulnerability reporting is disabled | Enable it; the security policy now explains what to do when the reporting option is absent |
| Repository protection | Secret scanning and push protection enabled; weekly Dependabot configuration present; strict `build-test` check and admin enforcement enabled | Zero approving reviews are required; consider requiring an independent reviewer for dependency and workflow changes |
| Secrets | Gitleaks 8.30.1 scanned 710 commits reachable through local refs, approximately 35 MB | Seven matches were localization identifiers, with no confirmed credentials. Keep scanning future changes; local ignored credentials were not published |
| Local storage | Owner-only permissions, restrictive umask, and Keychain for credentials | Recordings and databases lack app-level encryption. Recovery spools have no expiration or deletion UI and are outside ordinary retention settings |
| Network imports | HTTPS and literal-address/redirect checks; subprocesses use fixed arguments without a shell and a reduced environment | Public DNS names are not resolved and pinned, so DNS rebinding remains possible. Optional yt-dlp/ffmpeg are external executable dependencies |
| External AI and telemetry | Production policy disables external enhancement and MCP serving; the production telemetry and contribution uploaders are inert | Keep these boundaries when merging upstream features |
| Application updates | The production update service has no updater controller | Use deliberate signed local updates; establish an owner-controlled update channel before broader distribution |
| Distribution | Local Release signature verifies strictly, hardened runtime is enabled, and only the microphone entitlement remains; public release automation is disabled | The local app is Apple Development signed. Developer ID export and notarization are still required before public distribution |
| Toolchain | Compatible dependency upgrades completed | Upgrade Xcode separately before migrating to current MLX and Collections releases; existing Swift 6 isolation and deprecated-API warnings remain |

Repository security settings are at [GitHub security settings](https://github.com/dtacci/superduper/settings/security_analysis). No repository settings, tags, releases, or remote branches were changed during this sweep.

Local diagnostics also contain four historical audio-writer backlog failures. The recorder deliberately aborts when its bounded writer queue cannot keep up. Reproduce and profile capture under disk/CPU pressure before changing that safety bound; unit tests do not establish the cause of those historical overruns.

## Validation

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just build` passes.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just build-release` passes. `codesign --verify --deep --strict` passes; the signed Release app has hardened runtime, only the microphone entitlement, and no debugger entitlement.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just test` passes: 1,492 tests. Real model suites are opt-in.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just test-integration` passes: 22 tests, including loading Parakeet v2, Parakeet v3, and WhisperKit tiny. Two diarization-quality checks are skipped because their fixtures are absent; speaker-label accuracy is not established by this run.
- `just l10n-lint` passes.
- `git diff --check` passes.
- A fresh package resolution with an empty checkout directory and `-onlyUsePackageVersionsFromResolvedFile` passes and leaves the lockfile unchanged.
- OSV scan: 32 source pins, zero advisory matches. Gitleaks history scan: seven reviewed localization false positives, zero confirmed secrets. The scan of the current diff and new audit files returns zero matches.

The validated local app is available at `DerivedData/Build/Products/Release/Superduper Dictation.app`.
