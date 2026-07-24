# mac-voice-dictation

Native macOS **menu-bar push-to-talk dictation** app in Swift.
Hold a global hotkey, speak, release - the recorded utterance is sent to the remote whisper service, transcribed, and the resulting text is pasted at the cursor of whatever app is focused.

This is the Mac counterpart of the BikeOffice Android dictation, reusing the same whisper backend (`large-v3-turbo`) on the shared gpuserver.

## What it does

- Lives in the menu bar only (no Dock icon). The status icon reflects state: idle, recording, transcribing, inserting, error, or needs-permission.
- **On-screen recording overlay**: a floating HUD appears at the bottom-centre of your screen while recording / transcribing / inserting, so feedback never depends on the menu-bar icon (which the notch on 15" MacBook Airs can hide). It shows a pulsing red dot while recording and fades out shortly after you finish. See [On-screen feedback](#on-screen-feedback-and-reaching-the-app).
- **Status/settings window**: a normal window with live status, both permission states (with Grant buttons), a server check, and every setting the menu has. **Re-open the app while it is already running (click it in Finder/Dock, or `open build/VoiceDictation.app` again) to bring this window up** - a dependable way in even when the notch hides the menu-bar icon.
- **Hold-to-talk**: hold the hotkey (default **fn / Globe**) to record, release to transcribe and insert. A short debounce ignores accidental taps. Right Option and other modifiers are selectable fallbacks.
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

This runs `swift build -c release`, assembles `build/VoiceDictation.app`, and code-signs it with a **stable self-signed identity** (see below).
We use an SPM executable plus a bundling step (rather than an Xcode project) so the build is fully reproducible from the command line with only the Swift toolchain.

### Stable signing so permissions survive rebuilds

macOS records Microphone / Accessibility grants against the app's code-signing identity - specifically the *designated requirement*, which pins the signing certificate. Plain ad-hoc signing (`codesign --sign -`) has no stable certificate: every rebuild gets a fresh code hash, so macOS treats each reinstall as a brand-new app and **forgets the grants**, forcing you to re-approve permissions every time.

To avoid that, `Scripts/build-app.sh` signs with a persistent self-signed code-signing identity:

- On the **first** build it creates a self-signed cert named `VoiceDictation Self-Signed` in a small dedicated keychain (`~/Library/Keychains/voicedictation-signing.keychain-db`) with a known local passphrase, and authorises `codesign` to use it (`security set-key-partition-list`). This is **idempotent and prompt-free** - it never touches your login keychain, so it does not ask for your login password.
- Every **subsequent** build finds and reuses that same identity, so the designated requirement stays constant and your permission grants persist across rebuilds.
- If a signing identity cannot be created for any reason, the script **falls back to ad-hoc signing** with a warning; the app still runs, but you may need to re-grant permissions after an update.

Only `Scripts/build-app.sh` signs. `swift build` / `swift test` produce only the linker's automatic ad-hoc signature (no keychain access), so day-to-day dev iterations never prompt.

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

> Because the app is signed with a **stable self-signed identity** (see [Stable signing](#stable-signing-so-permissions-survive-rebuilds)), macOS remembers these grants across rebuilds instead of re-prompting after each reinstall.

### Free up the Globe key (required for the default hotkey)

The default hotkey is **fn / Globe**. By default macOS uses that key to show the emoji picker or switch input sources, which would fire every time you dictate. Turn that off once:

**System Settings → Keyboard → "Press 🌐 Globe key to" → "Do Nothing".**

After that, holding fn/Globe cleanly triggers push-to-talk and nothing else. (If you'd rather keep the Globe key's system behavior, pick a different hold key from the menu's **Hotkey** submenu - Right Option is a solid fallback.)

## On-screen feedback and reaching the app

Because the app is menu-bar-only, the notch on a 15" MacBook Air (and a crowded menu bar generally) can hide the status icon - leaving you unable to tell the app is running, see when it is recording, or reach its settings. Two features solve this without depending on the icon:

- **Recording overlay.** A small floating panel appears bottom-centre on the screen under your mouse whenever the app is active: "🎙 Recording…" with a pulsing red dot while recording, "⏳ Warming up server…" if the model is still loading, "✍️ Transcribing…", then "Inserting…", fading out on idle. It also surfaces "⚠ Microphone permission required" / "⚠ Server unreachable" style warnings. The overlay is deliberately **non-activating** - it never takes focus, so your Cmd+V paste still lands in the app you were typing into.
- **Re-open for the window.** Launching the app again while it is already running opens the **status/settings window** (standard "click the app to get its window" behaviour). From there you can see the current status, grant either permission, check the server, and change the hotkey / language / server URL / launch-at-login. On first launch the app also surfaces itself: it opens this window if a permission is missing, otherwise flashes a brief "Voice Dictation is running" greeting overlay so you know it started.

## Usage

1. Launch the app and grant both permissions, and set "Press Globe key to → Do Nothing" (see above).
2. Focus any text field in any app.
3. Hold **fn / Globe**, speak, and release. The transcription is pasted at the cursor.
4. Adjust the hotkey, language, server URL, and launch-at-login from the menu-bar icon.
5. "Check Server" runs a `/health` probe and shows the server's state (it boots asleep by design).

## Tests

```sh
swift test
```

Covers:
- **WAV encoding** - a canonical 16 kHz / mono / 16-bit header plus correct little-endian sample data.
- **Whisper client request shaping** - URL, method, `Content-Type: audio/wav`, and `X-Language` header for `/health`, `/start`, `/transcribe`.
- **Client behavior** - 502 backend-down, empty-text, retry-on-not-ready (503 **and** 500) with a bounded give-up, and `waitUntilReady` health-polling (ready-after-N-polls, timeout, and `{"state":"ready"}` without a `ready` flag), exercised with a stub `URLProtocol`.
- **Overlay view-model** - `AppStatus` → label / accent / pulse mapping and the auto-hide timing policy.
- **Config persistence** - round-trips through `UserDefaults`.
- **Live `/health` smoke check** - when on the tailnet it validates the real TLS trust exception and response decoding against the server; off the tailnet it skips gracefully.

## Server contract (reference - do not modify the server)

Base URL: `https://gpuserver.beaver-brotula.ts.net:9443` (HTTPS reverse proxy in front of a uvicorn backend). The cert is **self-signed / not system-trusted**; the app accepts it via a `URLSessionDelegate` scoped to that host only (see `HostTrustDelegate`).

| Endpoint | Method | Notes |
|---|---|---|
| `/health` | GET | `{"model","state","ready"}`, `state ∈ {sleeping, ready}`. Boots asleep (0 GPU). |
| `/start` | POST | Wakes and loads the model (a few seconds) → `{"state":"ready","ready":true}`. Fired on hotkey-down. |
| `/transcribe` | POST | `Content-Type: audio/wav`, body = mono/16-bit/16 kHz WAV, header `X-Language: de\|en\|auto` → `{"text","language","ms"}`. |

Handled failure modes (visible status, never a crash): HTTP 502 (backend down), empty `text`, network/timeout/unreachable, and **not-yet-ready after `/start`**. The server boots asleep and takes a few seconds to load the model after `/start`; transcribing before then makes it return HTTP 500 ("NoneType has no attribute transcribe"). The app therefore polls `GET /health` until `state == ready` (bounded ~15s, showing "Warming up server…") before sending audio, and additionally retries `/transcribe` on 500/503 with exponential backoff as a backstop. Health decoding tolerates a `ready` field that is absent, treating `{"state":"ready"}` as ready.

## Manual end-to-end verification

The mic / global-hotkey / paste path cannot be exercised headlessly. On a real Mac session:

1. `Scripts/build-app.sh && open build/VoiceDictation.app`.
2. Grant Microphone (prompt) and Accessibility (System Settings), confirm the menu ⚠ items clear. Set "Press Globe key to → Do Nothing".
3. Ensure Tailscale is connected; "Check Server" shows `sleeping` or `ready`.
4. Focus a text field, hold fn/Globe, speak a German phrase, release → text is pasted.
5. **Overlay**: while holding fn/Globe, confirm the "🎙 Recording…" HUD appears bottom-centre with a pulsing red dot, then progresses to "✍️ Transcribing…"/"Inserting…" (with "⏳ Warming up server…" in between if the model was still asleep) and fades out. Critically, confirm the **frontmost app does not change** when it appears and the text still pastes into your focused field (the overlay is non-activating).
6. Copy something to the clipboard first, dictate, then paste (Cmd+V) → confirm your original clipboard is back.
7. **Re-open window**: with the app already running, run `open build/VoiceDictation.app` again (or click it in Finder) → the status/settings window appears centred. Grant a permission from it and confirm the row flips to "✓ Granted"; close it and confirm no permanent Dock icon remains.
8. Change hotkey/language/server URL/launch-at-login in the window or menu, quit, relaunch → settings persist.
9. Disconnect Tailscale and dictate → the menu/overlay shows "Server unreachable", no crash.

## Architecture

Clean module split so each layer is independently testable:

- `Sources/DictationCore/` (no AppKit, headless-testable): `WavEncoder`, `WhisperClient` + `WhisperRequestFactory`, `WhisperModels`, `HostTrustDelegate`, `AppConfig` + `ConfigStore`, `AppStatus`, and `OverlayViewModel` (maps `AppStatus` → overlay label/accent/pulse + the auto-hide timing policy, unit-tested).
- `Sources/VoiceDictation/` (AppKit app): `AudioCapture` (AVAudioEngine → 16 kHz mono Int16), `HotkeyMonitor` (CGEventTap), `TextInserter` (pasteboard + Cmd+V + restore), `Permissions`, `LaunchAtLogin` (SMAppService), `DictationController` (orchestration; fans status out to multiple observers), `DictationActions` (shared settings mutations), `StatusItemController` (menu), `OverlayController` (non-activating floating HUD), `SettingsWindowController` (status/settings window), `AppDelegate`.
