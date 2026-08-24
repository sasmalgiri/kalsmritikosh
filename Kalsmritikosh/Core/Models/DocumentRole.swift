//
//  DocumentRole.swift
//  Kalsmritikosh
//
//  SEM-001 — a document's semantic ROLE is independent of its file TYPE. A `.jpg` may be a
//  payment receipt; a `.pdf` may be a résumé, a contract or a patent grant. Retrieval
//  authority (RET-003) and answer honesty depend on the ROLE, not the extension.
//
//  This is the canonical role vocabulary. The coarser `PreferredSourceRole` used by the
//  fitness scorer is derived from it (mapping below), so the two stay reconciled and the
//  scorer keeps its behavior while the ledger gains a precise role.
//
//  Classification here is deterministic and signal-based (filename / source type / fields
//  present) — a reusable bridge until domain packs (SEM-004…008) refine it. Absence of a
//  pack still yields a usable role (`.generic`), never a crash or a dropped source.
//

import Foundation

public enum DocumentRole: String, Codable, Sendable, Hashable, CaseIterable {
    case resume            // CV / biographical profile
    case paymentReceipt    // receipt / transaction confirmation
    case invoice           // invoice / bill
    case bankStatement     // account statement
    case contract          // contract / agreement / NDA / MoU
    case patentGrant       // patent grant / official filing
    case certificate       // certificate / registration / licence
    case correspondence    // email / letter / message (context, rarely primary authority)
    case report            // report / article / study
    case identityDocument  // ID / passport / licence card
    case spreadsheetData   // tabular data
    case presentation      // slides
    case generic           // no strong signal

    /// The coarse retrieval-authority bucket the fitness scorer consumes.
    public nonisolated var preferredSourceRole: PreferredSourceRole {
        switch self {
        case .resume:                         return .biographical
        case .paymentReceipt, .invoice, .bankStatement: return .transactional
        case .contract:                       return .contractual
        case .patentGrant, .certificate:      return .official
        case .correspondence:                 return .correspondence
        case .report, .presentation:          return .report
        case .identityDocument:               return .identityDocument
        case .spreadsheetData, .generic:      return .any
        }
    }
}

/// Deterministic role classifier from general signals. Returns the roles a document reads
/// as (a document may satisfy more than one), most-specific first.
public enum DocumentRoleClassifier {

    public nonisolated static func classify(
        fileName: String,
        sourceType: SourceType,
        presentFields: Set<RequestedField>
    ) -> [DocumentRole] {
        // Source role is the document TYPE, not quoted content: the email family is always
        // correspondence (a whole-mailbox KO quotes everything but is not those documents).
        switch sourceType {
        case .mbox, .eml, .appleMail, .pst, .msg, .nsf, .imessage, .chatExport:
            return [.correspondence]
        default:
            break
        }

        let n = fileName.lowercased()
        var roles: [DocumentRole] = []
        func add(_ r: DocumentRole) { if !roles.contains(r) { roles.append(r) } }

        // Filename signals
        if n.contains("resume") || n.contains("cv") || n.contains("curriculum") || n.contains("bio") { add(.resume) }
        if n.contains("receipt") || n.contains("transaction") || n.contains("payment") { add(.paymentReceipt) }
        if n.contains("invoice") || n.contains("bill") { add(.invoice) }
        if n.contains("statement") { add(.bankStatement) }
        if n.contains("contract") || n.contains("agreement") || n.contains("nda") || n.contains("mou") || n.contains("terms") { add(.contract) }
        if n.contains("patent") { add(.patentGrant) }
        if n.contains("certificate") || n.contains("grant") || n.contains("registration") || n.contains("licen") { add(.certificate) }
        if n.contains("report") || n.contains("study") || n.contains("article") || n.contains("paper") { add(.report) }

        // Content-field signals
        if presentFields.contains(.monetaryAmount) && presentFields.contains(.counterparty) { add(.paymentReceipt) }
        if presentFields.contains(.employment) { add(.resume) }
        if presentFields.contains(.terms) { add(.contract) }

        // Source-type fallbacks
        switch sourceType {
        case .xlsx, .xls, .csv, .ods: add(.spreadsheetData)
        case .pptx, .ppt, .keynote:   add(.presentation)
        default: break
        }

        if roles.isEmpty { add(.generic) }
        return roles
    }
}
