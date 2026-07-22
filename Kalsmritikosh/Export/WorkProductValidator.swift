//
//  WorkProductValidator.swift
//  Kalsmritikosh
//
//  EXP-002 — validate a composed work product against its blueprint (PER-002) and the
//  claim–evidence contract before it can be exported. Every claim-bearing section must have
//  claims; every material claim must carry at least the blueprint's required evidence; and
//  the export manifest must list every source a claim cites (nothing cited-but-unlisted).
//
//  Pure, deterministic. Round-trip safe: validation depends only on the composed structure,
//  so re-validating an exported package reproduces the same verdict.
//

import Foundation

public struct ComposedClaim: Sendable, Hashable {
    public let text: String
    public let sourceBlockIDs: [UUID]
    public let status: EvidenceStatus
    public nonisolated init(text: String, sourceBlockIDs: [UUID], status: EvidenceStatus) {
        self.text = text; self.sourceBlockIDs = sourceBlockIDs; self.status = status
    }
}

public struct ComposedSection: Sendable, Hashable {
    public let blueprint: BlueprintSection
    public let claims: [ComposedClaim]
    public nonisolated init(blueprint: BlueprintSection, claims: [ComposedClaim]) {
        self.blueprint = blueprint; self.claims = claims
    }
}

public struct ComposedWorkProduct: Sendable, Hashable {
    public let blueprint: WorkProductBlueprint
    public let sections: [ComposedSection]
    /// Source blocks listed in the export manifest.
    public let manifestSourceIDs: Set<UUID>
    public nonisolated init(blueprint: WorkProductBlueprint, sections: [ComposedSection], manifestSourceIDs: Set<UUID>) {
        self.blueprint = blueprint; self.sections = sections; self.manifestSourceIDs = manifestSourceIDs
    }
}

public struct WorkProductValidator: Sendable {
    public nonisolated init() {}

    public enum Violation: Sendable, Hashable {
        case sectionMissingClaims(section: String)
        case claimUnderEvidenced(section: String, claim: String, has: Int, needs: Int)
        case claimUnsupportedStatus(section: String, claim: String, status: String)
        case citedSourceNotInManifest(section: String, claim: String, sourceID: UUID)
    }

    public struct Report: Sendable {
        public let violations: [Violation]
        public var isValid: Bool { violations.isEmpty }
    }

    public nonisolated func validate(_ wp: ComposedWorkProduct) -> Report {
        var v: [Violation] = []
        for section in wp.sections {
            let bp = section.blueprint
            if bp.requiresEvidence && section.claims.isEmpty {
                v.append(.sectionMissingClaims(section: bp.title))
            }
            for claim in section.claims {
                if bp.requiresEvidence {
                    // Material claim must have an assertable status …
                    if !claim.status.isAssertable {
                        v.append(.claimUnsupportedStatus(section: bp.title, claim: claim.text, status: claim.status.rawValue))
                    }
                    // … and at least the blueprint's required evidence count …
                    if claim.sourceBlockIDs.count < bp.minEvidencePerClaim {
                        v.append(.claimUnderEvidenced(section: bp.title, claim: claim.text,
                                                      has: claim.sourceBlockIDs.count, needs: bp.minEvidencePerClaim))
                    }
                    // … and every cited source must be in the manifest.
                    for sid in claim.sourceBlockIDs where !wp.manifestSourceIDs.contains(sid) {
                        v.append(.citedSourceNotInManifest(section: bp.title, claim: claim.text, sourceID: sid))
                    }
                }
            }
        }
        return Report(violations: v)
    }
}
