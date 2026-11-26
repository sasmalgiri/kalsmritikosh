//
//  RetentionRegister.swift
//  Kalsmritikosh
//
//  ALCOA ALC-20 (DATA-30, owner 2026-11-24) — enduring. The retention register: for each class of record the app keeps,
//  how long it is kept (a default here; the person may change it in Settings ▸ Retention, each change kept with who,
//  when and why — v221 retention_rules, append-only). The app never deletes on its own (owner rule: never delete data):
//  a row past its period is only LISTED as due for review, and a row of a case under a legal hold (an unreleased hold
//  notice, or a held item on the case or one of its documents) is never due — the hold overrides. Removing anything is
//  an erasure, done by the person.
//

import Foundation
import os

public actor RetentionRegister {

    /// One class of record: the tables it covers, the column that dates a row, and the column naming its case (for the
    /// legal-hold override). `defaultDays` nil = kept until the person erases it.
    public struct TableClass: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let tables: [String]
        public let dateColumn: String
        public let caseColumn: String?
        public let defaultDays: Int?
        public let why: String
    }

    static let sevenYears = 2_557
    static let dateColumns = ["recorded_at", "occurred_at", "sent_at", "started_at", "produced_at", "replaced_at", "observed_at",
                              "requested_at", "created_at", "sealed_at", "erased_at", "finished_at", "at"]

    /// The register's classes and defaults.
    public static let classes: [TableClass] = [
        .init(id: "caseRecords", label: "Case records (map, journal, reports, decisions)", tables: ["case_actions"], dateColumn: "at", caseColumn: "case_id",
              defaultDays: nil, why: "Kept until the case is erased; the case log is the record of the work."),
        .init(id: "auditChain", label: "Audit chain, erasure registers and tombstones", tables: ["audit_chain", "case_erasures", "audit_chain_tombstones"],
              dateColumn: "recorded_at", caseColumn: nil, defaultDays: nil, why: "Kept for ever: they prove what happened, including erasures."),
        .init(id: "custody", label: "Chain of custody and source versions", tables: ["custody_events"], dateColumn: "at", caseColumn: nil,
              defaultDays: nil, why: "Kept while the document is kept; removed only with the document."),
        .init(id: "aiRuns", label: "AI runs, replies, tool steps and refused writes",
              tables: ["case_ai_runs", "case_ai_run_exchanges", "case_ai_rejected_writes"], dateColumn: "recorded_at", caseColumn: "case_id",
              defaultDays: sevenYears, why: "Seven years by default, so an AI-assisted finding can be reconstructed."),
        .init(id: "outbound", label: "What was sent online (outbound log)", tables: ["outbound_log"], dateColumn: "sent_at", caseColumn: nil,
              defaultDays: sevenYears, why: "Seven years by default: what left this Mac, when and to whom."),
        .init(id: "access", label: "Access log (who opened what)", tables: ["case_access_events"], dateColumn: "occurred_at", caseColumn: "case_id",
              defaultDays: sevenYears, why: "Seven years by default."),
        .init(id: "clock", label: "Clock jumps and trusted timestamps", tables: ["clock_events", "trusted_timestamps"], dateColumn: "observed_at", caseColumn: nil,
              defaultDays: sevenYears, why: "Seven years by default."),
        .init(id: "exports", label: "Export certifications", tables: ["export_certifications"], dateColumn: "produced_at", caseColumn: "case_id",
              defaultDays: sevenYears, why: "Seven years by default: what was exported, with its SHA-256."),
        .init(id: "askTranscripts", label: "Ask transcripts (including retracted ones)", tables: ["conversations"], dateColumn: "started_at", caseColumn: "case_id",
              defaultDays: nil, why: "Kept until erased; Retract hides a transcript and keeps it."),
        .init(id: "cleanedText", label: "Earlier cleaned texts", tables: ["clean_content_versions"], dateColumn: "replaced_at", caseColumn: nil,
              defaultDays: nil, why: "Kept with their document."),
    ]

    /// A class with the period in force and, when reviewed, how many rows are past it.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let tableClass: TableClass
        public let keepDays: Int?
        public let setBy: String?
        public let setAt: Date?
        public let reason: String?
        public var id: String { tableClass.id }
        public var periodText: String { keepDays.map { $0 % 365 == 0 || $0 == RetentionRegister.sevenYears ? "\(max(1, $0 / 365)) years" : "\($0) days" } ?? "until erased" }
        public var isDefault: Bool { setBy == nil }
    }

    public struct Review: Sendable, Equatable {
        public let classID: String
        /// Rows past the period (not under a hold).
        public let due: Int
        /// Rows past the period kept because their case is under a legal hold.
        public let heldBack: Int
    }

    public enum RetentionError: Error, LocalizedError {
        case unknownClass, reasonNeeded, kept(String)
        public var errorDescription: String? {
            switch self {
            case .unknownClass: return "That retention class is not in the register."
            case .reasonNeeded: return "Say why: every change to the retention register keeps its reason."
            case .kept(let why): return "\(why) cannot be shortened: it is kept for ever."
            }
        }
    }

    private let database: Database

    public init(database: Database) { self.database = database }

    /// Every class with the period in force (the newest change, else the default).
    public func entries() async throws -> [Entry] {
        let rows = try await database.query("""
            SELECT table_class, keep_days, set_by, set_at, reason FROM retention_rules r
            WHERE set_at = (SELECT MAX(set_at) FROM retention_rules x WHERE x.table_class = r.table_class);
            """, [])
        var latest: [String: SQLRow] = [:]
        for r in rows { if let c = r.string(0) { latest[c] = r } }
        return Self.classes.map { c in
            guard let r = latest[c.id] else { return Entry(tableClass: c, keepDays: c.defaultDays, setBy: nil, setAt: nil, reason: nil) }
            return Entry(tableClass: c, keepDays: r.int(1).map(Int.init), setBy: r.string(2), setAt: r.date(3), reason: r.string(4))
        }
    }

    /// Change a class's period (nil = until erased). The audit chain class is kept for ever and cannot be given a period.
    public func set(classID: String, keepDays: Int?, by actor: String, reason: String, at date: Date = Date()) async throws {
        guard let c = Self.classes.first(where: { $0.id == classID }) else { throw RetentionError.unknownClass }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RetentionError.reasonNeeded }
        if c.id == "auditChain" || c.id == "custody", keepDays != nil { throw RetentionError.kept(c.label) }
        try await database.exec("""
            INSERT INTO retention_rules (id, table_class, keep_days, set_by, set_at, reason) VALUES (?,?,?,?,?,?);
            """, [.uuid(UUID()), .text(classID), keepDays.map { .integer(Int64(max(1, $0))) } ?? .null, .text(actor), .date(date), .text(reason)])
    }

    /// The cases under a legal hold now (unreleased hold notices, or held items on the case or its documents).
    func heldCases() async throws -> Set<String> {
        var out = Set<String>()
        do {
            for r in try await database.query("SELECT DISTINCT upper(case_id) FROM case_hold_notices WHERE released_at IS NULL;", []) {
                if let c = r.string(0) { out.insert(c) }
            }
        } catch {
            KalsmritikoshLog.storage.error("Retention: hold notices not read: \(String(describing: error), privacy: .private)")
        }
        let held = try await database.query("""
            SELECT DISTINCT upper(s.case_id) FROM investigation_case_sources s
            JOIN legal_hold_items i ON upper(i.object_id) = upper(s.source_ref) JOIN legal_holds h ON h.id = i.hold_id
            WHERE h.released_at IS NULL AND i.removed_at IS NULL
            UNION
            SELECT DISTINCT upper(i.object_id) FROM legal_hold_items i JOIN legal_holds h ON h.id = i.hold_id
            WHERE h.released_at IS NULL AND i.removed_at IS NULL;
            """, [])
        for r in held { if let c = r.string(0) { out.insert(c) } }
        return out
    }

    /// For each class with a period: rows past it, and rows past it that a legal hold keeps. Nothing is deleted.
    public func review(now: Date = Date()) async throws -> [Review] {
        let held = try await heldCases()
        var out: [Review] = []
        for e in try await entries() {
            guard let days = e.keepDays else { continue }
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            var due = 0, back = 0
            for t in e.tableClass.tables {
                let cols = Set(try await database.query("PRAGMA table_info(\(t));", []).compactMap { $0.string(1) })
                // The class's date column, else the first dating column the table has.
                guard let dateCol = ([e.tableClass.dateColumn] + Self.dateColumns).first(where: cols.contains) else {
                    KalsmritikoshLog.storage.error("Retention: \(t, privacy: .public) has no dating column; not reviewed")
                    continue
                }
                let caseCol = e.tableClass.caseColumn.flatMap { cols.contains($0) ? $0 : nil }
                let rows = try await database.query("SELECT \(caseCol.map { "upper(\($0))" } ?? "NULL") FROM \(t) WHERE \(dateCol) < ?;",
                                                    [.real(cutoff)])
                for r in rows {
                    if let c = r.string(0), held.contains(c) { back += 1 } else { due += 1 }
                }
            }
            out.append(Review(classID: e.tableClass.id, due: due, heldBack: back))
        }
        return out
    }
}
