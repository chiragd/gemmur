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

    func insert(_ text: String) async {
        guard !text.isEmpty else { return }

        if tryAccessibilityInsert(text) { return }
        await clipboardFallback(text)
    }

    // MARK: - Accessibility path

    private func tryAccessibilityInsert(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var rawFocused: CFTypeRef?
        let fetchResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &rawFocused
        )
        guard fetchResult == .success, let rawFocused else { return false }

        // swiftlint:disable:next force_cast
        let focused = rawFocused as! AXUIElement

        // kAXSelectedTextAttribute: inserts at caret, or replaces the active selection.
        // This is preferable to kAXValueAttribute (which would overwrite the whole field).
        let setResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if setResult == .success { return true }

        // Some apps (e.g. certain Electron apps) don't support kAXSelectedTextAttribute
        // but do support kAXValueAttribute — only use it if the field is empty to avoid
        // overwriting existing content.
        if setResult == .failure || setResult == .attributeUnsupported {
            var currentValue: CFTypeRef?
            let getResult = AXUIElementCopyAttributeValue(
                focused, kAXValueAttribute as CFString, &currentValue
            )
            let existingText = (currentValue as? String) ?? ""
            if getResult == .success && existingText.isEmpty {
                let replaceResult = AXUIElementSetAttributeValue(
                    focused, kAXValueAttribute as CFString, text as CFTypeRef
                )
                if replaceResult == .success { return true }
            }
        }

        return false
    }

    // MARK: - Clipboard fallback

    private func clipboardFallback(_ text: String) async {
        let pb = NSPasteboard.general

        // Snapshot the current clipboard so we can restore it.
        let snapshot = ClipboardSnapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        simulateCmdV()

        // Give the target app time to process the paste before we restore.
        // 300 ms is enough for virtually all native and Electron apps.
        try? await Task.sleep(for: .milliseconds(300))

        snapshot.restore(to: pb)
    }

    private func simulateCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V

        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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
