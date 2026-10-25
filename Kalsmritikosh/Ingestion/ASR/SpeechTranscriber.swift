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

public extension ASRSegment {
    /// Format a second offset as `[mm:ss]`, or `[h:mm:ss]` past one hour, so the
    /// marker reads naturally at the head of a transcript line.
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "[%d:%02d:%02d]", h, m, s)
            : String(format: "[%02d:%02d]", m, s)
    }
}

public extension Array where Element == ASRSegment {
    /// Render timecoded segments into a transcript where every line is prefixed
    /// with its start marker. Because the marker lives *in the text*, it rides
    /// through chunking, FTS, vectors, and cited answers unchanged — so an answer
    /// drawn from a recording can point at "in recording.m4a at 12:34" without
    /// any schema or retrieval change. Returns "" for an empty transcript.
    func timecodedTranscript() -> String {
        map { "\(ASRSegment.timecode($0.start)) \($0.text)" }
            .joined(separator: "\n")
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

    /// D-1 (completion instructions) — user-facing capability-unavailable
    /// messages, exposed as constants so tests can hold them to the contract:
    /// they name the real remedy (System Settings), and never reference cloud
    /// routing or Apple Intelligence (Speech uses neither).
    public nonisolated static let recognizerUnavailableMessage =
        "Speech recognition isn't available right now. Check that English is installed under System Settings → Keyboard → Dictation, and that Investigations Made Easy is allowed under Privacy & Security → Speech Recognition."
    public nonisolated static let languageAssetsMissingMessage =
        "On-device English (en-US) transcription needs macOS's Dictation language assets, which aren't installed yet. Turn on Dictation in System Settings → Keyboard → Dictation (English), wait for the download, then try again. Nothing is sent off your Mac."

    public init() {}

    public func transcribe(audioAt url: URL) async throws -> String {
        #if canImport(Speech)
        // 1. Permission — REQUIRED before any recognition. Without the
        //    Info.plist usage string this call would trap, so the key must
        //    be present (see NSSpeechRecognitionUsageDescription).
        try await Self.ensureAuthorized()

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError(Self.recognizerUnavailableMessage)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // 2. Privacy-first (U-0): audio stays ON DEVICE in every build —
        //    there is no cloud fallback. Without on-device recognition the
        //    remedy is the Dictation language assets, so say exactly that.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            throw ASRError(Self.languageAssetsMissingMessage)
        }
        if #available(macOS 13.0, iOS 16.0, *) {
            request.addsPunctuation = true
        }

        // 3. Every utterance, not just the first final one (see `recognizeAll`).
        return Self.groupIntoLines(try await Self.recognizeAll(recognizer, request)).map(\.text).joined(separator: " ")
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
            throw ASRError(Self.recognizerUnavailableMessage)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            // U-0: no cloud fallback exists in any build.
            throw ASRError(Self.languageAssetsMissingMessage)
        }
        if #available(macOS 13.0, iOS 16.0, *) { request.addsPunctuation = true }

        return Self.groupIntoLines(try await Self.recognizeAll(recognizer, request))
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
            // Apple splits a clock time into "9:" and "30"; they rejoin without a space.
            var text = ""
            for w in bucket.map(\.substring) {
                if text.isEmpty || (text.hasSuffix(":") && w.first?.isNumber == true) { text += w } else { text += " " + w }
            }
            text = text.trimmingCharacters(in: .whitespaces)
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
            // The word cap never cuts a value in two ("9:" | "30", case bench 2026-10-25).
            let midValue = w.substring.hasSuffix(":") && i + 1 < words.count && words[i + 1].substring.first?.isNumber == true
            if endsSentence || (bucket.count >= 18 && !midValue) || i == words.count - 1 { flush() }
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
    /// Every word of the recording. On-device recognition delivers a long recording as SEVERAL
    /// final results, one per utterance; the old callback kept only the first final result and
    /// dropped the rest (measured 2026-10-25: a three-sentence recording came back as its middle
    /// sentence — 19 of 47 words). The delegate collects each finished utterance and resumes once,
    /// when the whole task has finished.
    static func recognizeAll(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechURLRecognitionRequest) async throws -> [SFTranscriptionSegment] {
        let collector = UtteranceCollector()
        let words: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
            collector.gate = ResumeOnce(continuation)
            collector.task = recognizer.recognitionTask(with: request, delegate: collector)
        }
        return withExtendedLifetime(collector) { words }
    }

    private final class UtteranceCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
        var gate: ResumeOnce<[SFTranscriptionSegment]>?
        var task: SFSpeechRecognitionTask?
        private var words: [SFTranscriptionSegment] = []
        private var seen = Set<String>()
        private let lock = NSLock()

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
            lock.lock(); defer { lock.unlock() }
            // The same word at the same moment can be reported twice; anything else is kept in order.
            for w in result.bestTranscription.segments where seen.insert("\(w.timestamp)|\(w.substring)").inserted {
                words.append(w)
            }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            lock.lock(); let collected = words; lock.unlock()
            if successfully || !collected.isEmpty {
                gate?.resume(returning: collected)
            } else {
                gate?.resume(throwing: task.error ?? ASRError("No speech was recognized in this recording."))
            }
        }
    }

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
