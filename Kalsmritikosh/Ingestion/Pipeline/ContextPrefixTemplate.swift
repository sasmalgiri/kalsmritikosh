//
//  ContextPrefixTemplate.swift
//  Kalsmritikosh
//
//  S2-U2 (R-3) — the DETERMINISTIC context prefix: title · class · block
//  kind, rendered identically on every run. This replaces the LLM/heuristic
//  prefix as the producer — the prefix feeds EMBEDDING ONLY (never shown,
//  never FTS-indexed), and an embedding input that changes between runs is
//  a reproducibility hole (§C class 4b's cousin). A model-written sentence
//  can be richer; it cannot be replayed. Determinism wins on an index field.
//
//  Versioned: chunks stamp `context_template_version` so a future template
//  change is a visible era, refreshed by reindex — never a silent drift.
//

import Foundation

public enum ContextPrefixTemplate {

    /// Bump when the rendered SHAPE changes; the shared reindex refreshes
    /// stamped rows whose version is older.
    public nonisolated static let currentVersion = 1

    /// Deterministic prefix: "<title> · <document class> · <block kind>".
    /// Empty/unknown parts are omitted; an all-unknown chunk gets nil
    /// (no prefix beats a meaningless one — single-chunk documents are
    /// already their own context).
    public nonisolated static func render(
        title: String?,
        documentClass: DocumentClass?,
        blockKind: String?
    ) -> String? {
        var parts: [String] = []
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            parts.append(String(t.prefix(120)))
        }
        if let c = documentClass, c != .other {
            parts.append(humanClass(c))
        }
        if let raw = blockKind, let kind = EvidenceBlockKind(rawValue: raw) {
            parts.append(humanKind(kind))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Plain-language class names (RC-8 discipline: no enum jargon in any
    /// string a pipeline writes, even an index-only one).
    nonisolated static func humanClass(_ c: DocumentClass) -> String {
        switch c {
        case .email:         return "email"
        case .invoice:       return "invoice"
        case .contract:      return "contract"
        case .meetingNotes:  return "meeting notes"
        case .researchPaper: return "research paper"
        case .resume:        return "résumé"
        case .receipt:       return "receipt"
        case .image:         return "image"
        case .audio:         return "audio"
        case .video:         return "video"
        case .spreadsheet:   return "spreadsheet"
        case .presentation:  return "presentation"
        case .legalDocument: return "legal document"
        case .certificate:   return "certificate"
        case .other:         return "document"
        }
    }

    nonisolated static func humanKind(_ k: EvidenceBlockKind) -> String {
        switch k {
        case .documentTitle:    return "title"
        case .documentHeader:   return "header"
        case .sectionHeading:   return "section heading"
        case .paragraph:        return "paragraph"
        case .listItem:         return "list item"
        case .quote:            return "quotation"
        case .codeBlock:        return "code"
        case .table, .tableRow, .tableCell: return "table"
        case .image:            return "image"
        case .figureCaption:    return "caption"
        case .pageHeader, .pageFooter: return "page furniture"
        case .footnote, .endnote: return "note"
        case .emailHeader:      return "email header"
        case .emailBody:        return "email body"
        case .quotedEmail:      return "quoted email"
        case .emailSignature:   return "signature"
        case .emailDisclaimer:  return "disclaimer"
        case .attachment:       return "attachment"
        case .slideTitle:       return "slide title"
        case .slideBody:        return "slide"
        case .slideNotes:       return "speaker notes"
        case .spreadsheetSheet, .spreadsheetRow, .spreadsheetCell: return "spreadsheet"
        case .transcriptSegment: return "transcript"
        case .logRecord:        return "log entry"
        case .archiveMember:    return "archive member"
        case .unknown:          return "text"
        }
    }
}
