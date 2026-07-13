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
/// A timecoded line of transcript produced by an ASR engine (F8). Times are
/// seconds from the start of the media. `confidence` is 0…1 (engine-reported;
/// 0 when unknown). No speaker label here — diarization is not done on-device,
/// so speakers are assigned/renamed by the user downstream.
public struct ASRSegment: Sendable, Hashable {
    public let start: Double
    public let end: Double
    public let text: String
    public let confidence: Double
    public nonisolated init(start: Double, end: Double, text: String, confidence: Double) {
        self.start = start; self.end = end; self.text = text; self.confidence = confidence
    }
}

public protocol AudioTranscribing: Sendable {
    /// Identifier surfaced in logs and KO metadata so the user can
    /// tell which engine transcribed a given file.
    nonisolated var engineID: String { get }
    func transcribe(audioAt url: URL) async throws -> String
    /// F8 — timecoded segments for the transcript workflow. Engines that
    /// cannot produce timings return `[]` (the default), so the UI falls back
    /// to the flat transcript. `SpeechTranscriber` overrides this with real
    /// per-word timings grouped into sentence-level lines.
    func transcribeSegments(audioAt url: URL) async throws -> [ASRSegment]
}

public extension AudioTranscribing {
    func transcribeSegments(audioAt url: URL) async throws -> [ASRSegment] { [] }
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

    /// F8 — timecoded segments. Uses the same on-device recognizer as
    /// `transcribe`, then groups Apple's per-word `SFTranscriptionSegment`s
    /// into sentence-level lines (split on terminal punctuation, a >1.5s gap,
    /// or ~18 words) so each line carries a real start/end for jump-to-time.
    public func transcribeSegments(audioAt url: URL) async throws -> [ASRSegment] {
        #if canImport(Speech)
        try await Self.ensureAuthorized()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError("Speech recognizer unavailable (check language + Apple Intelligence/Dictation availability).")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !PrivacyGate.shared.allowCloudRouting {
            throw ASRError("On-device transcription isn't available for this language and cloud routing is off. Enable 'Allow cloud-routed providers' in Settings, or use a supported language.")
        }
        if #available(macOS 13.0, iOS 16.0, *) { request.addsPunctuation = true }

        let words: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SFTranscriptionSegment], Error>) in
            let gate = ResumeOnce(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resume(throwing: error)
                } else if let result, result.isFinal {
                    gate.resume(returning: result.bestTranscription.segments)
                }
            }
        }
        return Self.groupIntoLines(words)
        #else
        throw ASRError("Speech framework unavailable on this platform.")
        #endif
    }

    #if canImport(Speech)
    /// Merge per-word segments into readable, timecoded lines.
    static func groupIntoLines(_ words: [SFTranscriptionSegment]) -> [ASRSegment] {
        var lines: [ASRSegment] = []
        var bucket: [SFTranscriptionSegment] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let text = bucket.map(\.substring).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { bucket.removeAll(); return }
            let conf = bucket.map { Double($0.confidence) }.reduce(0, +) / Double(bucket.count)
            lines.append(ASRSegment(
                start: first.timestamp,
                end: last.timestamp + last.duration,
                text: text,
                confidence: conf
            ))
            bucket.removeAll()
        }

        for (i, w) in words.enumerated() {
            if let prev = bucket.last {
                let gap = w.timestamp - (prev.timestamp + prev.duration)
                if gap > 1.5 { flush() }
            }
            bucket.append(w)
            let endsSentence = w.substring.hasSuffix(".") || w.substring.hasSuffix("?") || w.substring.hasSuffix("!")
            if endsSentence || bucket.count >= 18 || i == words.count - 1 { flush() }
        }
        flush()
        return lines
    }

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
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let continuation: CheckedContinuation<T, Error>
        private var resumed = false
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }
        func resume(returning value: T) {
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
