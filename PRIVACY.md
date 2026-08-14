# Privacy

Superduper Dictation is designed so ordinary dictation can remain on your Mac.

## Stored locally

- Transcript History and related metadata
- Dictionary entries and app preferences
- Before/after transcript pairs when local contribution storage is explicitly enabled
- Downloaded speech and diarization models
- Rotating diagnostic logs
- Meeting recordings and imported media
- Ordinary dictation audio only when retention is explicitly enabled

These files live under
`~/Library/Application Support/Superduper Dictation/`. The app applies
owner-only filesystem permissions. The files are not separately encrypted by
the app; macOS FileVault is recommended.

Deleting a History item or changing retention can remove app-managed files, but
copies you exported, pasted, or backed up are outside the app’s control.

## Network activity

The app may access the network when you:

- download an on-device speech/diarization model; or
- submit an HTTPS URL through Library → Paste Link.

Non-direct links can be passed to locally installed `yt-dlp` and `ffmpeg`.
Those tools and the source website have their own behavior and privacy terms.

No telemetry destination is configured. Cloud transcription models are not
selectable, and external AI enhancement plus MCP serving are disabled in the
supported build.

## Permissions

- **Microphone:** records dictation and the microphone side of Meetings.
- **Screen & System Audio Recording:** captures system audio only when you start
  the Meeting workflow and macOS requires this permission.
- **Accessibility:** sends the paste keystroke to the currently focused app.

Text pasted into another application becomes subject to that application’s
privacy and security behavior.
