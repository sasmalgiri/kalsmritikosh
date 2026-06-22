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
    var id: String { get }

    /// Does this environment recognize the KnowledgeObject?
    /// Implementations are expected to inspect `object.sourceType`
    /// first and optionally peek at metadata for sub-type detection
    /// (e.g. PDFEnvironment may further split into invoice vs contract).
    func recognizes(_ object: KnowledgeObject) -> Bool

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
    public let id = "env.base"
    public init() {}
    public func recognizes(_ object: KnowledgeObject) -> Bool { true }
}

/// First real environment — Email (RFC 5322 / .eml / .mbox).
///
/// Lifts EmailLoader-populated structural metadata (subject, thread id
/// via X-GM-THRID, in-reply-to) into a unified shape so downstream
/// retrieval layers can ask "give me everything in this thread" without
/// re-parsing the raw text. No chunker or extraction-prompt changes
/// yet — those can be added in a follow-on commit.
public struct EmailDocumentEnvironment: DocumentEnvironment {
    public let id = "env.email.rfc5322"
    public init() {}

    public func recognizes(_ object: KnowledgeObject) -> Bool {
        object.sourceType.category == .email
    }

    public func extractStructuralMetadata(
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
