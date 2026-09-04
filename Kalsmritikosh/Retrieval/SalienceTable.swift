//
//  SalienceTable.swift
//  Kalsmritikosh
//
//  S2-U1 (D-17 Part B) — structural salience as DATA. How strongly a chunk's
//  structural position says "this is what the document is about": an email's
//  subject line outranks its quoted tail; an invoice's table row outranks its
//  signature block. The table is a plain value map so a weight change is a
//  reviewable diff, never a code change.
//
//  Laws (D-17):
//  - Range [0, 1]; 0.6 is the NEUTRAL prior (matches the v124 column default) —
//    unknown kinds, missing kinds, and unclassified documents all land there,
//    so salience can only differentiate where structure is actually known.
//  - Presentation-and-ranking only. Nothing is dropped or hidden for scoring
//    low; low-salience chunks stay FTS- and citation-searchable untouched.
//  - Consumers are BOUNDED: rerank multiplies by (0.85 + 0.3 × s) — ±15%,
//    never overriding semantic relevance; confidence takes it as an advisory
//    component; slot ranking uses it only after tier + source-class.
//

import Foundation

public enum SalienceTable {

    /// The neutral prior — also the v124 column default for legacy rows.
    public nonisolated static let neutral: Double = 0.6

    /// Salience for a chunk given its block kind and the document's class.
    /// Order of resolution: class-specific override → base kind weight → neutral.
    public nonisolated static func salience(
        forBlockKind rawKind: String?,
        documentClass: DocumentClass?
    ) -> Double {
        guard let raw = rawKind, let kind = EvidenceBlockKind(rawValue: raw) else { return neutral }
        if let docClass = documentClass,
           let override_ = classOverrides[docClass]?[kind] {
            return override_
        }
        return baseWeights[kind] ?? neutral
    }

    // MARK: - The weight table (data, not code)

    /// Base structural weights, class-independent. Anchored at three points:
    /// identity-bearing structure (titles, headers, table rows) high; running
    /// prose neutral; boilerplate (footers, signatures, disclaimers) low.
    static let baseWeights: [EvidenceBlockKind: Double] = [
        .documentTitle:     0.95,
        .documentHeader:    0.9,
        .sectionHeading:    0.8,
        .emailHeader:       0.9,
        .table:             0.85,
        .tableRow:          0.85,
        .tableCell:         0.8,
        .spreadsheetSheet:  0.8,
        .spreadsheetRow:    0.85,
        .spreadsheetCell:   0.8,
        .slideTitle:        0.85,
        .figureCaption:     0.7,
        .listItem:          0.65,
        .paragraph:         neutral,
        .emailBody:         neutral,
        .slideBody:         neutral,
        .transcriptSegment: neutral,
        .logRecord:         neutral,
        .quote:             0.5,
        .codeBlock:         0.5,
        .footnote:          0.45,
        .endnote:           0.45,
        .attachment:        0.5,
        .slideNotes:        0.5,
        .archiveMember:     0.5,
        .image:             0.5,
        .quotedEmail:       0.35,
        .pageHeader:        0.3,
        .pageFooter:        0.3,
        .emailSignature:    0.3,
        .emailDisclaimer:   0.25,
        .unknown:           neutral,
    ]

    /// Class-specific overrides — only where the class genuinely changes what a
    /// structure means. Kept deliberately small; every row needs a reason.
    static let classOverrides: [DocumentClass: [EvidenceBlockKind: Double]] = [
        // In email, the header (subject/from/date) IS the document's identity,
        // and the quoted tail is someone else's document.
        .email: [
            .emailHeader: 0.95,
            .quotedEmail: 0.3,
        ],
        // In invoices/receipts the line-item table IS the content.
        .invoice: [
            .table:    0.95,
            .tableRow: 0.95,
        ],
        .receipt: [
            .table:    0.95,
            .tableRow: 0.95,
        ],
        // Legal documents and certificates carry their identity in titles and
        // headers ("LETTER OF GRANT", form numbers) — V4's class gating taught
        // us their structure reads differently from commercial paper.
        .legalDocument: [
            .documentTitle:  1.0,
            .documentHeader: 0.95,
        ],
        .certificate: [
            .documentTitle:  1.0,
            .documentHeader: 0.95,
        ],
        // A résumé's section headings ("Experience", "Skills") are navigation,
        // not answers — the owner's live archive proved résumé structure leaks
        // into unrelated asks; keep its skeleton neutral, not privileged.
        .resume: [
            .sectionHeading: neutral,
            .documentTitle:  0.7,
        ],
    ]
}
