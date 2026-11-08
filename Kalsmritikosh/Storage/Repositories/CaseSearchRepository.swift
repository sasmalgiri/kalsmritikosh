//
//  CaseSearchRepository.swift
//  Kalsmritikosh
//
//  Living case map M5 — the ledger reads a case evidence search needs, every one bounded to the documents
//  the case's authorised source versions resolve to (the caller passes those ids; nothing here widens
//  them), and the saved case searches (schema v172) in the encrypted ledger.
//
//  The stored-field clauses of a query (document type, tag, file modified date, extracted event date) are
//  compiled here into parameterised SQL: user text is only ever bound, never spliced into the statement.
//

import CryptoKit
import Foundation
import os

/// One document of the case: the knowledge object the case's authorised versions were read into.
public nonisolated struct CaseSearchDocumentRow: Sendable, Equatable {
    public let objectID: UUID
    /// The case's authorised versions this document was read from.
    public let versionIDs: [UUID]
    public let name: String
    public let sourceType: String
    /// nil when the file system recorded no modified date.
    public let modifiedAt: Date?
    public let statedDateText: String?
    public let updatedAt: Double
    public let length: Int
}

/// A passage (chunk) of a document: where it sits in the document's text.
public nonisolated struct CaseSearchPassageRow: Sendable, Equatable {
    public let id: UUID
    public let ordinal: Int
    public let range: Range<Int>
    public let page: Int?
    /// The person set this passage aside (a rejected chunk): it is blanked out before matching.
    public let setAside: Bool
}

/// A saved case search (v172): a LIVE search keeps the query, its options and the baseline of what it last
/// found, and runs again over the case's current material; a frozen RECEIPT keeps one run's result as it was.
public nonisolated struct CaseSavedSearch: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case live, receipt }
    public let id: UUID
    public let caseID: UUID
    public let name: String
    public let kind: Kind
    public let queryText: String
    public let queryVersion: Int
    public let query: CaseSearchQuery?
    public let options: CaseSearchOptions?
    public let scopeFingerprint: String
    public let scopeVersionIDs: [UUID]
    public let indexRevision: String
    public let executedAt: Date
    public let result: CaseSearchStoredResult
    public let createdBy: String
    public let createdAt: Date
    /// v180 (SEARCH-10) — a live search re-runs when the case's material changes only when the person chose so.
    public enum RerunPolicy: String, Sendable, Codable, CaseIterable { case manual, onMaterialChange }
    public var rerunPolicy: RerunPolicy = .manual
    /// The digest of the new matches last reported (the same alert is not raised twice).
    public var alertedDigest: String? = nil
    public var alertedAt: Date? = nil
}

/// What a saved search records of a run: the documents it matched and the counts, and the receipt lines.
public nonisolated struct CaseSearchStoredResult: Codable, Sendable, Equatable {
    public var matchedObjectIDs: [UUID]
    /// Name per matched document as it was when the run was saved.
    public var names: [String: String]
    public var documents: Int
    public var occurrences: Int
    public var passages: Int
    public var complete: Bool
    public var receiptLines: [String]

    public init(matchedObjectIDs: [UUID], names: [String: String], documents: Int, occurrences: Int, passages: Int, complete: Bool, receiptLines: [String]) {
        self.matchedObjectIDs = matchedObjectIDs; self.names = names; self.documents = documents; self.occurrences = occurrences
        self.passages = passages; self.complete = complete; self.receiptLines = receiptLines
    }

    func encoded() -> String {
        guard let d = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func decode(_ s: String?) -> CaseSearchStoredResult {
        let empty = CaseSearchStoredResult(matchedObjectIDs: [], names: [:], documents: 0, occurrences: 0, passages: 0, complete: false, receiptLines: [])
        guard let s, let d = s.data(using: .utf8) else { return empty }
        do { return try JSONDecoder().decode(CaseSearchStoredResult.self, from: d) } catch {
            KalsmritikoshLog.app.error("Saved case search result unreadable: \(error.localizedDescription, privacy: .public)")
            return empty
        }
    }
}

public nonisolated enum CaseSearchRepositoryError: Error, Equatable, LocalizedError {
    case blank(String)
    case caseNotFound
    case notFound
    case frozen

    public var errorDescription: String? {
        switch self {
        case .blank(let what): return "\(what) can't be empty."
        case .caseNotFound: return "The case was not found."
        case .notFound: return "The saved search was not found."
        case .frozen: return "A saved result is frozen; it is kept as it was. Save a new one instead."
        }
    }
}

public actor CaseSearchRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private static func batches<T>(_ items: [T], _ size: Int = 400) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    // MARK: The case's documents

    /// The documents the authorised `versionIDs` were read into, and the versions with no document in this
    /// ledger. Only these documents are ever searched.
    public func documents(versionIDs: Set<UUID>) async throws -> (documents: [CaseSearchDocumentRow], withoutDocument: Set<UUID>) {
        struct Pending { var versions: Set<UUID>; let name: String; let type: String; let modified: Double; let stated: String?
                         let updated: Double; let length: Int; let subject: String?; let file: UUID? }
        var byObject: [UUID: Pending] = [:]
        var seenVersions = Set<UUID>()
        var perFile: [UUID: Int] = [:]
        for batch in Self.batches(Array(versionIDs)) {
            let rows = try await database.query("""
                SELECT sv.id, ko.id, ko.source_type, f.modified_at, json_extract(ko.metadata_json, '$.date'), ko.updated_at, length(ko.content),
                       sv.original_url, f.url, json_extract(ko.metadata_json, '$.subject'), ko.file_id, sv.filename
                FROM source_versions sv
                JOIN knowledge_objects ko ON ko.file_id = sv.logical_source_id
                JOIN files f ON f.id = ko.file_id
                WHERE sv.id IN (\(Self.marks(batch.count)));
                """, batch.map { .uuid($0) })
            for r in rows {
                guard let v = r.uuid(0), let o = r.uuid(1) else { continue }
                seenVersions.insert(v)
                if byObject[o] != nil { byObject[o]?.versions.insert(v); continue }
                let url = r.string(7) ?? r.string(8)
                var name = url.flatMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }.map { $0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent } ?? ""
                if name.isEmpty { name = r.string(11) ?? "" }
                if name.isEmpty { name = "Source \(v.uuidString.prefix(8))" }
                let modified = r.double(3) ?? r.int(3).map(Double.init) ?? 0
                let updated = r.double(5) ?? r.int(5).map(Double.init) ?? 0
                byObject[o] = Pending(versions: [v], name: name, type: r.string(2) ?? "", modified: modified, stated: r.string(4),
                                      updated: updated, length: Int(r.int(6) ?? 0), subject: r.string(9), file: r.uuid(10))
                if let file = r.uuid(10) { perFile[file, default: 0] += 1 }
            }
        }
        // Several documents read from one file (a mailbox's messages) are named by their subject too.
        let docs = byObject.map { (o, e) -> CaseSearchDocumentRow in
            var name = e.name
            if let f = e.file, (perFile[f] ?? 0) > 1, let subject = e.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
                name += " — " + subject
            }
            return CaseSearchDocumentRow(objectID: o, versionIDs: e.versions.sorted { $0.uuidString < $1.uuidString }, name: name, sourceType: e.type,
                                         modifiedAt: e.modified > 0 ? Date(timeIntervalSince1970: e.modified) : nil, statedDateText: e.stated,
                                         updatedAt: e.updated, length: e.length)
        }
        return (docs, versionIDs.subtracting(seenVersions))
    }

    /// The documents' texts (only the ids asked for).
    public func contents(objectIDs: [UUID]) async throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for batch in Self.batches(objectIDs, 50) {
            for r in try await database.query("SELECT id, content FROM knowledge_objects WHERE id IN (\(Self.marks(batch.count)));", batch.map { .uuid($0) }) {
                if let id = r.uuid(0) { out[id] = r.string(1) ?? "" }
            }
        }
        return out
    }

    /// The live passages of the documents (superseded re-derivations left out), in document order.
    public func passages(objectIDs: [UUID]) async throws -> [UUID: [CaseSearchPassageRow]] {
        var out: [UUID: [CaseSearchPassageRow]] = [:]
        for batch in Self.batches(objectIDs, 200) {
            let rows = try await database.query("""
                SELECT object_id, id, ordinal, char_start, char_end, page_number, review_status FROM chunks
                WHERE object_id IN (\(Self.marks(batch.count))) AND superseded_by_run IS NULL
                ORDER BY object_id, char_start, ordinal;
                """, batch.map { .uuid($0) })
            for r in rows {
                guard let o = r.uuid(0), let id = r.uuid(1) else { continue }
                let s = Int(r.int(3) ?? 0), e = Int(r.int(4) ?? 0)
                guard e > s else { continue }
                out[o, default: []].append(CaseSearchPassageRow(id: id, ordinal: Int(r.int(2) ?? 0), range: s..<e,
                                                                page: r.int(5).map { Int($0) }, setAside: r.string(6) == "rejected"))
            }
        }
        return out
    }

    /// The mentions the ledger recorded in each document: the words as they appear and the recorded name.
    public func mentions(objectIDs: [UUID]) async throws -> [UUID: [String]] {
        var out: [UUID: Set<String>] = [:]
        for batch in Self.batches(objectIDs) {
            let rows = try await database.query("""
                SELECT m.source_object_id, m.surface, e.value FROM entity_mentions m LEFT JOIN entities e ON e.id = m.entity_id
                WHERE m.source_object_id IN (\(Self.marks(batch.count)));
                """, batch.map { .uuid($0) })
            for r in rows {
                guard let o = r.uuid(0) else { continue }
                for s in [r.string(1), r.string(2)].compactMap({ $0 }) where !s.isEmpty { out[o, default: []].insert(s) }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    /// The documents among `objectIDs` that satisfy one stored-field clause.
    public func matching(_ field: CaseSearchStoredField, within objectIDs: [UUID], zone: TimeZone) async throws -> Set<UUID> {
        let (predicate, binds) = Self.predicate(field, zone: zone)
        var out = Set<UUID>()
        for batch in Self.batches(objectIDs) {
            let rows = try await database.query("""
                SELECT ko.id FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                WHERE ko.id IN (\(Self.marks(batch.count))) AND (\(predicate));
                """, batch.map { SQLValue.uuid($0) } + binds)
            for r in rows { if let id = r.uuid(0) { out.insert(id) } }
        }
        return out
    }

    /// The parameterised SQL of a stored-field clause, over `ko` (knowledge_objects) and `f` (files).
    public nonisolated static func predicate(_ field: CaseSearchStoredField, zone: TimeZone) -> (String, [SQLValue]) {
        func dateClause(_ column: String, _ d: CaseSearchDate) -> (String, [SQLValue]) {
            guard let (s, e) = d.span(in: zone) else { return ("0", []) }
            switch d.relation {
            case .before: return ("\(column) < ?", [.real(s.timeIntervalSince1970)])
            case .on: return ("\(column) >= ? AND \(column) < ?", [.real(s.timeIntervalSince1970), .real(e.timeIntervalSince1970)])
            case .after: return ("\(column) >= ?", [.real(e.timeIntervalSince1970)])
            }
        }
        switch field {
        case .type(let v):
            return ("ko.source_type = ? COLLATE NOCASE", [.text(v)])
        case .tag(let v):
            return ("""
                EXISTS (SELECT 1 FROM user_tag_links l JOIN user_tags t ON t.id = l.tag_id
                        WHERE t.name = ? COLLATE NOCASE AND t.retired_at IS NULL AND l.removed_at IS NULL
                          AND ((l.subject_kind = 'object' AND l.subject_id = ko.id)
                            OR (l.subject_kind = 'chunk' AND l.subject_id IN (SELECT c.id FROM chunks c WHERE c.object_id = ko.id))))
                """, [.text(v)])
        case .modified(let d):
            let (c, b) = dateClause("f.modified_at", d)
            return ("f.modified_at > 0 AND " + c, b)
        case .event(let d):
            let (c, b) = dateClause("e.date", d)
            return ("EXISTS (SELECT 1 FROM events e WHERE e.source_object_id = ko.id AND \(c))", b)
        }
    }

    /// How many of the documents have at least one extracted event (for the receipt's date note).
    public func documentsWithEvents(objectIDs: [UUID]) async throws -> Set<UUID> {
        var out = Set<UUID>()
        for batch in Self.batches(objectIDs) {
            for r in try await database.query("SELECT DISTINCT source_object_id FROM events WHERE source_object_id IN (\(Self.marks(batch.count)));", batch.map { .uuid($0) }) {
                if let id = r.uuid(0) { out.insert(id) }
            }
        }
        return out
    }

    /// The index revision of the searched documents: a digest of each document's id, update time and text
    /// length, and its live passages (count and last derivation time). It changes when a document is
    /// re-read, re-derived or re-split, so a saved search can say the material changed.
    public func indexRevision(_ docs: [CaseSearchDocumentRow], semantics: Int) async throws -> String {
        var chunkInfo: [UUID: (Int, Double)] = [:]
        for batch in Self.batches(docs.map(\.objectID)) {
            let rows = try await database.query("""
                SELECT object_id, COUNT(*), MAX(created_at) FROM chunks WHERE object_id IN (\(Self.marks(batch.count))) AND superseded_by_run IS NULL GROUP BY object_id;
                """, batch.map { .uuid($0) })
            for r in rows { if let o = r.uuid(0) { chunkInfo[o] = (Int(r.int(1) ?? 0), r.double(2) ?? 0) } }
        }
        var canonical = "case-search-semantics:\(semantics)\n"
        for d in docs.sorted(by: { $0.objectID.uuidString < $1.objectID.uuidString }) {
            let c = chunkInfo[d.objectID] ?? (0, 0)
            canonical += "\(d.objectID.uuidString)|\(d.updatedAt)|\(d.length)|\(c.0)|\(c.1)\n"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "v\(semantics)-" + digest.prefix(32)
    }

    // MARK: Saved searches (v172)

    @discardableResult
    public func save(caseID: UUID, name: String, kind: CaseSavedSearch.Kind, query: CaseSearchQuery, options: CaseSearchOptions,
                     scopeFingerprint: String, scopeVersionIDs: [UUID], indexRevision: String, executedAt: Date,
                     result: CaseSearchStoredResult, actor: String, at date: Date = Date()) async throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CaseSearchRepositoryError.blank("The saved search's name") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseSearchRepositoryError.blank("Who saved it") }
        let id = UUID()
        let optionsJSON = String(decoding: (try JSONEncoder().encode(options)), as: UTF8.self)
        let versionsJSON = String(decoding: (try JSONEncoder().encode(scopeVersionIDs.map(\.uuidString).sorted())), as: UTF8.self)
        try await database.withSavepoint("csearch_\(id.uuidString.prefix(8))") { db in
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseSearchRepositoryError.caseNotFound }
            try db.exec("""
                INSERT INTO case_saved_searches (id, case_id, name, kind, query_text, query_version, query_json, options_json, scope_fingerprint,
                    scope_versions_json, index_revision, executed_at, result_json, created_by, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(clean), .text(kind.rawValue), .text(query.text), .integer(Int64(query.version)),
                      .text(query.encoded()), .text(optionsJSON), .text(scopeFingerprint), .text(versionsJSON), .text(indexRevision),
                      .date(executedAt), .text(result.encoded()), .text(who), .date(date)])
        }
        return id
    }

    public func savedSearches(caseID: UUID) async throws -> [CaseSavedSearch] {
        try await database.query("""
            SELECT id, case_id, name, kind, query_text, query_version, query_json, options_json, scope_fingerprint, scope_versions_json,
                   index_revision, executed_at, result_json, created_by, created_at, rerun_policy, alerted_digest, alerted_at
            FROM case_saved_searches WHERE case_id = ? ORDER BY created_at ASC, rowid ASC;
            """, [.uuid(caseID)]).compactMap(Self.decode)
    }

    public func savedSearch(id: UUID) async throws -> CaseSavedSearch? {
        try await database.query("""
            SELECT id, case_id, name, kind, query_text, query_version, query_json, options_json, scope_fingerprint, scope_versions_json,
                   index_revision, executed_at, result_json, created_by, created_at, rerun_policy, alerted_digest, alerted_at
            FROM case_saved_searches WHERE id = ?;
            """, [.uuid(id)]).compactMap(Self.decode).first
    }

    /// A live search's new baseline: what it matched when the person last looked (the v172 trigger refuses
    /// this for a frozen receipt).
    public func updateBaseline(id: UUID, caseID: UUID, scopeFingerprint: String, scopeVersionIDs: [UUID], indexRevision: String,
                               executedAt: Date, result: CaseSearchStoredResult) async throws {
        guard let existing = try await savedSearch(id: id), existing.caseID == caseID else { throw CaseSearchRepositoryError.notFound }
        guard existing.kind == .live else { throw CaseSearchRepositoryError.frozen }
        let versionsJSON = String(decoding: (try JSONEncoder().encode(scopeVersionIDs.map(\.uuidString).sorted())), as: UTF8.self)
        try await database.exec("""
            UPDATE case_saved_searches SET scope_fingerprint = ?, scope_versions_json = ?, index_revision = ?, executed_at = ?, result_json = ?
            WHERE id = ? AND case_id = ? AND kind = 'live';
            """, [.text(scopeFingerprint), .text(versionsJSON), .text(indexRevision), .date(executedAt), .text(result.encoded()), .uuid(id), .uuid(caseID)])
    }

    /// v180 (SEARCH-10): the person's re-run policy of a live search (a receipt is frozen and refuses it).
    public func setRerunPolicy(id: UUID, caseID: UUID, _ policy: CaseSavedSearch.RerunPolicy) async throws {
        guard let existing = try await savedSearch(id: id), existing.caseID == caseID else { throw CaseSearchRepositoryError.notFound }
        guard existing.kind == .live else { throw CaseSearchRepositoryError.frozen }
        try await database.exec("UPDATE case_saved_searches SET rerun_policy = ? WHERE id = ? AND case_id = ? AND kind = 'live';",
                                [.text(policy.rawValue), .uuid(id), .uuid(caseID)])
    }

    /// Record that the new matches with `digest` were reported (so the same alert is not raised again).
    public func markAlerted(id: UUID, caseID: UUID, digest: String, at date: Date) async throws {
        try await database.exec("UPDATE case_saved_searches SET alerted_digest = ?, alerted_at = ? WHERE id = ? AND case_id = ? AND kind = 'live';",
                                [.text(digest), .date(date), .uuid(id), .uuid(caseID)])
    }

    // MARK: S4 reads

    /// SEARCH-07 — each version's normalised-text digest (v178), so copies of the same text are counted as copies.
    public func textDigests(versionIDs: [UUID]) async throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for batch in Self.batches(versionIDs) {
            for r in try await database.query("SELECT source_version_id, text_sha256 FROM source_text_digests WHERE source_version_id IN (\(Self.marks(batch.count)));",
                                              batch.map { .uuid($0) }) {
                if let v = r.uuid(0), let d = r.string(1) { out[v] = d }
            }
        }
        return out
    }

    /// SEARCH-05 — where a version sits: the chain of documents it was attached to or taken out of, nearest first
    /// ("attachment of “mail.eml”", "member of “bundle.zip”"), at most 8 levels.
    public func nesting(versionIDs: [UUID]) async throws -> [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        for v in versionIDs {
            var chain: [String] = []
            var current = v
            var seen: Set<UUID> = [v]
            for _ in 0..<8 {
                guard let r = try await database.query("""
                    SELECT rel.parent_source_version_id, rel.relation, sv.filename, sv.original_url FROM source_version_relations rel
                    JOIN source_versions sv ON sv.id = rel.parent_source_version_id
                    WHERE rel.child_source_version_id = ? AND rel.relation <> 'derivedConversion' ORDER BY rel.created_at LIMIT 1;
                    """, [.uuid(current)]).first, let parent = r.uuid(0), seen.insert(parent).inserted else { break }
                let name = r.string(2).flatMap { $0.isEmpty ? nil : $0 }
                    ?? r.string(3).map { (URL(string: $0) ?? URL(fileURLWithPath: $0)).lastPathComponent } ?? "Source \(parent.uuidString.prefix(8))"
                let how: String
                switch r.string(1) {
                case "attachment": how = "attachment of"
                case "archiveMember": how = "member of"
                case "message": how = "message in"
                case "embedded": how = "embedded in"
                default: how = "inside"
                }
                chain.append("\(how) “\(name)”")
                current = parent
            }
            if !chain.isEmpty { out[v] = chain }
        }
        return out
    }

    /// SEARCH-07 — the canonical entity each recorded mention of the documents was recorded as.
    public func mentionEntities(objectIDs: [UUID]) async throws -> [UUID: [String: UUID]] {
        var out: [UUID: [String: UUID]] = [:]
        for batch in Self.batches(objectIDs) {
            let rows = try await database.query("""
                SELECT m.source_object_id, m.surface, e.value, m.entity_id FROM entity_mentions m LEFT JOIN entities e ON e.id = m.entity_id
                WHERE m.source_object_id IN (\(Self.marks(batch.count))) AND m.entity_id IS NOT NULL;
                """, batch.map { .uuid($0) })
            for r in rows {
                guard let o = r.uuid(0), let e = r.uuid(3) else { continue }
                for s in [r.string(1), r.string(2)].compactMap({ $0 }) where !s.isEmpty { out[o, default: [:]][s] = e }
            }
        }
        return out
    }

    // MARK: Saved relationship patterns (v180)

    func patternWrite(_ id: UUID, _ body: @escaping @Sendable (isolated Database) throws -> Void) async throws {
        try await database.withSavepoint("cpat_\(id.uuidString.prefix(8))", body)
    }

    func patternRows(caseID: UUID) async throws -> [CaseSavedPattern] {
        try await database.query("""
            SELECT id, case_id, name, version, kind, pattern_json, result_json, fence, created_by, created_at
            FROM case_saved_patterns WHERE case_id = ? ORDER BY name, version;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let name = r.string(2), let kind = r.string(4).flatMap(CaseSavedPattern.Kind.init(rawValue:)),
                  let by = r.string(8), let at = r.date(9) else { return nil }
            var result: CaseMapPathResult?
            if let json = r.string(6), let d = json.data(using: .utf8) {
                do { result = try JSONDecoder().decode(CaseMapPathResult.self, from: d) } catch {
                    KalsmritikoshLog.app.error("Saved pattern result unreadable: \(error.localizedDescription, privacy: .public)")
                }
            }
            return CaseSavedPattern(id: id, caseID: c, name: name, version: Int(r.int(3) ?? 1), kind: kind, query: CaseMapPathQuery.decode(r.string(5)),
                                    result: result, fence: r.string(7), createdBy: by, createdAt: at)
        }
    }

    public func deleteSavedSearch(id: UUID, caseID: UUID) async throws {
        try await database.exec("DELETE FROM case_saved_searches WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)])
    }

    private static func decode(_ r: SQLRow) -> CaseSavedSearch? {
        guard let id = r.uuid(0), let c = r.uuid(1), let name = r.string(2), let kind = r.string(3).flatMap(CaseSavedSearch.Kind.init(rawValue:)),
              let text = r.string(4), let at = r.date(11), let by = r.string(13), let created = r.date(14) else { return nil }
        let options: CaseSearchOptions?
        do { options = try r.string(7).flatMap { $0.data(using: .utf8) }.map { try JSONDecoder().decode(CaseSearchOptions.self, from: $0) } } catch {
            KalsmritikoshLog.app.error("Saved case search options unreadable: \(error.localizedDescription, privacy: .public)")
            options = nil
        }
        let versions: [UUID]
        do { versions = try r.string(9).flatMap { $0.data(using: .utf8) }.map { try JSONDecoder().decode([String].self, from: $0) }?.compactMap(UUID.init(uuidString:)) ?? [] } catch {
            KalsmritikoshLog.app.error("Saved case search scope unreadable: \(error.localizedDescription, privacy: .public)")
            versions = []
        }
        var saved = CaseSavedSearch(id: id, caseID: c, name: name, kind: kind, queryText: text, queryVersion: Int(r.int(5) ?? 0),
                                    query: CaseSearchQuery.decode(r.string(6)), options: options, scopeFingerprint: r.string(8) ?? "",
                                    scopeVersionIDs: versions, indexRevision: r.string(10) ?? "", executedAt: at,
                                    result: CaseSearchStoredResult.decode(r.string(12)), createdBy: by, createdAt: created)
        saved.rerunPolicy = r.string(15).flatMap(CaseSavedSearch.RerunPolicy.init(rawValue:)) ?? .manual
        saved.alertedDigest = r.string(16)
        saved.alertedAt = r.date(17)
        return saved
    }
}
