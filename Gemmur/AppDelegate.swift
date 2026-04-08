import AppKit
import SwiftUI
import AVFoundation

/// Owns the NSStatusItem (menu bar icon) and wires up the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = PermissionsManager.shared  // force init so the poll starts immediately
        setupStatusItem()
        setupHotkey()
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let hotkey = HotkeyManager.shared
        let capture = AudioCaptureEngine.shared
        let hud = ListeningHUD.shared

        // Auto-stop handler (30s cap) — fires transcription same as manual key release
        capture.onAutoStop = { samples in
            hud.hide()
            Task { await self.handleTranscription(samples: samples) }
        }

        hotkey.onKeyDown = {
            NSLog("[Gemmur] Fn key DOWN detected")
            Task {
                let ok = await PermissionsManager.shared.checkAll()
                NSLog("[Gemmur] Permissions OK: %@", ok ? "yes" : "no")
                guard ok else { return }
                do {
                    try capture.startRecording()
                    hud.show()
                    NSLog("[Gemmur] Recording started")
                } catch {
                    NSLog("[Gemmur] Audio capture failed: %@", error.localizedDescription)
                }
            }
        }

        hotkey.onKeyUp = {
            NSLog("[Gemmur] Fn key UP detected")
            var samples = capture.stopRecording()
            hud.hide()
            Task {
                await self.handleTranscription(samples: samples)
                samples = []  // release backing buffer as soon as transcription is done
            }
        }

        // Apply saved hotkey selection before starting
        hotkey.updateHotkey(AppSettings.shared.hotkey)

        if AXIsProcessTrusted() {
            hotkey.start()
        }
    }

    // MARK: - Transcription

    private func handleTranscription(samples: consuming [Float]) async {
        guard !samples.isEmpty else { return }
        let settings = AppSettings.shared
        let backend = OllamaBackend(model: settings.model.rawValue)
        NSLog("[Gemmur] Captured %d samples (%.1fs) — transcribing…",
              samples.count, Double(samples.count) / 16_000)

        do {
            let transcript = try await backend.transcribe(
                audio: consume samples,   // transfer ownership; buffer freed before Ollama call returns
                systemPrompt: settings.tone.systemPrompt
            )
            print("[Gemmur] Transcript: \(transcript)")
            await TextInserter.shared.insert(transcript)
        } catch {
            print("[Gemmur] Transcription error: \(error.localizedDescription)")
            showErrorBanner(error.localizedDescription)
        }
    }

    private func showErrorBanner(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Gemmur"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Gemmur")
        img?.isTemplate = true
        button.image = img

        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status line — updates dynamically when the menu opens
        let statusItem = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Gemmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        return menu
    }

    private func statusLine() -> String {
        let tapOK  = HotkeyManager.shared.isRunning
        let axOK   = AXIsProcessTrusted()
        let micOK  = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if tapOK && axOK && micOK {
            return "Ready — hold \(AppSettings.shared.hotkey.displayName) to dictate"
        }
        var issues: [String] = []
        if !axOK  { issues.append("Accessibility") }
        if !micOK { issues.append("Microphone") }
        if !tapOK && axOK { issues.append("tap not running") }
        return "Not ready: \(issues.joined(separator: ", "))"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.title = statusLine()
    }

    // MARK: - Actions

    @objc private func openSettings() {
        // Re-use existing window if it's already open
        if let w = settingsWindow, w.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        // Check if SwiftUI's WindowGroup already instantiated it
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            settingsWindow = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        // Fallback: create a standalone hosted window
        openSettingsStandalone()
    }

    private func openSettingsStandalone() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = "Gemmur Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
