# Gemmur

A 100% local, privacy-first dictation app for macOS. Hold a key, speak, release — your words appear in whatever app is focused. No cloud. No subscription. All processing happens on your machine.

**Powered by [Gemma 4 E-series](https://ai.google.dev/gemma) via [Ollama](https://ollama.com).** Gemma 4 E4B is a multimodal model that handles transcription and disfluency cleanup in a single inference pass — no separate Whisper + LLM pipeline.

---

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- [Ollama](https://ollama.com) ≥ 0.6 (with Gemma 4 audio support)
- Gemma 4 E4B or E2B model pulled locally

## Setup

### 1. Install Ollama

Download from [ollama.com](https://ollama.com) or via Homebrew:

```bash
brew install ollama
```

Start the Ollama server (or launch the Ollama menu bar app):

```bash
ollama serve
```

### 2. Pull the Gemma 4 model

```bash
# Default — good balance of speed and quality
ollama pull gemma4:e2b

# Higher quality, requires more memory/compute
ollama pull gemma4:e4b
```

Verify audio input is working:

```bash
ollama run gemma4:e4b "Hello"
# Should respond without errors
```

### 3. Build and run Gemmur

Open `Gemmur.xcodeproj` in Xcode 16+ and press **Run**, or build from the terminal:

```bash
xcodegen generate   # only needed after cloning or adding new source files
xcodebuild -scheme Gemmur -configuration Debug build
open DerivedData/Gemmur/Build/Products/Debug/Gemmur.app
```

### 4. Grant permissions

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
| Model | Gemma 4 E4B (recommended), Gemma 4 E2B |
| Launch at login | Toggle |

Use **Check connection** in Settings to verify Ollama is running and the selected model is available.

---

## Privacy

- Zero network calls to any external server. All audio stays on your machine.
- Audio is never written to disk — it lives in memory for the duration of the recording.
- Transcription runs entirely inside the local Ollama process.

---

## Troubleshooting

**The waveform icon doesn't appear in the menu bar**
→ Make sure `LSUIElement` is set to `true` in `Info.plist` (it is by default). Restart the app.

**"Could not reach Ollama at localhost:11434"**
→ Run `ollama serve` or start the Ollama desktop app.

**"Model 'gemma4:e4b' not found"**
→ Run `ollama pull gemma4:e4b` and wait for the download to complete.

**"Backend does not support audio input"**
→ Update Ollama to the latest version (`brew upgrade ollama`). Audio support for Gemma 4 E-series requires Ollama ≥ 0.6.

**Accessibility permission keeps asking**
→ Remove Gemmur from System Settings → Privacy & Security → Accessibility and re-add it after granting.

**Text is inserted into the wrong app**
→ Make sure the target text field was focused (had the blinking cursor) before you pressed Fn. The Gemmur Settings window will steal focus if it's open — close it first.
