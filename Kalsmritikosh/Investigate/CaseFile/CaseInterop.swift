//
//  CaseInterop.swift
//  Kalsmritikosh
//
//  Smart-map S12 (milestone M5) — existing jobs, specialist data and interoperability, over the case's ONE ledger:
//  • ADAPT-02 — the stable identity of a carry (`case_carried_records`, v188): a job result row carried into a money record
//    or a question, or a record imported from a structured exchange file, names its origin; the same origin is not carried
//    to the same kind of target twice unless the person asks for a distinct record. Written in the SAME savepoint as the
//    record it created, so a carry and its record exist together or not at all.
//  • ADAPT-05 — a summary SUPPLIED by a person for an original the app could not read: who supplied it, on what basis, in
//    which language; attached to the original, labelled, never presented as the document's own words; withdraw-only.
//  • ADAPT-06 — the documented structured exchange (`ime-case-exchange`, version 1): questions, people and dated events,
//    their source references, and the investigator's typed relationships between them, with stable identifiers. Import
//    is checked field by field: what was created, matched (already imported — the stable identifier), skipped (with the
//    reason) and every unsupported field, named, goes into a fixed receipt. A partial import never changes a record that
//    was already in the case. Nothing here opens a connection or calls a model.
//

import Foundation
import os

// MARK: - Carries (ADAPT-02)

/// What carried an item and which revision of it (a job row's saved result digest, or an exchange file's digest).
public nonisolated struct CaseCarryStamp: Sendable, Equatable {
    public var origin: String
    public var originDigest: String?
    public var reviewState: String?
    /// The person asked for a distinct record although the same origin was carried before.
    public var distinct: Bool
    public init(origin: String, originDigest: String? = nil, reviewState: String? = nil, distinct: Bool = false) {
        self.origin = origin; self.originDigest = originDigest; self.reviewState = reviewState; self.distinct = distinct
    }
}

/// The kinds of canonical record a carry may become.
public nonisolated enum CaseCarryTargetKind: String, Sendable, CaseIterable {
    case moneyRecord, question, person, event
    public var label: String {
        switch self {
        case .moneyRecord: return "money record"
        case .question: return "question"
        case .person: return "person"
        case .event: return "chronology entry"
        }
    }
}

public nonisolated struct CaseCarriedRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let origin: String
    public let targetKind: CaseCarryTargetKind
    public let targetID: UUID
    public let originDigest: String?
    public let reviewState: String?
    public let distinct: Bool
    public let recordedBy: String
    public let recordedAt: Date
}

// MARK: - Supplied summaries (ADAPT-05)

public nonisolated struct CaseSuppliedSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sourceVersionID: UUID?
    public let objectID: UUID?
    public let sourceName: String?
    public let summary: String
    public let suppliedBy: String
    public let basis: String?
    public let language: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
    /// How it is labelled wherever it is shown: supplied, by whom, and that the app did not read the original.
    public var label: String {
        "Supplied summary by \(suppliedBy)" + (basis.map { " (\($0))" } ?? "") + " — not read from the document; the app could not read the original."
    }
}

public nonisolated enum CaseInteropError: LocalizedError, Equatable, Sendable {
    case noOriginal
    case notUTF8
    case notJSON
    case wrongFormat(String)
    case unsupportedVersion(Int)
    case missingField(String)
    case alreadyWithdrawn
    case notFound
    public var errorDescription: String? {
        switch self {
        case .noOriginal: return "A supplied summary must name the original it describes."
        case .notUTF8: return "The file is not UTF-8 text, so nothing was imported. Save it as UTF-8 and import it again."
        case .notJSON: return "The file is not a structured exchange file (JSON), so nothing was imported."
        case .wrongFormat(let f): return "The file says it is “\(f)”, not “\(CaseExchange.format)”, so nothing was imported."
        case .unsupportedVersion(let v): return "The file is version \(v) of the exchange format; this version of the app reads version \(CaseExchange.version) only, so nothing was imported."
        case .missingField(let f): return "The file has no “\(f)”, so nothing was imported."
        case .alreadyWithdrawn: return "That summary was already withdrawn."
        case .notFound: return "That record is not in this case."
        }
    }
}

// MARK: - The exchange format (ADAPT-06)

/// `ime-case-exchange` version 1 — the one documented interchange (docs/INTEROP_CONTRACTS.md). JSON, UTF-8:
/// `{ "format", "version", "sourceSystem", "exportedAt", "caseTitle"?, "records": [...], "relationships": [...] }`
/// A record: `{ "id", "kind": question|person|event, "text", "date"? (as written; yyyy-MM-dd is placed in order),
/// "role"? (person), "sources": [{ "sourceVersionID", "quote"? }] }`.
/// A relationship: `{ "id", "type" (a drawable case-map link type), "from", "to", "rationale"?, "certainty"? }`.
public nonisolated enum CaseExchange {
    public static let format = "ime-case-exchange"
    public static let version = 1
    public static let recordKinds: [String: CaseCarryTargetKind] = ["question": .question, "person": .person, "event": .event]
    static let topKeys: Set<String> = ["format", "version", "sourceSystem", "exportedAt", "caseTitle", "records", "relationships"]
    static let recordKeys: Set<String> = ["id", "kind", "text", "date", "role", "sources"]
    static let sourceKeys: Set<String> = ["sourceVersionID", "quote"]
    static let relationshipKeys: Set<String> = ["id", "type", "from", "to", "rationale", "certainty"]

    public nonisolated struct SourceRef: Codable, Sendable, Equatable {
        public var sourceVersionID: String
        public var quote: String?
    }
    public nonisolated struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var text: String
        public var date: String?
        public var role: String?
        public var sources: [SourceRef]
    }
    public nonisolated struct Relationship: Codable, Sendable, Equatable {
        public var id: String
        public var type: String
        public var from: String
        public var to: String
        public var rationale: String?
        public var certainty: String?
    }
    public nonisolated struct Document: Codable, Sendable, Equatable {
        public var format: String
        public var version: Int
        public var sourceSystem: String
        public var exportedAt: String
        public var caseTitle: String?
        public var records: [Record]
        public var relationships: [Relationship]
    }

    /// An identifier the exchange accepts: printable, no control or direction characters, 1–200 characters.
    public static func validIdentifier(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t == s, t.count <= 200 else { return false }
        return !t.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }

    /// The canonical JSON of a document (sorted keys), as written to a file.
    public static func encode(_ d: Document) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(d)
    }

    /// A day written yyyy-MM-dd, read as that calendar day in UTC (the date is kept as written beside it).
    static func day(_ s: String?) -> Date? {
        guard let s, s.count == 10 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func dayText(_ d: Date, zone: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// The parse of a file: the document and the fields it holds that this format does not support (by path).
    public nonisolated struct Parsed: Sendable {
        public var document: Document
        public var unsupportedFields: [String]
        public var skipped: [String]
    }

    /// Parse and check a file without changing anything. Refuses a file that is not UTF-8, not JSON, not this format or
    /// not this version. Records and relationships missing a required field are skipped with the reason (never guessed).
    public static func parse(_ data: Data) throws -> Parsed {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw CaseInteropError.notUTF8 }
        guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let top = any as? [String: Any] else { throw CaseInteropError.notJSON }
        guard let format = top["format"] as? String else { throw CaseInteropError.missingField("format") }
        guard format == Self.format else { throw CaseInteropError.wrongFormat(format) }
        guard let version = top["version"] as? Int else { throw CaseInteropError.missingField("version") }
        guard version == Self.version else { throw CaseInteropError.unsupportedVersion(version) }
        guard let system = (top["sourceSystem"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty, validIdentifier(system) else {
            throw CaseInteropError.missingField("sourceSystem")
        }
        var unsupported = top.keys.filter { !topKeys.contains($0) }.sorted()
        var skipped: [String] = []
        var records: [Record] = []
        var seen = Set<String>()
        for (i, raw) in ((top["records"] as? [Any]) ?? []).enumerated() {
            guard let r = raw as? [String: Any] else { skipped.append("records[\(i)]: not a record"); continue }
            unsupported += r.keys.filter { !recordKeys.contains($0) }.sorted().map { "records[\(i)].\($0)" }
            guard let id = r["id"] as? String else { skipped.append("records[\(i)]: no id"); continue }
            guard validIdentifier(id) else { skipped.append("records[\(i)]: invalid id"); continue }
            guard seen.insert(id).inserted else { skipped.append("records[\(i)] (\(id)): the same id appears earlier in the file"); continue }
            guard let kind = r["kind"] as? String else { skipped.append("records[\(i)] (\(id)): no kind"); continue }
            guard recordKinds[kind] != nil else { skipped.append("records[\(i)] (\(id)): kind “\(kind)” is not supported"); continue }
            guard let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { skipped.append("records[\(i)] (\(id)): no text"); continue }
            var sources: [SourceRef] = []
            for (j, s) in ((r["sources"] as? [Any]) ?? []).enumerated() {
                guard let s = s as? [String: Any], let v = s["sourceVersionID"] as? String else { skipped.append("records[\(i)].sources[\(j)]: no sourceVersionID"); continue }
                unsupported += s.keys.filter { !sourceKeys.contains($0) }.sorted().map { "records[\(i)].sources[\(j)].\($0)" }
                sources.append(SourceRef(sourceVersionID: v, quote: s["quote"] as? String))
            }
            records.append(Record(id: id, kind: kind, text: t, date: r["date"] as? String, role: r["role"] as? String, sources: sources))
        }
        var relationships: [Relationship] = []
        var seenRel = Set<String>()
        for (i, raw) in ((top["relationships"] as? [Any]) ?? []).enumerated() {
            guard let r = raw as? [String: Any] else { skipped.append("relationships[\(i)]: not a relationship"); continue }
            unsupported += r.keys.filter { !relationshipKeys.contains($0) }.sorted().map { "relationships[\(i)].\($0)" }
            guard let id = r["id"] as? String, validIdentifier(id) else { skipped.append("relationships[\(i)]: no valid id"); continue }
            guard seenRel.insert(id).inserted else { skipped.append("relationships[\(i)] (\(id)): the same id appears earlier in the file"); continue }
            guard let type = r["type"] as? String, let from = r["from"] as? String, let to = r["to"] as? String else {
                skipped.append("relationships[\(i)] (\(id)): type, from and to are all required"); continue
            }
            relationships.append(Relationship(id: id, type: type, from: from, to: to, rationale: r["rationale"] as? String, certainty: r["certainty"] as? String))
        }
        let d = Document(format: format, version: version, sourceSystem: system, exportedAt: (top["exportedAt"] as? String) ?? "",
                         caseTitle: top["caseTitle"] as? String, records: records, relationships: relationships)
        return Parsed(document: d, unsupportedFields: unsupported, skipped: skipped)
    }
}

/// The receipt of one import: fixed once written (case_exchange_imports).
public nonisolated struct CaseExchangeReceipt: Codable, Sendable, Equatable {
    public var id: UUID
    public var sourceSystem: String
    public var fileSHA256: String
    public var created: [String]
    public var matched: [String]
    public var skipped: [String]
    public var unsupportedFields: [String]
    /// Kept, with a limitation stated (a source reference not in this case, a date kept as written, a role recorded as other).
    public var limitations: [String]
    public var summary: String {
        "Imported \(created.count) new record(s) and relationship(s); \(matched.count) already in the case (matched by their identifier); \(skipped.count) skipped; \(unsupportedFields.count) unsupported field(s) not imported."
    }
}

// MARK: - Repository

extension CaseFileRepository {

    /// Record the carry in the savepoint of the record it created. The same origin carried to the same kind of target is
    /// refused unless the person asked for a distinct record.
    static func stampCarry(_ db: isolated Database, caseID: UUID, _ stamp: CaseCarryStamp?, kind: CaseCarryTargetKind, target: UUID,
                           who: String, at date: Date) throws {
        guard let stamp else { return }
        let origin = stamp.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty else { throw CaseFileError.blank("The origin of the carried item") }
        if !stamp.distinct, try !db.query("SELECT 1 FROM case_carried_records WHERE case_id = ? AND origin = ? AND target_kind = ? LIMIT 1;",
                                          [.uuid(caseID), .text(origin), .text(kind.rawValue)]).isEmpty {
            throw CaseFileError.alreadyCarried("That \(kind.label)")
        }
        try db.exec("""
            INSERT INTO case_carried_records (id, case_id, origin, target_kind, target_id, origin_digest, review_state, distinct_copy, recorded_by, recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text(origin), .text(kind.rawValue), .uuid(target), .optionalText(stamp.originDigest),
                  .optionalText(stamp.reviewState), .integer(stamp.distinct ? 1 : 0), .text(who), .date(date)])
    }

    public func carriedRecords(caseID: UUID) async throws -> [CaseCarriedRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, origin, target_kind, target_id, origin_digest, review_state, distinct_copy, recorded_by, recorded_at
            FROM case_carried_records WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let o = r.string(1), let k = r.string(2).flatMap(CaseCarryTargetKind.init(rawValue:)), let t = r.uuid(3),
                  let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseCarriedRecord(id: id, origin: o, targetKind: k, targetID: t, originDigest: r.string(4), reviewState: r.string(5),
                                     distinct: (r.int(6) ?? 0) == 1, recordedBy: by, recordedAt: at)
        }
    }

    // MARK: ADAPT-05 supplied summaries

    @discardableResult
    public func addSuppliedSummary(caseID: UUID, sourceVersionID: UUID?, objectID: UUID?, sourceName: String?, summary: String, suppliedBy: String,
                                   basis: String?, language: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), text = try Self.clean(summary, "The summary"), by = try Self.clean(suppliedBy, "Who supplied it")
        guard sourceVersionID != nil || objectID != nil else { throw CaseInteropError.noOriginal }
        let id = UUID()
        try await write("cf_supsum", caseID: caseID, actor: who, action: "suppliedSummaryAdded", detail: sourceName, at: date) { db in
            if let v = sourceVersionID, !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_supplied_summaries (id, case_id, source_version_id, object_id, source_name, summary, supplied_by, basis, language, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), sourceVersionID.map { .uuid($0) } ?? .null, objectID.map { .uuid($0) } ?? .null,
                      .optionalText(Self.blankToNil(sourceName)), .text(text), .text(by), .optionalText(Self.blankToNil(basis)),
                      .optionalText(Self.blankToNil(language)), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawSuppliedSummary(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_supsumw", caseID: caseID, actor: who, action: "suppliedSummaryWithdrawn", detail: why, at: date) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_supplied_summaries WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseInteropError.notFound
            }
            guard r.isNull(0) else { throw CaseInteropError.alreadyWithdrawn }
            try db.exec("UPDATE case_supplied_summaries SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func suppliedSummaries(caseID: UUID) async throws -> [CaseSuppliedSummary] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, source_version_id, object_id, source_name, summary, supplied_by, basis, language, recorded_by, recorded_at, withdrawn_at, withdrawn_reason
            FROM case_supplied_summaries WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let s = r.string(4), let by = r.string(5), let rb = r.string(8), let at = r.date(9) else { return nil }
            return CaseSuppliedSummary(id: id, caseID: caseID, sourceVersionID: r.uuid(1), objectID: r.uuid(2), sourceName: r.string(3), summary: s,
                                       suppliedBy: by, basis: r.string(6), language: r.string(7), recordedBy: rb, recordedAt: at,
                                       withdrawnAt: r.date(10), withdrawnReason: r.string(11))
        }
    }

    // MARK: ADAPT-06 structured exchange — export

    /// The case's questions, people, chronology entries and the investigator's active links among them, as an exchange
    /// document. A record imported earlier keeps the identifier it came with (its stable identity); a native record is
    /// identified by its own id.
    public func exchangeDocument(caseID: UUID, sourceSystem: String = "investigations-made-easy", exportedAt: Date = Date()) async throws -> CaseExchange.Document {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let carried = try await carriedRecords(caseID: caseID)
        var external: [UUID: String] = [:]
        for c in carried where c.origin.hasPrefix("exchange:") {
            let parts = c.origin.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 { external[c.targetID] = parts[2] }
        }
        func xid(_ id: UUID) -> String { external[id] ?? id.uuidString.lowercased() }
        var records: [CaseExchange.Record] = []
        var nodeToID: [CaseMapNodeID: String] = [:]
        for a in try await allegations(caseID: caseID) {
            records.append(.init(id: xid(a.id), kind: "question", text: a.text, date: nil, role: nil, sources: []))
            nodeToID[CaseMapNodeID(caseID: caseID, kind: .allegation, recordID: a.id.uuidString.lowercased())] = xid(a.id)
        }
        for p in try await people(caseID: caseID) {
            records.append(.init(id: xid(p.id), kind: "person", text: p.name, date: nil, role: p.role.rawValue, sources: []))
            nodeToID[CaseMapNodeID(caseID: caseID, kind: .person, recordID: p.id.uuidString.lowercased())] = xid(p.id)
        }
        for j in try await journal(caseID: caseID, kind: .chronology) {
            var id = j.id.uuidString.lowercased()
            if let o = j.origin, o.hasPrefix("exchange:") { let parts = o.split(separator: ":", maxSplits: 2).map(String.init); if parts.count == 3 { id = parts[2] } }
            let date = j.dateText ?? j.eventDate.map { CaseExchange.dayText($0, zone: j.dateTimeZone) }
            var sources = j.citations.compactMap { c in c.sourceVersionID.map { CaseExchange.SourceRef(sourceVersionID: $0.uuidString.lowercased(), quote: c.quote) } }
            if sources.isEmpty, let ref = j.evidenceRef, let v = UUID(uuidString: ref) {
                sources = [CaseExchange.SourceRef(sourceVersionID: v.uuidString.lowercased(), quote: j.quote)]
            }
            records.append(.init(id: id, kind: "event", text: j.text, date: date, role: nil, sources: sources))
            nodeToID[CaseMapNodeID(caseID: caseID, kind: .journal, recordID: j.id.uuidString.lowercased())] = id
        }
        func lookup(_ n: CaseMapNodeID) -> String? {
            nodeToID[n] ?? nodeToID[CaseMapNodeID(caseID: n.caseID, kind: n.kind, recordID: n.recordID.lowercased())]
        }
        var relationships: [CaseExchange.Relationship] = []
        for l in try await CaseMapRepository(database: database).links(caseID: caseID) where l.withdrawnAt == nil {
            guard let f = lookup(l.from), let t = lookup(l.to) else { continue }
            relationships.append(.init(id: l.id.uuidString.lowercased(), type: l.type.rawValue, from: f, to: t, rationale: l.rationale,
                                       certainty: l.certainty == .notStated ? nil : l.certainty.rawValue))
        }
        let iso = ISO8601DateFormatter()
        return CaseExchange.Document(format: CaseExchange.format, version: CaseExchange.version, sourceSystem: sourceSystem,
                                     exportedAt: iso.string(from: exportedAt), caseTitle: try await database.query("SELECT title FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0),
                                     records: records, relationships: relationships)
    }

    // MARK: ADAPT-06 structured exchange — import

    /// Import an exchange file into this case. Each record becomes a canonical case record (question, person, chronology
    /// entry) stamped with its origin "exchange:<system>:<id>"; a record already imported is MATCHED, never duplicated or
    /// changed. Relationships become investigator links between imported (or matched) records. Everything not imported is
    /// in the receipt, by name. The receipt is written last and is fixed.
    public func importExchange(caseID: UUID, data: Data, actor: String, at date: Date = Date()) async throws -> CaseExchangeReceipt {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        let who = try Self.clean(actor, "Actor")
        let parsed = try CaseExchange.parse(data)
        let d = parsed.document
        let digest = StudioRecordRepository.sha256(data)
        var receipt = CaseExchangeReceipt(id: UUID(), sourceSystem: d.sourceSystem, fileSHA256: digest, created: [], matched: [], skipped: parsed.skipped,
                                          unsupportedFields: parsed.unsupportedFields, limitations: [])
        let carried = try await carriedRecords(caseID: caseID)
        let entries = try await journal(caseID: caseID, kind: .chronology)
        var local: [String: CaseMapNodeID] = [:]
        func origin(_ id: String) -> String { "exchange:\(d.sourceSystem):\(id)" }
        for r in d.records {
            guard let kind = CaseExchange.recordKinds[r.kind] else { continue }
            let o = origin(r.id)
            let stamp = CaseCarryStamp(origin: o, originDigest: digest, reviewState: "imported")
            do {
                switch kind {
                case .question:
                    if let c = carried.first(where: { $0.origin == o && $0.targetKind == .question }) {
                        receipt.matched.append(r.id); local[r.id] = CaseMapNodeID(caseID: caseID, kind: .allegation, recordID: c.targetID.uuidString.lowercased()); continue
                    }
                    let id = try await addAllegation(caseID: caseID, text: r.text, carry: stamp, actor: who, at: date)
                    local[r.id] = CaseMapNodeID(caseID: caseID, kind: .allegation, recordID: id.uuidString.lowercased())
                case .person:
                    if let c = carried.first(where: { $0.origin == o && $0.targetKind == .person }) {
                        receipt.matched.append(r.id); local[r.id] = CaseMapNodeID(caseID: caseID, kind: .person, recordID: c.targetID.uuidString.lowercased()); continue
                    }
                    let role = r.role.flatMap(CasePersonRole.init(rawValue:)) ?? .other
                    if let written = r.role, CasePersonRole(rawValue: written) == nil {
                        receipt.limitations.append("\(r.id): role “\(written)” is not one of this app's roles; recorded as other, the written role kept in the notes")
                    }
                    let notes = r.role.flatMap { CasePersonRole(rawValue: $0) == nil ? "Role as written in the imported file: \($0)" : nil }
                    let id = try await addPerson(caseID: caseID, name: r.text, role: role, entityID: nil, contact: nil, notes: notes, carry: stamp, actor: who, at: date)
                    local[r.id] = CaseMapNodeID(caseID: caseID, kind: .person, recordID: id.uuidString.lowercased())
                case .event:
                    if let e = entries.first(where: { $0.origin == o }) {
                        receipt.matched.append(r.id); local[r.id] = CaseMapNodeID(caseID: caseID, kind: .journal, recordID: e.id.uuidString.lowercased()); continue
                    }
                    let day = CaseExchange.day(r.date)
                    if let written = r.date, day == nil {
                        receipt.limitations.append("\(r.id): date “\(written)” kept as written; it is not placed in order")
                    }
                    var citations: [StudioEvidenceRef] = []
                    for s in r.sources {
                        guard let v = UUID(uuidString: s.sourceVersionID) else {
                            receipt.limitations.append("\(r.id): source reference “\(s.sourceVersionID)” is not a source version identifier; not cited"); continue
                        }
                        guard try await sourceVersionInCase(caseID: caseID, v) else {
                            receipt.limitations.append("\(r.id): source \(s.sourceVersionID) is not in this case; the entry is recorded without that citation"); continue
                        }
                        citations.append(StudioEvidenceRef(sourceVersionID: v, quote: s.quote))
                    }
                    let id = try await addJournal(caseID: caseID, kind: .chronology, text: r.text, eventDate: day, evidenceRef: citations.first?.sourceVersionID?.uuidString,
                                                  quote: citations.first?.quote, origin: o, citations: citations, reviewState: "imported", originDigest: digest,
                                                  datePrecision: day == nil ? nil : .day, dateText: r.date, timeZoneID: day == nil ? nil : "UTC",
                                                  actor: who, at: date)
                    local[r.id] = CaseMapNodeID(caseID: caseID, kind: .journal, recordID: id.uuidString.lowercased())
                case .moneyRecord:
                    continue
                }
                receipt.created.append(r.id)
            } catch {
                KalsmritikoshLog.storage.error("Exchange import: record not imported: \(error.localizedDescription, privacy: .public)")
                receipt.skipped.append("\(r.id): \(error.localizedDescription)")
            }
        }
        let maps = CaseMapRepository(database: database)
        let existing = try await maps.links(caseID: caseID).filter { $0.withdrawnAt == nil }
        for rel in d.relationships {
            guard let type = CaseMapLinkType(rawValue: rel.type), type.drawable else {
                receipt.skipped.append("\(rel.id): relationship type “\(rel.type)” is not a link a person can record"); continue
            }
            guard let from = local[rel.from], let to = local[rel.to] else {
                receipt.skipped.append("\(rel.id): an end (\(local[rel.from] == nil ? rel.from : rel.to)) is not a record imported or matched in this file"); continue
            }
            if existing.contains(where: { $0.type == type && $0.from == from && $0.to == to }) { receipt.matched.append(rel.id); continue }
            let certainty = rel.certainty.flatMap(CaseMapCertainty.init(rawValue:)) ?? .notStated
            if let c = rel.certainty, CaseMapCertainty(rawValue: c) == nil { receipt.limitations.append("\(rel.id): certainty “\(c)” is not supported; recorded as not stated") }
            let why = Self.blankToNil(rel.rationale) ?? "As recorded in the exchange file from \(d.sourceSystem); no reason was given there."
            do {
                _ = try await maps.addLink(caseID: caseID, type: type, from: from, to: to, rationale: why, certainty: certainty, actor: who, at: date)
                receipt.created.append(rel.id)
            } catch {
                KalsmritikoshLog.storage.error("Exchange import: relationship not imported: \(error.localizedDescription, privacy: .public)")
                receipt.skipped.append("\(rel.id): \(error.localizedDescription)")
            }
        }
        let json = String(data: (try? JSONEncoder().encode(receipt)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        let r = receipt
        try await write("cf_xchg", caseID: caseID, actor: who, action: "exchangeImported", detail: r.summary, at: date) { db in
            try db.exec("""
                INSERT INTO case_exchange_imports (id, case_id, format, format_version, source_system, file_sha256, created_count, matched_count, skipped_count,
                    receipt_json, imported_by, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(r.id), .uuid(caseID), .text(CaseExchange.format), .integer(Int64(CaseExchange.version)), .text(r.sourceSystem), .text(r.fileSHA256),
                      .integer(Int64(r.created.count)), .integer(Int64(r.matched.count)), .integer(Int64(r.skipped.count)), .text(json), .text(who), .date(date)])
        }
        return receipt
    }

    /// The receipts of this case's exchange imports, newest first.
    public func exchangeImports(caseID: UUID) async throws -> [CaseExchangeReceipt] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT receipt_json FROM case_exchange_imports WHERE case_id = ? ORDER BY imported_at DESC, rowid DESC;", [.uuid(caseID)])
            .compactMap { $0.string(0).flatMap { try? JSONDecoder().decode(CaseExchangeReceipt.self, from: Data($0.utf8)) } }
    }

    /// Whether a source version is in this case's scope.
    public func sourceVersionInCase(caseID: UUID, _ version: UUID) async throws -> Bool {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.withSavepoint("cf_vin_\(UUID().uuidString.prefix(8))") { db in try Self.versionInCase(db, version, caseID: caseID) }
    }
}
