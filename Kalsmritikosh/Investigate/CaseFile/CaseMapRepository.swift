//
//  CaseMapRepository.swift
//  Kalsmritikosh
//
//  Living case map, M2/M3 (schema v171): the only map state with no other canonical home — saved views,
//  item positions and pins, and the typed links an investigator draws — in the encrypted ledger, keyed by
//  stable item identity. It holds no copy of any case record. Also the map's two read helpers over
//  existing tables: the case's documents (logical source, version, name) and the case's revision fence.
//
//  An investigator link is written in ONE savepoint that checks, inside the write, that the case exists and
//  is not closed and that both ends are records of THIS case (target existence + parent-case membership).
//  A link is withdrawn with a reason, never edited (the v171 trigger refuses edits).
//

import Foundation
import os

public nonisolated enum CaseMapError: Error, Equatable, LocalizedError {
    case blank(String)
    case caseNotFound
    case caseClosed
    case notLinkable(String)
    case notInCase(String)
    case sameItem
    case linkNotFound
    case alreadyWithdrawn
    case notDrawable(String)
    case badPeriod

    public var errorDescription: String? {
        switch self {
        case .blank(let what): return "\(what) can't be empty."
        case .caseNotFound: return "The case was not found."
        case .caseClosed: return "The case is closed. Reopen it to change its links."
        case .notLinkable(let what): return "A map link can't point at \(what); link its documents or the question instead."
        case .notInCase(let what): return "That \(what) is not part of this case."
        case .sameItem: return "A link needs two different items."
        case .linkNotFound: return "The link was not found."
        case .alreadyWithdrawn: return "The link is already withdrawn."
        case .badPeriod: return "The period ends before it starts. Check the two dates."
        case .notDrawable(let what): return "A “\(what)” link is not drawn by hand: use Place in frame for a branch, or the identity review for a possible same person."
        }
    }
}

/// A saved view of the case map: a name, the built-in view it starts from, its filters and its place.
public nonisolated struct CaseMapSavedView: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public var name: String
    public var base: CaseMapViewKind
    public var filter: CaseMapFilter
    public var ordinal: Int
    public let createdBy: String
    public let createdAt: Date
    public var updatedAt: Date
    /// DATA-07: set when the stored filters could not be read (a newer or damaged value). The view is then shown with
    /// this note and NO filter is silently assumed to be the person's choice.
    public var filterProblem: String? = nil
}

/// Where an item sits on the map (world coordinates) and whether the person pinned it.
public nonisolated struct CaseMapPlacement: Equatable, Sendable, Codable {
    public var point: CaseMapPoint
    public var pinned: Bool
    public init(point: CaseMapPoint, pinned: Bool = false) { self.point = point; self.pinned = pinned }
}

public actor CaseMapRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: Saved views

    public func views(caseID: UUID) async throws -> [CaseMapSavedView] {
        try await database.query("""
            SELECT id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at
            FROM case_map_views WHERE case_id = ? ORDER BY ordinal ASC, created_at ASC, rowid ASC;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let name = r.string(2), let base = r.string(3).flatMap(CaseMapViewKind.init(rawValue:)),
                  let by = r.string(6), let at = r.date(7), let up = r.date(8) else { return nil }
            let (filter, problem) = CaseMapFilter.decodeChecked(r.string(4))
            if let problem {
                KalsmritikoshLog.app.error("Case map: saved view \(id.uuidString, privacy: .public) has unreadable filters: \(problem, privacy: .public)")
            }
            return CaseMapSavedView(id: id, caseID: c, name: name, base: base, filter: filter,
                                    ordinal: Int(r.int(5) ?? 0), createdBy: by, createdAt: at, updatedAt: up, filterProblem: problem)
        }
    }

    /// Save a new view or update one (name, base, filters, order). Views hold references and settings only.
    @discardableResult
    public func saveView(caseID: UUID, id: UUID? = nil, name: String, base: CaseMapViewKind, filter: CaseMapFilter,
                         ordinal: Int? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CaseMapError.blank("The view's name") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseMapError.blank("Who saved it") }
        let viewID = id ?? UUID()
        let json = filter.encoded()
        try await database.withSavepoint("cmview_\(viewID.uuidString.prefix(8))") { db in
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseMapError.caseNotFound }
            // S5 (TIME-04) — the view as it was, kept with the change (work history), in this savepoint.
            let capture = CaseRecordCapture.mapView(viewID)
            let before = try CaseRecordRevisions.rowJSON(db, capture)
            if let existing = try db.query("SELECT case_id FROM case_map_views WHERE id = ?;", [.uuid(viewID)]).first {
                guard existing.uuid(0) == caseID else { throw CaseMapError.notInCase("view") }
                try db.exec("UPDATE case_map_views SET name = ?, base_view = ?, filters_json = ?, ordinal = coalesce(?, ordinal), updated_at = ? WHERE id = ?;",
                            [.text(clean), .text(base.rawValue), .text(json), ordinal.map { .integer(Int64($0)) } ?? .null, .date(date), .uuid(viewID)])
            } else {
                let stored = Int(try db.query("SELECT coalesce(MAX(ordinal), -1) + 1 FROM case_map_views WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0)
                let next = ordinal ?? stored
                try db.exec("""
                    INSERT INTO case_map_views (id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?);
                    """, [.uuid(viewID), .uuid(caseID), .text(clean), .text(base.rawValue), .text(json), .integer(Int64(next)), .text(who), .date(date), .date(date)])
            }
            try CaseRecordRevisions.logDisplayChange(db, caseID: caseID, actor: who, action: before == nil ? "mapViewSaved" : "mapViewChanged",
                                                     detail: clean, capture: capture, before: before, at: date)
        }
        return viewID
    }

    /// Remove a saved view (display settings only; no case record is touched). S5 (TIME-04): the view as it was is kept in
    /// the case's work history; `actor` names who removed it.
    public func deleteView(caseID: UUID, id: UUID, actor: String = "the investigator", at date: Date = Date()) async throws {
        try await database.withSavepoint("cmviewx_\(id.uuidString.prefix(8))") { db in
            let capture = CaseRecordCapture.mapView(id)
            let before = try db.query("SELECT 1 FROM case_map_views WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).isEmpty ? nil : try CaseRecordRevisions.rowJSON(db, capture)
            try db.exec("DELETE FROM case_map_views WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)])
            if before != nil {
                let who = actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the investigator" : actor
                try CaseRecordRevisions.logDisplayChange(db, caseID: caseID, actor: who, action: "mapViewRemoved", detail: nil, capture: capture, before: before, at: date)
            }
        }
    }

    // MARK: Layout
    //
    // v176 (GRAPH-03): positions are kept per frame — `frame` is the frame's key (its anchor's identity key), and the
    // case's own map is the root frame ''. One canonical record can therefore sit in several frames, each with its own
    // position; the record itself is stored once.

    /// The positions stored for one frame of the case (the root frame by default).
    public func layout(caseID: UUID, frame: String = "") async throws -> [CaseMapNodeID: CaseMapPlacement] {
        var out: [CaseMapNodeID: CaseMapPlacement] = [:]
        for r in try await database.query("SELECT record_kind, record_id, x, y, pinned FROM case_map_layout WHERE case_id = ? AND frame_key = ?;",
                                          [.uuid(caseID), .text(frame)]) {
            guard let kind = r.string(0).flatMap(CaseMapRecordKind.init(rawValue:)), let rid = r.string(1),
                  let x = r.double(2), let y = r.double(3) else { continue }
            out[CaseMapNodeID(caseID: caseID, kind: kind, recordID: rid)] = CaseMapPlacement(point: CaseMapPoint(x: x, y: y), pinned: (r.int(4) ?? 0) == 1)
        }
        return out
    }

    /// Store positions (and pins) for the given items in one frame (the root frame by default), in one savepoint. Geometry only.
    public func savePlacements(caseID: UUID, frame: String = "", _ placements: [CaseMapNodeID: CaseMapPlacement], at date: Date = Date()) async throws {
        guard !placements.isEmpty else { return }
        let rows = placements.filter { $0.key.caseID == caseID }.sorted { $0.key < $1.key }
        try await database.withSavepoint("cmlayout_\(UUID().uuidString.prefix(8))") { db in
            // Late work cannot recreate an erased case's map state.
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseMapError.caseNotFound }
            for (id, p) in rows {
                try db.exec("""
                    INSERT INTO case_map_layout (case_id, frame_key, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(case_id, frame_key, record_kind, record_id) DO UPDATE SET x = excluded.x, y = excluded.y, pinned = excluded.pinned, updated_at = excluded.updated_at;
                    """, [.uuid(caseID), .text(frame), .text(id.kind.rawValue), .text(id.recordID), .real(p.point.x), .real(p.point.y), .bool(p.pinned), .date(date)])
            }
        }
    }

    /// "Reset view": forget the case's positions and pins — every frame's, or one frame's (no case record is touched).
    public func resetLayout(caseID: UUID, frame: String? = nil) async throws {
        if let frame {
            try await database.exec("DELETE FROM case_map_layout WHERE case_id = ? AND frame_key = ?;", [.uuid(caseID), .text(frame)])
        } else {
            try await database.exec("DELETE FROM case_map_layout WHERE case_id = ?;", [.uuid(caseID)])
        }
    }

    // MARK: Investigator links

    public func links(caseID: UUID) async throws -> [CaseMapInvestigatorLink] {
        try await database.query("""
            SELECT id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at, withdrawn_by, withdrawn_at, withdrawn_reason,
                   certainty, valid_from, valid_to, valid_text, revises_link_id
            FROM case_map_links WHERE case_id = ? ORDER BY created_at ASC, rowid ASC;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let type = r.string(2).flatMap(CaseMapLinkType.init(rawValue:)),
                  let fk = r.string(3).flatMap(CaseMapRecordKind.init(rawValue:)), let fid = r.string(4),
                  let tk = r.string(5).flatMap(CaseMapRecordKind.init(rawValue:)), let tid = r.string(6),
                  let why = r.string(7), let by = r.string(8), let at = r.date(9) else { return nil }
            var link = CaseMapInvestigatorLink(id: id, caseID: c, type: type, from: CaseMapNodeID(caseID: c, kind: fk, recordID: fid),
                                               to: CaseMapNodeID(caseID: c, kind: tk, recordID: tid), rationale: why, createdBy: by, createdAt: at,
                                               withdrawnBy: r.string(10), withdrawnAt: r.date(11), withdrawnReason: r.string(12))
            // v179 — certainty (an unreadable or missing value is "not stated", never upgraded), validity and revision.
            link.certainty = r.string(13).flatMap(CaseMapCertainty.init(rawValue:)) ?? .notStated
            let validity = CaseMapValidity(from: r.date(14), to: r.date(15), text: r.string(16))
            link.validity = validity.isRecorded ? validity : nil
            link.revisesLinkID = r.uuid(17)
            return link
        }
    }

    /// Draw a typed link between two items of the case, with the reason. Checked inside the write: the case
    /// exists and is open, both ends are linkable records that belong to this case.
    @discardableResult
    public func addLink(caseID: UUID, type: CaseMapLinkType, from: CaseMapNodeID, to: CaseMapNodeID, rationale: String,
                        certainty: CaseMapCertainty = .notStated, validity: CaseMapValidity? = nil,
                        actor: String, at date: Date = Date()) async throws -> UUID {
        let why = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CaseMapError.blank("The reason for the link") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseMapError.blank("Who drew the link") }
        guard from != to else { throw CaseMapError.sameItem }
        guard type.drawable else { throw CaseMapError.notDrawable(type.label) }
        for end in [from, to] {
            guard end.caseID == caseID else { throw CaseMapError.notInCase("item") }
            guard CaseMapRecordKind.linkable.contains(end.kind) else { throw CaseMapError.notLinkable(end.kind.rawValue) }
        }
        if let v = validity, let a = v.from, let b = v.to, b < a { throw CaseMapError.badPeriod }
        let id = UUID()
        let valid = validity?.isRecorded == true ? validity : nil
        try await database.withSavepoint("cmlink_\(id.uuidString.prefix(8))") { db in
            guard let status = try db.query("SELECT status FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0) else {
                throw CaseMapError.caseNotFound
            }
            guard status != InvestigationCaseStatus.closed.rawValue else { throw CaseMapError.caseClosed }
            for end in [from, to] { guard try Self.belongs(db, end, caseID: caseID) else { throw CaseMapError.notInCase(end.kind.rawValue) } }
            // A link with no stated certainty or period is the v171 row (its v179 columns stay NULL: "not stated").
            if certainty == .notStated && valid == nil {
                try db.exec("""
                    INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(id), .uuid(caseID), .text(type.rawValue), .text(from.kind.rawValue), .text(from.recordID),
                          .text(to.kind.rawValue), .text(to.recordID), .text(why), .text(who), .date(date)])
                return
            }
            try db.exec("""
                INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at,
                                            certainty, valid_from, valid_to, valid_text)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(type.rawValue), .text(from.kind.rawValue), .text(from.recordID),
                      .text(to.kind.rawValue), .text(to.recordID), .text(why), .text(who), .date(date),
                      .text(certainty.rawValue), valid?.from.map { .date($0) } ?? .null, valid?.to.map { .date($0) } ?? .null,
                      valid?.text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SQLValue.text($0) } ?? .null])
        }
        return id
    }

    /// GRAPH-08 — revise an investigator link: a NEW link (its type, reason, certainty or period changed) that names the
    /// one it revises, and the earlier link withdrawn with the reason — in one savepoint, so both happen or neither. The
    /// earlier link stays in the ledger; the chain is the link's history. The ends stay the same records.
    @discardableResult
    public func reviseLink(caseID: UUID, id old: UUID, type: CaseMapLinkType, rationale: String, certainty: CaseMapCertainty,
                           validity: CaseMapValidity?, reason: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let why = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CaseMapError.blank("The reason for the link") }
        let because = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !because.isEmpty else { throw CaseMapError.blank("Why it is revised") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseMapError.blank("Who revised it") }
        guard type.drawable else { throw CaseMapError.notDrawable(type.label) }
        if let v = validity, let a = v.from, let b = v.to, b < a { throw CaseMapError.badPeriod }
        let valid = validity?.isRecorded == true ? validity : nil
        let id = UUID()
        try await database.withSavepoint("cmrev_\(id.uuidString.prefix(8))") { db in
            guard let status = try db.query("SELECT status FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0) else { throw CaseMapError.caseNotFound }
            guard status != InvestigationCaseStatus.closed.rawValue else { throw CaseMapError.caseClosed }
            guard let r = try db.query("SELECT from_kind, from_id, to_kind, to_id, withdrawn_at FROM case_map_links WHERE id = ? AND case_id = ?;",
                                       [.uuid(old), .uuid(caseID)]).first,
                  let fk = r.string(0).flatMap(CaseMapRecordKind.init(rawValue:)), let fid = r.string(1),
                  let tk = r.string(2).flatMap(CaseMapRecordKind.init(rawValue:)), let tid = r.string(3) else { throw CaseMapError.linkNotFound }
            guard r.isNull(4) else { throw CaseMapError.alreadyWithdrawn }
            let from = CaseMapNodeID(caseID: caseID, kind: fk, recordID: fid), to = CaseMapNodeID(caseID: caseID, kind: tk, recordID: tid)
            for end in [from, to] { guard try Self.belongs(db, end, caseID: caseID) else { throw CaseMapError.notInCase(end.kind.rawValue) } }
            try db.exec("UPDATE case_map_links SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text("Revised: " + because), .uuid(old)])
            try db.exec("""
                INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at,
                                            certainty, valid_from, valid_to, valid_text, revises_link_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(type.rawValue), .text(from.kind.rawValue), .text(from.recordID), .text(to.kind.rawValue),
                      .text(to.recordID), .text(why), .text(who), .date(date), .text(certainty.rawValue),
                      valid?.from.map { .date($0) } ?? .null, valid?.to.map { .date($0) } ?? .null,
                      valid?.text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SQLValue.text($0) } ?? .null, .uuid(old)])
        }
        return id
    }

    /// GRAPH-08 — a link's revision chain, newest first (the link itself, then each link it revised), from the ledger.
    public func linkHistory(caseID: UUID, id: UUID) async throws -> [CaseMapInvestigatorLink] {
        let all = Dictionary(try await links(caseID: caseID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CaseMapInvestigatorLink] = []
        var seen = Set<UUID>()
        var next: UUID? = id
        while let n = next, seen.insert(n).inserted, let l = all[n] { out.append(l); next = l.revisesLinkID }
        return out
    }

    /// Withdraw a link with the reason; it stays in the ledger, marked withdrawn.
    public func withdrawLink(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CaseMapError.blank("The reason for withdrawing it") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseMapError.blank("Who withdrew it") }
        try await database.withSavepoint("cmwd_\(id.uuidString.prefix(8))") { db in
            guard let row = try db.query("SELECT withdrawn_at FROM case_map_links WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseMapError.linkNotFound
            }
            guard row.isNull(0) else { throw CaseMapError.alreadyWithdrawn }
            if try db.query("SELECT status FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0) == InvestigationCaseStatus.closed.rawValue {
                throw CaseMapError.caseClosed
            }
            try db.exec("UPDATE case_map_links SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    /// Target existence + parent-case membership for one link end (inside the write).
    static func belongs(_ db: isolated Database, _ end: CaseMapNodeID, caseID: UUID) throws -> Bool {
        let c = SQLValue.uuid(caseID)
        let r = SQLValue.text(end.recordID)
        // Stored ids are upper-case UUID strings; identity keeps them lower-case.
        let upper = SQLValue.text(end.recordID.uppercased())
        func exists(_ sql: String, _ binds: [SQLValue]) throws -> Bool { try db.query(sql, binds).first != nil }
        switch end.kind {
        case .caseFile: return end.recordID == caseID.uuidString.lowercased()
        case .allegation: return try exists("SELECT 1 FROM case_allegations WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .person: return try exists("SELECT 1 FROM case_people WHERE case_id = ? AND removed_at IS NULL AND id IN (?, ?);", [c, r, upper])
        case .exhibit: return try exists("SELECT 1 FROM case_exhibits WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .interview: return try exists("SELECT 1 FROM case_interviews WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .addendum: return try exists("SELECT 1 FROM case_statement_addenda WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .journal: return try exists("SELECT 1 FROM case_journal WHERE case_id = ? AND removed_at IS NULL AND id IN (?, ?);", [c, r, upper])
        case .hypothesis: return try exists("SELECT 1 FROM investigation_hypotheses WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .request: return try exists("SELECT 1 FROM investigation_evidence_requests WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .reportItem: return try exists("SELECT 1 FROM case_report_items WHERE case_id = ? AND id IN (?, ?);", [c, r, upper])
        case .task: return try exists("SELECT 1 FROM case_task_links WHERE case_id = ? AND task_id IN (?, ?);", [c, r, upper])
        case .report: return try exists("SELECT 1 FROM case_reports WHERE case_id = ? AND withdrawn_at IS NULL AND id IN (?, ?);", [c, r, upper])
        case .reportPoint: return try exists("SELECT 1 FROM case_report_points WHERE case_id = ? AND withdrawn_at IS NULL AND id IN (?, ?);", [c, r, upper])
        case .document:
            // A logical source in the case's scope (by the logical source or one of its versions).
            return try exists("""
                SELECT 1 FROM investigation_case_sources s WHERE s.case_id = ? AND s.in_scope = 1
                  AND (s.source_ref IN (?, ?) OR s.source_ref IN (SELECT id FROM source_versions WHERE logical_source_id IN (?, ?))) LIMIT 1;
                """, [c, r, upper, r, upper])
        case .contradiction, .allegationEvidence, .hypothesisEvidence, .requestReceipt, .reviewDecision, .investigatorLink, .rule,
             .workLink, .qualification, .actionContract, .frameMember, .actionDependency, .moneyTransaction, .identityDecision:
            return false
        }
    }

    // MARK: S3 read helpers (CaseMapAdapters: coverage and omitted stores, read on demand)

    func tableNames() async throws -> [String] {
        try await database.query("SELECT name FROM sqlite_master WHERE type = 'table';", []).compactMap { $0.string(0) }
    }
    func countRows(_ sql: String, _ binds: [SQLValue]) async throws -> Int64? {
        try await database.query(sql, binds).first?.int(0)
    }
    func readRows(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow] {
        try await database.query(sql, binds)
    }

    // MARK: Reads over existing tables

    /// The case's documents: for each source version in the case, its logical source, file name, whether it
    /// is the current version, and the document it was read into (from the existing object map).
    public func documents(versionIDs: Set<UUID>, objectsByVersion: [UUID: UUID]) async throws -> [CaseMapDocument] {
        guard !versionIDs.isEmpty else { return [] }
        let ids = versionIDs.sorted { $0.uuidString < $1.uuidString }
        // SRC-10 — the independence identity of each version's document (the law retrieval uses): an e-mail's thread
        // subject, else the version's content hash. A failed identity read leaves every document its own origin.
        var identities: [UUID: (emailSubject: String?, contentHash: String?)] = [:]
        do { identities = try await KnowledgeObjectRepository(database: database).independenceIdentities(for: Set(objectsByVersion.values)) } catch {
            KalsmritikoshLog.app.error("Case map: document identities not read, copies are not grouped: \(error.localizedDescription, privacy: .public)")
        }
        var out: [CaseMapDocument] = []
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for r in try await database.query("SELECT id, logical_source_id, filename, is_current, content_hash FROM source_versions WHERE id IN (\(marks));", chunk.map { .uuid($0) }) {
                guard let v = r.uuid(0) else { continue }
                // A version with no logical source is its own document.
                let logical = r.uuid(1) ?? v
                let object = objectsByVersion[v]
                out.append(CaseMapDocument(sourceVersionID: v, logicalSourceID: logical, name: r.string(2), objectID: object,
                                           isCurrent: (r.int(3) ?? 1) == 1,
                                           independenceKey: Self.independenceKey(subject: object.flatMap { identities[$0]?.emailSubject }, contentHash: r.string(4))))
            }
        }
        return out
    }

    /// SRC-10 — "thread:" + the normalised subject for a message, else "content:" + the content hash; nil when neither.
    nonisolated static func independenceKey(subject: String?, contentHash: String?) -> String? {
        if let subject {
            let thread = LedgerSourceIndependenceKeyProvider.threadKey(subject: subject)
            if !thread.isEmpty { return "thread:" + thread }
        }
        if let h = contentHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !h.isEmpty { return "content:" + h }
        return nil
    }

    /// The case's revision fence: a digest of what changes when the case changes (its header revision, its
    /// action log, decisions, requests and their history, hypotheses, journal, report items, grid rows, map
    /// links, people, interviews, exhibits, kept record revisions, the versions of its documents and the
    /// contradictions detected). A load that reads the same fence before and after saw one consistent state.
    /// Read in one savepoint, so the fence itself is one consistent reading.
    public func revisionFence(caseID: UUID) async throws -> String {
        try await database.withSavepoint("cmfence_\(UUID().uuidString.prefix(8))") { db in try Self.fence(db, caseID: caseID) }
    }

    /// The same fence inside a caller's savepoint (M7: a checkpoint is written only if the fence it was built
    /// under is still the fence inside the write — a validated revision fence).
    /// `ignoringActions`: action-log kinds left out (S3: a brief's own writes do not make that brief stale).
    static func fence(_ db: isolated Database, caseID: UUID, ignoringActions: [String] = [], ignoringRevisionKinds: [String] = []) throws -> String {
        // S5 — saved-view history is work history of the display, not a change to what the map projects.
        let ignoringActions = ignoringActions + CaseRecordRevisions.displayActions
        let ignoringRevisionKinds = ignoringRevisionKinds + CaseRecordRevisions.displayKinds
        let c = SQLValue.uuid(caseID)
        let ignored = ignoringActions.isEmpty ? "" : " AND action NOT IN (\(ignoringActions.map { _ in "?" }.joined(separator: ",")))"
        let ignoredKinds = ignoringRevisionKinds.isEmpty ? "" : " AND record_kind NOT IN (\(ignoringRevisionKinds.map { _ in "?" }.joined(separator: ",")))"
        let parts: [(String, [SQLValue])] = [
            ("SELECT revision, status FROM investigation_cases WHERE id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(sequence), 0) FROM case_actions WHERE case_id = ?\(ignored);", [c] + ignoringActions.map { .text($0) }),
            ("SELECT COUNT(*), coalesce(MAX(decided_at), 0) FROM investigation_review_decisions WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(SUM(revision), 0), coalesce(MAX(updated_at), 0) FROM investigation_evidence_requests WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(linked_at), 0), coalesce(MAX(withdrawn_at), 0) FROM investigation_evidence_request_receipts WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(SUM(revision), 0), coalesce(MAX(updated_at), 0) FROM investigation_hypotheses WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*) FROM investigation_hypothesis_evidence WHERE hypothesis_id IN (SELECT id FROM investigation_hypotheses WHERE case_id = ?);", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(removed_at), 0), coalesce(MAX(verified_at), 0) FROM case_journal WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(decided_at), 0), coalesce(MAX(verified_at), 0) FROM case_report_items WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(removed_at), 0), coalesce(MAX(verified_at), 0) FROM case_allegation_evidence WHERE allegation_id IN (SELECT id FROM case_allegations WHERE case_id = ?);", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_map_links WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(SUM(in_scope), 0) FROM investigation_case_sources WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(recorded_at), 0) FROM case_record_revisions WHERE case_id = ?\(ignoredKinds);", [c] + ignoringRevisionKinds.map { .text($0) }),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(removed_at), 0) FROM case_people WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(updated_at), 0) FROM case_interviews WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_exhibits WHERE case_id = ?;", [c]),
            // The versions of the case's documents (a revision arriving changes what the map shows as reopened).
            // Driven from the case's sources into source_versions by its primary key (the same pairs as matching
            // v.id against each source_ref in any case): the earlier form scanned every version for each source,
            // quadratic in the case size (4–5 s per fence at 5,000 documents; the fence is read twice per load).
            ("""
             SELECT COUNT(*), coalesce(MAX(sv.created_at), 0), coalesce(SUM(sv.is_current), 0) FROM source_versions sv
             WHERE sv.logical_source_id IN (SELECT v.logical_source_id FROM investigation_case_sources s CROSS JOIN source_versions v
                                            ON v.id IN (s.source_ref, upper(s.source_ref), lower(s.source_ref)) WHERE s.case_id = ? AND s.in_scope = 1);
             """, [c]),
            ("SELECT COUNT(*), coalesce(MAX(detected_at), 0) FROM contradictions;", []),
            // v176 — reports, points, qualifications, work links and action contracts.
            ("SELECT COUNT(*), coalesce(MAX(recorded_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_reports WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(recorded_at), 0), coalesce(MAX(reviewed_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_report_points WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(recorded_at), 0) FROM case_report_qualifications WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(created_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_work_links WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(updated_at), 0) FROM case_action_contracts WHERE case_id = ?;", [c]),
            // v177 — frame memberships and action dependencies.
            ("SELECT COUNT(*), coalesce(MAX(added_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_frame_members WHERE case_id = ?;", [c]),
            ("SELECT COUNT(*), coalesce(MAX(d.created_at), 0) FROM professional_task_dependencies d WHERE d.task_id IN (SELECT task_id FROM case_task_links WHERE case_id = ?);", [c]),
            // v179 — identity decisions (they change the map's links). Briefs and briefings are not in the fence: they
            // read the case, they are not part of what the map projects, and writing one must not make a brief stale.
            ("SELECT COUNT(*), coalesce(MAX(decided_at), 0), coalesce(MAX(withdrawn_at), 0) FROM case_person_identity_decisions WHERE case_id = ?;", [c]),
            // v182 — person roles (they change what a person's item says on the map).
            ("SELECT COUNT(*), coalesce(MAX(recorded_at), 0), coalesce(MAX(ended_at), 0) FROM case_person_roles WHERE case_id = ?;", [c]),
        ]
        var text = ""
        for (sql, binds) in parts {
            let row = try db.query(sql, binds).first
            text += (row?.values.map { "\($0)" }.joined(separator: ",") ?? "-") + ";"
        }
        return CaseFileHash.sha256(text)
    }
}
