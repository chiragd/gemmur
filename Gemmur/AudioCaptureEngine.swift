import AVFoundation

/// Captures microphone audio as 16 kHz mono float32 PCM — the format Gemma 4 expects.
///
/// Usage:
///   try engine.startRecording()
///   let samples = engine.stopRecording()   // call on key release
///
/// The engine also enforces a 30-second hard cap. If the user holds Fn longer,
/// `onAutoStop` fires with the accumulated samples so the caller can kick off inference.
@MainActor
final class AudioCaptureEngine: ObservableObject {

    static let shared = AudioCaptureEngine()

    // MARK: - Published state (drives HUD)

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0

    // MARK: - Configuration

    let targetSampleRate: Double = 16_000
    private let maxDuration: Double = 30.0   // hard cap
    private let autoChunkAt: Double = 25.0   // warn / auto-stop threshold (unused in v1)

    // MARK: - Callbacks

    /// Fired when the 30s cap is reached. Guaranteed to run on the main actor.
    var onAutoStop: (([Float]) -> Void)?

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var elapsedTimer: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func startRecording() throws {
        guard !isRecording else { return }

        samples.removeAll(keepingCapacity: true)
        elapsedSeconds = 0

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.formatUnavailable }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            // This closure runs on the AVAudioEngine's internal audio thread — never touch
            // @MainActor state here. Do all conversion work inline (nonisolated), then
            // dispatch only the resulting [Float] to main for safe append.
            guard let newSamples = AudioCaptureEngine.convert(buffer: buffer,
                                                              using: converter,
                                                              to: targetFormat) else { return }
            DispatchQueue.main.async { self?.samples.append(contentsOf: newSamples) }
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        startElapsedTimer()
    }

    /// Stops recording and returns the accumulated samples. Safe to call even if not recording.
    @discardableResult
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        elapsedTimer?.cancel()
        elapsedTimer = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        isRecording = false
        elapsedSeconds = 0

        var result: [Float] = []
        swap(&result, &samples)   // zero-copy hand-off; samples is now empty with no retained capacity
        return result
    }

    // MARK: - Private helpers

    private func startElapsedTimer() {
        elapsedTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self.elapsedSeconds += 0.1
                if self.elapsedSeconds >= self.maxDuration {
                    let captured = self.stopRecording()
                    self.onAutoStop?(captured)
                    break
                }
            }
        }
    }

    /// Pure conversion — no actor isolation, safe to call from any thread.
    private static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var inputProvided = false
        var conversionError: NSError?

        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputProvided = true
            return buffer
        }

        guard conversionError == nil,
              converted.frameLength > 0,
              let channelData = converted.floatChannelData?[0] else { return nil }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case formatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .formatUnavailable:  "Could not create 16 kHz mono audio format."
            case .converterUnavailable: "Could not create audio format converter."
            }
        }
    }
}
