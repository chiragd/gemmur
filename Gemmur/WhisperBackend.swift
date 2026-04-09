import Foundation
@preconcurrency import WhisperKit

/// Transcription backend that runs OpenAI Whisper entirely in-process via CoreML + Metal.
///
/// - For all tones when `AppSettings.whisperOnly` is true: returns raw Whisper transcript.
/// - For simple tones (Verbatim, Punctuated): always returns raw Whisper transcript.
/// - For rewriting tones (Cleaned up, Formal email, Casual): passes the Whisper transcript
///   to Ollama for a lightweight text-only rewrite (unless whisperOnly is set).
///
/// Call `warmUp(model:)` at app launch and whenever the selected Whisper model changes.
@MainActor
final class WhisperBackend: TranscriptionBackend {

    private var pipe: WhisperKit?

    var isReady: Bool { pipe != nil }

    /// Set by AppDelegate before each transcription. Called on the main actor with
    /// accumulated text as it becomes available (raw Whisper output first, then
    /// each MLX token if a rewrite is running).
    var onPartialTranscript: (@Sendable (String) -> Void)?

    /// Injected by AppDelegate so WhisperBackend can delegate rewrite passes to MLX.
    var mlxBackend: MLXRewriteBackend?

    // MARK: - Warm-up

    func warmUp(model: String) async throws {
        pipe = nil  // mark not-ready while loading so callers fall back to Ollama
        AppSettings.shared.whisperModelState = .loading
        NSLog("[WhisperBackend] Loading model '%@'…", model)
        do {
            pipe = try await WhisperKit(model: model)
            NSLog("[WhisperBackend] Model '%@' ready", model)
            AppSettings.shared.whisperModelState = .ready
        } catch {
            NSLog("[WhisperBackend] Load failed: %@", error.localizedDescription)
            AppSettings.shared.whisperModelState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - TranscriptionBackend

    func transcribe(audio: [Float], tone: DictationTone) async throws -> String {
        guard let pipe else {
            throw BackendError.backendUnreachable(
                "WhisperKit model not loaded yet — try again in a moment."
            )
        }

        NSLog("[WhisperBackend] Transcribing %d samples (%.1fs)…",
              audio.count, Double(audio.count) / 16_000)

        let results = try await pipe.transcribe(audioArray: audio)
        let rawTranscript = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawTranscript.isEmpty else { throw BackendError.emptyTranscript }
        NSLog("[WhisperBackend] Raw transcript: %@", rawTranscript)

        // Surface the raw Whisper result immediately so the UI can show something
        // while Ollama rewrites (or as the final result for simple tones).
        onPartialTranscript?(rawTranscript)

        let backend = AppSettings.shared.inferenceBackend
        let shouldRewrite = backend.mlxRunsForAllTones
                         || (tone.needsLLMRewrite && backend.usesMLX)

        if shouldRewrite {
            guard let mlxBackend, mlxBackend.isReady else {
                throw BackendError.backendUnreachable(
                    "AI model not loaded yet — try again in a moment."
                )
            }
            NSLog("[WhisperBackend] Rewriting via MLX (tone: %@)…", tone.rawValue)
            let onPartial = onPartialTranscript
            return try await mlxBackend.rewrite(text: rawTranscript, tone: tone, onPartial: onPartial)
        }

        return rawTranscript
    }

    func checkAvailability() async throws {
        guard pipe != nil else {
            throw BackendError.backendUnreachable("WhisperKit model not loaded yet.")
        }
    }
}
