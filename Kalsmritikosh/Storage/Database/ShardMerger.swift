//
//  ShardMerger.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-17 — merges the shard ledgers of a memory-sized import
//  run into the ONE main ledger. Everything that touches SQLite runs inside `actor Database` (the raw
//  sqlite3 handle never leaves it):
//
//   1. ATTACH the shard with the ledger key (`ATTACH DATABASE ? AS ingest_shard KEY ?`).
//   2. Read the shard's schema and derive the copy order from its foreign keys (parents before
//      children; ties alphabetical). Left out: SQLite's own tables, full-text indexes and their shadow
//      tables (the main ledger's triggers — or, where a full-text index has no trigger, an explicit
//      insert here — index the merged rows), vectors / nearest-neighbour index rows (the main ledger's
//      background drain embeds the merged chunks with its active model), the tamper-evident audit chain
//      and erasure registers (main-ledger-only by design), and the merge log itself.
//   3. Copy each table with `INSERT OR IGNORE … SELECT` (ids are UUID text, so a shard row keeps its
//      id). Only rows above the shard's seed marks are copied (rows the migration seeded are already in
//      every ledger). A row whose parent is not in the main ledger is held back instead of failing the
//      table, and the held-back rows are tried again after the other tables (cycles, self-references).
//
//  Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet. The S2 limits are removed:
//   • vector rows (chunk_embeddings) are merged (shards now embed their own chunks); nearest-neighbour index
//     rows still are not (the main ledger's index takes the merged vectors at its next reconcile; until then
//     the in-sync guard sends searches to the exact scan);
//   • the erasure registers (erasure_generations, erasure_tombstones) are merged, generations re-numbered;
//     the full/case/person erase MARKERS never are (they let append-only guards stand aside);
//   • the audit chain is not copied raw: the merged custody / review events are sealed into the main chain
//     in order through AuditChainService after the merges (AppState.afterShardMerges);
//   • an INTEGER-keyed table that other tables refer to is merged with its ids moved past the main ledger's
//     highest id (offset kept in `<index>.offsets.json` so a resumed merge rebuilds the map), and every
//     reference to it is rewritten through the id map;
//   • a row that clashes with a main row on a UNIQUE key now FOLDS into it: count columns are added
//     (weight, *_count), id-list columns (*_ids_json, *_ids, source_ids) are unioned, confidence takes the
//     higher value, first_seen the earlier and last_seen the later — once per mapped row, in the table's
//     savepoint (a table whose triggers refuse updates keeps its rows and logs the fold as skipped).
//   4. A row that collides with a main-ledger row on a UNIQUE key (the canonical entity "Acme Ltd"
//      that both ledgers know, its alias, a relationship) is not duplicated: the shard id is mapped to
//      the main row's id in a per-connection temp table, and every later reference to it (declared
//      foreign keys, and undeclared `entity_id` / `*_entity_id` columns) is rewritten to the main id.
//   5. A source the main ledger already holds under the same URL is skipped (with everything hanging
//      off it). Sources already held by content hash never reach a shard: the worker routes them to the
//      main ledger's coordinator before parsing (AppState+ShardImport).
//   6. Progress is recorded per table in `ingest_shard_merges` (v199) in the SAME savepoint as the
//      table's rows, so a crash resumes after the last committed table. The shard file is deleted only
//      once its row says `merged`; a shard whose merge failed stays on disk with the error recorded.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os
import SQLCipher

// MARK: - Plan

public nonisolated struct ShardForeignKey: Sendable, Hashable {
    public let parent: String
    public let from: [String]
    public let to: [String]
}

public nonisolated struct ShardTablePlan: Sendable {
    public let name: String
    /// Columns copied (generated and hidden columns, and an INTEGER PRIMARY KEY rowid alias, left out).
    public let columns: [String]
    /// Declared primary-key columns, in key order.
    public let primaryKey: [String]
    /// An INTEGER PRIMARY KEY (rowid alias): left out of the copy, so the main ledger assigns its own.
    public let integerPrimaryKey: String?
    public let withoutRowid: Bool
    public var foreignKeys: [ShardForeignKey]
    /// UNIQUE keys other than the primary key (whole-table, column-only indexes and constraints).
    public let uniqueKeys: [[String]]
    /// Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: an integer key other tables refer to —
    /// its rows take ids past the main ledger's highest, and references are rewritten through the id map.
    public var remapsIntegerKey = false

    /// A shard row of this table may stand for an existing main row (same UNIQUE key, different id).
    public var remappable: Bool { primaryKey.count == 1 && integerPrimaryKey == nil && !uniqueKeys.isEmpty }
    /// References to this table's rows go through the id map (text ids by UNIQUE clash, integer ids always).
    public var mapsReferences: Bool { remappable || remapsIntegerKey }
    /// Re-running the copy cannot duplicate a row.
    public var idempotent: Bool { !primaryKey.isEmpty && integerPrimaryKey == nil }
}

public nonisolated struct ShardTableResult: Sendable {
    public var candidates = 0
    public var inserted = 0
    public var remapped = 0
    /// PERF-20: the id offset an integer-keyed table used.
    public var integerOffset: Int64?
    /// PERF-20: main rows a clashing shard row was folded into.
    public var folded = 0
    public var heldBack: Int { max(0, candidates - inserted - remapped) }
}

/// One shard's merge, as recorded.
public nonisolated struct ShardMergeRecord: Sendable {
    public let runID: UUID
    public let index: Int
    public let path: String
    public let state: String
    public let lastTable: String?
}

public nonisolated enum ShardMergeOutcome: Sendable {
    case merged(rows: Int, tables: Int, heldBack: Int)
    case failed(String)
}

// MARK: - Database (all SQL inside the actor)

extension Database {
    static let shardSchema = "ingest_shard"

    /// Tables the merge never copies.
    nonisolated static func shardMergeExcludes(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("sqlite_") { return true }
        if n == "ingest_shard_merges" { return true }
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: the erasure registers are merged; the
        // raw audit chain (re-sealed instead) and the erase markers never are.
        if n.hasPrefix("audit_chain") || n == "ledger_person_erase" || n == "ledger_full_erase" || n == "ledger_case_erase" { return true }
        if n.hasPrefix("erasure_"), n != "erasure_generations", n != "erasure_tombstones" { return true }
        if n == "schema_conformance_marks" || n == "case_history_install" || n == "ledger_recording_device" { return true }
        if n.hasPrefix("ann_") { return true }   // PERF-20: chunk_embeddings are merged; index rows are rebuilt
        if n.contains("__v") { return true }   // a migration's interrupted rebuild copy
        return false
    }

    /// ATTACH a closed shard file with the ledger key. Never inside a transaction.
    public func attachShard(at url: URL) throws {
        guard inSavepoint == 0 else {
            throw DatabaseError.stepFailed(sql: "ATTACH", message: "a shard cannot be attached inside a transaction")
        }
        // A raw 256-bit key, as `PRAGMA key` takes it (LedgerKey.pragmaValue); '' for an unencrypted ledger.
        let keyText = key.map { k in "x'" + k.raw.map { String(format: "%02X", $0) }.joined() + "'" } ?? ""
        try exec("ATTACH DATABASE ? AS \(Self.shardSchema) KEY ?;", [.text(url.path), .text(keyText)])
        try execRaw("""
            CREATE TEMP TABLE IF NOT EXISTS ingest_shard_remap (
                tbl TEXT NOT NULL, shard_id TEXT NOT NULL, main_id TEXT NOT NULL, folded INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (tbl, shard_id));
            DELETE FROM temp.ingest_shard_remap;
            """)
    }

    public func detachShard() throws {
        do { try execRaw("DELETE FROM temp.ingest_shard_remap;") } catch {
            KalsmritikoshLog.storage.error("Shard merge: remap table not cleared: \(String(describing: error), privacy: .public)")
        }
        try execRaw("DETACH DATABASE \(Self.shardSchema);")
    }

    /// The copy plan for the attached shard, parents before children.
    public func shardMergePlan() throws -> [ShardTablePlan] {
        try withSavepoint("shard_plan") { db in try Database.buildShardPlan(db) }
    }

    /// Copy one table of the attached shard into the main ledger (one savepoint, progress row included).
    /// `strict` drops the same-statement self-reference allowance (used when a table's first try failed).
    public func mergeShardTable(_ plan: ShardTablePlan, plans: [String: ShardTablePlan], seedMark: Int64?,
                                runID: UUID, shardIndex: Int, strict: Bool, recordProgress: Bool,
                                integerOffset: Int64? = nil, exactOffset: Bool = false) throws -> ShardTableResult {
        try withSavepoint("shard_table") { db in
            try Database.copyShardTable(db, plan, plans: plans, seedMark: seedMark, strict: strict,
                                        runID: runID, shardIndex: shardIndex, recordProgress: recordProgress,
                                        integerOffset: integerOffset, exactOffset: exactOffset)
        }
    }

    /// Rebuild the id map of a table already copied by an earlier, interrupted merge of this shard (its
    /// clashes were folded in that merge's savepoint, so they are marked folded here).
    public func remapShardTable(_ plan: ShardTablePlan, plans: [String: ShardTablePlan], seedMark: Int64?,
                                integerOffset: Int64? = nil) throws -> Int {
        try withSavepoint("shard_remap") { db in
            var n = try Database.remap(db, plan, plans: plans, seedMark: seedMark)
            if plan.remapsIntegerKey, let pk = plan.integerPrimaryKey, let offset = integerOffset {
                n += try Database.recordIntegerMap(db, plan, pk: pk, offset: offset, seedMark: seedMark)
            }
            try db.exec("UPDATE temp.ingest_shard_remap SET folded = 1 WHERE tbl = ?;", [.text(plan.name)])
            return n
        }
    }

    /// PERF-20: the highest id the main ledger holds in `table`'s integer key (the offset a merge would use now).
    public func mainMaxIntegerKey(_ plan: ShardTablePlan) throws -> Int64 {
        guard let pk = plan.integerPrimaryKey else { return 0 }
        return try withSavepoint("shard_offset") { db in
            try db.query("SELECT COALESCE(MAX(\(ShardSQL.quoteIdent(pk))), 0) FROM main.\(ShardSQL.quoteIdent(plan.name));", []).first?.int(0) ?? 0
        }
    }

    // MARK: Plan building

    private static func buildShardPlan(_ db: isolated Database) throws -> [ShardTablePlan] {
        let s = shardSchema
        let rows = try db.query("SELECT name, COALESCE(sql, '') FROM \(s).sqlite_master WHERE type = 'table';", [])
        var virtuals: [String] = []
        var candidates: [(String, String)] = []
        for r in rows {
            guard let name = r.string(0) else { continue }
            let sql = r.string(1) ?? ""
            if sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE") { virtuals.append(name); continue }
            candidates.append((name, sql))
        }
        let mainTables = Set(try db.query("SELECT name FROM main.sqlite_master WHERE type = 'table';", []).compactMap { $0.string(0) })
        var plans: [String: ShardTablePlan] = [:]
        for (name, sql) in candidates {
            if shardMergeExcludes(name) { continue }
            if virtuals.contains(where: { name.hasPrefix($0 + "_") }) { continue }   // full-text shadow tables
            guard mainTables.contains(name) else {
                KalsmritikoshLog.storage.error("Shard merge: table \(name, privacy: .public) is not in the main ledger; skipped")
                continue
            }
            let q = ShardSQL.quoteLiteral(name)
            let shardCols = try db.query("SELECT name, type, pk, hidden FROM pragma_table_xinfo(\(q), '\(s)');", [])
            let mainCols = Set(try db.query("SELECT name FROM pragma_table_xinfo(\(q), 'main') WHERE hidden = 0;", []).compactMap { $0.string(0) })
            let withoutRowid = sql.uppercased().contains("WITHOUT ROWID")
            var pk: [(Int64, String, String)] = []
            var cols: [String] = []
            for c in shardCols {
                guard let cname = c.string(0), (c.int(3) ?? 0) == 0, mainCols.contains(cname) else { continue }
                cols.append(cname)
                if let pos = c.int(2), pos > 0 { pk.append((pos, cname, (c.string(1) ?? "").uppercased())) }
            }
            let pkCols = pk.sorted { $0.0 < $1.0 }.map(\.1)
            var integerPK: String?
            if pk.count == 1, pk[0].2 == "INTEGER", !withoutRowid { integerPK = pk[0].1 }
            if let integerPK { cols.removeAll { $0 == integerPK } }

            var fkGroups: [Int64: (parent: String, pairs: [(Int64, String, String?)])] = [:]
            for f in try db.query("SELECT id, seq, \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(\(q), '\(s)');", []) {
                guard let id = f.int(0), let parent = f.string(2), let from = f.string(3) else { continue }
                var g = fkGroups[id] ?? (parent, [])
                g.pairs.append((f.int(1) ?? 0, from, f.string(4)))
                fkGroups[id] = g
            }
            let fks = fkGroups.keys.sorted().compactMap { id -> ShardForeignKey? in
                guard let g = fkGroups[id] else { return nil }
                let pairs = g.pairs.sorted { $0.0 < $1.0 }
                return ShardForeignKey(parent: g.parent, from: pairs.map(\.1), to: pairs.compactMap(\.2))
            }

            var uniques: [[String]] = []
            for ix in try db.query("SELECT name, \"unique\", origin, partial FROM pragma_index_list(\(q), '\(s)');", []) {
                guard let ixName = ix.string(0), (ix.int(1) ?? 0) == 1, (ix.string(2) ?? "") != "pk", (ix.int(3) ?? 0) == 0 else { continue }
                let keyCols = try db.query("SELECT name FROM pragma_index_info(\(ShardSQL.quoteLiteral(ixName)), '\(s)') ORDER BY seqno;", [])
                let names = keyCols.compactMap { $0.string(0) }
                guard !names.isEmpty, names.count == keyCols.count, names.allSatisfy(cols.contains) else { continue }
                if names != pkCols { uniques.append(names) }
            }
            plans[name] = ShardTablePlan(name: name, columns: cols, primaryKey: pkCols, integerPrimaryKey: integerPK,
                                         withoutRowid: withoutRowid, foreignKeys: fks, uniqueKeys: uniques)
        }
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: undeclared integer references the
        // merge must follow (an erasure tombstone names its generation by number).
        if plans["erasure_tombstones"] != nil, plans["erasure_generations"] != nil,
           plans["erasure_tombstones"]?.foreignKeys.contains(where: { $0.parent == "erasure_generations" }) == false {
            plans["erasure_tombstones"]?.foreignKeys.append(
                ShardForeignKey(parent: "erasure_generations", from: ["generation"], to: ["generation"]))
        }
        // PERF-20: a table whose rowid-alias key is referenced by another table is merged with fresh ids past the
        // main ledger's highest; references follow the id map (it used to be left out of the merge).
        for (name, p) in plans where p.integerPrimaryKey != nil {
            let referenced = plans.values.contains { other in other.name != name && other.foreignKeys.contains { $0.parent == name } }
            if referenced {
                plans[name]?.remapsIntegerKey = true
                KalsmritikoshLog.storage.info("Shard merge: \(name, privacy: .public) has an integer key other tables refer to; its ids are moved and references remapped")
            }
        }
        return topologicalOrder(plans)
    }

    nonisolated static func topologicalOrder(_ plans: [String: ShardTablePlan]) -> [ShardTablePlan] {
        var remaining = Set(plans.keys)
        var done = Set<String>()
        var order: [ShardTablePlan] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { name in
                plans[name]?.foreignKeys.allSatisfy { $0.parent == name || done.contains($0.parent) || plans[$0.parent] == nil } ?? true
            }.sorted()
            // A cycle: take the alphabetically first table; its held-back rows are retried after the rest.
            let next = ready.isEmpty ? [remaining.sorted()[0]] : ready
            for n in next {
                remaining.remove(n); done.insert(n)
                if let p = plans[n] { order.append(p) }
            }
        }
        return order
    }

    // MARK: Copy

    /// The value a shard column contributes: a reference to a remapped parent row is rewritten to the
    /// main row's id.
    nonisolated static func shardColumnExpr(_ column: String, of plan: ShardTablePlan,
                                            plans: [String: ShardTablePlan], alias: String = "s") -> String {
        let raw = "\(alias).\(ShardSQL.quoteIdent(column))"
        var parent: String?
        if let fk = plan.foreignKeys.first(where: { $0.from == [column] }) {
            if let p = plans[fk.parent], p.remappable, fk.to.isEmpty || fk.to == p.primaryKey { parent = fk.parent }
            // PERF-20: a reference to a moved integer key (the map holds the ids as text).
            if let p = plans[fk.parent], p.remapsIntegerKey, let ipk = p.integerPrimaryKey, fk.to.isEmpty || fk.to == [ipk] {
                return "COALESCE((SELECT r.main_id FROM temp.ingest_shard_remap r WHERE r.tbl = \(ShardSQL.quoteLiteral(fk.parent)) AND r.shard_id = CAST(\(raw) AS TEXT)), \(raw))"
            }
        } else if plan.name != "entities", column == "entity_id" || column.hasSuffix("_entity_id"),
                  plans["entities"]?.remappable == true {
            parent = "entities"   // undeclared entity references
        } else if plan.name == "entities", column == "merged_into" || column == "canonical_id" {
            parent = "entities"
        }
        guard let parent else { return raw }
        return "COALESCE((SELECT r.main_id FROM temp.ingest_shard_remap r WHERE r.tbl = \(ShardSQL.quoteLiteral(parent)) AND r.shard_id = \(raw)), \(raw))"
    }

    /// The WHERE conditions that keep a shard row out of the copy: seed rows, sources the main ledger
    /// already holds, and rows whose parent is not (yet) in the main ledger.
    nonisolated static func shardFilters(_ plan: ShardTablePlan, plans: [String: ShardTablePlan],
                                         seedMark: Int64?, strict: Bool) -> [String] {
        var conds: [String] = []
        if !plan.withoutRowid, let seedMark, seedMark > 0 { conds.append("s.rowid > \(seedMark)") }
        if plan.name == "files" {
            conds.append("NOT EXISTS (SELECT 1 FROM main.files m WHERE m.url = s.url AND m.id <> s.id)")
        }
        for fk in plan.foreignKeys {
            let to = fk.to.isEmpty ? (plans[fk.parent]?.primaryKey ?? []) : fk.to
            guard to.count == fk.from.count, !to.isEmpty else { continue }
            let nulls = fk.from.map { "s.\(ShardSQL.quoteIdent($0)) IS NULL" }.joined(separator: " OR ")
            let match = zip(to, fk.from).map { "p.\(ShardSQL.quoteIdent($0.0)) = \(shardColumnExpr($0.1, of: plan, plans: plans))" }
                .joined(separator: " AND ")
            var cond = "(\(nulls) OR EXISTS (SELECT 1 FROM main.\(ShardSQL.quoteIdent(fk.parent)) p WHERE \(match))"
            if fk.parent == plan.name, !strict {
                let selfMatch = zip(to, fk.from).map { "p2.\(ShardSQL.quoteIdent($0.0)) = s.\(ShardSQL.quoteIdent($0.1))" }
                    .joined(separator: " AND ")
                cond += " OR EXISTS (SELECT 1 FROM \(shardSchema).\(ShardSQL.quoteIdent(plan.name)) p2 WHERE \(selfMatch))"
            }
            conds.append(cond + ")")
        }
        return conds
    }

    private static func copyShardTable(_ db: isolated Database, _ plan: ShardTablePlan, plans: [String: ShardTablePlan],
                                       seedMark: Int64?, strict: Bool, runID: UUID, shardIndex: Int,
                                       recordProgress: Bool, integerOffset: Int64?, exactOffset: Bool = false) throws -> ShardTableResult {
        let t = ShardSQL.quoteIdent(plan.name)
        if plan.remapsIntegerKey, let ipk = plan.integerPrimaryKey {
            return try copyIntegerKeyedTable(db, plan, pk: ipk, plans: plans, seedMark: seedMark, strict: strict,
                                             runID: runID, shardIndex: shardIndex, recordProgress: recordProgress,
                                             plannedOffset: integerOffset, exactOffset: exactOffset)
        }
        var result = ShardTableResult()
        guard !plan.columns.isEmpty else { return result }
        let seedCond = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " WHERE s.rowid > \(seedMark ?? 0)" : ""
        result.candidates = Int(try db.query("SELECT COUNT(*) FROM \(shardSchema).\(t) s\(seedCond);", []).first?.int(0) ?? 0)
        guard result.candidates > 0 else { return result }
        let beforeRowid: Int64 = plan.withoutRowid ? 0
            : (try db.query("SELECT COALESCE(MAX(rowid), 0) FROM main.\(t);", []).first?.int(0) ?? 0)
        let cols = plan.columns.map(ShardSQL.quoteIdent).joined(separator: ", ")
        let exprs = plan.columns.map { shardColumnExpr($0, of: plan, plans: plans) }.joined(separator: ", ")
        let conds = shardFilters(plan, plans: plans, seedMark: seedMark, strict: strict)
        let whereClause = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
        try db.exec("INSERT OR IGNORE INTO main.\(t) (\(cols)) SELECT \(exprs) FROM \(shardSchema).\(t) s\(whereClause);", [])
        result.inserted = Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
        result.remapped = try remap(db, plan, plans: plans, seedMark: seedMark)
        // PERF-20: a clash updates the main row's sources and counts.
        result.folded = foldClashes(db, plan, pk: plan.primaryKey.first, integer: false)
        if result.inserted > 0, !plan.withoutRowid {
            try indexUntriggeredFullText(db, table: plan.name, afterRowid: beforeRowid)
        }
        if recordProgress {
            try db.exec("""
                UPDATE main.ingest_shard_merges SET last_table = ?, rows_merged = rows_merged + ?, updated_at = ?
                WHERE run_id = ? AND shard_index = ?;
                """, [.text(plan.name), .integer(Int64(result.inserted)), .real(Date().timeIntervalSince1970),
                      .text(runID.uuidString), .integer(Int64(shardIndex))])
        }
        return result
    }

    /// Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: copy a table whose INTEGER key other
    /// tables refer to. Clashes on a UNIQUE key map to the main row; every other row takes `id + offset`, where
    /// offset is the main ledger's highest id now (so no id can collide), and the id map records it.
    private static func copyIntegerKeyedTable(_ db: isolated Database, _ plan: ShardTablePlan, pk: String,
                                              plans: [String: ShardTablePlan], seedMark: Int64?, strict: Bool,
                                              runID: UUID, shardIndex: Int, recordProgress: Bool,
                                              plannedOffset: Int64?, exactOffset: Bool = false) throws -> ShardTableResult {
        let t = ShardSQL.quoteIdent(plan.name)
        let pkq = ShardSQL.quoteIdent(pk)
        let lit = ShardSQL.quoteLiteral(plan.name)
        var result = ShardTableResult()
        let seedCond = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " WHERE s.rowid > \(seedMark ?? 0)" : ""
        result.candidates = Int(try db.query("SELECT COUNT(*) FROM \(shardSchema).\(t) s\(seedCond);", []).first?.int(0) ?? 0)
        guard result.candidates > 0 else { return result }
        let currentMax = try db.query("SELECT COALESCE(MAX(\(pkq)), 0) FROM main.\(t);", []).first?.int(0) ?? 0
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet. A retry of rows held back for a missing parent uses the SAME offset as the
        // first copy (exactOffset), so rows already copied collide on their moved id and are skipped, never duplicated.
        let offset = exactOffset ? (plannedOffset ?? currentMax) : max(currentMax, plannedOffset ?? 0)
        result.integerOffset = offset
        // 1. Rows that stand for an existing main row (same UNIQUE key).
        let before = Int(try db.query("SELECT COUNT(*) FROM temp.ingest_shard_remap WHERE tbl = \(lit);", []).first?.int(0) ?? 0)
        for key in plan.uniqueKeys {
            let join = key.map { "m.\(ShardSQL.quoteIdent($0)) = \(shardColumnExpr($0, of: plan, plans: plans))" }.joined(separator: " AND ")
            let seed = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " AND s.rowid > \(seedMark ?? 0)" : ""
            try db.exec("""
                INSERT OR IGNORE INTO temp.ingest_shard_remap (tbl, shard_id, main_id)
                SELECT \(lit), CAST(s.\(pkq) AS TEXT), CAST(m.\(pkq) AS TEXT)
                FROM \(shardSchema).\(t) s JOIN main.\(t) m ON \(join)
                WHERE 1 = 1\(seed);
                """, [])
        }
        // 2. The other rows, with moved ids.
        let cols = ([pk] + plan.columns).map(ShardSQL.quoteIdent).joined(separator: ", ")
        let exprs = (["s.\(pkq) + \(offset)"] + plan.columns.map { shardColumnExpr($0, of: plan, plans: plans) }).joined(separator: ", ")
        var conds = shardFilters(plan, plans: plans, seedMark: seedMark, strict: strict)
        conds.append("NOT EXISTS (SELECT 1 FROM temp.ingest_shard_remap r WHERE r.tbl = \(lit) AND r.shard_id = CAST(s.\(pkq) AS TEXT))")
        let beforeRowid = currentMax
        try db.exec("INSERT OR IGNORE INTO main.\(t) (\(cols)) SELECT \(exprs) FROM \(shardSchema).\(t) s WHERE \(conds.joined(separator: " AND "));", [])
        result.inserted = Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
        _ = try recordIntegerMap(db, plan, pk: pk, offset: offset, seedMark: seedMark)
        let after = Int(try db.query("SELECT COUNT(*) FROM temp.ingest_shard_remap WHERE tbl = \(lit);", []).first?.int(0) ?? 0)
        result.remapped = max(0, after - before - result.inserted)
        result.folded = foldClashes(db, plan, pk: pk, integer: true)
        if result.inserted > 0 { try indexUntriggeredFullText(db, table: plan.name, afterRowid: beforeRowid) }
        if recordProgress {
            try db.exec("""
                UPDATE main.ingest_shard_merges SET last_table = ?, rows_merged = rows_merged + ?, updated_at = ?
                WHERE run_id = ? AND shard_index = ?;
                """, [.text(plan.name), .integer(Int64(result.inserted)), .real(Date().timeIntervalSince1970),
                      .text(runID.uuidString), .integer(Int64(shardIndex))])
        }
        return result
    }

    /// Record `shard id → shard id + offset` for every shard row whose moved id is in the main ledger.
    static func recordIntegerMap(_ db: isolated Database, _ plan: ShardTablePlan, pk: String, offset: Int64,
                                 seedMark: Int64?) throws -> Int {
        let t = ShardSQL.quoteIdent(plan.name)
        let pkq = ShardSQL.quoteIdent(pk)
        let lit = ShardSQL.quoteLiteral(plan.name)
        let seed = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " AND s.rowid > \(seedMark ?? 0)" : ""
        try db.exec("""
            INSERT OR IGNORE INTO temp.ingest_shard_remap (tbl, shard_id, main_id, folded)
            SELECT \(lit), CAST(s.\(pkq) AS TEXT), CAST(s.\(pkq) + \(offset) AS TEXT), 1
            FROM \(shardSchema).\(t) s
            WHERE EXISTS (SELECT 1 FROM main.\(t) m WHERE m.\(pkq) = s.\(pkq) + \(offset))\(seed);
            """, [])
        return Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
    }

    /// Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: fold the shard rows that were mapped to
    /// an existing main row (UNIQUE clash) into that row — counts added, id lists unioned, confidence the
    /// higher, first_seen the earlier, last_seen the later. Each mapped row is folded once (`folded` flag),
    /// inside its own nested savepoint so a table whose triggers refuse updates keeps its merged rows.
    static func foldClashes(_ db: isolated Database, _ plan: ShardTablePlan, pk: String?, integer: Bool) -> Int {
        guard let pk else { return 0 }
        let t = ShardSQL.quoteIdent(plan.name)
        let pkq = ShardSQL.quoteIdent(pk)
        let lit = ShardSQL.quoteLiteral(plan.name)
        let keyCols = Set(plan.uniqueKeys.flatMap { $0 } + plan.primaryKey)
        let matched = "FROM \(shardSchema).\(t) s JOIN temp.ingest_shard_remap r ON r.tbl = \(lit) AND r.shard_id = CAST(s.\(pkq) AS TEXT) AND r.folded = 0 WHERE r.main_id = CAST(\(t).\(pkq) AS TEXT)"
        var sets: [String] = []
        for c in plan.columns where !keyCols.contains(c) {
            let lc = c.lowercased()
            let q = ShardSQL.quoteIdent(c)
            if lc == "weight" || lc == "count" || lc.hasSuffix("_count") || lc == "occurrences" {
                sets.append("\(q) = COALESCE(\(q), 0) + COALESCE((SELECT SUM(s.\(q)) \(matched)), 0)")
            } else if lc.hasSuffix("_ids_json") || lc.hasSuffix("_ids") || lc == "source_ids" {
                sets.append("""
                    \(q) = COALESCE((SELECT json_group_array(v) FROM (
                        SELECT j.value AS v FROM json_each(CASE WHEN json_valid(\(t).\(q)) AND json_type(\(t).\(q)) = 'array' THEN \(t).\(q) ELSE '[]' END) j
                        UNION
                        SELECT j2.value FROM \(shardSchema).\(t) s JOIN temp.ingest_shard_remap r ON r.tbl = \(lit) AND r.shard_id = CAST(s.\(pkq) AS TEXT) AND r.folded = 0,
                            json_each(CASE WHEN json_valid(s.\(q)) AND json_type(s.\(q)) = 'array' THEN s.\(q) ELSE '[]' END) j2
                        WHERE r.main_id = CAST(\(t).\(pkq) AS TEXT))), \(q))
                    """)
            } else if lc == "confidence" {
                sets.append("\(q) = MAX(COALESCE(\(q), 0), COALESCE((SELECT MAX(s.\(q)) \(matched)), 0))")
            } else if lc.hasPrefix("first_seen") {
                sets.append("\(q) = COALESCE(MIN(\(q), (SELECT MIN(s.\(q)) \(matched))), \(q))")
            } else if lc.hasPrefix("last_seen") {
                sets.append("\(q) = COALESCE(MAX(\(q), (SELECT MAX(s.\(q)) \(matched))), \(q))")
            }
        }
        var folded = 0
        do {
            let pending = Int(try db.query("SELECT COUNT(*) FROM temp.ingest_shard_remap WHERE tbl = \(lit) AND folded = 0;", []).first?.int(0) ?? 0)
            guard pending > 0 else { return 0 }
            if !sets.isEmpty {
                try db.execRaw("SAVEPOINT shard_fold;")
                do {
                    try db.exec("""
                        UPDATE main.\(t) SET \(sets.joined(separator: ", "))
                        WHERE CAST(\(pkq) AS TEXT) IN (SELECT main_id FROM temp.ingest_shard_remap WHERE tbl = \(lit) AND folded = 0);
                        """, [])
                    folded = Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
                    try db.execRaw("RELEASE SAVEPOINT shard_fold;")
                } catch {
                    KalsmritikoshLog.storage.notice("Shard merge: clashing rows of \(plan.name, privacy: .public) not folded into the main rows (kept as merged): \(String(describing: error), privacy: .public)")
                    do {
                        try db.execRaw("ROLLBACK TO SAVEPOINT shard_fold;")
                        try db.execRaw("RELEASE SAVEPOINT shard_fold;")
                    } catch {
                        KalsmritikoshLog.storage.error("Shard merge: fold savepoint not unwound: \(String(describing: error), privacy: .public)")
                    }
                    folded = 0
                }
            }
            try db.exec("UPDATE temp.ingest_shard_remap SET folded = 1 WHERE tbl = \(lit) AND folded = 0;", [])
        } catch {
            KalsmritikoshLog.storage.error("Shard merge: fold of \(plan.name, privacy: .public) skipped: \(String(describing: error), privacy: .public)")
        }
        if folded > 0 {
            KalsmritikoshLog.storage.info("Shard merge: \(folded, privacy: .public) main row(s) of \(plan.name, privacy: .public) took the sources and counts of their shard twins")
        }
        return folded
    }

    /// Map shard ids of rows that stand for existing main rows (same UNIQUE key) to the main ids.
    private static func remap(_ db: isolated Database, _ plan: ShardTablePlan, plans: [String: ShardTablePlan],
                              seedMark: Int64?) throws -> Int {
        guard plan.remappable, let pk = plan.primaryKey.first else { return 0 }
        let t = ShardSQL.quoteIdent(plan.name)
        let pkq = ShardSQL.quoteIdent(pk)
        var mapped = 0
        for key in plan.uniqueKeys {
            let join = key.map { "m.\(ShardSQL.quoteIdent($0)) = \(shardColumnExpr($0, of: plan, plans: plans))" }
                .joined(separator: " AND ")
            let seed = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " AND s.rowid > \(seedMark ?? 0)" : ""
            try db.exec("""
                INSERT OR IGNORE INTO temp.ingest_shard_remap (tbl, shard_id, main_id)
                SELECT \(ShardSQL.quoteLiteral(plan.name)), s.\(pkq), m.\(pkq)
                FROM \(shardSchema).\(t) s JOIN main.\(t) m ON \(join)
                WHERE m.\(pkq) <> s.\(pkq) AND NOT EXISTS (SELECT 1 FROM main.\(t) x WHERE x.\(pkq) = s.\(pkq))\(seed);
                """, [])
            mapped += Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
        }
        return mapped
    }

    /// External-content full-text indexes over `table` that no trigger of the main ledger maintains
    /// (the question / answer indexes are written by their repositories): index the new rows here.
    private static func indexUntriggeredFullText(_ db: isolated Database, table: String, afterRowid: Int64) throws {
        let vtabs = try db.query("""
            SELECT name, sql FROM main.sqlite_master WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%fts5%';
            """, [])
        for v in vtabs {
            guard let fts = v.string(0), let sql = v.string(1),
                  sql.replacingOccurrences(of: " ", with: "").lowercased().contains("content='\(table.lowercased())'") else { continue }
            let triggered = try db.query("""
                SELECT COUNT(*) FROM main.sqlite_master WHERE type = 'trigger' AND tbl_name = ? AND sql LIKE ?;
                """, [.text(table), .text("%INSERT INTO \(fts)%")]).first?.int(0) ?? 0
            if triggered > 0 { continue }
            let ftsCols = try db.query("SELECT name FROM pragma_table_info(\(ShardSQL.quoteLiteral(fts)), 'main');", [])
                .compactMap { $0.string(0) }
            guard !ftsCols.isEmpty else { continue }
            let list = ftsCols.map(ShardSQL.quoteIdent).joined(separator: ", ")
            try db.exec("""
                INSERT INTO main.\(ShardSQL.quoteIdent(fts)) (rowid, \(list))
                SELECT rowid, \(list) FROM main.\(ShardSQL.quoteIdent(table)) WHERE rowid > ?;
                """, [.integer(afterRowid)])
        }
    }

    // MARK: Merge log (ingest_shard_merges, v199)

    public func recordShard(runID: UUID, index: Int, path: String, state: String, files: Int) throws {
        let now = Date().timeIntervalSince1970
        try exec("""
            INSERT INTO ingest_shard_merges (run_id, shard_index, shard_path, state, files, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (run_id, shard_index) DO UPDATE SET state = excluded.state, files = excluded.files,
                shard_path = excluded.shard_path, error = NULL, updated_at = excluded.updated_at;
            """, [.text(runID.uuidString), .integer(Int64(index)), .text(path), .text(state), .integer(Int64(files)),
                  .real(now), .real(now)])
    }

    public func setShardState(runID: UUID, index: Int, state: String, error: String? = nil) throws {
        try exec("""
            UPDATE ingest_shard_merges SET state = ?, error = ?, updated_at = ? WHERE run_id = ? AND shard_index = ?;
            """, [.text(state), error.map(SQLValue.text) ?? .null, .real(Date().timeIntervalSince1970),
                  .text(runID.uuidString), .integer(Int64(index))])
    }

    /// Shards not yet merged (writing / written / merging), oldest first. Read live (inside a savepoint),
    /// never from an ask's snapshot.
    public func unmergedShards() throws -> [ShardMergeRecord] {
        try withSavepoint("shard_log_read") { db in
            try db.query("""
                SELECT run_id, shard_index, shard_path, state, last_table FROM ingest_shard_merges
                WHERE state IN ('writing','written','merging') ORDER BY created_at, shard_index;
                """, []).compactMap(Database.shardRecord(from:))
        }
    }

    public func shardRecord(runID: UUID, index: Int) throws -> ShardMergeRecord? {
        try withSavepoint("shard_log_read") { db in
            try db.query("""
                SELECT run_id, shard_index, shard_path, state, last_table FROM ingest_shard_merges WHERE run_id = ? AND shard_index = ?;
                """, [.text(runID.uuidString), .integer(Int64(index))]).first.flatMap(Database.shardRecord(from:))
        }
    }

    nonisolated static func shardRecord(from r: SQLRow) -> ShardMergeRecord? {
        guard let run = r.uuid(0), let idx = r.int(1), let path = r.string(2), let state = r.string(3) else { return nil }
        return ShardMergeRecord(runID: run, index: Int(idx), path: path, state: state, lastTable: r.string(4))
    }

    /// Rows of the attached shard (above its seed mark) whose key the main ledger does not hold.
    public func shardRowsNotInMain(_ plan: ShardTablePlan, seedMark: Int64?, integerOffset: Int64? = nil) throws -> Int {
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet. Integer-keyed rows: not in main under their moved id and not mapped to a main row.
        if let pk = plan.integerPrimaryKey, let offset = integerOffset {
            return try withSavepoint("shard_left_int") { db in
                let t = ShardSQL.quoteIdent(plan.name), pkq = ShardSQL.quoteIdent(pk)
                let seed = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " AND s.rowid > \(seedMark ?? 0)" : ""
                return Int(try db.query("""
                    SELECT COUNT(*) FROM \(Database.shardSchema).\(t) s
                    WHERE NOT EXISTS (SELECT 1 FROM main.\(t) m WHERE m.\(pkq) = s.\(pkq) + \(offset))
                      AND NOT EXISTS (SELECT 1 FROM temp.ingest_shard_remap r WHERE r.tbl = \(ShardSQL.quoteLiteral(plan.name)) AND r.shard_id = CAST(s.\(pkq) AS TEXT))\(seed);
                    """, []).first?.int(0) ?? 0)
            }
        }
        guard !plan.primaryKey.isEmpty, plan.integerPrimaryKey == nil else { return 0 }
        return try withSavepoint("shard_left") { db in
            let t = ShardSQL.quoteIdent(plan.name)
            let match = plan.primaryKey.map { "m.\(ShardSQL.quoteIdent($0)) = s.\(ShardSQL.quoteIdent($0))" }.joined(separator: " AND ")
            let seed = (!plan.withoutRowid && (seedMark ?? 0) > 0) ? " AND s.rowid > \(seedMark ?? 0)" : ""
            return Int(try db.query("""
                SELECT COUNT(*) FROM \(Database.shardSchema).\(t) s
                WHERE NOT EXISTS (SELECT 1 FROM main.\(t) m WHERE \(match))
                  AND NOT EXISTS (SELECT 1 FROM temp.ingest_shard_remap r WHERE r.tbl = \(ShardSQL.quoteLiteral(plan.name)) AND r.shard_id = s.\(ShardSQL.quoteIdent(plan.primaryKey[0])))\(seed);
                """, []).first?.int(0) ?? 0)
        }
    }
}

// MARK: - Orchestration

public nonisolated struct ShardMerger: Sendable {
    public let main: Database
    public init(main: Database) { self.main = main }

    /// How many extra passes retry rows held back for a parent that arrived later.
    static let retryPasses = 3

    /// Merge one closed shard file into the main ledger. Resumes after the last table a previous,
    /// interrupted merge of this shard committed. Deletes the shard only once its row says merged.
    public func merge(runID: UUID, index: Int, shardURL: URL) async -> ShardMergeOutcome {
        guard FileManager.default.fileExists(atPath: shardURL.path) else {
            let why = "the shard file is missing"
            do { try await main.setShardState(runID: runID, index: index, state: "failed", error: why) } catch {
                KalsmritikoshLog.storage.error("Shard merge: state not recorded: \(String(describing: error), privacy: .public)")
            }
            return .failed(why)
        }
        let previous: ShardMergeRecord?
        do { previous = try await main.shardRecord(runID: runID, index: index) } catch {
            KalsmritikoshLog.storage.error("Shard merge: merge log unreadable: \(String(describing: error), privacy: .public)")
            previous = nil
        }
        do { try await main.setShardState(runID: runID, index: index, state: "merging") } catch {
            KalsmritikoshLog.storage.error("Shard merge: state not recorded: \(String(describing: error), privacy: .public)")
        }
        let seedMarks = ShardLedger.loadSeedMarks(for: shardURL)
        // PERF-20: the id offsets of integer-keyed tables (kept beside the shard so a resume can rebuild the map).
        var offsets = ShardLedger.loadOffsets(for: shardURL)
        do {
            try await main.attachShard(at: shardURL)
        } catch {
            let why = "the shard could not be attached: \(error)"
            KalsmritikoshLog.storage.error("Shard merge: \(why, privacy: .public)")
            do { try await main.setShardState(runID: runID, index: index, state: "failed", error: String(why.prefix(500))) } catch {
                KalsmritikoshLog.storage.error("Shard merge: state not recorded: \(String(describing: error), privacy: .public)")
            }
            return .failed(why)
        }
        var errors: [String] = []
        var rows = 0
        var heldBack = 0
        var tableCount = 0
        do {
            let order = try await main.shardMergePlan()
            tableCount = order.count
            let plans = Dictionary(uniqueKeysWithValues: order.map { ($0.name, $0) })
            // Resume: tables up to the last committed one are done; only their id maps are rebuilt.
            var resumeAfter = -1
            if previous?.state == "merging", let last = previous?.lastTable, let i = order.firstIndex(where: { $0.name == last }) {
                resumeAfter = i
                KalsmritikoshLog.storage.info("Shard merge: shard \(index, privacy: .public) resumes after \(last, privacy: .public)")
            }
            var retry: [ShardTablePlan] = []
            for (i, plan) in order.enumerated() {
                if Task.isCancelled { errors.append("cancelled"); break }
                let mark = seedMarks[plan.name]
                if i <= resumeAfter {
                    do { _ = try await main.remapShardTable(plan, plans: plans, seedMark: mark, integerOffset: offsets[plan.name]) } catch {
                        errors.append("\(plan.name) (id map): \(error)")
                        KalsmritikoshLog.storage.error("Shard merge: id map of \(plan.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                    if plan.idempotent { retry.append(plan) }
                    continue
                }
                do {
                    // PERF-20: an integer-keyed table's offset is written down BEFORE its rows are committed.
                    var planned: Int64?
                    if plan.remapsIntegerKey {
                        let o = try await main.mainMaxIntegerKey(plan)
                        planned = o
                        offsets[plan.name] = o
                        ShardLedger.writeOffsets(offsets, for: shardURL)
                    }
                    let r: ShardTableResult
                    do {
                        r = try await main.mergeShardTable(plan, plans: plans, seedMark: mark, runID: runID, shardIndex: index,
                                                           strict: false, recordProgress: true, integerOffset: planned)
                    } catch {
                        // A same-statement self-reference to a row that was not copied: copy only rows whose
                        // parent is already in the main ledger now, and retry the rest below.
                        KalsmritikoshLog.storage.notice("Shard merge: \(plan.name, privacy: .public) retried strictly: \(String(describing: error), privacy: .public)")
                        r = try await main.mergeShardTable(plan, plans: plans, seedMark: mark, runID: runID, shardIndex: index,
                                                           strict: true, recordProgress: true, integerOffset: planned)
                    }
                    if let used = r.integerOffset, used != planned {
                        offsets[plan.name] = used
                        ShardLedger.writeOffsets(offsets, for: shardURL)
                    }
                    rows += r.inserted
                    // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet. Integer-keyed tables are retried too (same offset).
                    if r.heldBack > 0, plan.idempotent || (plan.remapsIntegerKey && offsets[plan.name] != nil) { retry.append(plan) }
                } catch {
                    errors.append("\(plan.name): \(error)")
                    KalsmritikoshLog.storage.error("Shard merge: table \(plan.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            // Rows held back for a parent that a later table brought in.
            var pass = 0
            while !retry.isEmpty, pass < Self.retryPasses, errors.isEmpty {
                pass += 1
                var progressed = false
                var still: [ShardTablePlan] = []
                for plan in retry {
                    do {
                        let integer = plan.remapsIntegerKey ? offsets[plan.name] : nil
                        let r = try await main.mergeShardTable(plan, plans: plans, seedMark: seedMarks[plan.name], runID: runID,
                                                               shardIndex: index, strict: true, recordProgress: false,
                                                               integerOffset: integer, exactOffset: integer != nil)
                        rows += r.inserted
                        if r.inserted > 0 { progressed = true }
                        if let integer {
                            if try await main.shardRowsNotInMain(plan, seedMark: seedMarks[plan.name], integerOffset: integer) > 0 { still.append(plan) }
                        } else if r.heldBack > 0 { still.append(plan) }
                    } catch {
                        errors.append("\(plan.name) (retry): \(error)")
                        KalsmritikoshLog.storage.error("Shard merge: retry of \(plan.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
                retry = still
                if !progressed { break }
            }
            for plan in retry {
                let left: Int
                do { left = try await main.shardRowsNotInMain(plan, seedMark: seedMarks[plan.name],
                                                              integerOffset: plan.remapsIntegerKey ? offsets[plan.name] : nil) } catch {
                    KalsmritikoshLog.storage.error("Shard merge: rows left in \(plan.name, privacy: .public) not counted: \(String(describing: error), privacy: .public)")
                    continue
                }
                heldBack += left
                if left > 0 {
                    KalsmritikoshLog.storage.notice("Shard merge: \(left, privacy: .public) row(s) of \(plan.name, privacy: .public) not merged (their parent row is not in the ledger, or they stand for a row it already holds)")
                }
            }
        } catch {
            errors.append("plan: \(error)")
            KalsmritikoshLog.storage.error("Shard merge: plan failed: \(String(describing: error), privacy: .public)")
        }
        do { try await main.detachShard() } catch {
            errors.append("detach: \(error)")
            KalsmritikoshLog.storage.error("Shard merge: detach failed: \(String(describing: error), privacy: .public)")
        }
        guard errors.isEmpty else {
            let why = errors.joined(separator: "; ")
            do { try await main.setShardState(runID: runID, index: index, state: "failed", error: String(why.prefix(2000))) } catch {
                KalsmritikoshLog.storage.error("Shard merge: state not recorded: \(String(describing: error), privacy: .public)")
            }
            return .failed(why)
        }
        do {
            try await main.setShardState(runID: runID, index: index, state: "merged")
            ShardLedger.removeFiles(at: shardURL)
        } catch {
            // Not recorded as merged: the file stays, and a later merge re-runs it (INSERT OR IGNORE).
            KalsmritikoshLog.storage.error("Shard merge: merged state not recorded; shard kept: \(String(describing: error), privacy: .public)")
        }
        KalsmritikoshLog.storage.info("Shard merge: shard \(index, privacy: .public) of run \(runID.uuidString, privacy: .public) merged — \(rows, privacy: .public) row(s) over \(tableCount, privacy: .public) table(s), \(heldBack, privacy: .public) held back")
        return .merged(rows: rows, tables: tableCount, heldBack: heldBack)
    }
}
