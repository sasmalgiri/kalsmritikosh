//
//  InvestigationWorkspaceIntake.swift
//  Kalsmritikosh
//
//  A case opened over a workspace takes in that workspace's documents — and the attachments and
//  archive members inside them — as in-scope sources, each inclusion recorded in the case's audit.
//
//  FOUND BY THE CASE BENCH, 2026-10-20 (AI-1000, investigation workflow). The case engine only
//  answers from sources included in the case, but nothing in the app ever included one: a case
//  created from the persona job screen had zero authorized sources, so its questions had nothing
//  to answer from and its findings report was empty. And an included email or ZIP authorized only
//  the container itself, never the PDF attached to it.
//
//  Inclusion stays explicit and auditable: this runs when a case is opened over a workspace, and
//  later through the person's explicit "Review new documents" (investigator workflow review
//  2026-10-30, I1): `preview` shows what is new — each version, what it is inside, and what stays
//  excluded — and `include` authorises only what they approve. Reopening a matter never includes
//  anything. Every source authorised is a recorded `includeSource` with a note saying why; a
//  deliberately excluded source is never re-included; an inclusion bumps the case revision, so every
//  approval bound to the earlier scope fingerprint (findings) is stale from then on.
//

import Foundation

/// One source version the case's workspace holds that the case has not decided on yet.
public nonisolated struct PendingCaseSource: Sendable, Hashable, Identifiable {
    public var id: UUID { sourceVersionID }
    public let sourceVersionID: UUID
    /// The file name it was read from.
    public let label: String
    /// Added to the workspace directly (true) or found inside a workspace document (false).
    public let isRoot: Bool
    /// The containing version when `isRoot` is false.
    public let parentVersionID: UUID?
    public let parentLabel: String?
}

/// A source the case has deliberately excluded; it stays excluded through any inclusion.
public nonisolated struct ExcludedCaseSource: Sendable, Hashable, Identifiable {
    public var id: String { sourceRef }
    public let sourceRef: String
    public let label: String
    public let note: String?
}

/// What approving an inclusion would do — shown before anything is authorised.
public nonisolated struct CaseInclusionPreview: Sendable, Equatable, Identifiable {
    /// One preview per case revision (a sheet shown for it is for that state).
    public var id: String { "\(caseID.uuidString)@\(caseRevision)" }
    public let caseID: UUID
    public let caseRevision: Int
    /// Sources already in scope.
    public let inScope: Int
    /// New in the workspace, not yet decided — what approval would include.
    public let pending: [PendingCaseSource]
    /// Deliberately excluded; they stay excluded.
    public let excluded: [ExcludedCaseSource]
    public var hasChanges: Bool { !pending.isEmpty }
}

public struct InvestigationWorkspaceIntake: Sendable {
    private let cases: InvestigationCaseRepository
    private let workspaces: WorkspaceRepository
    private let coverage: CaseCoverageRepository

    public init(cases: InvestigationCaseRepository, workspaces: WorkspaceRepository, coverage: CaseCoverageRepository) {
        self.cases = cases; self.workspaces = workspaces; self.coverage = coverage
    }

    /// What the case's workspace holds that the case has not yet decided on, with what stays excluded.
    /// Reads only; authorises nothing.
    public func preview(caseID: UUID) async throws -> CaseInclusionPreview {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        let decided = Set(record.sources.map(\.sourceRef))
        let walk = try await walkWorkspace(record.caseHeader.workspaceID)
        let undecided = walk.filter { !decided.contains($0.version.uuidString) }
        let excludedRefs = record.sources.filter { !$0.inScope }
        let labels = try await coverage.labels(for: undecided.flatMap { [$0.version] + ($0.parent.map { [$0] } ?? []) }
                                               + excludedRefs.compactMap { UUID(uuidString: $0.sourceRef) })
        let pending = undecided.map { item in
            PendingCaseSource(sourceVersionID: item.version, label: labels[item.version] ?? "Source \(item.version.uuidString.prefix(8))",
                              isRoot: item.root, parentVersionID: item.parent,
                              parentLabel: item.parent.flatMap { labels[$0] })
        }
        let excluded = excludedRefs.map { s in
            ExcludedCaseSource(sourceRef: s.sourceRef, label: UUID(uuidString: s.sourceRef).flatMap { labels[$0] } ?? s.sourceRef, note: s.note)
        }
        return CaseInclusionPreview(caseID: caseID, caseRevision: record.caseHeader.revision,
                                    inScope: record.sources.filter(\.inScope).count, pending: pending, excluded: excluded)
    }

    /// Include every current source version of the case's workspace — the files added to it and,
    /// through the source-version graph, everything inside them (archive members, attachments,
    /// mailbox messages, embedded files; the same closure the case coverage manifest uses).
    /// Returns the updated case and how many sources were newly included.
    @discardableResult
    public func includeWorkspaceSources(caseID: UUID, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        try await include(caseID: caseID, approved: nil, actor: actor, at: date)
    }

    /// Include what the person approved: the pending versions in `approved` (nil = every pending one).
    /// A version already decided — included or excluded — is left exactly as it is; a version not
    /// in the workspace's current closure is ignored. Returns the updated case and the count included.
    @discardableResult
    public func include(caseID: UUID, approved: Set<UUID>?, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var current = record.caseHeader
        // Already decided either way (included, or deliberately excluded): left as it is.
        let decided = Set(record.sources.map(\.sourceRef))
        var included = 0
        for item in try await walkWorkspace(current.workspaceID) where !decided.contains(item.version.uuidString) {
            if let approved, !approved.contains(item.version) { continue }
            current = try await cases.includeSource(
                caseID: caseID, expectedRevision: current.revision, sourceRef: item.version.uuidString,
                sourceKind: .sourceVersion,
                note: item.root ? "In the case's workspace" : "Inside a workspace document (attachment, archive member or message)",
                actor: actor, at: date)
            included += 1
        }
        return (current, included)
    }

    /// The workspace's current source versions and everything inside them, in deterministic order,
    /// each once.
    private func walkWorkspace(_ workspaceID: UUID) async throws -> [(version: UUID, root: Bool, parent: UUID?)] {
        var queue: [(version: UUID, root: Bool, parent: UUID?)] = []
        for file in try await workspaces.sourceIDs(in: workspaceID) {
            if let meta = try await coverage.currentVersion(forFileID: file) { queue.append((meta.sourceVersionID, true, nil)) }
        }
        var seen = Set<UUID>()
        var out: [(version: UUID, root: Bool, parent: UUID?)] = []
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard seen.insert(item.version).inserted else { continue }
            out.append(item)
            for child in try await coverage.descendants(of: item.version, relations: CaseCoverageScopeResolver.coverageRelations) {
                queue.append((child.child, false, item.version))
            }
        }
        return out
    }
}
