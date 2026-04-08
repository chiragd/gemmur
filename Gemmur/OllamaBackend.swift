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

    func transcribe(audio: [Float], systemPrompt: String) async throws -> String {
        let wavData = WavEncoder.encode(samples: audio, sampleRate: 16_000)
        let b64 = wavData.base64EncodedString()

        let body = OllamaChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt, images: nil),
                .init(role: "user",   content: "Transcribe this audio.", images: [b64])
            ],
            stream: false
        )

        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.unexpectedResponse("Non-HTTP response.")
        }

        switch http.statusCode {
        case 200:
            break
        case 404:
            throw BackendError.modelNotFound(model)
        case 400:
            // Ollama returns 400 with a message body when audio isn't supported by the build
            let msg = String(data: data, encoding: .utf8) ?? ""
            if msg.localizedCaseInsensitiveContains("audio") {
                throw BackendError.audioUnsupported(
                    "This Ollama build may not support audio. " +
                    "Try: ollama pull \(model) and ensure Ollama ≥ 0.6. Detail: \(msg)"
                )
            }
            throw BackendError.unexpectedResponse("HTTP 400: \(msg)")
        default:
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.unexpectedResponse("HTTP \(http.statusCode): \(msg)")
        }

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let transcript = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else { throw BackendError.emptyTranscript }
        return transcript
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

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable { let role: String; let content: String }
    let message: Message
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
