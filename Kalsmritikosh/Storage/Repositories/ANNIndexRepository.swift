//
//  ANNIndexRepository.swift
//  Kalsmritikosh
//
//  P9.3 (GOV-005) — raw-SQL repository for the disk-backed ANN state
//  (ann_index_meta / ann_cells / ann_postings, migration v103). All IVF
//  durable state lives in the SINGLE ledger, so WAL, SAVEPOINT migrations and
//  ON DELETE CASCADE apply for free; there is no sidecar-file consistency
//  protocol. The repository owns the retrain contract explicitly: a retrain
//  replaces cells and repopulates postings inside repository-managed calls
//  (ann_postings deliberately carries no FK to ann_cells).
//

import Foundation

/// The persisted index-strategy decision for one embedding model.
public enum ANNStrategy: String, Sendable, Codable {
    case inMemoryHNSW
    case diskIVF
}

/// Build state of the disk index. `building` doubles as the crash marker: a
/// reopen that finds it treats the disk index as not-ready (queries fall back
/// to the brute-force scan) and the background maintenance job resumes the
/// rebuild.
public enum ANNIndexState: String, Sendable, Codable {
    case empty
    case building
    case ready
}

public struct ANNIndexMeta: Sendable, Equatable {
    public let modelID: String
    public let strategy: ANNStrategy
    public let state: ANNIndexState
    public let dimension: Int
    public let cellCount: Int
    public let trainedVectorCount: Int
    public let trainSeed: UInt64
    public let createdAt: Date
    public let updatedAt: Date
}

public struct ANNCell: Sendable, Equatable {
    public let cellID: Int
    public let centroid: Data      // float32 LE, dimension × 4 bytes
    public let vectorCount: Int
}

public struct ANNPosting: Sendable, Equatable {
    public let cellID: Int
    public let chunkID: UUID
    public let q: Data             // int8 quantized vector
    public let scale: Double       // max|x|/127 symmetric scale
}

public actor ANNIndexRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Meta

    /// Create the meta row for a model if absent (strategy defaults to
    /// inMemoryHNSW, state to empty). Existing rows are left untouched so a
    /// boot can call this unconditionally.
    public func ensureMeta(modelID: String, dimension: Int, at now: Date) async throws {
        try await database.exec("""
        INSERT INTO ann_index_meta (model_id, strategy, state, dimension, created_at, updated_at)
        VALUES (?, 'inMemoryHNSW', 'empty', ?, ?, ?)
        ON CONFLICT(model_id) DO NOTHING;
        """, [.text(modelID), .integer(Int64(dimension)), .date(now), .date(now)])
    }

    public func meta(for modelID: String) async throws -> ANNIndexMeta? {
        let rows = try await database.query("""
        SELECT model_id, strategy, state, dimension, cell_count, trained_vector_count,
               train_seed, created_at, updated_at
        FROM ann_index_meta WHERE model_id = ?;
        """, [.text(modelID)])
        guard let r = rows.first,
              let strategyRaw = r.string(1), let strategy = ANNStrategy(rawValue: strategyRaw),
              let stateRaw = r.string(2), let state = ANNIndexState(rawValue: stateRaw)
        else { return nil }
        return ANNIndexMeta(
            modelID: r.string(0) ?? modelID,
            strategy: strategy,
            state: state,
            dimension: Int(r.int(3) ?? 0),
            cellCount: Int(r.int(4) ?? 0),
            trainedVectorCount: Int(r.int(5) ?? 0),
            trainSeed: UInt64(bitPattern: r.int(6) ?? 0),
            createdAt: r.date(7) ?? .distantPast,
            updatedAt: r.date(8) ?? .distantPast
        )
    }

    public func setStrategy(_ strategy: ANNStrategy, for modelID: String, at now: Date) async throws {
        try await database.exec(
            "UPDATE ann_index_meta SET strategy = ?, updated_at = ? WHERE model_id = ?;",
            [.text(strategy.rawValue), .date(now), .text(modelID)])
    }

    public func setState(_ state: ANNIndexState, for modelID: String, at now: Date) async throws {
        try await database.exec(
            "UPDATE ann_index_meta SET state = ?, updated_at = ? WHERE model_id = ?;",
            [.text(state.rawValue), .date(now), .text(modelID)])
    }

    /// Record a completed k-means training pass (geometry + reproducibility seed).
    public func recordTraining(cellCount: Int, trainedVectorCount: Int, seed: UInt64,
                               for modelID: String, at now: Date) async throws {
        try await database.exec("""
        UPDATE ann_index_meta
        SET cell_count = ?, trained_vector_count = ?, train_seed = ?, updated_at = ?
        WHERE model_id = ?;
        """, [.integer(Int64(cellCount)), .integer(Int64(trainedVectorCount)),
              .integer(Int64(bitPattern: seed)), .date(now), .text(modelID)])
    }

    // MARK: - Cells (retrain replaces the whole set)

    /// Replace every centroid for the model. Part of the repository-managed
    /// retrain contract: cells and postings are replaced together by the
    /// caller (IVFDiskVectorIndex) under state='building'.
    public func replaceCells(_ cells: [ANNCell], for modelID: String, at now: Date) async throws {
        try await database.exec("DELETE FROM ann_cells WHERE model_id = ?;", [.text(modelID)])
        for batch in stride(from: 0, to: cells.count, by: 100).map({ Array(cells[$0..<min($0 + 100, cells.count)]) }) {
            let placeholders = Array(repeating: "(?, ?, ?, ?, ?)", count: batch.count).joined(separator: ", ")
            var bindings: [SQLValue] = []
            bindings.reserveCapacity(batch.count * 5)
            for cell in batch {
                bindings.append(.text(modelID))
                bindings.append(.integer(Int64(cell.cellID)))
                bindings.append(.blob(cell.centroid))
                bindings.append(.integer(Int64(cell.vectorCount)))
                bindings.append(.date(now))
            }
            try await database.exec(
                "INSERT INTO ann_cells (model_id, cell_id, centroid, vector_count, updated_at) VALUES \(placeholders);",
                bindings)
        }
    }

    public func cells(for modelID: String) async throws -> [ANNCell] {
        let rows = try await database.query(
            "SELECT cell_id, centroid, vector_count FROM ann_cells WHERE model_id = ? ORDER BY cell_id;",
            [.text(modelID)])
        return rows.compactMap { r in
            guard let id = r.int(0), let centroid = r.blob(1) else { return nil }
            return ANNCell(cellID: Int(id), centroid: centroid, vectorCount: Int(r.int(2) ?? 0))
        }
    }

    // MARK: - Postings

    /// Batched upsert. INSERT OR REPLACE keeps a crash-interrupted populate
    /// idempotent; the unique (chunk_id, model_id) index means a re-assigned
    /// chunk must be removed first (removePosting) — reassignment is a
    /// repository-managed retrain concern, not an upsert side effect.
    public func insertPostings(_ postings: [ANNPosting], for modelID: String) async throws {
        for batch in stride(from: 0, to: postings.count, by: 100).map({ Array(postings[$0..<min($0 + 100, postings.count)]) }) {
            let placeholders = Array(repeating: "(?, ?, ?, ?, ?)", count: batch.count).joined(separator: ", ")
            var bindings: [SQLValue] = []
            bindings.reserveCapacity(batch.count * 5)
            for p in batch {
                bindings.append(.text(modelID))
                bindings.append(.integer(Int64(p.cellID)))
                bindings.append(.uuid(p.chunkID))
                bindings.append(.blob(p.q))
                bindings.append(.real(p.scale))
            }
            try await database.exec(
                "INSERT OR REPLACE INTO ann_postings (model_id, cell_id, chunk_id, q, scale) VALUES \(placeholders);",
                bindings)
        }
    }

    public func removePosting(chunkID: UUID, for modelID: String) async throws {
        try await database.exec(
            "DELETE FROM ann_postings WHERE chunk_id = ? AND model_id = ?;",
            [.uuid(chunkID), .text(modelID)])
    }

    public func postings(inCell cellID: Int, for modelID: String) async throws -> [ANNPosting] {
        let rows = try await database.query("""
        SELECT cell_id, chunk_id, q, scale FROM ann_postings
        WHERE model_id = ? AND cell_id = ? ORDER BY chunk_id;
        """, [.text(modelID), .integer(Int64(cellID))])
        return rows.compactMap { r in
            guard let cell = r.int(0), let chunk = r.uuid(1),
                  let q = r.blob(2), let scale = r.double(3) else { return nil }
            return ANNPosting(cellID: Int(cell), chunkID: chunk, q: q, scale: scale)
        }
    }

    /// Batched probe: fetch every posting in ANY of the given cells in a single
    /// query. The table is clustered on (model_id, cell_id, chunk_id) WITHOUT
    /// ROWID, so `cell_id IN (…)` is a set of sequential range scans. This
    /// collapses an N-cell probe from N actor round-trips to ONE (PERF-3: the
    /// per-cell round-trip, not coverage, was the query-latency bottleneck).
    public func postings(inCells cellIDs: [Int], for modelID: String) async throws -> [ANNPosting] {
        guard !cellIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: cellIDs.count).joined(separator: ",")
        var bindings: [SQLValue] = [.text(modelID)]
        bindings.reserveCapacity(cellIDs.count + 1)
        for c in cellIDs { bindings.append(.integer(Int64(c))) }
        let rows = try await database.query("""
        SELECT cell_id, chunk_id, q, scale FROM ann_postings
        WHERE model_id = ? AND cell_id IN (\(placeholders));
        """, bindings)
        return rows.compactMap { r in
            guard let cell = r.int(0), let chunk = r.uuid(1),
                  let q = r.blob(2), let scale = r.double(3) else { return nil }
            return ANNPosting(cellID: Int(cell), chunkID: chunk, q: q, scale: scale)
        }
    }

    public func postingCount(for modelID: String) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM ann_postings WHERE model_id = ?;", [.text(modelID)])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Retrain support: drop every posting for the model (cells are replaced
    /// separately). Idempotent.
    public func deleteAllPostings(for modelID: String) async throws {
        try await database.exec("DELETE FROM ann_postings WHERE model_id = ?;", [.text(modelID)])
    }

    /// Per-insert cell occupancy maintenance (retrain recomputes from scratch).
    public func adjustCellCount(cellID: Int, by delta: Int, for modelID: String, at now: Date) async throws {
        try await database.exec("""
        UPDATE ann_cells SET vector_count = MAX(0, vector_count + ?), updated_at = ?
        WHERE model_id = ? AND cell_id = ?;
        """, [.integer(Int64(delta)), .date(now), .text(modelID), .integer(Int64(cellID))])
    }

    // MARK: - chunk_embeddings read helpers (build/reconcile inputs)

    /// One stored embedding row as build input.
    public struct EmbeddingRow: Sendable {
        public let rowid: Int64
        public let chunkID: UUID
        public let q: Data
        public let scale: Double
    }

    public func embeddingCount(for modelID: String) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?;", [.text(modelID)])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Rowid-paged stream of the model's stored embeddings — the memory-bounded
    /// build input (same paging idiom as the store's brute-force scan).
    public func embeddingPage(for modelID: String, afterRowid: Int64, limit: Int) async throws -> [EmbeddingRow] {
        let rows = try await database.query("""
        SELECT rowid, chunk_id, q, scale FROM chunk_embeddings
        WHERE model_id = ? AND rowid > ? ORDER BY rowid LIMIT ?;
        """, [.text(modelID), .integer(afterRowid), .integer(Int64(limit))])
        return rows.compactMap { r in
            guard let rowid = r.int(0), let chunk = r.uuid(1),
                  let q = r.blob(2), let scale = r.double(3) else { return nil }
            return EmbeddingRow(rowid: rowid, chunkID: chunk, q: q, scale: scale)
        }
    }

    /// Embeddings that have NO posting yet — the reconcile input that closes
    /// the build-vs-concurrent-insert race and doubles as the DataHealthCheck
    /// parity repair. Bounded so a repair pass stays incremental.
    public func embeddingsMissingPostings(for modelID: String, limit: Int) async throws -> [EmbeddingRow] {
        let rows = try await database.query("""
        SELECT e.rowid, e.chunk_id, e.q, e.scale FROM chunk_embeddings e
        LEFT JOIN ann_postings p ON p.chunk_id = e.chunk_id AND p.model_id = e.model_id
        WHERE e.model_id = ? AND p.chunk_id IS NULL
        ORDER BY e.rowid LIMIT ?;
        """, [.text(modelID), .integer(Int64(limit))])
        return rows.compactMap { r in
            guard let rowid = r.int(0), let chunk = r.uuid(1),
                  let q = r.blob(2), let scale = r.double(3) else { return nil }
            return EmbeddingRow(rowid: rowid, chunkID: chunk, q: q, scale: scale)
        }
    }
}
