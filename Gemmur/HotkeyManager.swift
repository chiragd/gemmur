import CoreGraphics
import AppKit

/// Intercepts a configurable modifier key system-wide via a CGEventTap.
///
/// Fn/Globe key handling: on most Apple Silicon Macs the key generates `flagsChanged`
/// events (keyCode 63, .maskSecondaryFn). On some keyboards / macOS versions it generates
/// `keyDown`/`keyUp` events instead. We listen for all three and handle both.
///
/// Requires Accessibility permission. Call `start()` after it is granted.
final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()

    // MARK: - Published tap state (observed by AppDelegate for menu badge)

    /// True after the CGEventTap is successfully installed.
    private(set) var isRunning = false

    // MARK: - Callbacks (called on main actor)

    var onKeyDown: (@MainActor () -> Void)?
    var onKeyUp: (@MainActor () -> Void)?

    // MARK: - Private state

    private var currentHotkey: HotkeyOption = .fn
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Tracks push-to-talk state for the keyDown/keyUp path (Fn on some Macs)
    private var fnIsDown = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard AXIsProcessTrusted() else {
            NSLog("[HotkeyManager] Accessibility not granted — tap not installed.")
            return
        }
        guard eventTap == nil else { return }
        installTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        NSLog("[HotkeyManager] Tap removed.")
    }

    /// Called by AppSettings when the user changes the hotkey preference.
    func updateHotkey(_ option: HotkeyOption) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        currentHotkey = option
        if wasRunning { installTap() }
    }

    // MARK: - Tap installation

    private func installTap() {
        // Listen for flagsChanged (modifier keys) AND keyDown/keyUp (Fn on some hardware)
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: HotkeyManager.tapCallback,
            userInfo: userInfo
        )

        guard let tap else {
            NSLog("[HotkeyManager] CGEventTap creation failed. Accessibility permission granted?")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = src
        isRunning = true
        NSLog("[HotkeyManager] Tap installed for '%@'.", currentHotkey.displayName)
    }

    // MARK: - CGEventTap callback (C convention, runs on main run loop)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        let hotkey = manager.currentHotkey

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // ── Path A: flagsChanged (most Macs, modifier keys including Fn) ──────────
        if type == .flagsChanged {
            guard keyCode == hotkey.keyCode else { return Unmanaged.passRetained(event) }
            let isDown = event.flags.contains(hotkey.activeFlag)
            DispatchQueue.main.async {
                if isDown { manager.onKeyDown?() } else { manager.onKeyUp?() }
            }
            return nil // consume
        }

        // ── Path B: keyDown/keyUp (Fn on some Apple Silicon / macOS 14+ hardware) ─
        // Only applies to Fn; Right Option/Control are always flagsChanged.
        if hotkey == .fn && keyCode == hotkey.keyCode {
            if type == .keyDown && !manager.fnIsDown {
                manager.fnIsDown = true
                DispatchQueue.main.async { manager.onKeyDown?() }
                return nil // consume
            }
            if type == .keyUp && manager.fnIsDown {
                manager.fnIsDown = false
                DispatchQueue.main.async { manager.onKeyUp?() }
                return nil // consume
            }
        }

        return Unmanaged.passRetained(event)
    }
}
