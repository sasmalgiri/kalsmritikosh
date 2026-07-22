//
//  DatasetRepository.swift
//  Kalsmritikosh
//
//  LAB-002 — durable, paged persistence for the Workbench EvidenceDataset kernel (LAB-001).
//  Columns live in `evidence_datasets`; rows are paged in `dataset_rows` (cells as JSON,
//  each keeping its source-block lineage). This lets analyses survive relaunch and lets the
//  UI page large tables without loading everything into a SwiftUI array (pack §7 rule).
//
//  Raw sqlite3 C-API repository style (exec/query + SQLValue/SQLRow), matching the codebase.
//

import Foundation

public actor DatasetRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    /// Persist (or replace) a dataset and its rows. Idempotent on id.
    public func save(_ dataset: EvidenceDataset) async throws {
        let columnsJSON = String(data: try Self.encoder.encode(dataset.columns), encoding: .utf8) ?? "[]"
        try await database.exec("""
        INSERT OR REPLACE INTO evidence_datasets (id, name, version, columns_json, created_at)
        VALUES (?, ?, ?, ?, ?);
        """, [
            .uuid(dataset.id), .text(dataset.name),
            .integer(Int64(dataset.version)), .text(columnsJSON),
            .real(Date().timeIntervalSince1970)
        ])
        // Re-page the rows: clear then insert in order (small, durable, deterministic).
        try await database.exec("DELETE FROM dataset_rows WHERE dataset_id = ?;", [.uuid(dataset.id)])
        for (ordinal, row) in dataset.rows.enumerated() {
            let cellsJSON = String(data: try Self.encoder.encode(row.cells), encoding: .utf8) ?? "[]"
            try await database.exec("""
            INSERT INTO dataset_rows (dataset_id, ordinal, cells_json) VALUES (?, ?, ?);
            """, [.uuid(dataset.id), .integer(Int64(ordinal)), .text(cellsJSON)])
        }
    }

    /// Load a dataset by id (rows in stored order), or nil if absent.
    public func load(id: UUID) async throws -> EvidenceDataset? {
        let head = try await database.query("""
        SELECT name, version, columns_json FROM evidence_datasets WHERE id = ?;
        """, [.uuid(id)])
        guard let h = head.first, let name = h.string(0), let colsJSON = h.string(2) else { return nil }
        let columns = (try? Self.decoder.decode([DatasetColumn].self, from: Data(colsJSON.utf8))) ?? []

        let rowRows = try await database.query("""
        SELECT cells_json FROM dataset_rows WHERE dataset_id = ? ORDER BY ordinal ASC;
        """, [.uuid(id)])
        let rows: [DatasetRow] = rowRows.compactMap { r in
            guard let json = r.string(0),
                  let cells = try? Self.decoder.decode([DatasetCell].self, from: Data(json.utf8))
            else { return nil }
            return DatasetRow(cells: cells)
        }
        return EvidenceDataset(id: id, name: name, version: Int(h.int(1) ?? 1), columns: columns, rows: rows)
    }

    /// Row count for a dataset (paged access — never loads the rows).
    public func rowCount(id: UUID) async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM dataset_rows WHERE dataset_id = ?;", [.uuid(id)])
        return Int(rows.first?.int(0) ?? 0)
    }

    public func delete(id: UUID) async throws {
        try await database.exec("DELETE FROM evidence_datasets WHERE id = ?;", [.uuid(id)])
        // dataset_rows removed by FK cascade.
    }
}
