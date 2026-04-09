# Gemmur

A 100% local, privacy-first dictation app for macOS. Hold a key, speak, release — your words appear in whatever app is focused. No cloud. No subscription. All processing happens on your machine.

**Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) + [Gemma 3](https://ai.google.dev/gemma/docs/gemma3) (4-bit quantized via [MLX](https://github.com/ml-explore/mlx-swift)).** Speech is transcribed on-device by WhisperKit, then optionally rewritten by a local Gemma 3 model — no cloud, no external server, no Ollama required.

---

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 16+
- No external dependencies — models are downloaded automatically on first use

## Setup

### 1. Build and run Gemmur

Open `Gemmur.xcodeproj` in Xcode 16+ and press **Run**, or build from the terminal:

```bash
xcodegen generate   # only needed after cloning or adding new source files
xcodebuild -scheme Gemmur -configuration Debug build
open DerivedData/Gemmur/Build/Products/Debug/Gemmur.app
```

Models are downloaded from Hugging Face on first use (WhisperKit ~140 MB, Gemma 3 1B ~600 MB by default). Progress is shown in the Settings window.

### 2. Grant permissions

On first launch, open **Settings** from the menu bar icon and grant:

- **Microphone** — to capture your speech
- **Accessibility** — to insert transcribed text into other apps

Both can be granted directly from the Settings window without hunting through System Settings.

---

## Usage

1. Place your cursor in any text field in any app.
2. Hold **Fn** (Globe key) — a small "Listening…" indicator appears near your cursor.
3. Speak.
4. Release **Fn** — Gemmur transcribes and inserts the text.

The 30-second cap auto-triggers transcription if you hold longer than that.

### Settings

Click the `waveform.circle` icon in the menu bar → **Settings…**

| Setting | Options |
|---|---|
| Push-to-talk key | Fn / Globe, Right Option ⌥, Right Control ⌃ |
| Tone | Verbatim, Cleaned up, Formal email, Casual |
| Voice model | tiny.en (~40 MB), base.en (~140 MB), small.en (~460 MB) |
| AI model | Gemma 3 270M 4-bit (~170 MB), 1B 4-bit (~600 MB), 4B 4-bit (~2.5 GB) |
| Inference backend | Voice only, Voice + AI, AI for all tones |
| Launch at login | Toggle |

---

## Privacy

- Zero network calls to any external server. All audio stays on your machine.
- Audio is never written to disk — it lives in memory for the duration of the recording.
- Transcription runs entirely on-device via WhisperKit and MLX.

---

## Troubleshooting

**The waveform icon doesn't appear in the menu bar**
→ Make sure `LSUIElement` is set to `true` in `Info.plist` (it is by default). Restart the app.

**AI model is slow on first use**
→ The model is being downloaded from Hugging Face. Check Settings for progress. Once downloaded it's cached locally and loads in a few seconds.

**Transcription runs but AI rewrite does nothing**
→ Open Settings and check the AI model state indicator. If it shows "Failed", try switching to a smaller model (270M) which requires less memory.

**Accessibility permission keeps asking**
→ Remove Gemmur from System Settings → Privacy & Security → Accessibility and re-add it after granting.

**Text is inserted into the wrong app**
→ Make sure the target text field was focused (had the blinking cursor) before you pressed Fn. The Gemmur Settings window will steal focus if it's open — close it first.
