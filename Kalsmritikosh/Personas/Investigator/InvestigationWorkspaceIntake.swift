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
//  Inclusion stays explicit and auditable: this runs when a case is opened over a workspace (and
//  can be re-run to pick up documents added later); every source it authorizes is a recorded
//  `includeSource` with a note saying why. Excluded sources are never re-included.
//

import Foundation

public struct InvestigationWorkspaceIntake: Sendable {
    private let cases: InvestigationCaseRepository
    private let workspaces: WorkspaceRepository
    private let coverage: CaseCoverageRepository

    public init(cases: InvestigationCaseRepository, workspaces: WorkspaceRepository, coverage: CaseCoverageRepository) {
        self.cases = cases; self.workspaces = workspaces; self.coverage = coverage
    }

    /// Include every current source version of the case's workspace — the files added to it and,
    /// through the source-version graph, everything inside them (archive members, attachments,
    /// mailbox messages, embedded files; the same closure the case coverage manifest uses).
    /// Returns the updated case and how many sources were newly included.
    @discardableResult
    public func includeWorkspaceSources(caseID: UUID, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var current = record.caseHeader
        // Already decided either way (included, or deliberately excluded): left as it is.
        let decided = Set(record.sources.map(\.sourceRef))

        var queue: [(version: UUID, root: Bool)] = []
        for file in try await workspaces.sourceIDs(in: current.workspaceID) {
            if let meta = try await coverage.currentVersion(forFileID: file) { queue.append((meta.sourceVersionID, true)) }
        }
        var seen = Set<UUID>()
        var included = 0
        while !queue.isEmpty {
            let (version, root) = queue.removeFirst()
            guard seen.insert(version).inserted else { continue }
            if !decided.contains(version.uuidString) {
                current = try await cases.includeSource(
                    caseID: caseID, expectedRevision: current.revision, sourceRef: version.uuidString,
                    sourceKind: .sourceVersion,
                    note: root ? "In the case's workspace" : "Inside a workspace document (attachment, archive member or message)",
                    actor: actor, at: date)
                included += 1
            }
            for child in try await coverage.descendants(of: version, relations: CaseCoverageScopeResolver.coverageRelations) {
                queue.append((child.child, false))
            }
        }
        return (current, included)
    }
}
