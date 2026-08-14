# Superduper Dictation: local-only fork

This fork keeps Pindrop's native SwiftUI menu-bar architecture and narrows its
default experience to one action: press `Option+Space`, speak, press it again,
and insert the local transcript at the active cursor.

## Defaults

- macOS 14 or newer on Apple Silicon
- Toggle shortcut: `Option+Space`
- Output: direct insertion, with clipboard fallback when Accessibility access
  is unavailable
- Model: `openai_whisper-large-v3-v20240930_626MB`
- Secondary shortcuts: unset
- Model catalog: local providers only
- Telemetry destination and SDK: removed
- Cloud transcription and cloud AI settings: not exposed
- External AI execution and MCP serving: blocked by production policy
- Ordinary dictation audio retention: off until explicitly enabled
- Upstream automatic updater and release feed: removed

The model is downloaded during onboarding. After that download completes,
dictation and insertion work without a network connection.

## Library categories

Normal `Option+Space` recordings appear under **Dictations**. **Meetings** are
created only through **Record Meeting…** and capture microphone plus system
audio for long-form transcription. Meeting source audio is retained with the
Library record; speaker diarization can add speaker labels when its local model
is installed.

## Untrusted input

Transcripts are never routed to an LLM or agent in the supported build. HTTPS
media links and downloaded media remain untrusted input: link URLs are screened,
downloads are bounded, and optional tools run without a shell and with a reduced
environment. See `SECURITY.md` for the maintained threat model.

## Build and run

1. Install regular Xcode 16.4 or newer from Apple. Command Line Tools alone cannot
   build an Xcode application project.
2. Open `Pindrop.xcodeproj`.
3. If Xcode requests signing configuration, choose your personal development
   team for the Pindrop target. The upstream maintainer's team identifier has
   been removed from this fork.
4. Select the Pindrop scheme and run it.
5. Complete onboarding, granting Microphone and Accessibility permissions.

For an unsigned compile/test pass after Xcode is installed, install the `just`
command runner with `brew install just`, then run:

```sh
just build-unsigned
just test-unsigned
```

## Manual verification

Test the toggle-to-insert path in Notes, Safari or Chrome, Terminal, VS Code,
and an Electron chat application. Confirm that `Option+Space` does not insert a
nonbreaking space, the previous clipboard contents are restored after a
successful paste, and permission denial leaves the transcript on the clipboard.

Also test empty audio, a very short phrase, a 60-second recording, cancellation,
and operation with Wi-Fi disabled after the model has downloaded.

For the Meeting path, verify both `Option+Shift+Space` and the **Record
Meeting** action in the menu-bar dropdown. Confirm that the visible recording
indicator remains present, system-audio permission is requested only for a
Meeting, and the 90-minute safety stop finalizes the captured audio.
