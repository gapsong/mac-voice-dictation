# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## What this is

A native macOS menu-bar push-to-talk dictation app (Swift/AppKit). Hold a global hotkey → record mic → send a WAV to the remote whisper service → paste the transcription at the focused app's cursor. Mac counterpart of the BikeOffice Android dictation, sharing the same whisper backend.

## Build / run / test

- **Build the app bundle:** `Scripts/build-app.sh` → `build/VoiceDictation.app` (runs `swift build -c release`, assembles the bundle, signs with a stable self-signed identity - see below).
- **Run:** `open build/VoiceDictation.app`, or run `build/VoiceDictation.app/Contents/MacOS/VoiceDictation` directly for foreground logs.
- **Test:** `swift test`.
- We deliberately use an **SPM executable + bundling script**, not an Xcode project, so it is headless-buildable with only the Swift toolchain.

### Toolchain gotcha: Command Line Tools only

This machine has the **Command Line Tools**, not full Xcode. Consequences that will bite the next agent:

- `xcodebuild` is unavailable - hence the SPM + `Scripts/build-app.sh` approach.
- **`XCTest` is not in the CLT SDK.** `import XCTest` fails with "no such module". The tests therefore use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`), whose `Testing.framework` *is* bundled with CLT. Do not port tests back to XCTest here.
- Signing: see "Stable code-signing" below. `XCTest`'s absence is the CLT gotcha; signing is the TCC one.

## Stable code-signing (so TCC grants survive rebuilds)

macOS TCC keys Microphone/Accessibility grants off the app's **designated requirement**, which for a signed app pins the signing **certificate**. Pure ad-hoc (`codesign --sign -`) has no stable cert - every rebuild gets a new cdhash, so macOS forgets the grants on each reinstall and re-prompts. `Scripts/build-app.sh` therefore signs with a persistent self-signed identity (`ensure_signing_identity`). Sharp edges baked into that function:

- **Dedicated keychain, not login.** codesign's read of the private key is gated by the key's *partition list*, and updating a partition list (`security set-key-partition-list`) needs the keychain's password. We don't know the user's login-keychain password, so on the login keychain codesign fails non-interactively with `errSecInternalComponent` (only a one-time GUI "Always Allow" unblocks it). The script instead creates a small dedicated keychain (`~/Library/Keychains/voicedictation-signing.keychain-db`) with a known local passphrase, so it can set the partition list itself → fully prompt-free and headless. It is appended (never `-s`-replaced) to the search list so codesign finds the identity.
- **Idempotent, reference by hash.** The cert is created only if absent and reused every build (keeping the DR - and thus the grants - stable). We look it up with `security find-identity -p codesigning` (NOT `-v`: an untrusted self-signed cert reports `CSSMERR_TP_NOT_TRUSTED` and `-v` filters it out, yet codesign signs with it fine - trust only matters at *verification* time) and sign by **SHA-1 hash**, not name, so duplicate like-named certs never make codesign ambiguous.
- **openssl portability.** `security import` chokes on OpenSSL 3's default PKCS#12 algorithms ("MAC verification failed"), so we export with `-legacy` and a non-empty transport password, falling back to the plain form for the LibreSSL that ships with the CLT (which has no `-legacy` flag but already writes compatible output).
- **Fallback.** If an identity can't be created, the script signs ad-hoc with a warning (the app runs; grants just won't persist).
- Only `build-app.sh` signs. `swift build`/`swift test` produce only the linker's automatic ad-hoc signature (no keychain), so dev iterations never prompt.

## Required macOS permissions

Two, both surfaced in the menu as ⚠ items when missing:

1. **Microphone** - `AVAudioEngine` input. Auto-requested on first launch (`NSMicrophoneUsageDescription` in `Resources/Info.plist`).
2. **Accessibility** - needed for BOTH the global hotkey `CGEventTap` AND the synthetic Cmd+V paste. `CGEvent.tapCreate` returns `nil` without it. Granted out-of-band in System Settings; the app polls `AXIsProcessTrusted()` and arms the hotkey once granted.

## Self-signed cert handling

The whisper server at `:9443` presents a cert the system does **not** trust (reference client uses `curl -sk`). We accept it via `HostTrustDelegate` (a `URLSessionDelegate`) scoped to the configured host only - any other host falls through to default validation. `Resources/Info.plist` adds a narrow ATS exception for `gpuserver.beaver-brotula.ts.net` only; ATS is not disabled globally.

## Tailscale prerequisite

The whisper server is a **tailnet host** (`gpuserver.beaver-brotula.ts.net` → 100.x). The Mac must be on the tailnet or DNS won't resolve and the app shows "Server unreachable (on Tailscale?)". The live `/health` test in `swift test` skips gracefully when off the tailnet.

## Server contract (do NOT build or change the server)

Real server: `https://gpuserver.beaver-brotula.ts.net:9443` (HTTPS reverse proxy in front of uvicorn; model `large-v3-turbo`).

- `GET /health` → `{"model","state","ready"}`, `state ∈ {sleeping, ready}`. **Boots asleep by design** (0 GPU).
- `POST /start` → wakes + loads model (a few seconds) → `{"state":"ready","ready":true}`. Fired on hotkey-**down** so the model warms while the user speaks.
- `POST /transcribe` → `Content-Type: audio/wav`, body = **mono / 16-bit PCM / 16 kHz** WAV, header `X-Language: de|en|auto` → `{"text","language","ms"}`.
- Handled failure modes (visible status, never a crash): HTTP 502 (backend down), empty `text`, network/timeout/unreachable, and the warm-up race (below).

### Warm-up race (sharp edge)

The server boots **asleep** and takes a few seconds to load the model after `/start`. Transcribing before the model is up does **not** return a tidy 503 - it returns **HTTP 500** ("NoneType has no attribute transcribe"). So:

- `WhisperClient.transcribeOnce` maps **both 500 and 503** to `.notReady`, and `transcribe` retries `.notReady` a bounded number of times (`maxTranscribeAttempts`) with exponential backoff.
- Before sending audio, `DictationController.endRecording` gates on `WhisperClient.waitUntilReady` (polls `GET /health` until `isReady`, bounded ~15s), surfacing the `AppStatus.warmingUp` state ("Warming up server…") only when it actually has to wait.
- `HealthResponse.ready` is **optional**; readiness is read via `isReady` (`ready ?? (state == .ready)`) so a `{"state":"ready"}` body without the flag still decodes and counts as ready - previously this made `/start` decoding throw-and-swallow.

Do not "simplify" the transcribe path back to a single retry or drop the health gate: that reintroduces the 500 race that blocks real dictation on a cold server.

## Architecture

- `Sources/DictationCore/` - no AppKit, headless-unit-testable: `WavEncoder`, `WhisperClient`/`WhisperRequestFactory`, `WhisperModels`, `HostTrustDelegate`, `AppConfig`/`ConfigStore`, `AppStatus` (the shared state enum - pure Foundation so it lives here, not in the AppKit target), `OverlayViewModel` (maps `AppStatus` → overlay label/accent/pulse and the auto-hide timing policy).
- `Sources/VoiceDictation/` - AppKit app: `AudioCapture` (AVAudioEngine → 16 kHz mono Int16 via `AVAudioConverter`), `HotkeyMonitor` (CGEventTap; dispatches on `HotkeyTrigger`), `TextInserter` (pasteboard + Cmd+V + restore prior clipboard), `Permissions`, `LaunchAtLogin` (`SMAppService`, macOS 13+), `DictationController` (orchestration), `DictationActions` (the one shared set of settings mutations, used by both the menu and the settings window), `StatusItemController` (menu), `OverlayController` (non-activating floating HUD), `SettingsWindowController` (status/settings window), `AppDelegate`, `main.swift`.

Config (`AppConfig`) persists as one JSON blob in `UserDefaults`: server URL, hotkey, language, launch-at-login.

### Status fan-out: one state model, many surfaces

`DictationController` holds the single `AppStatus` and fans changes out to **multiple** observers via `observeStatus(_:)` (not a single `onStatusChange` closure). The menu-bar icon, the overlay HUD, and the settings window each register one - so they stay in lockstep off one state model. Do not fork the status into a second source of truth.

### On-screen overlay: the non-activating-panel focus constraint (sharp edge)

The recording HUD (`OverlayController`) is an `NSPanel` with `[.borderless, .nonactivatingPanel]`, and this is a **correctness** requirement, not a nicety. The app is an `.accessory` that pastes into the *currently frontmost* app via synthetic Cmd+V. If the overlay ever activates or takes key focus, the frontmost app changes and the paste lands in the wrong place (or fails). Rules the panel must keep:

- Subclass overrides `canBecomeKey`/`canBecomeMain` → `false`, and show via `orderFrontRegardless()` - **never** `makeKeyAndOrderFront`.
- `hidesOnDeactivate = false`, `isFloatingPanel = true`, `ignoresMouseEvents = true`, `level = .statusBar`, `collectionBehavior` includes `.canJoinAllSpaces` + `.fullScreenAuxiliary` so it rides over full-screen apps and every Space.
- When testing manually, verify the frontmost app does **not** change when the overlay appears and that Cmd+V still pastes into the field you were typing into.

The overlay is the primary feedback channel because the menu-bar icon can be **hidden by the notch** on 15" MacBook Airs. For the same reason, `AppDelegate.applicationShouldHandleReopen` opens the `SettingsWindowController` (briefly flipping activation policy to `.regular` to front the window, back to `.accessory` on close so no permanent Dock icon appears) - re-launching the running app is the dependable way in when the icon is hidden.

### Hotkey model (`HotkeyTrigger`)

The default hotkey is **fn / Globe**, and it drives the trigger abstraction:

- `.modifierFlag(mask:)` - fn/Globe. fn is NOT reliably a key code; the system reports it as the `.maskSecondaryFn` (`0x800000`, NSEvent `.function`) modifier *flag*. `HotkeyMonitor` watches the flag's rising/falling edge on `flagsChanged`, so unrelated flag changes (e.g. Shift pressed while fn is held) are ignored.
- `.modifierKey(keyCode:)` - Right/Left Option, Right Command/Control. These share a flag bit with their sibling, so they're matched by key code and toggled press/release on `flagsChanged`.
- `.regularKey(keyCode:)` - a normal key via `keyDown`/`keyUp`.

**Globe-key gotcha:** with fn as the hotkey the user must set System Settings → Keyboard → "Press Globe key to" → "Do Nothing", otherwise fn also fires emoji / input-source switching while dictating (and macOS may swallow the fn `flagsChanged` event). The app surfaces this as a hint in the Hotkey submenu (opens the Keyboard pane) and the README documents it. Right Option remains a selectable fallback that needs no such setting.
