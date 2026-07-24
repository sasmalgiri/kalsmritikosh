//
//  WorkProductReceiptBuilder.swift
//  Kalsmritikosh
//
//  PA-REC-001 — builds a tamper-evident SealedReceipt from an already-assembled, validated, and
//  custody-hash-enriched WorkProduct. It performs NO repository reads and NO independent
//  reconstruction: WorkspacesView only assembles → builds → writes.
//
//  A Verifiable receipt is advertised as pinned to each source's exact custody SHA-256, so it
//  fails CLOSED: if any MATERIAL cited Claim has a reopenable citation with no recorded
//  source-version hash, the receipt is refused before anything is written. Inference / conflict /
//  gap disclosure rows (non-assertive) never trigger this.
//

import Foundation

public enum WorkProductReceiptError: Error, Equatable {
    /// N distinct cited source versions on material claims have no recorded custody hash.
    case missingCustodyHashes(count: Int)
}

public struct WorkProductReceiptBuilder {
    public nonisolated init() {}

    public func build(from assembled: AssembledWorkProduct) throws -> SealedReceipt {
        let wp = assembled.workProduct

        // Fail-closed: every reopenable citation on a MATERIAL claim must carry an exact
        // source-version custody hash. Count DISTINCT unhashed versions for the message.
        var missingVersions = Set<UUID>()
        for section in wp.sections {
            for claim in section.claims where Self.isMaterial(claim) {
                for c in claim.supporting where c.sourceVersionID != nil && c.sourceHash == nil {
                    missingVersions.insert(c.sourceVersionID!)
                }
            }
        }
        guard missingVersions.isEmpty else {
            throw WorkProductReceiptError.missingCustodyHashes(count: missingVersions.count)
        }

        // Each rendered claim → a sealed entry pinned to its cited source(s) + custody hash.
        var drafts: [ReceiptDraft] = []
        for section in wp.sections {
            for claim in section.claims {
                let cites = claim.supporting
                let source = cites.first.map {
                    $0.effectiveLocator.isEmpty ? $0.sourceTitle : "\($0.sourceTitle) — \($0.effectiveLocator)"
                } ?? "(no source)"
                let pinned = cites.map { c -> String in
                    let loc = c.effectiveLocator.isEmpty ? "" : " \(c.effectiveLocator)"
                    let h = c.sourceHash.map { " sha256:\($0)" } ?? " (unresolved)"
                    return "\(c.sourceTitle)\(loc)\(h)"
                }.joined(separator: "; ")
                let passage = "[\(claim.status.displayName)] " + (pinned.isEmpty ? "no citation" : pinned)
                drafts.append(ReceiptDraft(claim: claim.text, source: source, date: cites.first?.date, passage: passage))
            }
        }
        return VerifiableReceipt.seal(title: wp.title, drafts: drafts)
    }

    /// A claim whose decision (or, for legacy rows, status) makes it an assertive/material claim
    /// requiring reopenable, custody-pinned evidence. Inference / human notes / uncited
    /// disclosures are not material.
    static func isMaterial(_ claim: WorkProductClaim) -> Bool {
        if let decision = claim.assertabilityDecision { return decision.isAssertiveDecision }
        switch claim.status {
        case .directEvidence, .sourceAssertion, .deterministicDerivation:
            return !claim.supporting.isEmpty
        case .inference, .humanNote:
            return false
        }
    }
}
