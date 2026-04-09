import SwiftUI
import ServiceManagement

// MARK: - Inference backend picker

enum InferenceBackend: String, CaseIterable, Identifiable {
    case voiceOnly  = "voiceOnly"   // WhisperKit only, no AI rewrite
    case voiceAndAI = "voiceAndAI"  // WhisperKit → MLX rewrite for complex tones
    case aiOnly     = "aiOnly"      // WhisperKit + MLX rewrite for every tone

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .voiceOnly:  "Local voice model only"
        case .voiceAndAI: "Local voice + AI model"
        case .aiOnly:     "Local AI model only"
        }
    }

    /// All modes use WhisperKit for audio transcription.
    var usesWhisper: Bool { true }
    /// Modes that run MLX for text rewriting.
    var usesMLX: Bool { self == .voiceAndAI || self == .aiOnly }
    /// In aiOnly mode the AI rewrite runs for every tone, not just complex ones.
    var mlxRunsForAllTones: Bool { self == .aiOnly }
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

// MARK: - AI rewrite model picker

enum AIModel: String, CaseIterable, Identifiable {
    case gemma3_270m = "mlx-community/gemma-3-270m-it-4bit"
    case gemma3_1b   = "mlx-community/gemma-3-1b-it-4bit"
    case gemma3_4b   = "mlx-community/gemma-3-4b-it-4bit"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .gemma3_270m: "Gemma 3 270M 4-bit (~170 MB, fastest)"
        case .gemma3_1b:   "Gemma 3 1B 4-bit (~600 MB, default)"
        case .gemma3_4b:   "Gemma 3 4B 4-bit (~2.5 GB, higher quality)"
        }
    }
}

// MARK: - AI model load state

enum AIModelState: Equatable {
    case notLoaded, loading, ready, failed(String)

    static func == (lhs: AIModelState, rhs: AIModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loading, .loading), (.ready, .ready): true
        case (.failed(let a), .failed(let b)): a == b
        default: false
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

    @Published var aiModel: AIModel {
        didSet {
            UserDefaults.standard.set(aiModel.rawValue, forKey: "aiModel")
            onAIModelChange?()
        }
    }
    /// Called by AppDelegate to restart MLX warm-up when the AI model changes.
    var onAIModelChange: (() -> Void)?

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
        didSet {
            UserDefaults.standard.set(inferenceBackend.rawValue, forKey: "inferenceBackend")
            onBackendChange?()
        }
    }
    /// Called by AppDelegate when the inference backend changes (e.g. switching to a mode that uses MLX).
    var onBackendChange: (() -> Void)?
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
    /// Reflects whether the MLX AI model is loaded. Updated by AppDelegate.
    @Published var aiModelState: AIModelState = .notLoaded

    private init() {
        let ud = UserDefaults.standard
        aiModel          = AIModel(rawValue: ud.string(forKey: "aiModel") ?? "") ?? .gemma3_1b
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
