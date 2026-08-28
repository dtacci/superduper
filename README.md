# Superduper Dictation

Superduper Dictation is a native, local-first macOS dictation and meeting
recorder. It is built for people who want the convenience of a polished
dictation app without a subscription or a transcript sent to a vendor by
default.

Press `Option+Space`, speak, press it again, and the transcript is inserted at
the active cursor. Successful transcripts are also saved in **History**. For a
long-form conversation, press `Option+Shift+Space` or choose **Record Meeting**
from the menu-bar dropdown.

This is a focused fork of the MIT-licensed
[Pindrop](https://github.com/watzon/pindrop) project. The Swift target and some
source paths retain the `Pindrop` name to keep the fork maintainable; the
product, bundle identifier, storage directory, and user-facing copy are
Superduper Dictation.

## Why this exists

Dictation is a small, useful computer function. It should be possible to run it
on your own Mac with an open model, inspect the code, and keep control of your
recordings. Superduper Dictation is my contribution back to that ecosystem:
open source, local-first, subscription-free, and deliberately conservative
about network access and automation.

## What it does

- Runs speech-to-text locally with WhisperKit and other on-device engines.
- Defaults to a quantized Whisper Large v3 model.
- Toggles dictation globally with `Option+Space`.
- Inserts text at the current cursor, with a clipboard fallback.
- Keeps a searchable transcript History with playback and export.
- Records Meetings from the menu bar, Home, History, or `Option+Shift+Space`.
- Captures microphone plus system audio for Meetings, with optional local
  speaker diarization.
- Preserves meeting audio in a managed workspace so failed processing can be
  retried without recording the meeting again.
- Provides diarized transcripts, editable speaker names and notes, summaries,
  decisions, and action items in local meeting workspaces.
- Can generate meeting insights entirely on-device on Apple Silicon with an
  optional, separately downloaded local model.
- Connects one Google Calendar account through a guided browser sign-in, then
  lets you explicitly arm individual meeting occurrences for scheduled capture.
- Includes a persistent recording-indicator privacy toggle and a compact,
  audio-reactive waveform indicator.
- Imports local audio/video and supported HTTPS media links.
- Provides a configurable global-hotkey editor and a native macOS settings UI.

## Quick start

### For users

When a public release is available, download the signed and notarized `.dmg`
from the repository’s **Releases** page, open it, and drag Superduper Dictation
to Applications. **You do not need Xcode to install or use a release build.**
The first launch downloads the selected on-device speech model. The optional
meeting-insights model is a separate download of roughly 2.15 GB.

This repository is currently source-first, so a public release artifact has not
been published yet. Until then, the instructions below are for building from
source.

### Use the app

1. Launch Superduper Dictation and complete onboarding.
2. Download an on-device transcription model when prompted.
3. Grant Microphone and Accessibility access. Accessibility is needed to insert
   text into the focused application.
4. Focus any text field, press `Option+Space`, speak, and press it again.

If direct insertion is unavailable, the transcript remains available through
the clipboard fallback and in History. If macOS says Accessibility is already
enabled but insertion does not work, choose **Repair Permission** when the app
alerts you. This resets only Superduper Dictation's stale Accessibility entry
and opens the exact installed app plus **System Settings → Privacy & Security →
Accessibility** for a fresh grant. Locally rebuilding with an ad-hoc signature
invalidates the previous grant; use `just build-self-signed` for a stable local
identity.

### Record a Meeting

Meetings are a separate workflow, not a label applied to ordinary dictation.

1. Press `Option+Shift+Space` anywhere, or open the menu-bar dropdown and
   choose **Record Meeting**.
2. The app starts immediately with automatic speaker detection. Use the
   optional meeting-controls button in Home or History only when you want to
   provide an expected speaker count.
3. Grant Screen & System Audio Recording access if macOS requests it. The app
   records microphone and system audio together.
4. Press `Option+Shift+Space` again, choose **Stop Meeting**, or use the visible
   recording control to finish.
5. The recording is preserved, transcribed locally, and opened as a meeting
   workspace with audio, speaker turns, editable notes, and optional on-device
   insights. If processing fails, use **Retry Processing**; the captured audio
   remains available.

Meeting capture automatically stops and finalizes at 90 minutes. This protects
against an unattended recording running indefinitely. The recording indicator
remains visible; this tool is intended for transparent, consent-based
recording, not covert capture. Follow the recording-consent rules where you
live and in every meeting you record.

## How it works

The normal dictation path is intentionally short:

```text
Global hotkey
    → native microphone capture
    → local transcription engine
    → Accessibility insertion (or clipboard fallback)
    → local History record
```

The Meeting path adds system-audio capture and speaker diarization:

```text
Meeting hotkey/menu action
    → microphone + system audio capture
    → persistent, file-backed meeting workspace
    → local transcription + optional diarization
    → editable transcript/notes + optional on-device insights
```

The app is a SwiftUI/AppKit menu-bar application. Carbon global hotkeys route
into `AppCoordinator`; audio capture is handled by the recorder services;
WhisperKit, FluidAudio, and other local engines implement transcription; and
History persists records under the app’s local Application Support directory.

## Privacy and security

The supported app experience is deliberately local-first:

- No telemetry or analytics backend is configured.
- Cloud transcription models are excluded from the selectable model catalog.
- External AI enhancement and the inherited MCP server are disabled at runtime,
  including when old preferences are present.
- Meeting transcripts are never sent to configured HTTP AI providers. Optional
  meeting insights use a separately downloaded local model on Apple Silicon and
  can be disabled independently.
- Google Calendar integration sends only OAuth and read-only calendar metadata
  to Google; recordings, transcripts, notes, and insights remain local.
- Ordinary dictation audio retention defaults to **Off**. Transcripts remain in
  History; Meetings and imported media retain their source audio/video.
- App data is created with owner-only filesystem permissions.
- Web imports require public HTTPS URLs, reject embedded credentials and obvious
  local-address forms, cap downloads at 2 GB, ignore user `yt-dlp`
  configuration, disable discovered plugins, and run tools with a minimal
  environment.

The app is not App-Sandboxed because global hotkeys, system-wide insertion, and
system-audio capture require broader macOS integration. That is a deliberate
tradeoff and part of the threat model. Read [PRIVACY.md](PRIVACY.md) and
[SECURITY.md](SECURITY.md) before distributing a build.

### Local data locations

App-managed data primarily lives under:

```text
~/Library/Application Support/Superduper Dictation/
```

This includes History metadata, downloaded models, Meeting recordings, imported
media, preferences, and rotating diagnostic logs. The app does not separately
encrypt these files; FileVault is recommended for data at rest. Exported or
pasted copies are outside the app’s control. Some third-party model runtimes may
also maintain their own cache under `~/Library/Application Support/`; inspect
the relevant model’s documentation before deleting caches.

## Models and licensing

The application source code is MIT-licensed. The transcription models are
downloaded separately and are **not automatically MIT-licensed**: each model’s
weights, training data, and model card determine its own terms. Review those
terms before redistribution or commercial use.

The same applies to third-party libraries, fonts, and optional tools such as
`yt-dlp` and `ffmpeg`. Their notices are preserved in the repository where
appropriate, and their licenses continue to govern those components. See the
acknowledgements bundled with the app and the upstream project notices.

## Requirements

### End users

- A signed/notarized Superduper Dictation release
- macOS 14 or newer
- Several GB of free space for the selected speech model

Xcode is not an end-user requirement.

### Contributors building from source

- macOS 14 or newer
- Apple Silicon recommended
- Regular Xcode 16.4 or newer (Command Line Tools alone cannot build the app)
- Several GB of free space for the selected model, dependencies, and build
  products

## Build from source

Open `Pindrop.xcodeproj` in Xcode, select the `Pindrop` scheme, choose your
personal development team if Xcode requests one, and press `Cmd+R`.

For a command-line build, install [just](https://github.com/casey/just):

```sh
brew install just
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just build-unsigned
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just test-unsigned
```

The first onboarding run downloads the selected model. Dictation can run
offline after that download completes. See [BUILD.md](BUILD.md) for stable
local signing and public distribution requirements.

## Google Calendar setup

Google Calendar is optional. Open **Meetings → Set Up Google Calendar** and
follow the three-step wizard. A publisher build can include its Google **Desktop
app** OAuth client ID in `GoogleCalendarClientID` in `Pindrop/Info.plist`. If it
does not, the wizard links to Google Cloud and lets the user paste a Desktop app
client ID without rebuilding the app. Contributors can also set
`PINDROP_GOOGLE_CLIENT_ID` when launching a development build. Desktop clients
use PKCE and do not embed a client secret.

After connecting, choose **Check Weekly Meetings** from the menu bar or the
Meetings page. The rolling seven-day review puts calls with other attendees and
a supported join link in the recommended section. Solo, all-day, and unsupported
events stay under **Other calls**. Nothing new is checked automatically: select
the individual occurrences to arm, then save the week. Already armed meetings
remain checked so the same screen can be used to disarm them.

At an armed meeting's scheduled start, Superduper Dictation opens its join link
when available and records microphone plus system audio. It stops at the event's
scheduled end, preserves the audio, transcribes and diarizes it, and creates the
local meeting workspace. The app must be running, the Mac must be awake, and
Launch at Login should be enabled for dependable scheduling.

For a zero-configuration public build, the repository owner must supply one
publisher-owned client ID, configure the OAuth consent screen, and complete any
Google verification required for the two read-only Calendar scopes. Until then,
friends can use the wizard's client-ID field with credentials from their own
Google Cloud project.

## Optional media-link tools

**History → Paste Link** requires `yt-dlp` and `ffmpeg` for non-direct media
URLs:

```sh
brew install yt-dlp ffmpeg
```

Only install these tools from a source you trust. Local file import and normal
dictation do not require them.

## Development commands

```sh
just --list
just build-unsigned
just test-unsigned
just lint       # requires SwiftLint
just format     # requires SwiftFormat
just l10n-sync
just l10n-lint
```

Swift package versions are locked in `Package.resolved`. The default unit suite
does not download models or contact external services. Keep transcripts,
recordings, credentials, certificates, and machine-specific Xcode data out of
commits.

## Project layout

```text
Pindrop/                    App source (inherited target name)
Pindrop/Services/           Audio, transcription, storage, and integrations
Pindrop/UI/                 SwiftUI and AppKit UI
PindropTests/               Swift Testing unit suite
PindropUITests/             XCTest UI suite
Localization/               YAML-first localized strings
scripts/                    Build, signing, and packaging helpers
docs/                       Design, security, and research notes
```

## Distribution status

The source repository is ready for owner-managed packaging, but a trusted
public release still needs an Apple Developer ID signing certificate,
notarization, and a published `.dmg` or `.zip`. A local self-signed build is
useful for development and preserves local Accessibility approval, but it is
not a substitute for a public notarized release: other users may see Gatekeeper
warnings and will have to approve the app manually.

See [BUILD.md](BUILD.md), [RELEASING.md](RELEASING.md), and
[SECURITY.md](SECURITY.md) before publishing an artifact.

## Current limitations

- Meeting transcription is local and post-capture; live meeting notes are not
  generated.
- Scheduled recording requires the app to be running, the Mac to be awake, and
  Launch at Login to be enabled; no privileged wake daemon is installed.
- Automated meeting insights require Apple Silicon and the optional local model;
  Intel Macs retain the full workspace, transcript, audio, and manual notes.
- A public downloadable release is not currently provided by this repository.
  Local self-signed artifacts are for development only and are not notarized.
- The app has no universal sandbox because its core features require global
  hotkeys, Accessibility insertion, and system-audio capture.

These limitations are documented so contributors can improve the project
without mistaking a prototype boundary for a security guarantee.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), run
the unsigned build and unit suite, and include focused tests for behavior and
security boundaries. Security reports should follow [SECURITY.md](SECURITY.md)
instead of being posted publicly.

## License

Superduper Dictation’s original source and modifications are released under the
[MIT License](LICENSE). Copyright and license notices for upstream code and
third-party components remain applicable. In particular, the app’s source
license does not change the license of separately downloaded model weights.

## Acknowledgements

- [Pindrop](https://github.com/watzon/pindrop), the upstream native app
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [OpenAI Whisper](https://github.com/openai/whisper)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
