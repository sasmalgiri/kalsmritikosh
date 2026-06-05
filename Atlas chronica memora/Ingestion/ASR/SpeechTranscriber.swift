//
//  SpeechTranscriber.swift
//  Atlas chronica memora
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

public actor SpeechTranscriber {
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
