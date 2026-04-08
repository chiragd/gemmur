import AppKit
import SwiftUI

enum HUDMode {
    case listening
    case processing
}

/// A small, non-activating floating panel near the cursor.
/// Shows "Listening…" while recording and "Processing…" while waiting for transcription.
@MainActor
final class ListeningHUD {

    static let shared = ListeningHUD()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?
    private(set) var mode: HUDMode = .listening

    private init() {}

    // MARK: - Show / Hide

    func show(mode: HUDMode = .listening) {
        self.mode = mode
        if panel == nil { makePanel() }
        guard let panel, let hostingView else { return }
        hostingView.rootView = HUDView(mode: mode)
        positionNearCursor(panel)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Construction

    private func makePanel() {
        let view = HUDView(mode: .listening)
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 44),
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
        var y = cursor.y - size.height - offset

        x = max(screenFrame.minX, min(x, screenFrame.maxX - size.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - size.height))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

struct HUDView: View {
    let mode: HUDMode
    @ObservedObject private var capture = AudioCaptureEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(color: dotColor)
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var dotColor: Color {
        switch mode {
        case .listening:  .red
        case .processing: .blue
        }
    }

    private var label: String {
        switch mode {
        case .listening:
            if capture.elapsedSeconds < 1 { return "Listening…" }
            let remaining = max(0, 30 - Int(capture.elapsedSeconds))
            return "Listening… \(remaining)s"
        case .processing:
            return "Processing…"
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var scale = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: scale)
            .onAppear { scale = 1.4 }
    }
}
