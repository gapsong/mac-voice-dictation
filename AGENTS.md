# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## What this is

A native macOS menu-bar push-to-talk dictation app (Swift/AppKit). Hold a global hotkey → record mic → send a WAV to the local whisper-service → paste the transcription at the focused app's cursor.

## Build / run / test

- **Build the app bundle:** `Scripts/build-app.sh` → `build/VoiceDictation.app` (runs `swift build -c release`, assembles the bundle, signs with a stable self-signed identity - see below).
- **Run:** `open build/VoiceDictation.app`, or run `build/VoiceDictation.app/Contents/MacOS/VoiceDictation` directly for foreground logs.
- **Test:** `Scripts/test.sh` (wraps `swift test`; see the toolchain gotcha below).
- We deliberately use an **SPM executable + bundling script**, not an Xcode project, so it is headless-buildable with only the Swift toolchain.

### Toolchain gotcha: Command Line Tools only

This machine has the **Command Line Tools**, not full Xcode. Consequences that will bite the next agent:

- `xcodebuild` is unavailable - hence the SPM + `Scripts/build-app.sh` approach.
- **`XCTest` is not in the CLT SDK.** `import XCTest` fails with "no such module". The tests therefore use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`), whose `Testing.framework` *is* bundled with CLT. Do not port tests back to XCTest here.
- **Newer toolchains do not find that `Testing.framework` by themselves** (seen with Swift 6.3.3): a bare `swift test` fails with "no such module 'Testing'". `Scripts/test.sh` passes the CLT framework path to compiler, linker and runtime; always run tests through it.
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

## Default server: local whisper-service

The default server is `http://127.0.0.1:9876`, the local [whisper-service](https://github.com/gapsong/whisper-service) (MLX on the Mac's GPU, LaunchAgent `com.gapsong.whisper-service`). Plain HTTP to it is allowed by `NSAllowsLocalNetworking` in `Resources/Info.plist`, which covers local addresses only. If it is not running, the app shows "Server unreachable (whisper-service running?)"; the live `/health` test in `swift test` skips gracefully.

## TLS

Plain HTTP is allowed for local addresses only (`NSAllowsLocalNetworking`). A remote server must use HTTPS with a certificate the system trusts: the app does no custom certificate handling, and ATS is not disabled. Do not add a trust-everything `URLSessionDelegate` - with a user-configurable server URL it would turn off certificate validation for whatever host the user types in.

## Server contract (implemented by whisper-service - change it there, not here)

Default server: `http://127.0.0.1:9876` (whisper-service; uvicorn; model `large-v3-turbo`). Any server with the same three endpoints works.

- `GET /health` → `{"model","state","ready"}`, `state ∈ {sleeping, ready}`. **Boots asleep by design** (0 GPU).
- `POST /start` → starts loading the model and returns the current health body (whisper-service answers at once; other servers may block until `{"state":"ready","ready":true}`). Either way the app then polls `/health`. Fired on hotkey-**down** so the model warms while the user speaks.
- `POST /transcribe` → `Content-Type: audio/wav`, body = **mono / 16-bit PCM / 16 kHz** WAV, header `X-Language: de|en|auto` → `{"text","language","ms"}`.
- Handled failure modes (visible status, never a crash): HTTP 502 (backend down), empty `text`, network/timeout/unreachable, and the warm-up race (below).

### Warm-up race (sharp edge)

The server boots **asleep** and takes a few seconds to load the model after `/start`. Transcribing before the model is up does **not** return a tidy 503 - it returns **HTTP 500** ("NoneType has no attribute transcribe"). So:

- `WhisperClient.transcribeOnce` maps **both 500 and 503** to `.notReady`, and `transcribe` retries `.notReady` a bounded number of times (`maxTranscribeAttempts`) with exponential backoff.
- Before sending audio, `DictationController.endRecording` gates on `WhisperClient.waitUntilReady` (polls `GET /health` until `isReady`, bounded ~15s), surfacing the `AppStatus.warmingUp` state ("Warming up server…") only when it actually has to wait.
- `HealthResponse.ready` is **optional**; readiness is read via `isReady` (`ready ?? (state == .ready)`) so a `{"state":"ready"}` body without the flag still decodes and counts as ready - previously this made `/start` decoding throw-and-swallow.

Do not "simplify" the transcribe path back to a single retry or drop the health gate: that reintroduces the 500 race that blocks real dictation on a cold server.

### Silence does not come back empty (sharp edge)

Whisper was trained on subtitled video, so near-silence yields the boilerplate that ends a subtitle track - reliably **"Untertitelung des ZDF, 2020"** in German, "Subtitles by the Amara.org community" / "Thanks for watching!" in English. The server returns these as an ordinary 200 with a non-empty `text`, so the old `trimmed.isEmpty` check never fired and the app pasted them into the user's document.

`SilenceArtifactFilter.isArtifact` now gates the same spot in `WhisperClient.transcribeOnce` and throws `WhisperError.emptyText`, which already surfaces as "No speech detected". Two constraints on any change there:

- **Patterns are anchored to the whole normalized utterance.** "Das lief gestern im ZDF" is real speech that merely names a broadcaster and must survive. Never switch to a substring match.
- **Do not add "Vielen Dank." / "Thank you."** Whisper emits those on silence too, but a user may dictate exactly those words. Dropping real speech is the worse failure, and the filter's whole justification is that its false positives stay visible ("No speech detected") rather than silent.

## Architecture

- `Sources/DictationCore/` - no AppKit, headless-unit-testable: `WavEncoder`, `WhisperClient`/`WhisperRequestFactory`, `WhisperModels`, `AppConfig`/`ConfigStore`, `AppStatus` (the shared state enum - pure Foundation so it lives here, not in the AppKit target), `OverlayViewModel` (maps `AppStatus` → overlay label/accent/pulse and the auto-hide timing policy).
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

`AppConfig.hotkeys` is a **set**, not one key: several hold-to-talk hotkeys are armed at once. Defaults are `[.fnGlobe, .f13]`. The trigger abstraction:

- `.modifierFlag(mask:)` - fn/Globe. fn is NOT reliably a key code; the system reports it as the `.maskSecondaryFn` (`0x800000`, NSEvent `.function`) modifier *flag*, so its state is read straight off the flag on `flagsChanged`. Unrelated flag changes (Shift pressed while fn is held) therefore resolve to "still down" rather than a release.
- `.modifierKey(keyCode:)` - Right/Left Option, Right Command/Control. These share a flag bit with their sibling, so they're matched by key code and alternate press/release on `flagsChanged`.
- `.regularKey(keyCode:)` - a normal key via `keyDown`/`keyUp`. This is the F13-F19 path.

**A hold is owned by the trigger that started it.** While one key is held the others are ignored, so a second hotkey pressed mid-recording can neither nest a hold nor end it early, and a regular key's auto-repeat is absorbed. Re-arming mid-hold cancels the hold (`onPressEnd(committed: false)`), because the held key may no longer be watched and its release would never arrive.

### External keyboards do not send fn (sharp edge)

**fn from a third-party keyboard never reaches macOS.** Apple's fn/Globe rides a private Apple HID usage page; third-party keyboards resolve their own fn in firmware as a layer switch and send nothing. No app-side change can see it - do not accept a bug report claiming otherwise without a capture.

Measured on this machine with a session-level `CGEventTap` (a throwaway probe logging type / keycode / flags / source device):

- NuPhy Air75 V2 (`0x19F5:0x3246`, registry `0x100007C5B`): 661 events, every letter / Shift / Command / Space, **zero** fn.
- Apple Internal Keyboard (registry `0x10000099A`): fn only.

Useful probe trick: `CGEventField(rawValue: 87)` on a key event returns the **IOHIDServiceClient registry ID**, which matches the `RegistryID` column of `hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":6}'`. That is how to attribute an event to a physical keyboard.

**Hence F13.** `HotkeyConfig.functionKeys` (F13-F19, key codes 105/107/113/106/64/79/80) are in the standard HID keyboard page, absent from Apple keyboards, and unbound in macOS. F13 ships armed by default because no physical keyboard sends it unless remapped, so leaving it on costs nothing and an external keyboard needs only a remap in its own configurator. Prefer them over live modifiers such as Right Option: on the German layout Right Option is how `@`, `€` and `|` are typed, so holding it as a hotkey fights with typing.

**Globe-key gotcha:** with fn armed the user must set System Settings → Keyboard → "Press Globe key to" → "Do Nothing", otherwise fn also fires emoji / input-source switching while dictating (and macOS may swallow the fn `flagsChanged` event). The app surfaces this as a hint in the Hotkeys submenu (opens the Keyboard pane) and the README documents it.

### Where the hotkey logic lives

`HotkeyMonitor` (AppKit target) is only the CGEventTap adapter plus the debounce. The decision - which event begins or ends a hold, across the armed set - is `DictationCore.HotkeyEdgeResolver`, pure Foundation and unit-tested. Keep it that way: the AppKit target cannot be tested under Command Line Tools, so anything worth testing has to live in the core.

**Config migration:** `AppConfig` decodes the pre-multi-hotkey `hotkey` key when `hotkeys` is absent and migrates it to `[legacy, .f13]`. Encoding writes only `hotkeys`. Do not drop that fallback - it is what stops an existing install from silently losing its hotkey.

**Diagnosing a dead key:** `VOICEDICTATION_LOG_HOTKEYS=1` on a foreground launch makes `HotkeyDiagnostics` trace every key event with its shape, flags, source device and the resolver's decision. No line at all for a key press means macOS never received it. `device=` is the HID registry id and matches `hidutil list`, so events can be attributed to a physical keyboard. This is the first thing to run for "my hotkey does nothing" - the three failure modes are indistinguishable from the UI.
