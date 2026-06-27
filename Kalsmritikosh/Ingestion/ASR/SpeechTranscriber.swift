//
//  SpeechTranscriber.swift
//  Kalsmritikosh
//
//  Audio / video transcription via Apple Speech. WhisperKit lands as
//  a swap-in provider once we add it via SPM. The transcriber writes
//  follow-up KnowledgeObjects so the brain treats transcripts like
//  any other source.
//

import Foundation
#if canImport(Speech)
import Speech
#endif

/// Format-specialist abstraction for audio transcription. The current
/// implementation is `SpeechTranscriber` (Apple Speech). Future swap-
/// ins (WhisperKit, Parakeet, Canary) conform to this protocol and
/// AudioLoader / VideoLoader pick them up via constructor injection
/// without any further code change.
///
/// Quality ranking on Apple Silicon (from 2026 benchmarks):
///   1. Parakeet v2 — best English WER, ~80 ms latency
///   2. WhisperKit (Whisper Large v3) — best multilingual (99 langs)
///   3. Apple SpeechAnalyzer (macOS 26) — mid-tier; on-device
///   4. SFSpeechRecognizer (current) — mid-tier; requires online for
///      some languages
public protocol AudioTranscribing: Sendable {
    /// Identifier surfaced in logs and KO metadata so the user can
    /// tell which engine transcribed a given file.
    nonisolated var engineID: String { get }
    func transcribe(audioAt url: URL) async throws -> String
}

public actor SpeechTranscriber: AudioTranscribing {
    public nonisolated let engineID = "apple-speech"

    public init() {}

    public func transcribe(audioAt url: URL) async throws -> String {
        #if canImport(Speech)
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "atlas.asr",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable."]
            )
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        throw NSError(
            domain: "atlas.asr",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Speech framework unavailable on this platform."]
        )
        #endif
    }
}
