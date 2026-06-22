//
//  DocumentEnvironment.swift
//  Kalsmritikosh
//
//  G2-ENVIRONMENTS — Per-format semantic adapter protocol.
//
//  Loaders (PDFLoader, EmailLoader, SpreadsheetLoader, …) extract raw
//  TEXT. Today, after that, every format walks the same generic
//  enrich → embed → index pipeline. A markdown contract and a CSV
//  transactions table both flow through NLTagger entity extraction
//  and a uniform chunker; neither gets format-specific semantic help.
//
//  A `DocumentEnvironment` is the per-format "expert" that lives in
//  the gap between the loader (bytes → text) and the generic enricher
//  (text → entities/events). It knows:
//    - what the document IS (invoice / contract / receipt / thread)
//    - which fields are structural vs body text
//    - how to chunk it (cells vs sections vs MIME parts)
//    - which entity / event extraction prompts apply
//
//  This file ships the protocol and a no-op `BaseDocumentEnvironment`
//  default. Real per-format implementations (Email / PDF / Spreadsheet
//  / Video) land in follow-on commits. Wiring through IngestCoordinator
//  is a separate commit so this scaffolding can land without behavior
//  change.
//

import Foundation

/// A doc-type-aware adapter that augments the generic ingest pipeline
/// with format-specific knowledge.
///
/// Conformers MUST be pure value types or actors — IngestCoordinator
/// may run multiple environments concurrently across files.
public protocol DocumentEnvironment: Sendable {

    /// Stable id for capability resolution + debugging. e.g.
    /// "env.email.rfc5322", "env.pdf.pdfkit", "env.spreadsheet.xlsx".
    // G2-SWIFT6 — nonisolated so the IngestCoordinator actor can read
    // these declaratively (id for logs, recognizes for dispatch).
    nonisolated var id: String { get }

    /// Does this environment recognize the KnowledgeObject?
    /// Implementations are expected to inspect `object.sourceType`
    /// first and optionally peek at metadata for sub-type detection
    /// (e.g. PDFEnvironment may further split into invoice vs contract).
    nonisolated func recognizes(_ object: KnowledgeObject) -> Bool

    /// Optional structural facts the environment lifts BEFORE generic
    /// entity / event extraction runs. These survive into KO metadata
    /// so downstream layers can read them without re-parsing.
    ///
    /// Examples:
    /// - EmailEnvironment: thread_id, in_reply_to, quoted_region_offsets
    /// - PDFEnvironment: detected_document_class (invoice/contract),
    ///   table_regions, signature_blocks
    /// - SpreadsheetEnvironment: header_row, named_ranges, column_types
    ///
    /// Default no-op preserves the existing pipeline behavior.
    func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable]

    /// Optional override of the generic chunker. Returns `nil` to
    /// accept the default Chunker output, or a tailored list (e.g.
    /// SpreadsheetEnvironment chunks per sheet+section, not arbitrary
    /// 1000-char blocks).
    ///
    /// Returning a non-nil result entirely replaces the generic
    /// Chunker output — implementations are responsible for ordinal
    /// numbering and character-range correctness.
    func chunkOverride(
        for object: KnowledgeObject
    ) async -> [Chunk]?

    /// Optional list of additional prompt hints the format-specific
    /// extractors should use during entity / event extraction. Empty
    /// by default. EmailEnvironment might return ["sender", "recipient",
    /// "thread_topic"]; PDFEnvironment for an invoice might return
    /// ["line_item", "total", "payment_terms"].
    var extractionHints: [String] { get }
}

public extension DocumentEnvironment {
    func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable] { [:] }

    func chunkOverride(
        for object: KnowledgeObject
    ) async -> [Chunk]? { nil }

    var extractionHints: [String] { [] }
}

/// Generic fallback — recognizes everything, contributes nothing.
/// IngestCoordinator falls back to this when no more-specific
/// environment claims the KO. Ensures every code path through the
/// future wiring still works even when no per-format adapter is wired.
public struct BaseDocumentEnvironment: DocumentEnvironment {
    public nonisolated let id = "env.base"
    public nonisolated init() {}
    public nonisolated func recognizes(_ object: KnowledgeObject) -> Bool { true }
}

/// First real environment — Email (RFC 5322 / .eml / .mbox).
///
/// Lifts EmailLoader-populated structural metadata (subject, thread id
/// via X-GM-THRID, in-reply-to) into a unified shape so downstream
/// retrieval layers can ask "give me everything in this thread" without
/// re-parsing the raw text. No chunker or extraction-prompt changes
/// yet — those can be added in a follow-on commit.
public struct EmailDocumentEnvironment: DocumentEnvironment {
    public nonisolated let id = "env.email.rfc5322"
    public nonisolated init() {}

    public nonisolated func recognizes(_ object: KnowledgeObject) -> Bool {
        object.sourceType.category == .email
    }

    public nonisolated func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable] {
        // EmailLoader already populates subject/date/X-GM-THRID. Promote
        // those into a canonical key set the rest of the engine can
        // depend on without knowing the email lineage.
        var out: [String: AnyCodable] = [:]
        if let v = object.metadata["subject"] {
            out["env.email.subject"] = v
        }
        if let v = object.metadata["date"] {
            out["env.email.date"] = v
        }
        if let v = object.metadata["X-GM-THRID"] {
            out["env.email.thread_id"] = v
        }
        if let v = object.metadata["in-reply-to"] {
            out["env.email.in_reply_to"] = v
        }
        return out
    }

    public var extractionHints: [String] {
        ["sender", "recipient", "thread_topic", "subject"]
    }
}

/// PDF environment — recognizes PDF/PPT/DOCX/MD KOs and lifts a
/// detected document-class hint into metadata. Doesn't override the
/// chunker today (the generic Chunker still applies). Future commits
/// can add table-region detection and signature-block tagging.
public struct PDFDocumentEnvironment: DocumentEnvironment {
    public nonisolated let id = "env.pdf.pdfkit"
    public nonisolated init() {}

    public nonisolated func recognizes(_ object: KnowledgeObject) -> Bool {
        let category = object.sourceType.category
        return category == .document || category == .presentation
    }

    public nonisolated func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable] {
        // Light heuristic: classify the doc-shape from content first
        // 1KB. Future: PDFKit tables / images / signatures, mlmodel
        // template classifier. Today's hints feed downstream prompts.
        let preview = String(object.content.prefix(1500)).lowercased()
        var docClass = "unknown"
        if preview.contains("invoice") && (preview.contains("amount") || preview.contains("total")) {
            docClass = "invoice"
        } else if preview.contains("agreement") || preview.contains("party a") || preview.contains("party b") {
            docClass = "contract"
        } else if preview.contains("amendment") {
            docClass = "amendment"
        } else if preview.contains("receipt") {
            docClass = "receipt"
        } else if preview.contains("minutes") || preview.contains("attendees") {
            docClass = "meeting_minutes"
        }
        return [
            "env.pdf.detected_doc_class": AnyCodable(.string(docClass))
        ]
    }

    public var extractionHints: [String] {
        ["title", "date", "parties", "total", "line_items"]
    }
}

/// Spreadsheet environment — recognizes CSV / XLSX / TSV. Provides
/// header-row + column-type hints downstream extraction can use to
/// avoid treating every cell as free text. Chunker override is the
/// future addition; today the generic chunker still applies.
public struct SpreadsheetDocumentEnvironment: DocumentEnvironment {
    public nonisolated let id = "env.spreadsheet.tabular"
    public nonisolated init() {}

    public nonisolated func recognizes(_ object: KnowledgeObject) -> Bool {
        object.sourceType.category == .spreadsheet
    }

    public nonisolated func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable] {
        // First non-empty line is the canonical header row in most
        // CSVs and XLSX-rendered-to-tab-separated layouts (which is
        // what SpreadsheetLoader emits today).
        let firstLine = object.content
            .split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else { return [:] }
        let columns = firstLine
            .components(separatedBy: CharacterSet(charactersIn: ",\t|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !columns.isEmpty else { return [:] }
        return [
            "env.spreadsheet.header_row": AnyCodable(.string(columns.joined(separator: " | "))),
            "env.spreadsheet.column_count": AnyCodable(.int(Int64(columns.count)))
        ]
    }

    public var extractionHints: [String] {
        ["column_header", "row_label", "date", "amount", "category"]
    }
}

/// Video environment — recognizes audio/video KOs. The actual
/// transcription has already happened in the loader (SpeechTranscriber);
/// this env tags the KO so downstream prompts know the body is a
/// transcript and not native prose.
public struct VideoDocumentEnvironment: DocumentEnvironment {
    public nonisolated let id = "env.video.transcript"
    public nonisolated init() {}

    public nonisolated func recognizes(_ object: KnowledgeObject) -> Bool {
        let cat = object.sourceType.category
        return cat == .audio || cat == .video
    }

    public nonisolated func extractStructuralMetadata(
        from object: KnowledgeObject
    ) async -> [String: AnyCodable] {
        [
            "env.transcript.source_kind": AnyCodable(.string(object.sourceType.category.rawValue)),
            "env.transcript.is_transcription": AnyCodable(.bool(true))
        ]
    }

    public var extractionHints: [String] {
        ["speaker", "topic", "duration", "decision", "action_item"]
    }
}
