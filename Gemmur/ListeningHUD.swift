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
            contentRect: NSRect(x: 0, y: 0, width: 525, height: 44),
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
        HStack(spacing: 12) {
            if mode == .listening {
                ScrollingWaveform(history: capture.audioHistory)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            } else {
                PulsingDot(color: .blue)
            }
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 420)
        .background(.regularMaterial, in: Capsule())
    }

    private var label: String {
        switch mode {
        case .listening:
            if capture.elapsedSeconds < 1 { return "Listening…" }
            let elapsed = Int(capture.elapsedSeconds)
            let m = elapsed / 60
            let s = elapsed % 60
            let time = m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
            return "Listening… \(time)"
        case .processing:
            return "Processing…"
        }
    }
}

// MARK: - Scrolling waveform

/// Renders the rolling audio level history as a bank of thin symmetric bars.
/// Newer bars appear on the right; older bars fade toward the left.
private struct ScrollingWaveform: View {
    let history: [Float]

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5
            let gap: CGFloat = 1.5
            let step = barWidth + gap
            let totalBars = max(1, Int(size.width / step))
            let centerY = size.height / 2
            let maxHalf = size.height / 2 - 1   // 1pt breathing room

            for i in 0..<totalBars {
                // Map bar slot to history index (newest = rightmost)
                let histIdx = history.count - totalBars + i
                let level: CGFloat = histIdx >= 0 ? CGFloat(history[histIdx]) : 0

                // Minimum idle height so the bar is always faintly visible
                let half = max(1.5, maxHalf * level)

                let x = CGFloat(i) * step
                let rect = CGRect(x: x, y: centerY - half, width: barWidth, height: half * 2)
                let path = Path(roundedRect: rect, cornerRadius: 1)

                // Fade older (left) bars; newest bars are fully opaque
                let progress = CGFloat(i + 1) / CGFloat(totalBars)
                let opacity = 0.2 + 0.8 * progress
                context.fill(path, with: .color(Color.primary.opacity(opacity)))
            }
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
