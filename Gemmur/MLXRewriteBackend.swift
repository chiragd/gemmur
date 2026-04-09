import Foundation
import MLXLLM
import MLXLMCommon

/// Text-rewrite backend backed by Apple MLX running entirely in-process.
///
/// Models are downloaded on first use from Hugging Face Hub (same pattern as WhisperKit).
/// Runs on Metal / Neural Engine — no subprocess, no external server required.
///
/// Call `warmUp(modelId:)` at app launch and whenever the selected AI model changes.
@MainActor
final class MLXRewriteBackend {

    /// Containers keyed by model ID — keeps previously loaded models in memory
    /// so switching back to one that's already been loaded is instant.
    private var cache: [String: ModelContainer] = [:]
    private var activeModelId: String?

    var isReady: Bool { activeModelId != nil }
    private var container: ModelContainer? { activeModelId.flatMap { cache[$0] } }

    // MARK: - Warm-up

    func warmUp(modelId: String) async throws {
        // If we already have this model loaded, just switch to it — no download needed.
        if let cached = cache[modelId] {
            NSLog("[MLXRewriteBackend] Model '%@' already loaded — reusing", modelId)
            activeModelId = modelId
            AppSettings.shared.aiModelState = .ready
            _ = cached  // keep reference live
            return
        }

        activeModelId = nil
        AppSettings.shared.aiModelState = .loading
        NSLog("[MLXRewriteBackend] Loading model '%@'…", modelId)
        do {
            let config = ModelConfiguration(id: modelId, extraEOSTokens: ["<end_of_turn>"])
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: config)
            cache[modelId] = loaded
            activeModelId = modelId
            NSLog("[MLXRewriteBackend] Model '%@' ready", modelId)
            AppSettings.shared.aiModelState = .ready
        } catch {
            NSLog("[MLXRewriteBackend] Load failed: %@", error.localizedDescription)
            AppSettings.shared.aiModelState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Rewrite

    /// Rewrite `text` according to the given `tone` using the loaded MLX model.
    /// - Parameter onPartial: Called on the main actor with accumulated text after each token.
    func rewrite(
        text: String,
        tone: DictationTone,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let container else {
            throw BackendError.backendUnreachable("AI model not loaded yet — try again in a moment.")
        }

        NSLog("[MLXRewriteBackend] Rewriting (tone: %@)…", tone.rawValue)

        let messages: [[String: String]] = [
            ["role": "system", "content": tone.systemPrompt],
            ["role": "user",   "content": "Rewrite the following transcript:\n\n\(text)"]
        ]

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(messages: messages)
            )
            NSLog("[MLXRewriteBackend] Starting generation…")
            // Cap at 500 tokens to prevent runaway generation.
            // The didGenerate callback receives accumulated tokens on each call.
            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 500),
                context: context
            ) { tokens in
                // Decode all accumulated tokens, stripping special tokens like <end_of_turn>.
                let currentOutput = context.tokenizer.decode(tokens: tokens, skipSpecialTokens: true)
                if let onPartial {
                    Task { @MainActor in onPartial(currentOutput) }
                }
                return .more
            }
        }
        NSLog("[MLXRewriteBackend] Generation complete: %d tokens, %.1f tok/s",
              result.tokens.count, result.tokensPerSecond)

        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[MLXRewriteBackend] Rewrite complete: %d chars", trimmed.count)
        guard !trimmed.isEmpty else { throw BackendError.emptyTranscript }
        return trimmed
    }
}
