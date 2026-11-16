//
//  JobResultHandoff+Review.swift
//  Kalsmritikosh
//
//  Owner's implementation plan 2026-11-04, P1-A 3 — a contradiction the person confirmed in the case
//  screen is carried into the chronology or the report the same way a reviewed job-result row is: no
//  retyping, EVERY side's passage as a citation (both of a pair; all of a conflict with three or more sides — owner
//  request 2026-11-16 — each with the source version it was confirmed on), the
//  review state, and an origin stamp naming the decision, with the digest of that decision as recorded.
//  Each citation is verified through the case's one evidence verifier (JobResultHandoff.verifyAll) as it
//  is carried. Only a confirmed item that has not been reopened by a changed document can be carried;
//  the same decision is not carried twice to the same place.
//

import Foundation

public nonisolated enum ReviewedItemHandoffError: Error, Equatable, LocalizedError {
    case notConfirmed
    case reopened
    case noSource

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Only a confirmed contradiction can be carried into the case record. Confirm it first."
        case .reopened: return "A document behind this contradiction changed after it was decided. Review it again before carrying it."
        case .noSource: return "Neither side of this contradiction names a source version in this case."
        }
    }
}

extension JobResultHandoff {

    /// The origin stamp of a carried review decision: which item, which decision.
    public nonisolated static func reviewOrigin(itemKind: DeskItemKind, itemID: String, decisionID: UUID) -> String {
        "review:\(itemKind.rawValue):\(itemID):decision:\(decisionID.uuidString)"
    }

    /// The text carried for a contradiction: its summary as shown (without the check's provenance marker).
    public nonisolated static func reviewText(_ c: Contradiction) -> String {
        guard let p = CaseContradictionFinder.provenance(of: c) else { return c.description }
        return c.description.replacingOccurrences(of: " " + p.marker, with: "")
    }

    /// Every side as a citation (A, B and — owner request 2026-11-16 — every side beyond them of a conflict with three or
    /// more), each pinned to the version it was confirmed on (else its current one, else the version its words were read
    /// from). Every side is treated alike: one whose document is known to resolve no more is left out, as A and B are,
    /// rather than cited on a version the case no longer has (which would mark the whole carried item unverified).
    public nonisolated static func reviewCitations(_ item: CaseContradictionReviewItem) -> [StudioEvidenceRef] {
        let decided = item.status.latest?.sourceVersions ?? [:]
        let readFrom = Dictionary(item.extraSides.compactMap { s in s.sourceVersionID.map { (s.objectID, $0) } }, uniquingKeysWith: { a, _ in a })
        var out: [StudioEvidenceRef] = []
        for (object, quote) in item.allSides {
            guard let object else { continue }
            let version: UUID?
            if let v = decided[object] {
                version = v
            } else if let current = item.currentVersions[object] {
                version = current   // looked up: nil means the document no longer resolves
            } else {
                version = readFrom[object]
            }
            guard let version else { continue }
            out.append(StudioEvidenceRef(sourceVersionID: version, objectID: object, quote: quote))
        }
        return out
    }

    /// SHA-256 of the decision as recorded (id, item, decision, reason, note, versions, who, when).
    public nonisolated static func reviewDigest(_ d: CaseReviewDecisionRecord) -> String {
        CaseFileHash.sha256([d.id.uuidString, d.itemKind.rawValue, d.itemID, d.decision.rawValue, d.reason?.rawValue ?? "",
                             d.note ?? "", CaseReviewDecisionRecord.encodeVersions(d.sourceVersions), d.actor,
                             String(d.decidedAt.timeIntervalSince1970)].joined(separator: "|"))
    }

    private nonisolated static func carriedDecision(_ item: CaseContradictionReviewItem) throws -> (CaseReviewDecisionRecord, [StudioEvidenceRef]) {
        guard let d = item.status.latest, d.decision == .confirmed else { throw ReviewedItemHandoffError.notConfirmed }
        guard !item.status.isReopened else { throw ReviewedItemHandoffError.reopened }
        let refs = reviewCitations(item)
        guard !refs.isEmpty else { throw ReviewedItemHandoffError.noSource }
        return (d, refs)
    }

    /// Add a confirmed contradiction to the case chronology with both passages and the decision's origin.
    @discardableResult
    public nonisolated static func addReviewedToChronology(_ item: CaseContradictionReviewItem, caseFiles: CaseFileService,
                                               actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a reviewed item into the case")
        let (d, refs) = try carriedDecision(item)
        let support = await verifyAll(refs, caseID: d.caseID, caseFiles: caseFiles)
        return try await caseFiles.file.addJournal(caseID: d.caseID, kind: .chronology, text: reviewText(item.contradiction), eventDate: nil,
                                                   evidenceRef: refs.first?.sourceVersionID?.uuidString, quote: refs.first?.quote,
                                                   origin: reviewOrigin(itemKind: d.itemKind, itemID: d.itemID, decisionID: d.id),
                                                   citations: refs, support: support, reviewState: d.decision.rawValue,
                                                   originDigest: reviewDigest(d), actor: actor, at: date)
    }

    /// Select a confirmed contradiction for the final report, with both passages and the decision's origin.
    @discardableResult
    public nonisolated static func addReviewedToReport(_ item: CaseContradictionReviewItem, allegationID: UUID? = nil, caseFiles: CaseFileService,
                                           actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a reviewed item into the case")
        let (d, refs) = try carriedDecision(item)
        let support = await verifyAll(refs, caseID: d.caseID, caseFiles: caseFiles)
        return try await caseFiles.file.addReportItem(caseID: d.caseID, allegationID: allegationID, text: reviewText(item.contradiction),
                                                      quote: refs.first?.quote, evidenceRef: refs.first?.sourceVersionID?.uuidString,
                                                      origin: reviewOrigin(itemKind: d.itemKind, itemID: d.itemID, decisionID: d.id),
                                                      included: true, citations: refs, reviewState: d.decision.rawValue,
                                                      originDigest: reviewDigest(d), support: support, actor: actor, at: date)
    }
}
