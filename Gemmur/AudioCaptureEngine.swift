import AVFoundation

/// Captures microphone audio as 16 kHz mono float32 PCM.
///
/// Usage:
///   try engine.startRecording()
///   let samples = engine.stopRecording()   // call on key release
///
/// The engine enforces a 5-minute hard cap. If the user holds the hotkey longer,
/// `onAutoStop` fires with the accumulated samples so the caller can kick off inference.
@MainActor
final class AudioCaptureEngine: ObservableObject {

    static let shared = AudioCaptureEngine()

    // MARK: - Published state (drives HUD)

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0
    /// Smoothed audio level in 0…1, updated each tap callback.
    @Published private(set) var audioLevel: Float = 0
    /// Rolling history of smoothed levels — newest value last. Max 120 entries (~10s).
    @Published private(set) var audioHistory: [Float] = []

    // MARK: - Configuration

    let targetSampleRate: Double = 16_000
    private let maxDuration: Double = 300.0  // 5-minute hard cap

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            // Runs on the AVAudioEngine audio thread — no @MainActor state here.
            guard let newSamples = AudioCaptureEngine.convert(buffer: buffer,
                                                              using: converter,
                                                              to: targetFormat) else { return }
            let rms = AudioCaptureEngine.computeRMS(newSamples)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.samples.append(contentsOf: newSamples)
                // Exponential smoothing: fast attack (α=0.85), slow decay (α=0.15)
                let smoothed = rms > self.audioLevel
                    ? 0.85 * rms + 0.15 * self.audioLevel
                    : 0.15 * rms + 0.85 * self.audioLevel
                self.audioLevel = smoothed
                self.audioHistory.append(smoothed)
                if self.audioHistory.count > 120 { self.audioHistory.removeFirst() }
            }
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
        audioLevel = 0
        audioHistory = []

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

    /// RMS of a float32 PCM buffer, normalised to 0…1. Safe to call from any thread.
    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return min(1, sqrt(sumOfSquares / Float(samples.count)) * 12) // ×12 scales typical speech levels to 0…1
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
