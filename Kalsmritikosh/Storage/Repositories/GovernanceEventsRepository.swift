//
//  GovernanceEventsRepository.swift
//  Kalsmritikosh
//
//  Fifth audit — append-only ledger of governance acts (schema v111): findings
//  approval, approval withdrawal, conformance-assessment recording, and
//  verification-bundle export. Rows are only ever INSERTed; the AUD-CHAIN
//  seals them as a third source alongside custody_events and fact_reviews,
//  so the chain covers governance history, not just evidence handling.
//

import Foundation

public nonisolated enum GovernanceEventKind: String, Sendable, CaseIterable {
    case findingsApproved   = "findings.approved"
    case approvalWithdrawn  = "approval.withdrawn"
    case assessmentRecorded = "assessment.recorded"
    case bundleExported     = "bundle.exported"
}

public actor GovernanceEventsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Append one governance act. `detail` carries the act's stable facts
    /// (run revision, seal signature prefix, export target hash, …).
    @discardableResult
    public func record(kind: GovernanceEventKind, caseID: UUID, actor: String,
                       detail: String, at date: Date) async throws -> UUID {
        let id = UUID()
        try await database.exec("""
        INSERT INTO governance_events (id, kind, case_id, actor, detail, occurred_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [
            .uuid(id),
            .text(kind.rawValue),
            .uuid(caseID),
            .text(actor),
            .text(detail),
            .real(date.timeIntervalSince1970)
        ])
        return id
    }

    /// AUD-CHAIN — every governance event as a canonical seal input, oldest
    /// first. The payload is a stable sorted `key=value;` string over the
    /// immutable fields so re-hashing during verification is deterministic.
    public func auditChainEvents() async throws -> [AuditChainEvent] {
        let rows = try await database.query("""
        SELECT id, kind, case_id, actor, detail, occurred_at
        FROM governance_events ORDER BY occurred_at ASC, id ASC;
        """, [])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let kind = r.string(1), let caseID = r.uuid(2),
                  let actor = r.string(3), let at = r.date(5) else { return nil }
            let detail = r.string(4) ?? ""
            let payload = "actor=\(actor);at=\(at.timeIntervalSince1970);caseID=\(caseID.uuidString);"
                + "detail=\(detail);kind=\(kind)"
            return AuditChainEvent(source: .governance, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }
}
