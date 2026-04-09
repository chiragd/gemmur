import AppKit
import SwiftUI

/// A small floating panel that appears near the cursor after every transcription.
/// Shows the transcript text with Copy and dismiss controls. Auto-dismisses after 8 seconds.
@MainActor
final class TranscriptPopup {

    static let shared = TranscriptPopup()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<PopupView>?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    // MARK: - Show / Hide

    func show(transcript: String) {
        dismissTask?.cancel()

        if panel == nil { makePanel() }
        guard let panel, let hostingView else { return }

        hostingView.rootView = PopupView(
            transcript: transcript,
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
                self?.hide()
            },
            onDismiss: { [weak self] in self?.hide() }
        )

        positionNearCursor(panel)
        panel.orderFront(nil)

        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                self?.hide()
            } catch {
                // Cancelled — do nothing
            }
        }
    }

    /// Update the displayed text without repositioning or resetting the dismiss timer.
    func update(transcript: String) {
        guard let hostingView, panel?.isVisible == true else {
            show(transcript: transcript)
            return
        }
        hostingView.rootView = PopupView(
            transcript: transcript,
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
                self?.hide()
            },
            onDismiss: { [weak self] in self?.hide() }
        )
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - Construction

    private func makePanel() {
        let view = PopupView(transcript: "", onCopy: {}, onDismiss: {})
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        hostingView = hosting
        panel = p
    }

    private func positionNearCursor(_ panel: NSPanel) {
        let cursor = NSEvent.mouseLocation
        let size = panel.frame.size
        let offset: CGFloat = 24

        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        var x = cursor.x - size.width / 2
        var y = cursor.y + offset   // above cursor (unlike HUD which goes below)

        x = max(screenFrame.minX, min(x, screenFrame.maxX - size.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - size.height))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

private struct PopupView: View {
    let transcript: String
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(transcript)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            VStack(spacing: 4) {
                Button("Copy", action: onCopy)
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
