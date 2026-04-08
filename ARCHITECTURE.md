# Gemmur — Architecture

## Overview

```
Fn key held
    │
    ▼
HotkeyManager          CGEventTap at cghidEventTap
    │                  Intercepts flagsChanged events for the configured key.
    │                  Consumes the event (returns nil) so the OS never sees it.
    ▼
AudioCaptureEngine     AVAudioEngine tap → AVAudioConverter → [Float]
    │                  Captures mic at hardware sample rate, converts to
    │                  16 kHz mono float32 PCM in-tap. Accumulates samples.
    │                  Hard cap at 30 s; fires onAutoStop if exceeded.
    ▼
Fn key released
    │
    ▼
TranscriptionBackend   Protocol. v1: OllamaBackend.
    │                  Encodes [Float] → IEEE_FLOAT WAV → base64.
    │                  POSTs to http://localhost:11434/api/chat with
    │                  model = gemma4:e4b, audio in the `images` field.
    │                  Returns the assistant message content string.
    ▼
TextInserter           1. AX primary: AXUIElementSetAttributeValue(focused,
                              kAXSelectedTextAttribute, transcript)
                       2. Clipboard fallback: save clipboard → set text →
                              CGEvent Cmd-V → restore clipboard after 300 ms.
```

---

## Key design decisions

### Single-model pipeline

Traditional dictation tools use Whisper for transcription and a separate LLM for cleanup. Gemmur uses a single Gemma 4 E-series model for both steps. The model receives raw audio and a system prompt that simultaneously dictates transcription style (verbatim / cleaned-up / formal / casual). This eliminates latency from a second model call and keeps the dependency surface small.

### Audio format

Gemma 4 E-series expects mono 16 kHz float32 PCM (~6.25 audio tokens/sec). `AVAudioEngine` captures at the hardware's native format (typically 44.1 kHz or 48 kHz stereo); `AVAudioConverter` resamples to 16 kHz mono in the tap callback on the audio thread. Samples accumulate as `[Float]` in memory — never written to disk.

The WAV encoding uses format type 3 (IEEE_FLOAT) rather than 1 (PCM/integer) to avoid a lossy int16 quantization step.

### Fn key interception

The Fn / Globe key is intercepted at `cghidEventTap` (the lowest-level user-space tap, before Dock and system handlers). The callback returns `nil` to consume the event, preventing the emoji picker or Globe menu from appearing. Right Option and Right Control are handled by the same tap, differentiated by `CGKeyCode` and `CGEventFlags`.

A `flagsChanged` event carries the full flags state after the change. Press is detected when the relevant flag bit is *gained*; release when it is *lost*.

### Text insertion

`kAXSelectedTextAttribute` is the correct Accessibility attribute for "insert at cursor / replace selection." It is non-destructive: if nothing is selected, it inserts at the caret; if text is selected, it replaces only the selection. `kAXValueAttribute` (replaces the entire field value) is only used as a last resort and only when the field is empty.

The clipboard fallback saves the full pasteboard state (all types, all representations) before overwriting it, then restores after 300 ms. This is long enough for virtually all apps to process a Cmd-V paste.

### Concurrency

All UI-touching code runs on `@MainActor`. The `AVAudioEngine` tap callback runs on an internal audio thread; samples are dispatched to the main actor with `DispatchQueue.main.async`. The `CGEventTap` callback also runs on the main run loop (added via `CFRunLoopAddSource`), so the dispatch hop is just a precaution against race conditions with the hotkey state.

`OllamaBackend` uses `URLSession.shared.data(for:)` which suspends on a background thread and resumes on the caller's actor (main), keeping the main thread responsive.

---

## File map

```
Gemmur/
├── GemmurApp.swift          @main entry point; WindowGroup("settings") scene
├── AppDelegate.swift        NSStatusItem, menu, hotkey wiring, transcription orchestration
│
├── AppSettings.swift        UserDefaults-backed settings (model, tone, hotkey, launchAtLogin)
├── PermissionsManager.swift Mic + Accessibility status; polls for AX grant without restart
│
├── HotkeyManager.swift      CGEventTap; supports Fn / Right Option / Right Control
├── AudioCaptureEngine.swift AVAudioEngine → AVAudioConverter → [Float] at 16 kHz mono
├── ListeningHUD.swift       Non-activating NSPanel near cursor; SwiftUI pulsing indicator
│
├── TranscriptionBackend.swift  Protocol + DictationTone system prompts + BackendError
├── OllamaBackend.swift         HTTP client for Ollama /api/chat; WavEncoder (IEEE_FLOAT)
│
├── TextInserter.swift       AX insert (kAXSelectedTextAttribute) → clipboard fallback
└── SettingsView.swift       TabView: General (dictation/backend/permissions/system) + About
```

---

## Plugging in alternative backends

`TranscriptionBackend` is a Swift protocol with two requirements:

```swift
protocol TranscriptionBackend: Sendable {
    func transcribe(audio: [Float], systemPrompt: String) async throws -> String
    func checkAvailability() async throws
}
```

To add MLX-VLM or a llama.cpp server backend:

1. Create a new file (e.g. `MLXBackend.swift`) that conforms to `TranscriptionBackend`.
2. Add the case to the backend picker in `AppSettings` / `SettingsView`.
3. In `AppDelegate.handleTranscription()`, instantiate the selected backend.

The audio format contract (`[Float]`, 16 kHz, mono) is fixed — backends that need a different format should convert internally.

---

## Adding a new hotkey

1. Add a case to `HotkeyOption` in `AppSettings.swift` with the correct `keyCode` and `activeFlag`.
2. `HotkeyManager` will pick it up automatically — no other changes needed.

Keys that don't appear as `flagsChanged` events (e.g. arbitrary letter keys with modifier combos) would require changing the `eventsOfInterest` mask in `HotkeyManager.installTap()` to also include `keyDown` / `keyUp` events.
