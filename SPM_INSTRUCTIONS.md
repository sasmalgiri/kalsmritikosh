# Adding Swift Package Dependencies — one-time setup

This file lists the SPM packages Atlas's protocol-abstracted slots are ready to use. Each package needs to be added once via Xcode (it can't be added programmatically — the project file is a binary plist managed by Xcode). After adding, the matching swap-in file already in the codebase becomes callable.

For each package below: **File → Add Package Dependencies… → paste the URL → Add Package → tick the Kalsmritikosh target → Add Package.**

---

## 1. WhisperKit — Apple-Silicon-optimized Whisper for audio transcription

**URL**: `https://github.com/argmaxinc/WhisperKit`
**Recommended product**: `WhisperKit`
**Pinned version (suggested)**: 0.9.0+

After adding:

1. Open the Kalsmritikosh target → Build Settings → search for "Active Compilation Conditions" → add `WHISPERKIT_AVAILABLE` to Debug and Release.
2. The scaffold file `Kalsmritikosh/Ingestion/ASR/WhisperKitTranscriber.swift` will start compiling its real implementation against the package (it was guarded by `#if WHISPERKIT_AVAILABLE` until now).
3. Inject in `AppState.boot` wherever `SpeechTranscriber()` is currently the default:

    ```swift
    let transcriber: any AudioTranscribing = WhisperKitTranscriber(
        modelVariant: "openai_whisper-large-v3"
    )
    let audioLoader = AudioLoader(transcriber: transcriber)
    let videoLoader = VideoLoader(transcriber: transcriber)
    ```

4. First transcribe call downloads the model from Hugging Face (~3 GB for large-v3, ~150 MB for tiny). For offline-first deployments, ship `openai_whisper-tiny` in `Resources/`.

Quality jump: 99 languages, sub-5% English WER, 100-300 ms per-utterance latency on M-series.

---

## 2. MLX Swift — Apple's MLX framework for local reasoning models

**URL**: `https://github.com/ml-explore/mlx-swift`
**Recommended products**: `MLX`, `MLXNN`, `MLXOptimizers`, `MLXRandom`
**Pinned version (suggested)**: 0.21.0+

Additionally needs the helper package for model loading:

**URL**: `https://github.com/ml-explore/mlx-swift-examples`
**Recommended product**: `MLXLLM`

After adding both:

1. The stub `Kalsmritikosh/Routing/Providers/MLXProvider.swift` returns `unavailable` until you implement `generate` against `MLXLLM.LLMModelFactory`. Reference implementation: `MLXLLM.generate(prompt:model:tokenizer:parameters:)`.
2. Drop user-supplied MLX checkpoints into `~/Library/Application Support/Kalsmritikosh/MLXModels/` — `MLXDiscovery.list()` already picks them up at boot.

Quality jump: any model that ships in MLX format runs on the Neural Engine + GPU with significantly less RAM than the equivalent Ollama Q4 quantization.

---

## 3. llama.cpp via Swift — user-supplied `.gguf` files

**URL**: `https://github.com/ggerganov/llama.cpp` (use the SwiftPM target shipped in the repo)
**Recommended product**: `llama`
**Pinned version (suggested)**: the latest tagged release

After adding:

1. `Kalsmritikosh/Routing/Providers/LlamaCppProvider.swift` is the stub to flesh out.
2. The GGUF file registry (`Kalsmritikosh/Routing/Providers/GGUFRegistry.swift`) already persists file paths the user picked via Settings → Your models → GGUF files. Each entry's `filePath` is the input to `llama_load_model_from_file`.

Quality jump: any quantized `.gguf` model the user has downloaded runs locally without Ollama.

---

## 4. PaddleOCR-VL — better OCR than Apple Vision (optional, heavier lift)

**URL**: No first-party Swift package; available via Python `paddleocr` or via Core ML conversion.

**Approach A — Mistral OCR cloud (already shipped)**: skip this entire item; `Kalsmritikosh/Ingestion/OCR/MistralOCREngine.swift` is the production cloud-OCR path. Costs ~$1 per 1000 pages, no SPM dep needed.

**Approach B — local PaddleOCR via Python**: outside the scope of a "single Swift package add" — requires shipping a Python subprocess and the PaddleOCR weights. The cleaner local path is to convert PaddleOCR-VL to Core ML and add a `PaddleOCREngine: OCREngine` that runs it via `MLModel`. Bounded but multi-day work.

**Approach C — Donut / TrOCR via Core ML**: for handwriting specifically. Same shape as B — Core ML conversion + new OCREngine implementation.

For users who care about OCR quality TODAY, **Approach A (MistralOCREngine)** is the recommended path — fully shipped, just needs the API key in Settings → Cloud endpoints.

---

## What works WITHOUT any SPM add

The following ship today and do NOT need any SPM dependency:

- ✅ Apple Speech (`SpeechTranscriber`) — default audio
- ✅ Apple Vision (`VisionOCR`) — default OCR; multi-orientation + language pinning fixed in commit 6d99ce8
- ✅ Ollama discovery + onboarding — discovers every installed model
- ✅ OpenAI / Anthropic / Azure / OpenRouter via `CloudProvider` — real `/chat/completions` + `/embeddings`
- ✅ Mistral OCR cloud (`MistralOCREngine`) — real `/v1/ocr`
- ✅ OpenAI Whisper cloud (`OpenAIWhisperTranscriber`) — real `/v1/audio/transcriptions`

For a quality-first cloud user, none of the SPM additions above are needed. They're the local-first alternative paths.

---

## How to verify after adding a package

Each package above has a matching Atlas swap-in file. After adding the package:

1. **Build the project** — should succeed without any source-level Atlas changes.
2. **Run the corresponding probe**:
    - WhisperKit: ingest an MP3 with `WhisperKitTranscriber` injected; check the KO's `loader` metadata reads `whisperkit` instead of `apple-speech`.
    - MLX: drop a model in `MLXModels/`, restart, check Settings → Your models lists it and `state.modelChoiceAdvice` recommends it.
    - LlamaCpp: pick a `.gguf` via Settings, restart, check the same.
3. **Smoke test runs green** (`SmokeTest.swift`).

If any of these fail, the failure is local to that package's wire-up — Atlas's protocol layer is already verified by the existing test matrix.
