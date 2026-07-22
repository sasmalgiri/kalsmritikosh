//
//  WorkProductBlueprint.swift
//  Kalsmritikosh
//
//  PER-002 — a registry of versioned work-product blueprints. A blueprint declares the
//  SECTIONS of an output (chronology, memo, exhibits, dossier…) and, for each, what evidence
//  it requires. Personas select blueprints; the composer builds from the blueprint. This
//  replaces any hard-coded per-persona template switch with data, so new outputs are added
//  by registering a blueprint, not by branching code.
//
//  Every section that makes claims must require evidence — a section can't ship unbacked
//  assertions (claim–evidence contract). Pure value types.
//

import Foundation

public struct BlueprintSection: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let kind: Kind
    /// Does this section assert material claims (and therefore require evidence)?
    public let requiresEvidence: Bool
    /// Minimum distinct evidence items a claim in this section needs.
    public let minEvidencePerClaim: Int

    public enum Kind: String, Codable, Sendable, Hashable {
        case narrative, chronology, matrix, exhibitList, relationships,
             transactions, bibliography, summary, gapsAndConflicts, deadlines
    }

    public nonisolated init(id: UUID = UUID(), title: String, kind: Kind,
                            requiresEvidence: Bool = true, minEvidencePerClaim: Int = 1) {
        self.id = id; self.title = title; self.kind = kind
        self.requiresEvidence = requiresEvidence; self.minEvidencePerClaim = minEvidencePerClaim
    }
}

public struct WorkProductBlueprint: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let persona: WorkspaceTemplate
    public let version: Int
    public let sections: [BlueprintSection]

    public nonisolated init(id: UUID = UUID(), name: String, persona: WorkspaceTemplate,
                            version: Int = 1, sections: [BlueprintSection]) {
        self.id = id; self.name = name; self.persona = persona
        self.version = version; self.sections = sections
    }

    /// Sound only if every claim-bearing section requires evidence.
    public var isSound: Bool {
        sections.allSatisfy { !$0.requiresEvidence || $0.minEvidencePerClaim >= 1 }
    }
}

public enum WorkProductBlueprintRegistry {
    public nonisolated static let version = 1

    /// Default blueprints per persona (data, not a code switch on output type).
    public nonisolated static func blueprints(for persona: WorkspaceTemplate) -> [WorkProductBlueprint] {
        switch persona {
        case .legalMatter:
            return [WorkProductBlueprint(name: "Chronology & Memo", persona: persona, version: version, sections: [
                BlueprintSection(title: "Chronology", kind: .chronology, minEvidencePerClaim: 1),
                BlueprintSection(title: "Legal Memo", kind: .narrative, minEvidencePerClaim: 2),
                BlueprintSection(title: "Exhibits", kind: .exhibitList),
                BlueprintSection(title: "Conflicts & Gaps", kind: .gapsAndConflicts, requiresEvidence: false)])]
        case .investigation:
            return [WorkProductBlueprint(name: "Dossier", persona: persona, version: version, sections: [
                BlueprintSection(title: "Subject Dossier", kind: .narrative, minEvidencePerClaim: 2),
                BlueprintSection(title: "Relationships", kind: .relationships),
                BlueprintSection(title: "Transactions", kind: .transactions),
                BlueprintSection(title: "Gaps", kind: .gapsAndConflicts, requiresEvidence: false)])]
        case .journalism:
            return [WorkProductBlueprint(name: "Story Brief", persona: persona, version: version, sections: [
                BlueprintSection(title: "Claims & Sources", kind: .matrix, minEvidencePerClaim: 2),
                BlueprintSection(title: "Narrative", kind: .narrative, minEvidencePerClaim: 2),
                BlueprintSection(title: "Right-of-Reply Checklist", kind: .summary, requiresEvidence: false)])]
        case .researchReview:
            return [WorkProductBlueprint(name: "Literature Review", persona: persona, version: version, sections: [
                BlueprintSection(title: "Findings Matrix", kind: .matrix),
                BlueprintSection(title: "Reconstruction", kind: .chronology),
                BlueprintSection(title: "Bibliography", kind: .bibliography)])]
        case .personalMatter:
            return [WorkProductBlueprint(name: "Personal Summary", persona: persona, version: version, sections: [
                BlueprintSection(title: "Summary", kind: .summary, minEvidencePerClaim: 1),
                BlueprintSection(title: "Deadlines", kind: .deadlines),
                BlueprintSection(title: "Redacted Pack", kind: .exhibitList, requiresEvidence: false)])]
        case .general:
            return [WorkProductBlueprint(name: "Summary Report", persona: persona, version: version, sections: [
                BlueprintSection(title: "Summary", kind: .summary),
                BlueprintSection(title: "Timeline", kind: .chronology)])]
        }
    }
}
