import Foundation

/// Plug-in point for local inference runtimes (Ollama, llama.cpp, MLX).
/// All implementations must only make requests to localhost.
protocol TranscriptionBackend: Sendable {
    /// Transcribe raw 16 kHz mono float32 PCM samples.
    /// - Parameters:
    ///   - audio: Float32 PCM samples at 16 kHz, mono.
    ///   - tone: Dictation tone controlling style and post-processing.
    /// - Returns: Transcribed string, ready to insert.
    func transcribe(audio: [Float], tone: DictationTone) async throws -> String

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
    case punctuated   = "Punctuated"
    case cleanedUp    = "Cleaned up"
    case formalEmail  = "Formal email"
    case casual       = "Casual"
    case bulletList   = "Bullet list"

    var id: String { rawValue }

    /// Tones that require an LLM rewrite pass after raw Whisper transcription.
    var needsLLMRewrite: Bool {
        switch self {
        case .verbatim, .punctuated, .bulletList: false
        case .cleanedUp, .formalEmail, .casual: true
        }
    }

    var systemPrompt: String {
        switch self {
        case .verbatim:
            "You are a dictation engine. Transcribe the user's speech exactly as spoken, " +
            "including filler words. Add minimal punctuation only where obviously needed. " +
            "Output only the transcript — no commentary, no quotation marks."
        case .punctuated:
            "You are a dictation engine. Transcribe the user's speech word for word without " +
            "changing, rephrasing, or removing any words. Add natural punctuation (commas, " +
            "periods, question marks) and start new paragraphs where there is a clear topic " +
            "shift or a long natural pause. Do not remove filler words or alter the wording " +
            "in any way. Output only the transcript — no commentary, no quotation marks."
        case .cleanedUp:
            "You are a dictation engine. Transcribe the user's speech, removing filler words " +
            "(um, uh, like, you know), false starts, and repetitions. Add natural punctuation " +
            "and paragraph breaks where appropriate. " +
            "Output only the transcript — no commentary, no quotation marks."
        case .formalEmail:
            "You are a dictation engine. Transcribe the user's speech and rewrite it as polished, " +
            "professional prose suitable for a formal email. Fix grammar, remove filler words, " +
            "and add appropriate punctuation. Output only the transcript — no commentary, no quotation marks."
        case .casual:
            "You are a dictation engine. Transcribe the user's speech in a relaxed, friendly tone. " +
            "Remove filler words and add light punctuation. " +
            "Output only the transcript — no commentary, no quotation marks."
        case .bulletList:
            // No LLM rewrite; formatting is applied in post-processing.
            ""
        }
    }
}

// MARK: - Post-processing

extension DictationTone {
    /// Apply tone-specific formatting that doesn't require an LLM (vocab replacement, emoji, bullets).
    func postProcess(_ text: String, vocabularyReplacements: [(word: String, replacement: String)] = []) -> String {
        var result = text
        // Vocabulary replacements first (user-defined, highest priority)
        for (word, replacement) in vocabularyReplacements {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        result = substituteEmoji(in: result)
        if self == .bulletList {
            result = "• " + result + "\n"
        }
        return result
    }

    /// Replace spoken emoji phrases (e.g. "fire emoji") with the actual character.
    private func substituteEmoji(in text: String) -> String {
        var result = text
        for (phrase, emoji) in Self.emojiMap {
            // Word-boundary aware, case-insensitive
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: emoji)
            }
        }
        return result
    }

    private static let emojiMap: [(phrase: String, emoji: String)] = [
        // Faces
        ("crying laughing emoji",       "😂"),
        ("face with tears of joy emoji","😂"),
        ("laughing crying emoji",       "😂"),
        ("laughing emoji",              "😄"),
        ("crying emoji",                "😢"),
        ("sobbing emoji",               "😭"),
        ("smiling emoji",               "😊"),
        ("smile emoji",                 "😊"),
        ("winking emoji",               "😉"),
        ("wink emoji",                  "😉"),
        ("sunglasses emoji",            "😎"),
        ("cool emoji",                  "😎"),
        ("thinking emoji",              "🤔"),
        ("mind blown emoji",            "🤯"),
        ("exploding head emoji",        "🤯"),
        ("facepalm emoji",              "🤦"),
        ("face palm emoji",             "🤦"),
        ("shrug emoji",                 "🤷"),
        ("skull emoji",                 "💀"),
        ("poop emoji",                  "💩"),
        ("heart eyes emoji",            "😍"),
        ("kissing emoji",               "😘"),
        ("nervous emoji",               "😬"),
        ("grimace emoji",               "😬"),
        ("sleeping emoji",              "😴"),
        ("sick emoji",                  "🤒"),
        ("nerd emoji",                  "🤓"),
        ("angry emoji",                 "😠"),
        ("devil emoji",                 "😈"),
        ("ghost emoji",                 "👻"),
        ("alien emoji",                 "👽"),
        ("robot emoji",                 "🤖"),
        ("clown emoji",                 "🤡"),
        // Hands & gestures
        ("thumbs up emoji",             "👍"),
        ("thumbs down emoji",           "👎"),
        ("wave emoji",                  "👋"),
        ("waving emoji",                "👋"),
        ("clapping emoji",              "👏"),
        ("clap emoji",                  "👏"),
        ("prayer emoji",                "🙏"),
        ("praying emoji",               "🙏"),
        ("folded hands emoji",          "🙏"),
        ("muscle emoji",                "💪"),
        ("flex emoji",                  "💪"),
        ("point up emoji",              "☝️"),
        ("finger pointing up emoji",    "☝️"),
        ("ok hand emoji",               "👌"),
        ("peace emoji",                 "✌️"),
        ("rock on emoji",               "🤘"),
        ("crossed fingers emoji",       "🤞"),
        // Objects & symbols
        ("fire emoji",                  "🔥"),
        ("heart emoji",                 "❤️"),
        ("red heart emoji",             "❤️"),
        ("broken heart emoji",          "💔"),
        ("sparkles emoji",              "✨"),
        ("star emoji",                  "⭐"),
        ("hundred emoji",               "💯"),
        ("hundred percent emoji",       "💯"),
        ("check emoji",                 "✅"),
        ("checkmark emoji",             "✅"),
        ("cross emoji",                 "❌"),
        ("x emoji",                     "❌"),
        ("party emoji",                 "🎉"),
        ("celebration emoji",           "🎉"),
        ("rocket emoji",                "🚀"),
        ("money emoji",                 "💰"),
        ("money bag emoji",             "💰"),
        ("eyes emoji",                  "👀"),
        ("rainbow emoji",               "🌈"),
        ("lightning emoji",             "⚡"),
        ("bomb emoji",                  "💣"),
        ("trophy emoji",                "🏆"),
        ("crown emoji",                 "👑"),
        ("gem emoji",                   "💎"),
        ("diamond emoji",               "💎"),
        ("key emoji",                   "🔑"),
        ("lock emoji",                  "🔒"),
        ("bell emoji",                  "🔔"),
        ("warning emoji",               "⚠️"),
        ("pin emoji",                   "📌"),
        ("calendar emoji",              "📅"),
        ("clock emoji",                 "🕐"),
        ("hourglass emoji",             "⏳"),
        ("magnifying glass emoji",      "🔍"),
        ("light bulb emoji",            "💡"),
        ("microphone emoji",            "🎤"),
        ("camera emoji",                "📷"),
        ("phone emoji",                 "📱"),
        ("computer emoji",              "💻"),
        ("email emoji",                 "📧"),
        ("book emoji",                  "📖"),
        ("pencil emoji",                "✏️"),
        ("chart emoji",                 "📈"),
        ("graph emoji",                 "📈"),
        ("globe emoji",                 "🌍"),
        ("earth emoji",                 "🌍"),
        ("sun emoji",                   "☀️"),
        ("moon emoji",                  "🌙"),
        ("snowflake emoji",             "❄️"),
        ("wave emoji",                  "🌊"),
        ("tree emoji",                  "🌳"),
        ("flower emoji",                "🌸"),
        ("rose emoji",                  "🌹"),
        ("dog emoji",                   "🐶"),
        ("cat emoji",                   "🐱"),
        ("pizza emoji",                 "🍕"),
        ("coffee emoji",                "☕"),
        ("beer emoji",                  "🍺"),
        ("wine emoji",                  "🍷"),
        ("cake emoji",                  "🎂"),
        ("muscle car emoji",            "🏎️"),
        ("car emoji",                   "🚗"),
        ("plane emoji",                 "✈️"),
        ("house emoji",                 "🏠"),
        ("hospital emoji",              "🏥"),
        ("school emoji",                "🏫"),
    ]
}
