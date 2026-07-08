//
//  WhisperKitTranscriber.swift
//  Kalsmritikosh
//
//  Drop-in replacement for SpeechTranscriber that delegates to
//  Argmax's WhisperKit Swift package — Apple Silicon-optimized Whisper
//  inference via Core ML + Neural Engine.
//
//  Why this exists: SpeechTranscriber (Apple Speech) is mid-tier on
//  English and weaker on multilingual / accented audio. WhisperKit
//  Large v3 gives 99-language coverage at sub-5% English WER with
//  100-300ms latency on M-series chips. The G2-3 lane scheduler
//  routes this to the .neuralEngine lane same as Apple Speech, so
//  AudioLoader / VideoLoader pick it up without further changes —
//  just inject `WhisperKitTranscriber()` instead of the default.
//
//  Wiring it requires:
//    1. Add WhisperKit via Swift Package Manager:
//         File → Add Packages…
//         https://github.com/argmaxinc/WhisperKit
//    2. Remove the `WHISPERKIT_AVAILABLE` guard below (or set the
//       compilation condition via the target's "Active Compilation
//       Conditions" build setting).
//    3. Optionally pre-download a model: WhisperKit downloads on
//       first transcribe; for offline boot, ship "openai_whisper-large-v3"
//       in Resources/.
//    4. Inject in AppState wherever AudioLoader / VideoLoader are
//       constructed:
//         AudioLoader(transcriber: WhisperKitTranscriber())
//
//  Until step 1 is done, this file ships as a stub that conforms to
//  the protocol but throws on transcribe — the existence of the type
//  lets the operator pick it from a future Settings dropdown (and
//  the protocol exists so the swap is a one-line change).
//

import Foundation
import OSLog

#if WHISPERKIT_AVAILABLE
import WhisperKit
#endif

public actor WhisperKitTranscriber: AudioTranscribing {
    public nonisolated let engineID = "whisperkit"

    /// Model variant to load on first transcribe. WhisperKit's
    /// `WhisperKit` initializer accepts model names from the Hugging
    /// Face MLX hub. Defaults to large-v3 (best quality);
    /// "openai_whisper-tiny" / "openai_whisper-base" / "openai_whisper-small"
    /// / "openai_whisper-medium" available for lower-RAM devices.
    private let modelVariant: String

    #if WHISPERKIT_AVAILABLE
    private var whisper: WhisperKit?
    #endif

    public init(modelVariant: String = "openai_whisper-large-v3") {
        self.modelVariant = modelVariant
    }

    public func transcribe(audioAt url: URL) async throws -> String {
        #if WHISPERKIT_AVAILABLE
        if whisper == nil {
            KalsmritikoshLog.knowledge.info("WhisperKit: loading model \(self.modelVariant, privacy: .public)")
            whisper = try await WhisperKit(model: modelVariant)
        }
        guard let whisper else {
            throw NSError(
                domain: "kalsmritikosh.asr.whisperkit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WhisperKit failed to load model."]
            )
        }
        let results = try await whisper.transcribe(audioPath: url.path)
        // WhisperKit returns one TranscriptionResult per audio chunk;
        // concatenate `text` to get the full transcript.
        return results.map(\.text).joined(separator: " ")
        #else
        throw NSError(
            domain: "kalsmritikosh.asr.whisperkit",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: """
                WhisperKit is not wired. Add the package via File → Add Packages…
                https://github.com/argmaxinc/WhisperKit
                then set WHISPERKIT_AVAILABLE in the target's Active Compilation
                Conditions, and inject WhisperKitTranscriber() into AudioLoader /
                VideoLoader instead of the default SpeechTranscriber.
                """]
        )
        #endif
    }
}
