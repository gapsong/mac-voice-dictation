# Design and internals

This page is for people who want to read or change the code.
For installing and using the app, see the [README](../README.md).

## Architecture

The code is split in two modules, so that everything worth testing can be tested without a screen, a microphone or macOS permissions.

- `Sources/DictationCore/` has no AppKit and is unit-tested headlessly:
  - `WavEncoder`: 16 kHz / mono / 16-bit PCM WAV.
  - `WhisperClient` and `WhisperRequestFactory`: the HTTP client for the server contract below.
  - `WhisperModels`: the response types.
  - `AppConfig` and `ConfigStore`: the settings, stored as one JSON blob in `UserDefaults`.
  - `AppStatus`: the one shared state enum.
  - `OverlayViewModel`: maps `AppStatus` to the overlay's label, accent and pulse, plus the auto-hide timing.
  - `HotkeyEdgeResolver`: the hold-to-talk state machine over the set of armed hotkeys.
  - `SilenceArtifactFilter`: drops Whisper's subtitle boilerplate on silence.
- `Sources/VoiceDictation/` is the AppKit app:
  - `AudioCapture`: `AVAudioEngine` input, converted to 16 kHz mono Int16.
  - `HotkeyMonitor`: the `CGEventTap` adapter plus a debounce over `HotkeyEdgeResolver`.
  - `TextInserter`: pasteboard, synthetic Cmd+V, then restore the previous pasteboard.
  - `Permissions` and `LaunchAtLogin` (`SMAppService`, macOS 13+).
  - `DictationController`: the orchestration.
  - `DictationActions`: the one shared set of settings changes, used by the menu and the settings window.
  - `StatusItemController` (menu), `OverlayController` (floating HUD), `SettingsWindowController` (status and settings window), `AppDelegate`.

### One state model, many surfaces

`DictationController` holds the single `AppStatus` and fans every change out to several observers through `observeStatus(_:)`.
The menu-bar icon, the overlay and the settings window each register one, so they always agree.
There is no second source of truth for the status.

### The overlay must never take focus

The recording HUD is an `NSPanel` with `[.borderless, .nonactivatingPanel]`.
This is a correctness rule, not a detail.
The app pastes with a synthetic Cmd+V into the frontmost app.
If the overlay became active, the frontmost app would change and the paste would land in the wrong place.
So the panel refuses key and main status, is shown with `orderFrontRegardless()` (never `makeKeyAndOrderFront`), ignores the mouse, and floats over full-screen apps and every Space.

The overlay is the main feedback channel because the notch on some MacBooks can hide the menu-bar icon.
For the same reason, opening the app again while it runs (`applicationShouldHandleReopen`) shows the settings window.

## Hotkeys

`AppConfig.hotkeys` is a set: several hold-to-talk keys are armed at the same time.
The default is fn/Globe plus F13.
There are three kinds of trigger:

- `.modifierFlag(mask:)` for fn/Globe.
  macOS reports fn as the `.maskSecondaryFn` flag, not as a key code, so its state is read from the flag.
- `.modifierKey(keyCode:)` for Right/Left Option, Right Command and Right Control.
  These share a flag bit with their sibling key, so they are matched by key code.
- `.regularKey(keyCode:)` for normal keys, which is the F13-F19 path.

A hold belongs to the key that started it.
While one key is held, the other keys are ignored, and key auto-repeat is absorbed.
`HotkeyMonitor` is only the event tap and the debounce.
The decision logic lives in `DictationCore.HotkeyEdgeResolver`, because the AppKit target cannot be unit-tested with only the Command Line Tools.

Older configs stored one `hotkey`.
`AppConfig` still decodes that key and migrates it to `[old key, F13]`, so an update never loses the user's hotkey.

### Why fn does not work on external keyboards

Apple's fn/Globe key travels on a private Apple HID usage page.
A third-party keyboard handles its own fn key inside its firmware, as a layer switch, and sends nothing to the Mac.
No app can see a key that never arrives.
Measured on a NuPhy Air75 V2 with a session-level event tap: 666 key events, every letter, Shift, Command and Space, and no fn flag at all.

F13-F19 are in the standard USB HID keyboard page, missing from Apple keyboards, and unbound in macOS.
They are plain keys, so holding one does not change what other keys type (unlike Right Option, which types `@`, `€` and `|` on a German layout).

## Silence artifacts

Whisper was trained on subtitled video.
On near-silence it does not return an empty string, it returns the text that ends a subtitle track: "Untertitelung des ZDF, 2020" in German, "Subtitles by the Amara.org community" or "Thanks for watching!" in English.
The server reports this as a normal successful transcription.

`SilenceArtifactFilter` rejects these whole utterances, and the app shows "No speech detected".
Two rules keep the filter safe:

- The patterns must match the whole normalized utterance.
  "Das lief gestern im ZDF" is real speech and must pass.
- Short polite phrases like "Vielen Dank." or "Thank you." are not filtered, even though Whisper also produces them on silence.
  A user may dictate exactly those words, and silently dropping real speech is the worse failure.

## Server contract

The app talks to [whisper-service](https://github.com/gapsong/whisper-service) on `http://127.0.0.1:9876` by default.
Any server that implements these three endpoints works; set its URL in the settings.
Plain HTTP is allowed for local addresses only (`NSAllowsLocalNetworking` in `Resources/Info.plist`).
A remote server must use HTTPS with a certificate the system trusts.

| Endpoint | Method | Notes |
|---|---|---|
| `/health` | GET | `{"model","state","ready"}`, `state` is `sleeping` or `ready`. The server starts asleep. |
| `/start` | POST | Starts loading the model and returns the health body. Sent on key-down, so the model warms while you speak. |
| `/transcribe` | POST | `Content-Type: audio/wav`, body is a mono / 16-bit / 16 kHz WAV, header `X-Language: de\|en\|auto`. Returns `{"text","language","ms"}`. |

### The warm-up race

After `/start`, the model needs a moment to load.
A `/transcribe` before that does not return a clean 503, it returns HTTP 500.
So the app does two things:

- Before it sends audio, it polls `GET /health` until the server is ready (at most about 15 s) and shows "Warming up server…" while it waits.
- `WhisperClient` treats both 500 and 503 as "not ready" and retries a bounded number of times with exponential backoff.

`HealthResponse.ready` is optional: `{"state":"ready"}` without the flag still counts as ready.
Errors (502, empty text, timeout, unreachable server) always become a visible status, never a crash.

## Stable code signing

macOS remembers Microphone and Accessibility grants by the app's code-signing identity.
Plain ad-hoc signing (`codesign --sign -`) gives every build a new identity, so macOS would forget the grants after each update.

`Scripts/build-app.sh` therefore signs with a persistent self-signed identity:

- On the first build it creates a certificate named `VoiceDictation Self-Signed` in a small dedicated keychain, `~/Library/Keychains/voicedictation-signing.keychain-db`, with a known local passphrase.
  It never touches the login keychain, so it never asks for your password.
- Every later build reuses that identity, so the grants survive updates.
- If the identity cannot be created, the script falls back to ad-hoc signing with a warning.
  The app still runs, but you may have to grant the permissions again after an update.

Only `build-app.sh` signs.
`swift build` and `swift test` use the linker's automatic ad-hoc signature and never touch a keychain.

## App icon

`Resources/AppIcon.svg` is the source of the icon: a speech bubble in which a sound wave turns into lines of text.
`Scripts/make-icon.sh` renders it into every size macOS needs and writes `Resources/AppIcon.icns` (it needs `uv`).
The build only copies the committed `.icns`, so building needs no extra tools.
The README logo in `docs/assets/` repeats the icon shapes; keep it in step when the icon changes.

## Tests

```sh
Scripts/test.sh
```

The script wraps `swift test`.
With only the Command Line Tools, newer Swift toolchains do not find the bundled `Testing.framework` by themselves ("no such module 'Testing'"), so the script points them at it.
The tests use Swift Testing (`import Testing`), because `XCTest` is not part of the Command Line Tools.

They cover the WAV encoder, request shaping, client behavior (502, empty text, retries on 500 and 503, health polling), the overlay view model, the hotkey state machine, the silence filter and config persistence.
A live `/health` smoke test runs against a local whisper-service when one is running, and skips otherwise.

## Manual end-to-end check

The microphone, the global hotkey and the paste cannot be tested headlessly.
Before a release, check them by hand on a real Mac:

1. `Scripts/install.sh`.
2. Grant Microphone and Accessibility, and check that the warning items in the menu go away.
3. `curl http://127.0.0.1:9876/health` answers, and "Check Server" shows `sleeping` or `ready`.
4. Click into a text field, hold fn/Globe, speak, release: the text is pasted.
5. While you hold the key, the "Recording" overlay shows at the bottom of the screen, then "Transcribing" and "Inserting", then it fades out.
   The frontmost app must not change when the overlay appears.
6. Copy something, dictate, then press Cmd+V: your original clipboard is back.
7. With the app running, open it again (`open /Applications/VoiceDictation.app`): the settings window appears, and no Dock icon stays after you close it.
8. Change hotkeys, language, server URL and launch at login, quit, start again: the settings are kept.
9. Stop whisper-service (`launchctl bootout gui/$(id -u)/com.gapsong.whisper-service`) and dictate: the app shows "Server unreachable" and does not crash.
   Start the server again with its `scripts/install.sh`.
