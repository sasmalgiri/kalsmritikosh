//
//  ExtractionProvenance.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-02 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05) — where a passage's words
//  came from, so an investigator can tell the original wording of a file from text the app recognised, transcribed
//  or generated: the reader and its version, the recognition engine and its version (OCR / speech / layout), the
//  exact source version, the run's coverage, the language, the confidence and when the text was extracted.
//
//  • The kind is decided by how the words were obtained (`ExtractionMethod`), never by the file's type.
//  • The engine identity is recorded when the run is written (schema v178 `parser_runs.engines`); a passage written
//    before v178 names no run of its own, and its provenance says so instead of borrowing a run silently.
//  Nothing here calls a model or the network.
//

import Foundation
import os
#if canImport(Vision)
import Vision
#endif

/// What a piece of text is, as an investigator needs to read it.
public nonisolated enum TextProvenanceKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// The file's own text layer — the original wording.
    case original
    /// Recognised from an image or scan (OCR or layout recognition): a reading of the original, which may differ.
    case recognized
    /// Transcribed from audio or video: a reading of what was said.
    case transcribed
    /// Typed in by a person as the source's content (a manual entry).
    case entered
    /// Produced by an external service.
    case external
    /// The investigator's own statement or summary — not the source's words.
    case interpretation
    /// Produced by the app or an AI reader (a draft, a summary, a description) — not the source's words.
    case generated

    public init(method: ExtractionMethod) {
        switch method {
        case .native: self = .original
        case .ocr, .vision: self = .recognized
        case .asr: self = .transcribed
        case .manual: self = .entered
        case .api: self = .external
        }
    }

    /// The short badge text.
    public var badge: String {
        switch self {
        case .original: return "Original text"
        case .recognized: return "Recognized text (OCR)"
        case .transcribed: return "Transcribed"
        case .entered: return "Typed entry"
        case .external: return "From an external service"
        case .interpretation: return "Investigator's statement"
        case .generated: return "Generated text"
        }
    }

    public var symbol: String {
        switch self {
        case .original: return "doc.text"
        case .recognized: return "text.viewfinder"
        case .transcribed: return "waveform"
        case .entered: return "keyboard"
        case .external: return "network"
        case .interpretation: return "person.text.rectangle"
        case .generated: return "wand.and.stars"
        }
    }

    /// One sentence on what the badge means.
    public var explanation: String {
        switch self {
        case .original: return "The words are the file's own text, as the reader extracted them."
        case .recognized: return "The words were recognised from an image of the page. Recognition can misread characters — check the original image."
        case .transcribed: return "The words were transcribed from a recording. Transcription can mishear words — listen to the original."
        case .entered: return "The words were typed in by a person as the content of this source."
        case .external: return "The words were produced by an external service, not read from the file by this app."
        case .interpretation: return "This is the investigator's own wording of what the source says. It is not a quotation."
        case .generated: return "This text was produced by the app or an AI reader. It is not the source's wording."
        }
    }

    /// The exact words of the original file (not a reading, transcription, statement or generated text).
    public var isOriginalWording: Bool { self == .original }
}

/// The recognition engines a reader run used, with their versions (recorded with the run, schema v178).
public nonisolated enum ExtractionEngineIdentity {

    /// The engine (and its version) that produces text by `method` on this Mac; nil for the file's own text layer
    /// (the reader and its version identify it).
    public static func engine(for method: ExtractionMethod) -> String? {
        let system = osVersion
        switch method {
        case .native: return nil
        case .ocr: return "Apple Vision text recognition, revision \(textRecognitionRevision), macOS \(system)"
        case .vision: return "Apple Vision layout recognition, revision \(textRecognitionRevision), macOS \(system)"
        case .asr: return "Apple Speech recognition, macOS \(system)"
        case .manual: return "Typed in by a person"
        case .api: return "External service (its name and version were not reported to the app)"
        }
    }

    /// method raw value → engine, for the methods given (none for the native text layer).
    public static func engines(for methods: Set<ExtractionMethod>) -> [String: String] {
        var out: [String: String] = [:]
        for m in methods { if let e = engine(for: m) { out[m.rawValue] = e } }
        return out
    }

    /// The engines as the JSON object stored on the run; nil when the run used none.
    public static func enginesJSON(for methods: Set<ExtractionMethod>) -> String? {
        let map = engines(for: methods)
        guard !map.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return String(decoding: try encoder.encode(map), as: UTF8.self) } catch {
            KalsmritikoshLog.storage.error("Extraction engines not encoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func decodeEngines(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        do { return try JSONDecoder().decode([String: String].self, from: data) } catch {
            KalsmritikoshLog.storage.error("Stored extraction engines unreadable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The revision of the text-recognition request the app's OCR creates (a fresh request uses the default revision).
    static var textRecognitionRevision: Int {
        #if canImport(Vision)
        return VNRecognizeTextRequest().revision
        #else
        return 0
        #endif
    }
}

/// The provenance of one passage (or of a document's passages taken together).
public nonisolated struct ExtractionProvenance: Sendable, Hashable {
    public let kind: TextProvenanceKind
    /// How the words were obtained; nil for an interpretation or generated text.
    public let method: ExtractionMethod?
    public let sourceVersionID: UUID?
    public let blockID: UUID?
    /// The reader (parser) that produced the passage, and its version.
    public let reader: String?
    public let readerVersion: String?
    /// The recognition engine and its version (OCR / speech / layout); nil for the file's own text layer.
    public let engine: String?
    /// When the reader run that produced the words ended (else when it started).
    public let extractedAt: Date?
    /// False when the passage predates per-passage run records: the reader shown is the newest run of the version.
    public let runRecordedForPassage: Bool
    public let language: String?
    /// 0…1 confidence in the extracted words (1 for the file's own text layer).
    public let confidence: Double?
    /// The run's coverage of the source ("complete", "partial — some parts were not read", block and page counts).
    public let coverage: String?
    /// For a document taken as a whole: how its passages divide by kind ("3 of 40 passages recognised from images").
    public let mixture: String?

    public init(kind: TextProvenanceKind, method: ExtractionMethod?, sourceVersionID: UUID?, blockID: UUID?, reader: String?, readerVersion: String?,
                engine: String?, extractedAt: Date?, runRecordedForPassage: Bool, language: String?, confidence: Double?, coverage: String?,
                mixture: String? = nil) {
        self.kind = kind; self.method = method; self.sourceVersionID = sourceVersionID; self.blockID = blockID; self.reader = reader
        self.readerVersion = readerVersion; self.engine = engine; self.extractedAt = extractedAt; self.runRecordedForPassage = runRecordedForPassage
        self.language = language; self.confidence = confidence; self.coverage = coverage; self.mixture = mixture
    }

    /// An investigator's statement or summary (or generated text): no reader, no engine — not the source's words.
    public static func statement(_ kind: TextProvenanceKind = .interpretation) -> ExtractionProvenance {
        ExtractionProvenance(kind: kind, method: nil, sourceVersionID: nil, blockID: nil, reader: nil, readerVersion: nil, engine: nil,
                             extractedAt: nil, runRecordedForPassage: true, language: nil, confidence: nil, coverage: nil)
    }

    public var isOriginalWording: Bool { kind.isOriginalWording }

    /// The detail lines an inspector shows under the badge.
    public var lines: [String] {
        var out: [String] = [kind.explanation]
        if let mixture { out.append(mixture) }
        if let reader {
            out.append("Read by \(reader)" + (readerVersion.map { " \($0)" } ?? "")
                       + (runRecordedForPassage ? "" : " (the newest reading of this version — this passage predates per-passage records)"))
        }
        if let engine { out.append("Engine: \(engine)") }
        if let extractedAt { out.append("Extracted \(extractedAt.formatted(date: .abbreviated, time: .shortened))") }
        if let sourceVersionID { out.append("Source version \(sourceVersionID.uuidString.prefix(8))") }
        if let language { out.append("Language: \(language)") }
        if let confidence, kind != .original, method != nil { out.append("Recognition confidence: \(Int((confidence * 100).rounded())) %") }
        if let coverage { out.append("Coverage: \(coverage)") }
        return out
    }
}
