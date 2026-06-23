//
//  FactBondsRepository.swift
//  Kalsmritikosh
//
//  G3.10 — actor wrapper over the `fact_bonds` table. Bonds are
//  polymorphic typed edges between facts (entities, events,
//  memory_objects). Unlike `relationships` which is entity↔entity
//  only, a bond can connect e.g. an Email event to a Person entity
//  via `sent_by`.
//
//  Idempotency: UNIQUE INDEX on (bond_name, from_fact_id, to_fact_id)
//  means re-ingest of the same KO upserts (weight++, evidence append).
//

import Foundation

public actor FactBondsRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Max source KO ids retained per bond row (mirrors RelationshipsRepository).
    public static let evidenceCap = 20

    public enum FactKind: String, Sendable, Hashable, CaseIterable {
        case entity
        case event
        case memoryObject = "memory_object"
    }

    public struct BondUpsert: Sendable, Hashable {
        public let bondName: String
        public let fromKind: FactKind
        public let fromID: UUID
        public let toKind: FactKind
        public let toID: UUID

        public init(
            bondName: String,
            fromKind: FactKind,
            fromID: UUID,
            toKind: FactKind,
            toID: UUID
        ) {
            self.bondName = bondName
            self.fromKind = fromKind
            self.fromID = fromID
            self.toKind = toKind
            self.toID = toID
        }
    }

    public struct Bond: Sendable, Hashable {
        public let id: UUID
        public let bondName: String
        public let fromKind: FactKind
        public let fromID: UUID
        public let toKind: FactKind
        public let toID: UUID
        public let sourceObjectID: UUID
        public let confidence: Double
        public let weight: Int
    }

    public init(database: Database) {
        self.database = database
    }

    /// Batched upserts wrapped in BEGIN IMMEDIATE / COMMIT so an N-bond
    /// write amortises fsync cost. ROLLBACK on partial failure leaves
    /// the table at its pre-batch state.
    public func upsertBonds(
        _ bonds: [BondUpsert],
        sourceObjectID: KnowledgeObject.ID,
        confidence: Confidence = .medium
    ) async throws {
        guard !bonds.isEmpty else { return }
        try await database.exec("BEGIN IMMEDIATE;")
        do {
            for bond in bonds {
                try await upsertBond(
                    bond,
                    sourceObjectID: sourceObjectID,
                    confidence: confidence
                )
            }
            try await database.exec("COMMIT;")
        } catch {
            try? await database.exec("ROLLBACK;")
            throw error
        }
    }

    public func upsertBond(
        _ bond: BondUpsert,
        sourceObjectID: KnowledgeObject.ID,
        confidence: Confidence = .medium
    ) async throws {
        let existing = try await database.query("""
        SELECT id, weight, evidence_object_ids_json
        FROM fact_bonds
        WHERE bond_name = ? AND from_fact_id = ? AND to_fact_id = ?
        LIMIT 1;
        """, [
            .text(bond.bondName),
            .uuid(bond.fromID),
            .uuid(bond.toID)
        ])

        if let row = existing.first, let id = row.uuid(0) {
            let weight = Int(row.int(1) ?? 1)
            var evidence = parseEvidence(row.string(2) ?? "[]")
            let srcStr = sourceObjectID.uuidString
            if !evidence.contains(srcStr) {
                evidence.append(srcStr)
                if evidence.count > Self.evidenceCap {
                    evidence = Array(evidence.suffix(Self.evidenceCap))
                }
            }
            try await database.exec("""
            UPDATE fact_bonds
            SET weight = ?, evidence_object_ids_json = ?
            WHERE id = ?;
            """, [
                .integer(Int64(weight + 1)),
                .text(serializeEvidence(evidence)),
                .uuid(id)
            ])
        } else {
            try await database.exec("""
            INSERT INTO fact_bonds (
                id, bond_name, from_fact_kind, from_fact_id,
                to_fact_kind, to_fact_id, source_object_id,
                confidence, weight, evidence_object_ids_json, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?);
            """, [
                .uuid(UUID()),
                .text(bond.bondName),
                .text(bond.fromKind.rawValue),
                .uuid(bond.fromID),
                .text(bond.toKind.rawValue),
                .uuid(bond.toID),
                .uuid(sourceObjectID),
                .real(confidence.value),
                .text("[\"\(sourceObjectID.uuidString)\"]"),
                .date(.init())
            ])
        }
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM fact_bonds;")
        return Int(rows.first?.int(0) ?? 0)
    }

    public func count(bondName: String) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM fact_bonds WHERE bond_name = ?;",
            [.text(bondName)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// All bonds originating at `factID`, optionally filtered by name.
    public func outgoing(from factID: UUID, named name: String? = nil, limit: Int = 200) async throws -> [Bond] {
        let sql: String
        let bindings: [SQLValue]
        if let name {
            sql = """
            SELECT id, bond_name, from_fact_kind, from_fact_id,
                   to_fact_kind, to_fact_id, source_object_id,
                   confidence, weight
            FROM fact_bonds
            WHERE from_fact_id = ? AND bond_name = ?
            LIMIT ?;
            """
            bindings = [.uuid(factID), .text(name), .integer(Int64(limit))]
        } else {
            sql = """
            SELECT id, bond_name, from_fact_kind, from_fact_id,
                   to_fact_kind, to_fact_id, source_object_id,
                   confidence, weight
            FROM fact_bonds
            WHERE from_fact_id = ?
            LIMIT ?;
            """
            bindings = [.uuid(factID), .integer(Int64(limit))]
        }
        let rows = try await database.query(sql, bindings)
        return rows.compactMap(decode)
    }

    /// All bonds terminating at `factID`, optionally filtered by name.
    public func incoming(to factID: UUID, named name: String? = nil, limit: Int = 200) async throws -> [Bond] {
        let sql: String
        let bindings: [SQLValue]
        if let name {
            sql = """
            SELECT id, bond_name, from_fact_kind, from_fact_id,
                   to_fact_kind, to_fact_id, source_object_id,
                   confidence, weight
            FROM fact_bonds
            WHERE to_fact_id = ? AND bond_name = ?
            LIMIT ?;
            """
            bindings = [.uuid(factID), .text(name), .integer(Int64(limit))]
        } else {
            sql = """
            SELECT id, bond_name, from_fact_kind, from_fact_id,
                   to_fact_kind, to_fact_id, source_object_id,
                   confidence, weight
            FROM fact_bonds
            WHERE to_fact_id = ?
            LIMIT ?;
            """
            bindings = [.uuid(factID), .integer(Int64(limit))]
        }
        let rows = try await database.query(sql, bindings)
        return rows.compactMap(decode)
    }

    // MARK: - Decoding

    private func decode(_ row: SQLRow) -> Bond? {
        guard
            let id = row.uuid(0),
            let bondName = row.string(1),
            let fromKindRaw = row.string(2),
            let fromKind = FactKind(rawValue: fromKindRaw),
            let fromID = row.uuid(3),
            let toKindRaw = row.string(4),
            let toKind = FactKind(rawValue: toKindRaw),
            let toID = row.uuid(5),
            let src = row.uuid(6),
            let conf = row.double(7)
        else { return nil }
        let weight = Int(row.int(8) ?? 1)
        return Bond(
            id: id,
            bondName: bondName,
            fromKind: fromKind,
            fromID: fromID,
            toKind: toKind,
            toID: toID,
            sourceObjectID: src,
            confidence: conf,
            weight: weight
        )
    }

    // MARK: - JSON evidence list helpers

    private func parseEvidence(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private func serializeEvidence(_ list: [String]) -> String {
        guard let data = try? encoder.encode(list),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
