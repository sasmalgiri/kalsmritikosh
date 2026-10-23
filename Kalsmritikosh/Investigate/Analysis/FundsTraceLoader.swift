//
//  FundsTraceLoader.swift
//  Kalsmritikosh
//
//  A-8 — reads what FundsTrace needs from the ledger: the `paid` payer → payee relationships (with
//  the knowledge objects each was observed in) and the extracted money facts (generic_facts field
//  'amount') whose evidence blocks belong to those same knowledge objects. Read-only. Facts that are
//  superseded, invalidated or rejected on review are left out of the sums.
//

import Foundation
import os

public nonisolated struct FundsLedgerSnapshot: Sendable {
    public let edges: [FundsPaymentEdge]
    public let amounts: [FundsAmountFact]
    /// knowledge-object id → file name, for citing documents.
    public let documentNames: [String: String]
    public let edgeLimitReached: Bool
}

public nonisolated enum FundsTraceLoader {

    public static func load(_ database: Database, edgeLimit: Int = 2_000) async throws -> FundsLedgerSnapshot {
        let rows = try await database.query("""
            SELECT r.from_entity_id, r.to_entity_id, ef.value, et.value, r.evidence_object_ids_json, r.source_object_id
            FROM relationships r
            JOIN entities ef ON ef.id = r.from_entity_id
            JOIN entities et ON et.id = r.to_entity_id
            WHERE r.kind = 'paid'
              AND ef.review_status IS NULL AND ef.merged_into IS NULL
              AND et.review_status IS NULL AND et.merged_into IS NULL
            ORDER BY r.weight DESC
            LIMIT ?;
            """, [.integer(Int64(edgeLimit))])
        var edges: [FundsPaymentEdge] = []
        var docSet = Set<String>()
        for r in rows {
            guard let from = r.string(0), let to = r.string(1), let fl = r.string(2), let tl = r.string(3) else { continue }
            var docs = decodeIDs(r.string(4))
            if let src = r.string(5) { docs.append(src) }
            let clean = Array(Set(docs.map { $0.uppercased() })).sorted()
            docSet.formUnion(clean)
            edges.append(FundsPaymentEdge(fromID: from.uppercased(), fromLabel: fl, toID: to.uppercased(), toLabel: tl, documentIDs: clean))
        }
        guard !docSet.isEmpty else {
            return FundsLedgerSnapshot(edges: edges, amounts: [], documentNames: [:], edgeLimitReached: rows.count >= edgeLimit)
        }
        let wanted = encodeIDs(docSet.sorted())
        let factRows = try await database.query("""
            WITH blk(ko, b) AS (
                SELECT upper(o.knowledge_object_id), upper(o.evidence_block_id) FROM evidence_block_objects o
                WHERE o.knowledge_object_id IN (SELECT value FROM json_each(?1))
                UNION
                SELECT upper(c.object_id), upper(c.evidence_block_id) FROM chunks c
                WHERE c.evidence_block_id IS NOT NULL AND c.object_id IN (SELECT value FROM json_each(?1))
            )
            SELECT DISTINCT blk.ko, f.id, f.value, f.unit
            FROM generic_facts f
            JOIN json_each(CASE WHEN json_valid(f.source_blocks_json) THEN f.source_blocks_json ELSE '[]' END) j
            JOIN blk ON blk.b = upper(j.value)
            WHERE f.field = 'amount' AND f.superseded_by IS NULL AND f.invalid_at IS NULL
              AND (f.review_disposition IS NULL OR f.review_disposition != 'rejected');
            """, [.text(wanted)])
        let amounts = factRows.compactMap { r -> FundsAmountFact? in
            guard let ko = r.string(0), let id = r.string(1), let value = r.string(2) else { return nil }
            return FundsAmountFact(factID: id, documentID: ko, value: value, unit: r.string(3))
        }
        let nameRows = try await database.query("""
            SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE ko.id IN (SELECT value FROM json_each(?));
            """, [.text(wanted)])
        var names: [String: String] = [:]
        for r in nameRows {
            guard let id = r.string(0), let url = r.string(1) else { continue }
            names[id.uppercased()] = URL(string: url)?.lastPathComponent ?? url
        }
        return FundsLedgerSnapshot(edges: edges, amounts: amounts, documentNames: names, edgeLimitReached: rows.count >= edgeLimit)
    }

    static func decodeIDs(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        do { return try JSONDecoder().decode([String].self, from: data) } catch {
            KalsmritikoshLog.storage.error("Fund-flow evidence list unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func encodeIDs(_ ids: [String]) -> String {
        do { return String(data: try JSONEncoder().encode(ids), encoding: .utf8) ?? "[]" } catch {
            KalsmritikoshLog.storage.error("Fund-flow id list encode failed: \(error.localizedDescription, privacy: .public)")
            return "[]"
        }
    }
}
