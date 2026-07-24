//
//  WorkProduct.swift
//  Kalsmritikosh
//
//  Persona features Epic 3 (F4). The output model for the evidence-backed
//  work-product composer (§9.2). Every factual claim carries an epistemic
//  status label (§9.5) and its supporting / contradicting evidence, so a
//  reader can always tell direct evidence from inference from a human note.
//  Nothing here generates unsupported allegations, professional conclusions,
//  admissibility claims, diagnosis, or tax advice — the composer only labels
//  and organizes what the ledger already holds.
//

import Foundation

/// How a claim is grounded (§9.5). Ordered strongest → weakest.
public enum EpistemicStatus: String, Sendable, CaseIterable, Codable {
    case directEvidence
    case sourceAssertion
    case deterministicDerivation
    case inference
    case humanNote

    public var displayName: String {
        switch self {
        case .directEvidence:          return "Direct evidence"
        case .sourceAssertion:         return "Source assertion"
        case .deterministicDerivation: return "Deterministic derivation"
        case .inference:               return "Inference"
        case .humanNote:               return "Human note"
        }
    }
}

/// The four v1 report shapes (§9.4).
public enum WorkProductTemplate: String, Sendable, CaseIterable, Codable {
    case generalSummary
    case chronology
    case investigationFindings
    case factMemo

    public var displayName: String {
        switch self {
        case .generalSummary:        return "General sourced summary"
        case .chronology:            return "Chronology report"
        case .investigationFindings: return "Investigation findings report"
        case .factMemo:              return "Fact memo"
        }
    }
}

public struct WorkProductClaim: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    /// Output-occurrence identity: distinct per rendered row. The SAME canonical Claim can
    /// appear as more than one occurrence (e.g. in both the summary and the chronology), so
    /// this is NOT the canonical Claim id — `sourceClaimID` carries that.
    public let id: ID
    public var text: String
    public var status: EpistemicStatus
    public var supporting: [CitationRecord]
    public var contradicting: [CitationRecord]
    public var confidence: Double?
    public var reviewState: String?
    /// The canonical Claim this row was rendered from, when it came through the claim engine.
    /// nil for legacy-composed claims.
    public var sourceClaimID: Claim.ID?
    /// The exact AssertabilityPolicy decision that produced this row, when rendered from a
    /// claim. Lets the production validator gate on the FULL materiality set (derivation and
    /// user-attributed assertions, not just direct/source) rather than the coarse status.
    public var assertabilityDecision: AssertabilityDecision?

    public nonisolated init(
        id: ID = UUID(),
        text: String,
        status: EpistemicStatus,
        supporting: [CitationRecord] = [],
        contradicting: [CitationRecord] = [],
        confidence: Double? = nil,
        reviewState: String? = nil,
        sourceClaimID: Claim.ID? = nil,
        assertabilityDecision: AssertabilityDecision? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.supporting = supporting
        self.contradicting = contradicting
        self.confidence = confidence
        self.reviewState = reviewState
        self.sourceClaimID = sourceClaimID
        self.assertabilityDecision = assertabilityDecision
    }
}

public struct WorkProductSection: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public var title: String
    public var claims: [WorkProductClaim]
    /// Free prose that is not itself a cited claim (scope statements, method
    /// descriptions). Rendered above the claims.
    public var preamble: [String]

    public nonisolated init(id: ID = UUID(), title: String, preamble: [String] = [], claims: [WorkProductClaim] = []) {
        self.id = id
        self.title = title
        self.preamble = preamble
        self.claims = claims
    }
}

public struct WorkProduct: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public var template: WorkProductTemplate
    public var title: String
    public var subtitle: String?
    public var sections: [WorkProductSection]
    /// Optional tabular block (chronology / review table).
    public var table: ExportTable?
    public var disclaimer: String?

    public nonisolated init(
        id: ID = UUID(),
        template: WorkProductTemplate,
        title: String,
        subtitle: String? = nil,
        sections: [WorkProductSection] = [],
        table: ExportTable? = nil,
        disclaimer: String? = nil
    ) {
        self.id = id
        self.template = template
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self.table = table
        self.disclaimer = disclaimer
    }

    /// Every citation referenced by any claim, de-duplicated by id, in order.
    public var allCitations: [CitationRecord] {
        var seen = Set<CitationRecord.ID>()
        var out: [CitationRecord] = []
        for section in sections {
            for claim in section.claims {
                for c in claim.supporting + claim.contradicting where !seen.contains(c.id) {
                    seen.insert(c.id); out.append(c)
                }
            }
        }
        return out
    }
}
