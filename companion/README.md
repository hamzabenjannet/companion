# Companion

macOS SwiftUI meeting assistant. Pick a processing mode with the **Mode** drop-down:

```text
Local (Whisper + Ollama)
Microphone (AVAudioEngine) ──► "Me" WAV chunks ─────┐
                                                    ├─► Whisper /asr ─► transcript ─► Ollama /api/chat ─► suggestion
System audio (ScreenCaptureKit) ─► "Others" WAV chunks ┘

Google Gemini / OpenRouter
Microphone ──► "Me" WAV chunks ──────┐
System audio ─► "Others" WAV chunks ─┼─► one multimodal request ─► JSON { transcript, suggestion }
Screen ──────► "Screen" MP4 chunks ──┘
```

In the remote modes, nothing is transcribed locally. Raw audio and video chunks are batched (up to 12 per request) and sent inline. The model returns the labelled transcript and the suggestion in one reply.

- The mic and system audio are captured **separately**, so every transcript line is labelled `Me` or `Others`.
- Audio is resampled to 16 kHz mono and cut into fixed-length chunks (8 s by default). Silent chunks are skipped.
- Chunks are transcribed one at a time, in order. Only one Ollama request runs at a time. New lines that arrive while the model is busy are sent together in the next request.
- The model sees the last 30 transcript lines and replies `NO_RESPONSE` when it has nothing useful to add (these replies are hidden).

## Files

| File | Purpose |
| --- | --- |
| `AudioCapture.swift` | `CaptureSource`, `MediaChunk`, `AudioChunker` (resample, silence gate, WAV writer), `MicrophoneCapture`, `SystemAudioCapture` |
| `ScreenCapture.swift` | `ScreenCapture` (ScreenCaptureKit, 1 fps, ≤1280 px wide) and `VideoChunkWriter` (H.264 MP4 chunks) |
| `APIClient.swift` | `HTTPTransport`, Whisper multipart upload and Ollama chat |
| `MultimodalProvider.swift` | `ProcessingProvider`, `MultimodalClient` protocol, prompt builder and JSON reply parser |
| `GeminiClient.swift` | Gemini REST: model list (paginated) and `generateContent` with inline audio/video |
| `OpenRouterClient.swift` | OpenRouter: model list (audio-capable only) and chat completions with `input_audio` / `video_url` |
| `ProviderConfiguration.swift` | Provider, hosts and models (UserDefaults) and API keys (Keychain) |
| `KeychainStore.swift` | Generic-password Keychain wrapper |
| `ChunkLog.swift` | Debug list of the last 10 chunks. Evicted files are deleted. |
| `MeetingAssistant.swift` | Pipeline orchestration (local and remote) and prompts |
| `ContentView.swift` | Start/Stop, mode picker, settings, transcript, assistant and debug panels |

Unit tests (Swift Testing) live in `companionTests/` and run with the `MyApp` scheme (⌘U).

## Requirements

- **Local**: Whisper ASR webservice (default `http://localhost:42940`) and Ollama (default `http://localhost:11434`) with `qwen2.5:3b` pulled.
- **Google Gemini**: an API key from Google AI Studio. Host `https://generativelanguage.googleapis.com`. After you enter the key, the model drop-down loads from `GET /v1beta/models` (only models that support `generateContent` are shown). Some listed models (e.g. `gemini-2.5-flash`) return 404 for new keys. The default is `models/gemini-3.8-flash`.
- **OpenRouter**: an API key. The drop-down only lists models that accept audio. If **Screen** is enabled, pick one that also accepts video. The default is `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` (text, image, audio and video input).
  - OpenRouter rejects audio requests (HTTP 402) unless the account has at least **$0.50 of credit**, even for `:free` models. Text-only requests work without credit.
  - Free models are limited to 20 requests/min and 50/day. Set **Request interval** (e.g. 30–60 s). Chunks captured in the meantime are sent together in the next request, up to 24 per request.
  - `response_format: json_object` is only sent when the model lists it in `supported_parameters` (Nemotron doesn't). The prompt asks for JSON either way, and the reply parser tolerates surrounding text.

API keys are stored in the macOS Keychain, never in UserDefaults or source.

## Debug

The ladybug button shows the last 10 chunks from every channel (mic, system audio, screen), with their size, status, and the transcript or error. **Play** opens a chunk in the default player. **Open Folder** shows the chunk directory. Older chunk files are deleted automatically.

All endpoints, the model, the language, and the chunk length can be changed with the gear button. The Compose file defaults to host port **42040**, while the curl example uses **42940**. Use the port that is actually mapped.

## Permissions

- **Microphone**: macOS asks the first time you press Start.
- **Screen & System Audio Recording** (system audio and **Screen**): macOS asks the first time you press Start. After you grant it, **relaunch the app**.

Project configuration: App Sandbox with *Outgoing Connections (Client)* and *Audio Input* enabled, plus `NSMicrophoneUsageDescription`.

## Tips

- Wear headphones. Otherwise the mic also picks up the speakers, and the remote participants get transcribed twice.
- For lower latency, use shorter chunks (5–6 s). For better accuracy, use longer chunks, or a larger Whisper model (`ASR_MODEL=small`).
- Setting the language (e.g. `fr`) avoids misdetection on short chunks.

## Consent

Only capture meetings you are authorized to record or transcribe, and follow applicable consent and workplace rules.
