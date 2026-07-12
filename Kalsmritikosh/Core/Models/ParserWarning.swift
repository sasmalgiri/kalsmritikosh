//
//  ParserWarning.swift
//  Kalsmritikosh
//
//  A1 — extraction provenance for a ParsedDocument: HOW a block was obtained,
//  whether extraction fully succeeded, and any non-fatal warnings. These make
//  source health explicit instead of silently degrading (spec §7.7 / P3.7).
//

import Foundation

/// How a block's text was obtained. Preserved on every EvidenceBlock so the UI
/// can distinguish native text from OCR/ASR guesses and surface confidence.
public nonisolated enum ExtractionMethod: String, Codable, Sendable, Hashable {
    case native   // format's own text layer (PDF text, DOCX runs, …)
    case ocr      // Vision OCR of an image/scan
    case vision   // layout/vision model
    case asr      // speech-to-text
    case manual   // user-entered
    case api      // external service
}

/// Whether a source parsed cleanly, partially, or not at all.
public nonisolated enum ExtractionStatus: String, Codable, Sendable, Hashable {
    case complete
    case partial       // some blocks extracted, some failed
    case unsupported   // no parser for this format
    case encrypted
    case corrupt
    case empty
    case deferred      // queued for later (e.g. heavy OCR/ASR)
    case failed
}

public nonisolated struct ParserWarning: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, Hashable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let severity: Severity
    public let code: String        // stable machine code, e.g. "pdf.ocr_low_confidence"
    public let message: String
    /// Block ordinal / locator hint the warning is about, when applicable.
    public let context: String?

    public nonisolated init(
        id: UUID = UUID(),
        severity: Severity = .warning,
        code: String,
        message: String,
        context: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.context = context
    }
}
