//
//  InvestigationCustodyService.swift
//  Kalsmritikosh
//
//  INV-18 — Evidence vault & custody. Orchestration only: it forks NO custody authority. It REUSES the
//  shared append-only CustodyRepository (chain-of-custody ledger) + the EvidenceStore's exact per-version
//  content hashes, bounded to the active case's authorized source versions. Truth boundaries:
//    • custody is never broken silently — every custody entry is a NEW append-only row in the shared ledger
//      (the repository only ever INSERTs; a hash mismatch is recorded, never overwritten),
//    • the manifest carries the exact custody HASH PER VERSION (from the canonical source-version bytes),
//    • only the case's authorized source versions appear; recording an event for an unauthorized version is
//      refused (the case boundary is the hard evidence boundary).
//

import Foundation

/// One row of the case Evidence/Custody Manifest: an authorized source version, its exact content hash, and
/// the custody chain of the file it belongs to (newest first).
public nonisolated struct CustodyManifestEntry: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let contentHash: String?
    public let custodyEvents: [CustodyEvent]

    public nonisolated init(sourceVersionID: UUID, contentHash: String?, custodyEvents: [CustodyEvent]) {
        self.sourceVersionID = sourceVersionID; self.contentHash = contentHash; self.custodyEvents = custodyEvents
    }
}

public nonisolated enum InvestigationCustodyError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case sourceOutOfScope(UUID)
    case unknownSourceVersion(UUID)   // no such source version row (cannot resolve its file)
    case blankActor
}

public actor InvestigationCustodyService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    private let custody: CustodyRepository
    private let database: Database

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                evidence: EvidenceStore, custody: CustodyRepository, database: Database) {
        self.cases = cases; self.resolver = resolver; self.evidence = evidence; self.custody = custody; self.database = database
    }

    /// The case Evidence/Custody Manifest: one entry per authorized source version, carrying its exact
    /// content hash and the custody chain of the file it belongs to.
    public func manifest(caseID: UUID) async throws -> [CustodyManifestEntry] {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCustodyError.caseNotFound(caseID) }
        let scope = try await resolver.scope(for: record)
        let versions = scope.authorizedSourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        let hashes = try await evidence.contentHashes(forSourceVersionIDs: Set(versions))
        var out: [CustodyManifestEntry] = []
        for v in versions {
            var events: [CustodyEvent] = []
            if let file = try await fileID(forVersion: v) { events = (try? await custody.history(forFile: file)) ?? [] }
            out.append(CustodyManifestEntry(sourceVersionID: v, contentHash: hashes[v], custodyEvents: events))
        }
        return out
    }

    /// Record a custody event for an authorized source version — the human "confirm custody entry" decision.
    /// Appends to the SHARED custody ledger (never overwrites); fails closed if the version is not authorized
    /// for the case or cannot be resolved to a file.
    @discardableResult
    public func recordCustodyEvent(caseID: UUID, sourceVersionID: UUID, kind: CustodyEvent.Kind, detail: String?,
                                   hash: String?, actor: String, at date: Date) async throws -> CustodyEvent {
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationCustodyError.blankActor }
        let scope = try await requireOpenCaseScope(caseID)
        guard scope.authorizedSourceVersionIDs.contains(sourceVersionID) else {
            throw InvestigationCustodyError.sourceOutOfScope(sourceVersionID)
        }
        guard let file = try await fileID(forVersion: sourceVersionID) else {
            throw InvestigationCustodyError.unknownSourceVersion(sourceVersionID)
        }
        let event = CustodyEvent(fileID: file, kind: kind, actor: cleanActor, at: date, detail: detail, hash: hash)
        _ = try await custody.record(event)
        return event
    }

    // MARK: - Internals

    /// The logical file a source version belongs to (source_versions.logical_source_id), read-only.
    private func fileID(forVersion versionID: UUID) async throws -> UUID? {
        try await database.query("SELECT logical_source_id FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(versionID)]).first?.uuid(0)
    }

    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCustodyError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationCustodyError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }
}
