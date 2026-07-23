import AppKit

// Menu-bar-only app: no Dock icon, no main window. `LSUIElement` in Info.plist
// makes this durable across launch styles; `.accessory` enforces it at runtime
// even when run as a bare binary.
//
// `main.swift` top-level code is nonisolated, but it genuinely executes on the
// main thread, so we assert main-actor isolation to construct the (main-actor)
// app delegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
