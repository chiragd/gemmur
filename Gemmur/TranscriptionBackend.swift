import Foundation

/// Plug-in point for local inference runtimes (Ollama, llama.cpp, MLX).
/// All implementations must only make requests to localhost.
protocol TranscriptionBackend: Sendable {
    /// Transcribe raw 16 kHz mono float32 PCM samples.
    /// - Parameters:
    ///   - audio: Float32 PCM samples at 16 kHz, mono.
    ///   - systemPrompt: Dictation instruction (controls tone / verbatim vs. cleaned-up).
    /// - Returns: Transcribed string, ready to insert.
    func transcribe(audio: [Float], systemPrompt: String) async throws -> String

    /// Verify the backend is reachable and the required model is available.
    /// Throws a descriptive `BackendError` if not ready.
    func checkAvailability() async throws
}

// MARK: - Errors

enum BackendError: LocalizedError {
    case backendUnreachable(String)
    case modelNotFound(String)
    case audioUnsupported(String)
    case unexpectedResponse(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .backendUnreachable(let detail):
            "Inference backend unreachable. \(detail)"
        case .modelNotFound(let model):
            "Model '\(model)' not found. Run: ollama pull \(model)"
        case .audioUnsupported(let detail):
            "Backend does not support audio input yet. \(detail)"
        case .unexpectedResponse(let detail):
            "Unexpected response from backend. \(detail)"
        case .emptyTranscript:
            "Transcription returned an empty result."
        }
    }
}

// MARK: - Tone / system prompts

enum DictationTone: String, CaseIterable, Identifiable {
    case verbatim     = "Verbatim"
    case cleanedUp    = "Cleaned up"
    case formalEmail  = "Formal email"
    case casual       = "Casual"

    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .verbatim:
            "You are a dictation engine. Transcribe the user's speech exactly as spoken. " +
            "Add natural punctuation. Output only the transcript — no commentary, no quotation marks."
        case .cleanedUp:
            "You are a dictation engine. Transcribe the user's speech, removing filler words " +
            "(um, uh, like, you know), false starts, and repetitions. Add natural punctuation. " +
            "Output only the transcript — no commentary, no quotation marks."
        case .formalEmail:
            "You are a dictation engine. Transcribe the user's speech and rewrite it as polished, " +
            "professional prose suitable for a formal email. Fix grammar, remove filler words, " +
            "and add appropriate punctuation. Output only the transcript — no commentary, no quotation marks."
        case .casual:
            "You are a dictation engine. Transcribe the user's speech in a relaxed, friendly tone. " +
            "Remove filler words and add light punctuation. " +
            "Output only the transcript — no commentary, no quotation marks."
        }
    }
}
