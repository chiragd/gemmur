import AppKit
import ApplicationServices

/// Inserts text into whatever UI element currently has keyboard focus.
///
/// Primary path: Accessibility API — sets kAXSelectedTextAttribute on the focused
/// element, which inserts at the caret or replaces the current selection.
///
/// Fallback: writes to the clipboard, simulates Cmd-V, then restores the prior
/// clipboard contents after a short delay.
@MainActor
final class TextInserter {

    static let shared = TextInserter()
    private init() {}

    // MARK: - Public

    @discardableResult
    func insert(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }

        // Only trust AX insertion for roles that are known to honour it correctly.
        // Chrome, Terminal, and web-based elements report success but silently discard
        // the value — so we verify the role before trusting the result.
        if tryAccessibilityInsert(text) {
            NSLog("[TextInserter] Inserted via AX")
            return true
        }
        NSLog("[TextInserter] Falling back to clipboard paste")
        await clipboardFallback(text)
        return true
    }

    // MARK: - Accessibility path

    /// Native macOS roles that reliably honour kAXSelectedTextAttribute.
    private static let trustedAXRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    private func tryAccessibilityInsert(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var rawFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &rawFocused
        ) == .success, let rawFocused else { return false }

        let focused = rawFocused as! AXUIElement

        // Check role
        var rawRole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &rawRole)
        let role = (rawRole as? String) ?? ""
        guard Self.trustedAXRoles.contains(role) else {
            NSLog("[TextInserter] AX role '%@' not trusted, skipping", role)
            return false
        }

        // Confirm the attribute is actually settable on this element.
        // Terminal and some custom text views report a trusted role but mark
        // kAXSelectedTextAttribute as read-only.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else {
            NSLog("[TextInserter] kAXSelectedTextAttribute not settable on '%@', skipping", role)
            return false
        }

        // Snapshot the selection before writing so we can verify it changed.
        var beforeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &beforeRef)
        let before = (beforeRef as? String) ?? ""

        let setResult = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard setResult == .success else {
            NSLog("[TextInserter] AX set failed on '%@': %d", role, setResult.rawValue)
            return false
        }

        // Read back: after a real insertion the selection collapses to "" (cursor
        // placed after the inserted text). If it still equals `before`, the write
        // was silently ignored.
        var afterRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &afterRef)
        let after = (afterRef as? String) ?? ""

        let verified = after != before
        NSLog("[TextInserter] AX insert on '%@' — verified: %@", role, verified ? "yes" : "no (falling back)")
        return verified
    }

    // MARK: - Clipboard fallback

    private func clipboardFallback(_ text: String) async {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Route Cmd-V through System Events (osascript). This is the only approach
        // that reliably reaches Chrome, Terminal, and Electron apps — CGEvent
        // synthetic keystrokes are filtered by those apps regardless of source.
        await pasteViaSystemEvents()

        // Wait for the target app to process the paste before restoring.
        try? await Task.sleep(for: .milliseconds(300))

        snapshot.restore(to: pb)
    }

    /// Simulates Cmd-V via NSAppleScript (in-process, inherits our Accessibility permission).
    /// Runs on a background thread so it doesn't block the main actor.
    private func pasteViaSystemEvents() async {
        await Task.detached(priority: .userInitiated) {
            let source = """
tell application "System Events"
    keystroke "v" using {command down}
end tell
"""
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                NSLog("[TextInserter] Failed to create NSAppleScript")
                return
            }
            script.executeAndReturnError(&errorDict)
            if let err = errorDict {
                NSLog("[TextInserter] AppleScript error: %@", err)
            } else {
                NSLog("[TextInserter] AppleScript paste sent")
            }
        }.value
    }
}

// MARK: - Clipboard snapshot

/// Captures the full pasteboard state so it can be restored after the paste fallback.
private struct ClipboardSnapshot {
    // Each entry is (type → data). We eagerly read all data to avoid lazy-provider issues.
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pb: NSPasteboard) {
        items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }

        let newItems = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}
