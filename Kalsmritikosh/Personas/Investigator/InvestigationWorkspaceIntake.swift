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
    private let evidence: EvidenceStore
    private let relations: SourceRelationsRepository

    public init(cases: InvestigationCaseRepository, workspaces: WorkspaceRepository,
                evidence: EvidenceStore, relations: SourceRelationsRepository) {
        self.cases = cases; self.workspaces = workspaces; self.evidence = evidence; self.relations = relations
    }

    /// Include every current source version of the case's workspace — the files added to it and,
    /// recursively, their attachments and archive members. Returns the updated case and how many
    /// sources were newly included.
    @discardableResult
    public func includeWorkspaceSources(caseID: UUID, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var current = record.caseHeader
        // Already decided either way (included, or deliberately excluded): left as it is.
        let decided = Set(record.sources.map(\.sourceRef))

        var queue: [(file: UUID, via: UUID?)] = try await workspaces.sourceIDs(in: current.workspaceID).map { ($0, nil) }
        var seenFiles = Set<UUID>()
        var included = 0
        while !queue.isEmpty {
            let (file, via) = queue.removeFirst()
            guard seenFiles.insert(file).inserted else { continue }
            for object in try await evidence.objectIDs(forFile: file).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let version = try await evidence.currentVersionID(forObject: object),
                      !decided.contains(version.uuidString) else { continue }
                current = try await cases.includeSource(
                    caseID: caseID, expectedRevision: current.revision, sourceRef: version.uuidString,
                    sourceKind: .sourceVersion,
                    note: via == nil ? "In the case's workspace" : "Attachment or member of a workspace document",
                    actor: actor, at: date)
                included += 1
            }
            for child in await relations.children(of: file) {
                queue.append((child.childFileID, file))
            }
        }
        return (current, included)
    }
}
