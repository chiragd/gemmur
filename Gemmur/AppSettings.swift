import SwiftUI
import ServiceManagement

// MARK: - Inference backend picker

enum InferenceBackend: String, CaseIterable, Identifiable {
    case voiceOnly  = "voiceOnly"   // WhisperKit only, no Ollama
    case aiOnly     = "aiOnly"      // Ollama only, no WhisperKit
    case voiceAndAI = "voiceAndAI"  // WhisperKit → Ollama rewrite for complex tones

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .voiceOnly:  "Local voice model only"
        case .aiOnly:     "Local AI model only"
        case .voiceAndAI: "Local voice + AI model"
        }
    }

    var usesWhisper: Bool { self != .aiOnly }
    var usesOllama: Bool  { self != .voiceOnly }
}

// MARK: - WhisperKit model state

enum WhisperModelState: Equatable {
    case notLoaded, loading, ready, failed(String)

    static func == (lhs: WhisperModelState, rhs: WhisperModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loading, .loading), (.ready, .ready): true
        case (.failed(let a), .failed(let b)): a == b
        default: false
        }
    }
}

// MARK: - Whisper model picker

enum WhisperModel: String, CaseIterable, Identifiable {
    case tinyEn  = "tiny.en"
    case baseEn  = "base.en"
    case smallEn = "small.en"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tinyEn:  "tiny.en  (~40 MB, fastest)"
        case .baseEn:  "base.en  (~140 MB, default)"
        case .smallEn: "small.en (~460 MB, best quality)"
        }
    }
}

// MARK: - Model picker

enum OllamaModel: String, CaseIterable, Identifiable {
    case gemma3_270m = "gemma3:270m"
    case gemma3_1b   = "gemma3:1b"
    case e2b         = "gemma4:e2b"
    case e4b         = "gemma4:e4b"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .gemma3_270m: "Gemma 3 270M (fastest)"
        case .gemma3_1b:   "Gemma 3 1B (fast rewrite)"
        case .e2b:         "Gemma 4 E2B"
        case .e4b:         "Gemma 4 E4B (higher quality, slower)"
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
    @Published var inferenceBackend: InferenceBackend {
        didSet { UserDefaults.standard.set(inferenceBackend.rawValue, forKey: "inferenceBackend") }
    }
    @Published var whisperModel: WhisperModel {
        didSet {
            UserDefaults.standard.set(whisperModel.rawValue, forKey: "whisperModel")
            onWhisperModelChange?()
        }
    }
    /// Called by AppDelegate to restart WhisperKit warm-up when the model changes.
    var onWhisperModelChange: (() -> Void)?
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Reflects whether the bundled WhisperKit model is loaded. Updated by AppDelegate.
    @Published var whisperModelState: WhisperModelState = .notLoaded

    private init() {
        let ud = UserDefaults.standard
        model            = OllamaModel(rawValue: ud.string(forKey: "model") ?? "") ?? .e2b
        tone             = DictationTone(rawValue: ud.string(forKey: "tone") ?? "") ?? .punctuated
        hotkey           = HotkeyOption(rawValue: ud.string(forKey: "hotkey") ?? "") ?? .fn
        inferenceBackend = InferenceBackend(rawValue: ud.string(forKey: "inferenceBackend") ?? "") ?? .voiceAndAI
        whisperModel     = WhisperModel(rawValue: ud.string(forKey: "whisperModel") ?? "") ?? .baseEn
        launchAtLogin    = ud.bool(forKey: "launchAtLogin")
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
