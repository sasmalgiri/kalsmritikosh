//
//  CaseAccessLog.swift
//  Kalsmritikosh
//
//  ALCOA ALC-11 (owner 2026-11-24; DATA-21) — traceable: the view log. Append-only, content-free access events
//  (`case_access_events`, v216): who, what (case opened, original opened, export viewed, export created, AI findings
//  reviewed — the subject is an id, never a name or text), when, and the recorder's time zone. Shown in the case log
//  (Case log ▸ Access log), sealed in the audit chain ('accessEvent'), erased with the case.
//

import Foundation
import os

public nonisolated enum CaseAccessKind: String, Sendable, CaseIterable {
    case caseOpened, originalOpened, exportViewed, exportCreated, aiFindingsReviewed

    public var label: String {
        switch self {
        case .caseOpened: return "opened the case"
        case .originalOpened: return "opened an original"
        case .exportViewed: return "viewed an export"
        case .exportCreated: return "made an export"
        case .aiFindingsReviewed: return "reviewed AI findings"
        }
    }
}

public nonisolated enum CaseAccessLog {

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let caseID: UUID
        public let actor: String
        public let kind: CaseAccessKind
        public let subjectRef: String?
        public let occurredAt: Date
        public let recordedTimeZone: String
        public let clockSource: String?
    }

    /// Record one access event. Content-free: `subject` is the id of what was looked at (a source version, an export,
    /// a record), never its name or text. A blank actor is recorded as "this Mac's owner".
    @discardableResult
    public static func record(_ database: Database, caseID: UUID, kind: CaseAccessKind, subject: UUID? = nil, actor: String,
                              at date: Date = Date()) async throws -> UUID {
        let id = UUID()
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = RecorderClock.stamp()
        try await database.exec("""
            INSERT INTO case_access_events (id, case_id, actor, kind, subject_ref, occurred_at, recorded_tz, clock_source)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(caseID), .text(who.isEmpty ? "this Mac's owner" : who), .text(kind.rawValue),
                  subject.map { .uuid($0) } ?? .null, .date(date), .text(stamp.timeZone), .text(stamp.clockSource)])
        return id
    }

    /// Record, logging (never throwing) — for screens: a failed write is logged, the screen still opens.
    public static func note(_ database: Database?, caseID: UUID, kind: CaseAccessKind, subject: UUID? = nil, actor: String) async {
        guard let database else { return }
        do { try await record(database, caseID: caseID, kind: kind, subject: subject, actor: actor) } catch {
            KalsmritikoshLog.app.error("Access event not recorded (\(kind.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The case's access events, oldest first.
    public static func events(_ database: Database, caseID: UUID) async throws -> [Entry] {
        try await database.query("""
            SELECT id, case_id, actor, kind, subject_ref, occurred_at, recorded_tz, clock_source FROM case_access_events
            WHERE case_id IN (?, ?) ORDER BY occurred_at, id;
            """, [.uuid(caseID), .text(caseID.uuidString.lowercased())]).compactMap(entry)
    }

    static func entry(_ r: SQLRow) -> Entry? {
        guard let id = r.uuid(0), let c = r.uuid(1), let actor = r.string(2), let kind = r.string(3).flatMap(CaseAccessKind.init(rawValue:)),
              let at = r.date(5), let tz = r.string(6) else { return nil }
        return Entry(id: id, caseID: c, actor: actor, kind: kind, subjectRef: r.string(4), occurredAt: at, recordedTimeZone: tz, clockSource: r.string(7))
    }

    /// The line the case log shows (time in the recorder's zone, named).
    public static func line(_ e: Entry) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: e.recordedTimeZone) ?? .current
        f.dateFormat = "d MMM yyyy HH:mm:ss"
        var s = "\(f.string(from: e.occurredAt)) (\(e.recordedTimeZone)) · \(e.actor) \(e.kind.label)"
        if let ref = e.subjectRef { s += " · ref \(ref.prefix(8).lowercased())" }
        if let clock = e.clockSource, clock != RecorderClock.systemSource { s += " · clock: \(clock)" }
        return s
    }

    /// Audit-chain events: every field is fixed once written (the table is append-only); no content exists to copy.
    public static func auditChainEvents(_ database: Database) async throws -> [AuditChainEvent] {
        guard !(try await database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'case_access_events';", []).isEmpty) else { return [] }
        return try await database.query("""
            SELECT id, case_id, actor, kind, subject_ref, occurred_at, recorded_tz, clock_source FROM case_access_events;
            """, []).compactMap(entry).map { e in
            let payload = "actor=\(e.actor);caseID=\(e.caseID.uuidString.lowercased());kind=\(e.kind.rawValue);occurredAt=\(e.occurredAt.timeIntervalSince1970);"
                + "subject=\((e.subjectRef ?? "").lowercased());tz=\(e.recordedTimeZone)" + (e.clockSource.map { ";clock=\($0)" } ?? "")
            return AuditChainEvent(source: .accessEvent, eventID: e.id, occurredAt: e.occurredAt, canonicalPayload: payload)
        }
    }
}
