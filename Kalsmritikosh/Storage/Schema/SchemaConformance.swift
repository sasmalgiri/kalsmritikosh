//
//  SchemaConformance.swift
//  Kalsmritikosh
//
//  2026-10-24 — the self-heal check that stopped tracking new migrations after v118 could stamp a
//  ledger "latest" without running a migration. The repair pass re-runs create-if-missing
//  migrations, but migrations that ALTER or rebuild tables can't be re-run. This closes the rest:
//  build a fresh, empty ledger at the latest version in a temporary file, compare it with the live
//  ledger, and add whatever the live one lacks — tables, indexes and triggers from their exact
//  original SQL, columns with ADD COLUMN. It only ever adds; it never drops, rewrites or moves data.
//  Runs once per schema version (and again whenever a previous run found something it could not add).
//

import Foundation
import os

public nonisolated enum SchemaConformance {

    public struct Report: Sendable, Equatable {
        public var added: [String] = []
        public var couldNotAdd: [String] = []
        public var isClean: Bool { added.isEmpty && couldNotAdd.isEmpty }
    }

    static let checkedKey = "kalsmritikosh.schemaConformance.checkedVersion"

    /// Boot entry: check once per schema version.
    public static func checkAtBoot(_ live: Database, defaults: UserDefaults = .standard) async {
        guard defaults.integer(forKey: checkedKey) != SchemaMigrations.latestVersion else { return }
        do {
            let report = try await repair(live)
            if !report.added.isEmpty {
                KalsmritikoshLog.storage.notice("Schema conformance added \(report.added.count) object(s): \(report.added.joined(separator: ", "), privacy: .public)")
            }
            if report.couldNotAdd.isEmpty {
                defaults.set(SchemaMigrations.latestVersion, forKey: checkedKey)
            } else {
                KalsmritikoshLog.storage.error("Schema conformance could not add: \(report.couldNotAdd.joined(separator: ", "), privacy: .public)")
            }
        } catch {
            KalsmritikoshLog.storage.error("Schema conformance check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    struct Object: Hashable { let type: String; let name: String; let table: String; let sql: String }
    struct Column: Hashable { let name: String; let type: String; let notNull: Bool; let defaultValue: String? }

    static func objects(_ db: Database) async throws -> [Object] {
        try await db.query("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%';", [])
            .compactMap { r in
                guard let t = r.string(0), let n = r.string(1), let tb = r.string(2), let sql = r.string(3) else { return nil }
                return Object(type: t, name: n, table: tb, sql: sql)
            }
    }

    static func columns(_ db: Database, _ table: String) async throws -> [Column] {
        try await db.query("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\");", [])
            .compactMap { r in
                guard let n = r.string(1) else { return nil }
                return Column(name: n, type: r.string(2) ?? "", notNull: (r.int(3) ?? 0) != 0,
                              defaultValue: r.isNull(4) ? nil : (r.string(4) ?? r.int(4).map(String.init) ?? r.double(4).map { String($0) }))
            }
    }

    /// Compare `live` with a fresh ledger at the latest version and add what is missing.
    public static func repair(_ live: Database) async throws -> Report {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("schema-reference-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let reference = try Database(url: url)
        try await SchemaMigrations.migrate(reference)
        return try await repair(live, against: reference)
    }

    static func repair(_ live: Database, against reference: Database) async throws -> Report {
        var report = Report()
        let ref = try await objects(reference)
        let have = Set(try await objects(live).map { "\($0.type)|\($0.name)" })
        // Virtual tables create their own shadow tables; never create those directly.
        let virtuals = ref.filter { $0.type == "table" && $0.sql.uppercased().hasPrefix("CREATE VIRTUAL") }.map(\.name)
        func isShadow(_ name: String) -> Bool { virtuals.contains { name != $0 && name.hasPrefix($0 + "_") } }

        // 1. Tables (virtual tables first), then 2. columns, then 3. indexes and triggers.
        let tables = ref.filter { $0.type == "table" && !isShadow($0.name) }
            .sorted { ($0.sql.uppercased().hasPrefix("CREATE VIRTUAL") ? 0 : 1) < ($1.sql.uppercased().hasPrefix("CREATE VIRTUAL") ? 0 : 1) }
        for t in tables where !have.contains("table|\(t.name)") {
            if await apply(live, t.sql, name: "table \(t.name)") { report.added.append("table \(t.name)") }
            else { report.couldNotAdd.append("table \(t.name)") }
        }
        for t in tables where have.contains("table|\(t.name)") && !t.sql.uppercased().hasPrefix("CREATE VIRTUAL") {
            let liveCols = Set(try await columns(live, t.name).map(\.name))
            for c in try await columns(reference, t.name) where !liveCols.contains(c.name) {
                var def = "ALTER TABLE \"\(t.name)\" ADD COLUMN \"\(c.name)\" \(c.type)"
                if let d = c.defaultValue { def += " DEFAULT \(d)" }
                if c.notNull {
                    guard c.defaultValue != nil else { report.couldNotAdd.append("column \(t.name).\(c.name) (NOT NULL without a default)"); continue }
                    def += " NOT NULL"
                }
                if await apply(live, def + ";", name: "column \(t.name).\(c.name)") { report.added.append("column \(t.name).\(c.name)") }
                else { report.couldNotAdd.append("column \(t.name).\(c.name)") }
            }
        }
        let nowHave = Set(try await objects(live).map { "\($0.type)|\($0.name)" })
        for o in ref where (o.type == "index" || o.type == "trigger" || o.type == "view") && !isShadow(o.table)
            && !nowHave.contains("\(o.type)|\(o.name)") {
            if await apply(live, o.sql, name: "\(o.type) \(o.name)") { report.added.append("\(o.type) \(o.name)") }
            else { report.couldNotAdd.append("\(o.type) \(o.name)") }
        }
        return report
    }

    /// One statement in its own savepoint; a failure is rolled back and reported, never thrown.
    static func apply(_ db: Database, _ sql: String, name: String) async -> Bool {
        let sp = "schema_conformance_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await db.exec("SAVEPOINT \(sp);")
            try await db.exec(sql.hasSuffix(";") ? sql : sql + ";")
            try await db.exec("RELEASE SAVEPOINT \(sp);")
            return true
        } catch {
            try? await db.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await db.exec("RELEASE SAVEPOINT \(sp);")
            KalsmritikoshLog.storage.error("Schema conformance: \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
