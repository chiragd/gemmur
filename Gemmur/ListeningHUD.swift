import AppKit
import SwiftUI

/// A small, non-activating floating panel that appears near the cursor while recording.
/// It does not steal focus from whatever app the user is typing in.
@MainActor
final class ListeningHUD {

    static let shared = ListeningHUD()

    private var panel: NSPanel?

    private init() {}

    // MARK: - Show / Hide

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }

        positionNearCursor(panel)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Construction

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
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
        p.contentView = NSHostingView(rootView: HUDView())
        return p
    }

    private func positionNearCursor(_ panel: NSPanel) {
        let cursor = NSEvent.mouseLocation         // flipped screen coords
        let size = panel.frame.size
        let offset: CGFloat = 24                   // px below cursor

        // Keep panel within the screen that contains the cursor
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        var x = cursor.x - size.width / 2
        var y = cursor.y - size.height - offset

        // Clamp to visible screen
        x = max(screenFrame.minX, min(x, screenFrame.maxX - size.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - size.height))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

private struct HUDView: View {
    @ObservedObject private var capture = AudioCaptureEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            PulsingCircle()
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var label: String {
        if capture.elapsedSeconds < 1 { return "Listening…" }
        let remaining = max(0, 30 - Int(capture.elapsedSeconds))
        return "Listening… \(remaining)s"
    }
}

private struct PulsingCircle: View {
    @State private var scale = 1.0

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: scale)
            .onAppear { scale = 1.4 }
    }
}
