# mac-voice-dictation

Native macOS **menu-bar push-to-talk dictation** app in Swift.
Hold a global hotkey, speak, release - the recorded utterance is sent to the remote whisper service, transcribed, and the resulting text is pasted at the cursor of whatever app is focused.

This is the Mac counterpart of the BikeOffice Android dictation, reusing the same whisper backend (`large-v3-turbo`) on the shared gpuserver.

## What it does

- Lives in the menu bar only (no Dock icon). The status icon reflects state: idle, recording, transcribing, inserting, error, or needs-permission.
- **Hold-to-talk**: hold the hotkey (default **Right Option**) to record, release to transcribe and insert. A short debounce ignores accidental taps.
- On hotkey-down it proactively fires `POST /start` so the (asleep-by-default) model warms while you are still speaking.
- Inserts text by putting it on the pasteboard, synthesizing **Cmd+V** into the focused app, then **restoring the previous pasteboard contents**.
- Server URL, hotkey, language (`de` default, plus `en`/`auto`), and launch-at-login are configurable from the menu and persist across restarts.

## Requirements

- macOS 13 (Ventura) or later.
- Swift toolchain (the Xcode **Command Line Tools** are sufficient - a full Xcode install is *not* required).
- **Tailscale**: the whisper server is a tailnet host (`gpuserver.beaver-brotula.ts.net`). The Mac must be on the tailnet for it to resolve; otherwise the menu shows "Server unreachable (on Tailscale?)".

## Build

```sh
Scripts/build-app.sh
```

This runs `swift build -c release`, assembles `build/VoiceDictation.app`, and ad-hoc code-signs it.
We use an SPM executable plus a bundling step (rather than an Xcode project) so the build is fully reproducible from the command line with only the Swift toolchain.

## Run

```sh
open build/VoiceDictation.app
```

The app appears in the menu bar (look for the microphone icon). To see logs in the foreground instead:

```sh
build/VoiceDictation.app/Contents/MacOS/VoiceDictation
```

## Required permissions

The app needs **two** macOS permissions. The menu shows a clear ⚠ item for whichever is missing.

1. **Microphone** - to record audio (`AVAudioEngine`). Requested automatically on first launch; the system prompt uses the `NSMicrophoneUsageDescription` copy.
2. **Accessibility** - required for *both* the global hotkey event tap and the synthetic Cmd+V paste. macOS does not prompt for this the same way; grant it in **System Settings → Privacy & Security → Accessibility** and enable **VoiceDictation**. The app opens this pane for you from the menu's "Grant Accessibility access" item, and arms the hotkey automatically once it is granted.

> Because the app is ad-hoc signed with a stable bundle identifier, macOS remembers these grants across rebuilds instead of re-prompting each launch.

## Usage

1. Launch the app and grant both permissions.
2. Focus any text field in any app.
3. Hold **Right Option**, speak, and release. The transcription is pasted at the cursor.
4. Adjust the hotkey, language, server URL, and launch-at-login from the menu-bar icon.
5. "Check Server" runs a `/health` probe and shows the server's state (it boots asleep by design).

## Tests

```sh
swift test
```

Covers:
- **WAV encoding** - a canonical 16 kHz / mono / 16-bit header plus correct little-endian sample data.
- **Whisper client request shaping** - URL, method, `Content-Type: audio/wav`, and `X-Language` header for `/health`, `/start`, `/transcribe`.
- **Client behavior** - 502 backend-down, empty-text, and retry-once-when-not-ready, exercised with a stub `URLProtocol`.
- **Config persistence** - round-trips through `UserDefaults`.
- **Live `/health` smoke check** - when on the tailnet it validates the real TLS trust exception and response decoding against the server; off the tailnet it skips gracefully.

## Server contract (reference - do not modify the server)

Base URL: `https://gpuserver.beaver-brotula.ts.net:9443` (HTTPS reverse proxy in front of a uvicorn backend). The cert is **self-signed / not system-trusted**; the app accepts it via a `URLSessionDelegate` scoped to that host only (see `HostTrustDelegate`).

| Endpoint | Method | Notes |
|---|---|---|
| `/health` | GET | `{"model","state","ready"}`, `state ∈ {sleeping, ready}`. Boots asleep (0 GPU). |
| `/start` | POST | Wakes and loads the model (a few seconds) → `{"state":"ready","ready":true}`. Fired on hotkey-down. |
| `/transcribe` | POST | `Content-Type: audio/wav`, body = mono/16-bit/16 kHz WAV, header `X-Language: de\|en\|auto` → `{"text","language","ms"}`. |

Handled failure modes (visible status, never a crash): HTTP 502 (backend down), empty `text`, network/timeout/unreachable, and not-yet-ready after `/start` (retried once with a short backoff).

## Manual end-to-end verification

The mic / global-hotkey / paste path cannot be exercised headlessly. On a real Mac session:

1. `Scripts/build-app.sh && open build/VoiceDictation.app`.
2. Grant Microphone (prompt) and Accessibility (System Settings), confirm the menu ⚠ items clear.
3. Ensure Tailscale is connected; "Check Server" shows `sleeping` or `ready`.
4. Focus a text field, hold Right Option, speak a German phrase, release → text is pasted.
5. Copy something to the clipboard first, dictate, then paste (Cmd+V) → confirm your original clipboard is back.
6. Change hotkey/language/server URL/launch-at-login in the menu, quit, relaunch → settings persist.
7. Disconnect Tailscale and dictate → the menu shows "Server unreachable", no crash.

## Architecture

Clean module split so each layer is independently testable:

- `Sources/DictationCore/` (no AppKit, headless-testable): `WavEncoder`, `WhisperClient` + `WhisperRequestFactory`, `WhisperModels`, `HostTrustDelegate`, `AppConfig` + `ConfigStore`.
- `Sources/VoiceDictation/` (AppKit app): `AudioCapture` (AVAudioEngine → 16 kHz mono Int16), `HotkeyMonitor` (CGEventTap), `TextInserter` (pasteboard + Cmd+V + restore), `Permissions`, `LaunchAtLogin` (SMAppService), `DictationController` (orchestration), `StatusItemController` (menu), `AppDelegate`.
