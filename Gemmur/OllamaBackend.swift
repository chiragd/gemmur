import Foundation

/// Transcription backend that posts to a local Ollama instance.
///
/// Audio is encoded as a 32-bit float WAV and passed in the `images` field of the
/// /api/chat payload — the same slot Ollama uses for vision model image attachments.
///
/// Setup:
///   ollama pull gemma4:e4b
///   ollama serve          # or start via the Ollama menu bar app
final class OllamaBackend: TranscriptionBackend {

    // MARK: - Configuration

    let model: String
    private let baseURL: URL

    init(model: String = "gemma4:e2b") {
        self.model = model
        // Hard-coded to localhost — no external network calls ever leave this machine.
        self.baseURL = URL(string: "http://localhost:11434")!
    }

    // MARK: - TranscriptionBackend

    func transcribe(audio: [Float], tone: DictationTone) async throws -> String {
        let wavData = WavEncoder.encode(samples: audio, sampleRate: 16_000)
        let b64 = wavData.base64EncodedString()

        let body = OllamaChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: tone.systemPrompt, images: nil),
                .init(role: "user",   content: "Transcribe this audio.", images: [b64])
            ],
            stream: true
        )

        let transcript = try await streamChat(body, errorHints: true)
        guard !transcript.isEmpty else { throw BackendError.emptyTranscript }
        return transcript
    }

    /// Text-only rewrite — used by WhisperBackend for tones that need LLM post-processing.
    /// - Parameter onPartial: Called on the main actor with the accumulated text after each token.
    func rewrite(
        text: String,
        tone: DictationTone,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let body = OllamaChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: tone.systemPrompt, images: nil),
                .init(role: "user",   content: "Rewrite the following transcript:\n\n\(text)", images: nil)
            ],
            stream: true
        )

        let result = try await streamChat(body, errorHints: false, onPartial: onPartial)
        guard !result.isEmpty else { throw BackendError.emptyTranscript }
        NSLog("[OllamaBackend] Rewrite complete")
        return result
    }

    // MARK: - Streaming helper

    /// Posts a chat request with `stream: true` and accumulates the NDJSON token deltas.
    /// - Parameters:
    ///   - errorHints: when true, adds Ollama-specific hints for 400/404 errors.
    ///   - onPartial: called (fire-and-forget on main actor) with accumulated text after each token.
    private func streamChat(
        _ body: OllamaChatRequest,
        errorHints: Bool,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.unexpectedResponse("Non-HTTP response.")
        }

        guard http.statusCode == 200 else {
            // On error Ollama sends a plain JSON body, not a stream — collect it.
            var errorData = Data()
            for try await byte in asyncBytes { errorData.append(byte) }
            let msg = String(data: errorData, encoding: .utf8) ?? ""
            if errorHints {
                switch http.statusCode {
                case 404: throw BackendError.modelNotFound(model)
                case 400 where msg.localizedCaseInsensitiveContains("audio"):
                    throw BackendError.audioUnsupported(
                        "This Ollama build may not support audio. " +
                        "Try: ollama pull \(model) and ensure Ollama ≥ 0.6. Detail: \(msg)"
                    )
                default: break
                }
            }
            throw BackendError.unexpectedResponse("HTTP \(http.statusCode): \(msg)")
        }

        var result = ""
        for try await line in asyncBytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data)
            else { continue }
            result += chunk.message.content
            if let onPartial {
                let snapshot = result
                Task { @MainActor in onPartial(snapshot) }
            }
            if chunk.done { break }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkAvailability() async throws {
        // 1. Ping the Ollama server
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: tagsURL)
        } catch {
            throw BackendError.backendUnreachable(
                "Could not reach Ollama at localhost:11434. " +
                "Is Ollama running? Start it with: ollama serve"
            )
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.backendUnreachable("Ollama returned an unexpected status.")
        }

        // 2. Confirm the model is pulled
        struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        let found = tags.models.contains { $0.name.hasPrefix(model.split(separator: ":").first.map(String.init) ?? model) }
        if !found {
            throw BackendError.modelNotFound(model)
        }
    }
}

// MARK: - Request / Response types (private)

private struct OllamaChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
        let images: [String]?
    }
    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
    let done: Bool
}

// MARK: - WAV encoder

/// Encodes float32 mono PCM samples into a valid IEEE_FLOAT WAV file (format type 3).
enum WavEncoder {
    static func encode(samples: [Float], sampleRate: UInt32) -> Data {
        let bitsPerSample: UInt16 = 32
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(chunkSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk (IEEE_FLOAT = 3)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))           // sub-chunk size
        data.appendLE(UInt16(3))            // audio format: IEEE float
        data.appendLE(channels)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)
        let sampleData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        data.append(sampleData)

        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
