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

public struct ASRError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public actor SpeechTranscriber: AudioTranscribing {
    public nonisolated let engineID = "apple-speech"

    public init() {}

    public func transcribe(audioAt url: URL) async throws -> String {
        #if canImport(Speech)
        // 1. Permission — REQUIRED before any recognition. Without the
        //    Info.plist usage string this call would trap, so the key must
        //    be present (see NSSpeechRecognitionUsageDescription).
        try await Self.ensureAuthorized()

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError("Speech recognizer unavailable (check language + Apple Intelligence/Dictation availability).")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // 2. Privacy-first: keep audio ON DEVICE. Only fall back to Apple's
        //    servers if the user has explicitly enabled cloud routing.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !PrivacyGate.shared.allowCloudRouting {
            throw ASRError("On-device transcription isn't available for this language and cloud routing is off. Enable 'Allow cloud-routed providers' in Settings, or use a supported language.")
        }
        if #available(macOS 13.0, iOS 16.0, *) {
            request.addsPunctuation = true
        }

        // 3. Bridge the callback API to async, guaranteeing exactly one resume.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = ResumeOnce(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resume(throwing: error)
                } else if let result, result.isFinal {
                    gate.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
        #else
        throw ASRError("Speech framework unavailable on this platform.")
        #endif
    }

    #if canImport(Speech)
    /// Request Speech authorization once; throw a clear error if unavailable.
    private static func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw ASRError("Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition.")
        case .notDetermined:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard status == .authorized else {
                throw ASRError("Speech recognition wasn't authorized.")
            }
        @unknown default:
            throw ASRError("Speech recognition is unavailable.")
        }
    }

    /// Ensures a CheckedContinuation is resumed at most once, from any queue
    /// (SFSpeechRecognitionTask may deliver partials + a final on arbitrary
    /// threads).
    private final class ResumeOnce: @unchecked Sendable {
        private let continuation: CheckedContinuation<String, Error>
        private var resumed = false
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }
        func resume(returning value: String) {
            lock.lock(); defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
        func resume(throwing error: Error) {
            lock.lock(); defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: error)
        }
    }
    #endif
}
