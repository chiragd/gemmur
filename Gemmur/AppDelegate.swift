import AppKit
import SwiftUI
import AVFoundation

/// Owns the NSStatusItem (menu bar icon) and wires up the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var whisperBackend: WhisperBackend?
    private var mlxBackend: MLXRewriteBackend?
    private var transcriptionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = PermissionsManager.shared  // force init so the poll starts immediately
        // Request permissions at launch so the app appears in Privacy & Security lists
        // immediately, even before the user presses the hotkey for the first time.
        Task { await PermissionsManager.shared.checkAll() }
        setupStatusItem()
        setupHotkey()
        startWhisperWarmUp()
        AppSettings.shared.onWhisperModelChange = { [weak self] in self?.startWhisperWarmUp() }
        startMLXWarmUp()
        AppSettings.shared.onAIModelChange = { [weak self] in self?.startMLXWarmUp() }
        AppSettings.shared.onBackendChange = { [weak self] in self?.startMLXWarmUp() }
    }

    // MARK: - Backend management

    private func startWhisperWarmUp() {
        if whisperBackend == nil { whisperBackend = WhisperBackend() }
        guard let wb = whisperBackend else { return }
        wb.mlxBackend = mlxBackend
        let modelName = AppSettings.shared.whisperModel.rawValue
        Task {
            do {
                try await wb.warmUp(model: modelName)
            } catch {
                NSLog("[Gemmur] WhisperKit warm-up failed: %@", error.localizedDescription)
            }
        }
    }

    private func startMLXWarmUp() {
        guard AppSettings.shared.inferenceBackend.usesMLX else { return }
        if mlxBackend == nil { mlxBackend = MLXRewriteBackend() }
        guard let mlx = mlxBackend else { return }
        whisperBackend?.mlxBackend = mlx
        let modelId = AppSettings.shared.aiModel.rawValue
        Task {
            do {
                try await mlx.warmUp(modelId: modelId)
            } catch {
                NSLog("[Gemmur] MLX warm-up failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let hotkey = HotkeyManager.shared
        let capture = AudioCaptureEngine.shared
        let hud = ListeningHUD.shared

        // Auto-stop handler (30s cap) — fires transcription same as manual key release
        capture.onAutoStop = { samples in
            hud.hide()
            hotkey.onEscPress = { [weak self] in self?.cancelTranscription() }
            self.transcriptionTask = Task {
                await self.handleTranscription(samples: samples)
                self.transcriptionTask = nil
                HotkeyManager.shared.onEscPress = nil
            }
        }

        hotkey.onKeyDown = {
            NSLog("[Gemmur] Fn key DOWN detected")
            Task {
                let ok = await PermissionsManager.shared.checkAll()
                NSLog("[Gemmur] Permissions OK: %@", ok ? "yes" : "no")
                guard ok else { return }
                do {
                    try capture.startRecording()
                    hud.show(mode: .listening)
                    NSLog("[Gemmur] Recording started")
                } catch {
                    NSLog("[Gemmur] Audio capture failed: %@", error.localizedDescription)
                }
            }
        }

        hotkey.onKeyUp = {
            NSLog("[Gemmur] Fn key UP detected")
            var samples = capture.stopRecording()
            hud.show(mode: .processing)   // switch to processing state immediately
            hotkey.onEscPress = { [weak self] in self?.cancelTranscription() }
            self.transcriptionTask = Task {
                await self.handleTranscription(samples: samples)
                samples = []
                self.transcriptionTask = nil
                HotkeyManager.shared.onEscPress = nil
            }
        }

        // Apply saved hotkey selection before starting
        hotkey.updateHotkey(AppSettings.shared.hotkey)

        if AXIsProcessTrusted() {
            hotkey.start()
        }
    }

    // MARK: - Transcription

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        HotkeyManager.shared.onEscPress = nil
        whisperBackend?.onPartialTranscript = nil
        ListeningHUD.shared.hide()
        TranscriptPopup.shared.hide()
    }

    private func handleTranscription(samples: consuming [Float]) async {
        guard !samples.isEmpty else { return }
        let settings = AppSettings.shared
        NSLog("[Gemmur] Captured %d samples (%.1fs) — transcribing…",
              samples.count, Double(samples.count) / 16_000)

        // All modes use WhisperKit for transcription.
        guard let wb = whisperBackend, wb.isReady else {
            NSLog("[Gemmur] WhisperKit not ready yet — please wait for the model to load")
            showErrorBanner("Voice model not ready yet — please wait a moment and try again.")
            ListeningHUD.shared.hide()
            return
        }
        NSLog("[Gemmur] Using WhisperKit backend")
        wb.onPartialTranscript = { partial in
            Task { @MainActor in
                ListeningHUD.shared.hide()
                TranscriptPopup.shared.update(transcript: partial)
            }
        }
        let backend: any TranscriptionBackend = wb

        do {
            let transcript = try await backend.transcribe(
                audio: consume samples,   // transfer ownership; buffer freed before inference returns
                tone: settings.tone
            )
            whisperBackend?.onPartialTranscript = nil
            NSLog("[Gemmur] Transcript: %@", transcript)
            ListeningHUD.shared.hide()
            await TextInserter.shared.insert(transcript)
            TranscriptPopup.shared.show(transcript: transcript)
        } catch {
            whisperBackend?.onPartialTranscript = nil
            ListeningHUD.shared.hide()
            NSLog("[Gemmur] Transcription error: %@", error.localizedDescription)
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
