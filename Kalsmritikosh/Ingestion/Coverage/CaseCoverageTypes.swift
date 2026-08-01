//
//  CaseCoverageTypes.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-007) — the deterministic Case Coverage Manifest. It is a SNAPSHOT reconstructed from
//  the existing authorities (workspace_sources, files/alias_of, source_versions, source_version_relations,
//  source_readiness_*, container_manifests/members) — NOT a second persistent case/source-membership or
//  readiness system. It answers "for this workspace, what sources exist, how far is each processed, and
//  what is NOT admitted (encrypted / blocked / unsupported / failed)" — never as one misleading overall
//  percentage. Readiness vocabulary is reused verbatim (SourceCompletionState / SourceReadinessSnapshot).
//

import Foundation

/// One admitted canonical source reachable from the workspace. `parentPaths` lists the DISTINCT paths
/// by which this exact source version is reached (a source reachable three ways counts once here, with
/// three occurrence paths).
public nonisolated struct CaseCoverageItem: Sendable, Hashable {
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let sourceType: SourceType
    public let isDirectRoot: Bool
    public let parentPaths: [String]
    public let completionState: SourceCompletionState
    public let isSearchReady: Bool
    public let isEvidenceReady: Bool
    public let isAnalyticallyReady: Bool
    public let limitations: [String]
    public let blockers: [String]
    public let custodyMode: String
    public let preservationStatus: String

    public nonisolated init(logicalSourceID: UUID, sourceVersionID: UUID, sourceType: SourceType,
                            isDirectRoot: Bool, parentPaths: [String], completionState: SourceCompletionState,
                            isSearchReady: Bool, isEvidenceReady: Bool, isAnalyticallyReady: Bool,
                            limitations: [String], blockers: [String], custodyMode: String, preservationStatus: String) {
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.sourceType = sourceType
        self.isDirectRoot = isDirectRoot
        self.parentPaths = parentPaths
        self.completionState = completionState
        self.isSearchReady = isSearchReady
        self.isEvidenceReady = isEvidenceReady
        self.isAnalyticallyReady = isAnalyticallyReady
        self.limitations = limitations
        self.blockers = blockers
        self.custodyMode = custodyMode
        self.preservationStatus = preservationStatus
    }
}

/// A container member reachable from the workspace that never became a source (encrypted, blocked by a
/// safety policy, unsupported, or failed). Surfaced so nothing is silently dropped from coverage.
public nonisolated struct UnadmittedContainerMemberItem: Sendable, Hashable {
    public let parentSourceVersionID: UUID
    public let memberID: UUID
    public let memberPath: String
    public let detectedType: SourceType?
    public let disposition: ContainerMemberDisposition
    public let detail: String?

    public nonisolated init(parentSourceVersionID: UUID, memberID: UUID, memberPath: String,
                            detectedType: SourceType?, disposition: ContainerMemberDisposition, detail: String?) {
        self.parentSourceVersionID = parentSourceVersionID
        self.memberID = memberID
        self.memberPath = memberPath
        self.detectedType = detectedType
        self.disposition = disposition
        self.detail = detail
    }
}

/// Explicit COUNTS — deliberately no single overall percentage (USF-002 rejected misleading percentages).
public nonisolated struct CaseCoverageSummary: Sendable, Hashable {
    public let directRoots: Int
    public let canonicalSources: Int
    public let sourceOccurrences: Int
    public let containerMembersDiscovered: Int
    public let containerMembersAdmitted: Int
    public let containerMembersNotAdmitted: Int
    public let searchable: Int
    public let evidenceReady: Int
    public let analyticallyReady: Int
    public let preservedOnly: Int
    public let deferred: Int
    public let encrypted: Int
    public let corrupt: Int
    public let unsupported: Int
    public let failed: Int
    public let safetyBlocked: Int
    public let unavailable: Int
}

/// The deterministic coverage snapshot for one workspace at `generatedAt`.
public nonisolated struct CaseCoverageManifest: Sendable, Hashable {
    public let workspaceID: UUID
    public let workspaceUpdatedAt: Date
    public let generatedAt: Date
    public let directRoots: [CaseCoverageItem]
    public let canonicalSources: [CaseCoverageItem]
    public let unadmittedContainerMembers: [UnadmittedContainerMemberItem]
    public let summary: CaseCoverageSummary
    public let limitations: [String]
    public let blockers: [String]

    public nonisolated init(workspaceID: UUID, workspaceUpdatedAt: Date, generatedAt: Date,
                            directRoots: [CaseCoverageItem], canonicalSources: [CaseCoverageItem],
                            unadmittedContainerMembers: [UnadmittedContainerMemberItem],
                            summary: CaseCoverageSummary, limitations: [String], blockers: [String]) {
        self.workspaceID = workspaceID
        self.workspaceUpdatedAt = workspaceUpdatedAt
        self.generatedAt = generatedAt
        self.directRoots = directRoots
        self.canonicalSources = canonicalSources
        self.unadmittedContainerMembers = unadmittedContainerMembers
        self.summary = summary
        self.limitations = limitations
        self.blockers = blockers
    }
}

public nonisolated enum CaseCoverageError: Error, Sendable, Equatable {
    case workspaceNotFound(UUID)
}
