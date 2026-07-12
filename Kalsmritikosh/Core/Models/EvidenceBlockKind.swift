//
//  EvidenceBlockKind.swift
//  Kalsmritikosh
//
//  A1 (spec §6.1) — the type of a persisted structural evidence block. The
//  parser layer classifies each atomic unit of a file into one of these so the
//  ledger keeps a heading distinct from body text, an email header distinct
//  from its body, a spreadsheet cell distinct from prose, etc. This is what the
//  current flatten-to-`KnowledgeObject.content` pipeline throws away.
//

import Foundation

public nonisolated enum EvidenceBlockKind: String, Codable, Sendable, Hashable, CaseIterable {
    case documentTitle
    case documentHeader
    case sectionHeading
    case paragraph
    case listItem
    case quote
    case codeBlock
    case table
    case tableRow
    case tableCell
    case image
    case figureCaption
    case pageHeader
    case pageFooter
    case footnote
    case endnote
    case emailHeader
    case emailBody
    case quotedEmail
    case emailSignature
    case emailDisclaimer
    case attachment
    case slideTitle
    case slideBody
    case slideNotes
    case spreadsheetSheet
    case spreadsheetRow
    case spreadsheetCell
    case transcriptSegment
    case logRecord
    case archiveMember
    case unknown

    /// Repeated page furniture / boilerplate that must be preserved but
    /// down-ranked as evidence (A1 §6.5) — never treated as event/entity proof.
    public var isBoilerplate: Bool {
        switch self {
        case .pageHeader, .pageFooter, .emailSignature, .emailDisclaimer:
            return true
        default:
            return false
        }
    }

    /// A block a chunk may NOT span across (A1 §6.5 / P3.0k) — crossing these
    /// boundaries mixes evidence from independent sources.
    public var isHardChunkBoundary: Bool {
        switch self {
        case .emailBody, .quotedEmail, .attachment, .slideBody, .slideTitle,
             .table, .tableRow, .transcriptSegment, .archiveMember:
            return true
        default:
            return false
        }
    }
}
