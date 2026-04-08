import SwiftUI
import ServiceManagement

// MARK: - Model picker

enum OllamaModel: String, CaseIterable, Identifiable {
    case e2b = "gemma4:e2b"
    case e4b = "gemma4:e4b"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .e2b: "Gemma 4 E2B (default)"
        case .e4b: "Gemma 4 E4B (higher quality, slower)"
        }
    }
}

// MARK: - Hotkey picker

enum HotkeyOption: String, CaseIterable, Identifiable {
    case fn           = "fn"
    case rightOption  = "rightOption"
    case rightControl = "rightControl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn:           "Fn / Globe"
        case .rightOption:  "Right Option ⌥"
        case .rightControl: "Right Control ⌃"
        }
    }

    /// The CGKeyCode for this key (used in the flagsChanged event).
    var keyCode: CGKeyCode {
        switch self {
        case .fn:           63  // kVK_Function
        case .rightOption:  61  // kVK_RightOption
        case .rightControl: 62  // kVK_RightControl
        }
    }

    /// The CGEventFlags bit that is set while this key is held.
    var activeFlag: CGEventFlags {
        switch self {
        case .fn:           .maskSecondaryFn
        case .rightOption:  .maskAlternate
        case .rightControl: .maskControl
        }
    }
}

// MARK: - Settings store

/// Single source of truth for all user-configurable settings.
/// Persisted via UserDefaults so values survive relaunches.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: Persisted values

    @Published var model: OllamaModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "model") }
    }
    @Published var tone: DictationTone {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: "tone") }
    }
    @Published var hotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(hotkey.rawValue, forKey: "hotkey")
            HotkeyManager.shared.updateHotkey(hotkey)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private init() {
        let ud = UserDefaults.standard
        model       = OllamaModel(rawValue: ud.string(forKey: "model") ?? "") ?? .e2b
        tone        = DictationTone(rawValue: ud.string(forKey: "tone") ?? "") ?? .punctuated
        hotkey      = HotkeyOption(rawValue: ud.string(forKey: "hotkey") ?? "") ?? .fn
        launchAtLogin = ud.bool(forKey: "launchAtLogin")
    }

    // MARK: - Launch at login

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[AppSettings] Launch-at-login error: \(error.localizedDescription)")
        }
    }

    var launchAtLoginActualState: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
