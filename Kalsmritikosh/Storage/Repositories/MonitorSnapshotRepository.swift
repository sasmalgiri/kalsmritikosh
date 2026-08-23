//
//  MonitorSnapshotRepository.swift
//  Kalsmritikosh
//
//  Persists change-monitoring snapshots (v53): the content signatures of the
//  contradictions + gaps present when the user last acknowledged the state. The
//  newest snapshot is the baseline a fresh digest diffs against.
//

import Foundation

public nonisolated struct MonitorSnapshot: Sendable {
    public let id: UUID
    public let createdAt: Date
    public let signatures: [String]
    public let contradictionCount: Int
    public let gapCount: Int
    public init(id: UUID = UUID(), createdAt: Date, signatures: [String], contradictionCount: Int, gapCount: Int) {
        self.id = id; self.createdAt = createdAt; self.signatures = signatures
        self.contradictionCount = contradictionCount; self.gapCount = gapCount
    }
}

public actor MonitorSnapshotRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The most recent snapshot (the baseline for a diff), or nil if none.
    public func latest() async -> MonitorSnapshot? {
        let rows = (try? await database.query("""
        SELECT id, created_at, signatures_json, contradiction_count, gap_count
        FROM monitor_snapshots ORDER BY created_at DESC LIMIT 1;
        """, [])) ?? []
        guard let row = rows.first,
              let id = row.uuid(0), let created = row.double(1),
              let json = row.string(2) else { return nil }
        let sigs = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        return MonitorSnapshot(
            id: id, createdAt: Date(timeIntervalSince1970: created),
            signatures: sigs,
            contradictionCount: Int(row.int(3) ?? 0),
            gapCount: Int(row.int(4) ?? 0)
        )
    }

    /// Save a new baseline snapshot.
    public func save(_ snapshot: MonitorSnapshot) async {
        let json = (try? JSONEncoder().encode(snapshot.signatures)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try? await database.exec("""
        INSERT INTO monitor_snapshots (id, created_at, signatures_json, contradiction_count, gap_count)
        VALUES (?, ?, ?, ?, ?);
        """, [
            .uuid(snapshot.id),
            .real(snapshot.createdAt.timeIntervalSince1970),
            .text(json),
            .integer(Int64(snapshot.contradictionCount)),
            .integer(Int64(snapshot.gapCount))
        ])
    }

    /// Prune old snapshots, keeping the most recent `keep`.
    public func prune(keep: Int = 20) async {
        try? await database.exec("""
        DELETE FROM monitor_snapshots WHERE id NOT IN (
            SELECT id FROM monitor_snapshots ORDER BY created_at DESC LIMIT ?
        );
        """, [.integer(Int64(keep))])
    }
}
