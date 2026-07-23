import AppKit
import CoreGraphics

/// Inserts text at the cursor of whatever app is focused by putting it on the
/// pasteboard and synthesizing Cmd+V, then restoring the previous pasteboard
/// contents.
///
/// Pasting (rather than typing each character) is the most reliable path across
/// apps and for Unicode / German text. The synthetic keystrokes require
/// Accessibility permission.
enum TextInserter {

    /// Puts `text` on the pasteboard, sends Cmd+V to the focused app, then
    /// restores whatever was on the pasteboard before.
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot the current pasteboard so we can restore it. We capture every
        // item/type pair to preserve rich content, not just plain strings.
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendPasteKeystroke()

        // Restore after a short delay so the paste has been read by the target
        // app before we put the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            restore(saved, to: pasteboard)
        }
    }

    // MARK: - Pasteboard snapshot / restore

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Synthetic Cmd+V

    private static func sendPasteKeystroke() {
        let vKeyCode: CGKeyCode = 0x09 // 'v'
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
