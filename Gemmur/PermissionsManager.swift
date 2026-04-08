import AVFoundation
import ApplicationServices
import AppKit

/// Tracks microphone and Accessibility permission status.
/// Call `checkAll()` on first hotkey press; each check method is safe to call repeatedly.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibilityGranted: Bool = false

    static let shared = PermissionsManager()
    private var axPollTimer: Timer?

    private init() {
        // Immediately reflect current state
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()

        // Always poll so we pick up changes made in System Settings at any time,
        // without relying on app-activation notifications (which don't fire for
        // accessory-policy apps).
        startPollingForAccessibility()
    }

    // MARK: - Combined check (called before first recording attempt)

    /// Returns true only if both permissions are satisfied.
    /// Triggers system prompts where possible; opens System Settings for Accessibility.
    func checkAll() async -> Bool {
        async let mic = ensureMicrophone()
        async let ax = ensureAccessibility()
        let (micOK, axOK) = await (mic, ax)
        return micOK && axOK
    }

    // MARK: - Microphone

    func refreshMicStatus() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Requests mic access if not yet determined. Returns whether access is granted.
    func ensureMicrophone() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        switch current {
        case .authorized:
            micStatus = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            return granted
        case .denied, .restricted:
            micStatus = current
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility

    func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Checks accessibility trust. If not granted, prompts the user via system dialog
    /// (which shows the Accessibility panel in System Settings) and returns false.
    /// The caller should surface UI directing the user to grant access.
    func ensureAccessibility() async -> Bool {
        if AXIsProcessTrusted() {
            accessibilityGranted = true
            return true
        }
        // Trigger the system "Accessibility" prompt — opens System Settings pane
        // "AXTrustedCheckOptionPrompt" is the underlying string for kAXTrustedCheckOptionPrompt.
        // We use it directly to avoid Swift 6 concurrency issues with the CF global.
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Status is still false until user grants. Poll until granted so the
        // HotkeyManager can start without requiring an app restart.
        accessibilityGranted = false
        startPollingForAccessibility()
        return false
    }

    private func startPollingForAccessibility() {
        guard axPollTimer == nil else { return }
        // Poll every second for both mic and AX — cheap calls, catches changes
        // made in System Settings without relying on activation notifications.
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Mic
                self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

                // Accessibility
                let trusted = AXIsProcessTrusted()
                let wasGranted = self.accessibilityGranted
                self.accessibilityGranted = trusted
                if !wasGranted && trusted {
                    HotkeyManager.shared.start()
                }
            }
        }
    }

    /// Opens the Accessibility section of System Settings directly.
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Opens the Microphone section of System Settings directly.
    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
