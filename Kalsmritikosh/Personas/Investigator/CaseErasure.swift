//
//  CaseErasure.swift
//  Kalsmritikosh
//
//  Final completion instructions K10 — erasing one case, or one person's derived record, on the
//  person's deliberate act. Fail-closed throughout:
//   • A legal hold on any of the case's (or the person's) documents, an unreleased hold notice for
//     the case, or a hold check that cannot be read refuses the erase — nothing is deleted.
//   • Every case-scoped row (every table carrying `case_id`, their child rows, the case itself) is
//     removed in ONE savepoint, and counted back inside it: any row left rolls the whole erase back.
//   • The case's documents are kept unless the person also asks to erase the ones no other case or
//     workspace uses; a shared document is never removed, only reported.
//   • A content-free record is kept (`case_erasures`): who, when, why, how many rows — never the
//     content. A person is recorded by a SHA-256 of the name, not the name.
//

import Foundation
import CryptoKit
import os

public nonisolated enum CaseErasureError: Error, Equatable, LocalizedError {
    case blankActor, blankReason, caseNotFound, entityNotFound
    public var errorDescription: String? {
        switch self {
        case .blankActor: return "An erasure needs the name of the person making it."
        case .blankReason: return "An erasure needs a reason."
        case .caseNotFound: return "That case no longer exists."
        case .entityNotFound: return "That person is not in the ledger."
        }
    }
}

public nonisolated struct CaseErasureReport: Sendable, Equatable {
    /// The kept erasure record, or nil when the erase was refused or rolled back.
    public let erasureID: UUID?
    /// Why nothing was erased (a hold, an unreadable check, a row that would not go).
    public let refused: String?
    public let rowsErased: [String: Int]
    public let sourcesErased: Int
    /// The case's documents kept because another case or workspace uses them.
    public let sourcesKeptShared: Int
    /// The case's documents kept because the person did not ask to erase them.
    public let sourcesKeptInLibrary: Int
    /// For a person: the documents whose text still names them (their originals are not edited).
    public let documentsStillNaming: Int
    /// A5 — for a person: everything else that still names them and is not erased by this act
    /// (studio drafts, saved answers, topics, conversation turns), by kind → count.
    public var stillNamedIn: [String: Int] = [:]
    /// A3 — facts carrying the name that could not be tied to this person alone (a same-name person
    /// is mentioned in their documents, or their sources cannot be resolved): kept, not erased.
    public var ambiguousFactsKept: Int = 0
    /// A5 — saved answers removed because they cited erased documents.
    public var answersRemoved: Int = 0
    /// The content addresses of vault copies that belonged only to the erased documents.
    public let vaultAddresses: [String]

    static func refusal(_ why: String) -> CaseErasureReport {
        CaseErasureReport(erasureID: nil, refused: why, rowsErased: [:], sourcesErased: 0, sourcesKeptShared: 0,
                          sourcesKeptInLibrary: 0, documentsStillNaming: 0, vaultAddresses: [])
    }
}

public actor CaseEraser {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Tables that are records of erasure itself, never erased by a case or person erasure.
    nonisolated static let keptTables: Set<String> = ["case_erasures", "studio_erasures", "ledger_case_erase", "ledger_full_erase"]

    /// Child tables that point at a case table without a declared foreign key: (child, column, parent).
    nonisolated static let undeclaredChildren: [(String, String, String)] = [
        ("case_allegation_evidence", "allegation_id", "case_allegations"),
        ("case_contacts", "person_id", "case_people"),
        ("case_credibility", "interview_id", "case_interviews"),
        ("ach_hypotheses", "analysis_id", "ach_analyses"),
        ("ach_evidence", "analysis_id", "ach_analyses"),
        ("ach_cells", "analysis_id", "ach_analyses"),
        ("investigation_hypothesis_decisions", "hypothesis_id", "investigation_hypotheses"),
        ("investigation_hypothesis_evidence", "hypothesis_id", "investigation_hypotheses"),
        ("studio_record_revisions", "record_id", "studio_records"),
        ("studio_record_exports", "record_id", "studio_records"),
    ]

    struct Refused: Error { let why: String }

    /// A5 — the vault addresses of the case's documents (read before the erase, so the file step can be
    /// recorded before the ledger commits; the file step itself re-checks that no remaining version uses one).
    public func vaultCandidates(sourceVersionIDs: Set<UUID>) async throws -> [String] {
        guard !sourceVersionIDs.isEmpty else { return [] }
        let ids = Array(sourceVersionIDs)
        return try await database.query("""
            SELECT DISTINCT lower(content_hash) FROM source_versions WHERE logical_source_id IN
              (SELECT logical_source_id FROM source_versions WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ","))));
            """, ids.map { .uuid($0) }).compactMap { $0.string(0) }
    }

    // MARK: - Case

    /// Erase one case. `sourceVersionIDs` are the case's authorised source versions (from its scope).
    public func erase(caseID: UUID, sourceVersionIDs: Set<UUID>, eraseExclusiveSources: Bool,
                      reason: String, legalBasis: String?, actor: String, at date: Date = Date()) async throws -> CaseErasureReport {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseErasureError.blankActor }
        guard !why.isEmpty else { throw CaseErasureError.blankReason }
        guard let ws = try await database.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0) else {
            throw CaseErasureError.caseNotFound
        }
        let versions = sourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        let caseRef = caseID
        let erasureID = UUID()
        do {
            return try await database.withSavepoint("case_erase_\(erasureID.uuidString.prefix(8))") { db in
                try Self.eraseCase(db, caseID: caseRef, workspaceID: ws, versions: versions, eraseExclusive: eraseExclusiveSources,
                                   reason: why, legalBasis: legalBasis, actor: who, at: date, erasureID: erasureID)
            }
        } catch let r as Refused {
            KalsmritikoshLog.app.notice("Case erasure refused: \(r.why, privacy: .public)")
            return .refusal(r.why)
        } catch {
            KalsmritikoshLog.app.error("Case erasure rolled back: \(error.localizedDescription, privacy: .public)")
            return .refusal("Not erased: \(error.localizedDescription). Nothing was deleted.")
        }
    }

    static func eraseCase(_ db: isolated Database, caseID: UUID, workspaceID: String, versions: [UUID], eraseExclusive: Bool,
                          reason: String, legalBasis: String?, actor: String, at date: Date, erasureID: UUID) throws -> CaseErasureReport {
        let vBinds = versions.map { SQLValue.uuid($0) }
        let vMarks = versions.isEmpty ? "NULL" : versions.map { _ in "?" }.joined(separator: ",")
        let logical: [String] = versions.isEmpty ? [] : try db.query(
            "SELECT DISTINCT logical_source_id FROM source_versions WHERE id IN (\(vMarks));", vBinds).compactMap { $0.string(0) }

        // 1. Holds — inside the destructive boundary, so a hold placed meanwhile refuses the erase.
        //    A4: every supported hold target — the case itself, its studio drafts, its source versions,
        //    its files and their knowledge objects — plus unreleased hold notices for the case.
        let held: Int
        let notices: Int
        do {
            var targets = [caseID.uuidString] + versions.map(\.uuidString) + logical
            targets += try db.query("SELECT id FROM studio_records WHERE case_id = ?;", [.uuid(caseID)]).compactMap { $0.string(0) }
            held = try heldCount(db, targets: targets, logical: logical)
            notices = Int(try db.query("SELECT COUNT(*) FROM case_hold_notices WHERE case_id = ? AND released_at IS NULL;", [.uuid(caseID)]).first?.int(0) ?? 0)
        } catch { throw Refused(why: "Not erased: the legal-hold check could not be read (\(error.localizedDescription)). Nothing was deleted.") }
        if held > 0 { throw Refused(why: "Not erased: the case, one of its drafts or \(held == 1 ? "one of its documents" : "its documents") is under a legal hold. Release the hold first. Nothing was deleted.") }
        if notices > 0 { throw Refused(why: "Not erased: the case has \(notices) unreleased legal-hold notice(s). Release them first. Nothing was deleted.") }

        // 2. Which of the case's documents another case or workspace uses.
        var shared: [String] = [], exclusive: [String] = []
        for l in logical {
            let inOtherWorkspace = try db.query("SELECT 1 FROM workspace_sources WHERE file_id = ? AND workspace_id <> ? LIMIT 1;",
                                                [.text(l), .text(workspaceID)]).first != nil
            let inOtherCase = try db.query("""
                SELECT 1 FROM investigation_case_sources s WHERE s.case_id <> ? AND (s.source_ref = ?
                   OR s.source_ref IN (SELECT id FROM source_versions WHERE logical_source_id = ?)) LIMIT 1;
                """, [.uuid(caseID), .text(l), .text(l)]).first != nil
            if inOtherWorkspace || inOtherCase { shared.append(l) } else { exclusive.append(l) }
        }

        // 3. Every case-scoped row, children first; the append-only guards stand aside for this case only.
        try db.exec("INSERT INTO ledger_case_erase (case_id) VALUES (?);", [.uuid(caseID)])
        let tables = try userTables(db)
        var caseTables: [String] = []
        for t in tables where !keptTables.contains(t) {
            if try columns(db, t).contains("case_id") { caseTables.append(t) }
        }
        var counts: [String: Int] = [:]
        // A5 — each of the case's studio drafts is erased the way a single draft is: recorded in
        // studio_erasures (kept, content-free), its quarantined copy and the captured pre-ledger store
        // that held it cleared (the store's guard allows that only after a recorded erasure).
        for row in try db.query("SELECT id, payload_sha256 FROM studio_records WHERE case_id = ?;", [.uuid(caseID)]) {
            guard let rid = row.string(0) else { continue }
            try db.exec("""
                INSERT INTO studio_erasures (id, record_id, case_id, reason, legal_basis, payload_sha256, revisions_cleared,
                    exports_cleared, quarantine_cleared, legacy_originals, erased_by, erased_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?, ?);
                """, [.uuid(UUID()), .text(rid), .uuid(caseID), .text("case erasure: \(reason)"),
                      legalBasis.map { .text($0) } ?? .null, .text(row.string(1) ?? ""), .text(actor), .date(date)])
            try db.exec("""
                UPDATE studio_legacy_quarantine SET raw_json = '' WHERE EXISTS (
                  SELECT 1 FROM studio_legacy_outcomes o WHERE o.record_id = ?
                    AND o.source_key = studio_legacy_quarantine.source_key AND o.element_index = studio_legacy_quarantine.element_index);
                """, [.text(rid)])
            let legacy = try count(db, """
                SELECT COUNT(*) FROM studio_legacy_blobs WHERE raw_blob <> ''
                  AND source_key IN (SELECT DISTINCT source_key FROM studio_legacy_outcomes WHERE record_id = ?);
                """, [.text(rid)])
            try db.exec("""
                UPDATE studio_legacy_blobs SET raw_blob = '', cleared_reason = ?, cleared_at = ?
                WHERE raw_blob <> '' AND source_key IN (SELECT DISTINCT source_key FROM studio_legacy_outcomes WHERE record_id = ?);
                """, [.text("case erasure \(erasureID.uuidString): \(reason)"), .date(date), .text(rid)])
            if legacy > 0 { counts["studio_legacy_blobs", default: 0] += legacy }
        }
        for (child, col, parent) in undeclaredChildren where tables.contains(child) && tables.contains(parent) {
            let n = try count(db, "SELECT COUNT(*) FROM \"\(child)\" WHERE \"\(col)\" IN (SELECT id FROM \"\(parent)\" WHERE case_id = ?);", [.uuid(caseID)])
            try db.exec("DELETE FROM \"\(child)\" WHERE \"\(col)\" IN (SELECT id FROM \"\(parent)\" WHERE case_id = ?);", [.uuid(caseID)])
            if n > 0 { counts[child, default: 0] += n }
        }
        for t in caseTables {
            let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE case_id = ?;", [.uuid(caseID)])
            try db.exec("DELETE FROM \"\(t)\" WHERE case_id = ?;", [.uuid(caseID)])
            if n > 0 { counts[t, default: 0] += n }
        }
        try db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(caseID)])
        counts["investigation_cases"] = 1

        // 4. The documents only this case used, when asked: every row derived from them.
        var vault: [String] = []
        var answersRemoved = 0
        if eraseExclusive && !exclusive.isEmpty {
            vault = try vaultAddressesOnlyUsedBy(db, logical: exclusive)
            answersRemoved = try eraseDerivedProse(db, logical: exclusive, tables: Set(tables), counts: &counts)
            for (t, n) in try eraseSources(db, logical: exclusive, tables: tables) { counts[t, default: 0] += n }
        }

        // 5. Count back inside the boundary: anything left rolls everything back.
        var left: [String] = []
        for t in caseTables {
            if try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE case_id = ?;", [.uuid(caseID)]) > 0 { left.append(t) }
        }
        if try count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]) > 0 { left.append("investigation_cases") }
        if eraseExclusive, !exclusive.isEmpty {
            let marks = exclusive.map { _ in "?" }.joined(separator: ",")
            if try count(db, "SELECT COUNT(*) FROM files WHERE id IN (\(marks));", exclusive.map { .text($0) }) > 0 { left.append("files") }
            if try count(db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id IN (\(marks));", exclusive.map { .text($0) }) > 0 { left.append("source_versions") }
        }
        if !left.isEmpty { throw Refused(why: "Not erased: rows in \(left.joined(separator: ", ")) could not be removed. Nothing was deleted.") }

        try db.exec("DELETE FROM ledger_case_erase WHERE case_id = ?;", [.uuid(caseID)])
        try record(db, id: erasureID, scope: "case", caseID: caseID, subject: nil, reason: reason, legalBasis: legalBasis,
                   counts: counts, erased: eraseExclusive ? exclusive.count : 0, kept: shared.count, actor: actor, at: date)
        var report = CaseErasureReport(erasureID: erasureID, refused: nil, rowsErased: counts,
                                       sourcesErased: eraseExclusive ? exclusive.count : 0, sourcesKeptShared: shared.count,
                                       sourcesKeptInLibrary: eraseExclusive ? 0 : exclusive.count, documentsStillNaming: 0, vaultAddresses: vault)
        report.answersRemoved = answersRemoved
        return report
    }

    // MARK: - Person

    /// Erase one person's derived record: the canonical entity (and the entities merged into it),
    /// its aliases, mentions, links, communities, workspace and case subject rows, and the field facts
    /// whose value is the name. Original documents are not edited; those that still name the person
    /// are counted so the person can erase or redact them.
    public func erasePerson(entityID: UUID, reason: String, legalBasis: String?, actor: String,
                            at date: Date = Date()) async throws -> CaseErasureReport {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseErasureError.blankActor }
        guard !why.isEmpty else { throw CaseErasureError.blankReason }
        guard let name = try await database.query("SELECT value FROM entities WHERE id = ?;", [.uuid(entityID)]).first?.string(0) else {
            throw CaseErasureError.entityNotFound
        }
        let erasureID = UUID()
        do {
            return try await database.withSavepoint("person_erase_\(erasureID.uuidString.prefix(8))") { db in
                try Self.erasePerson(db, entityID: entityID, name: name, reason: why, legalBasis: legalBasis, actor: who, at: date, erasureID: erasureID)
            }
        } catch let r as Refused {
            return .refusal(r.why)
        } catch {
            KalsmritikoshLog.app.error("Person erasure rolled back: \(error.localizedDescription, privacy: .public)")
            return .refusal("Not erased: \(error.localizedDescription). Nothing was deleted.")
        }
    }

    static func erasePerson(_ db: isolated Database, entityID: UUID, name: String, reason: String, legalBasis: String?,
                            actor: String, at date: Date, erasureID: UUID) throws -> CaseErasureReport {
        let ids = [entityID.uuidString] + (try db.query("SELECT id FROM entities WHERE merged_into = ?;", [.uuid(entityID)]).compactMap { $0.string(0) })
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let binds = ids.map { SQLValue.text($0) }
        let held: Int
        do {
            // A4 — the person's documents (by object, file and version) and the cases they are a subject of.
            let objects = try db.query("SELECT DISTINCT source_object_id FROM entity_mentions WHERE entity_id IN (\(marks));", binds).compactMap { $0.string(0) }
            var targets = objects
            if !objects.isEmpty {
                let om = objects.map { _ in "?" }.joined(separator: ",")
                let ob = objects.map { SQLValue.text($0) }
                let files = try db.query("SELECT DISTINCT file_id FROM knowledge_objects WHERE id IN (\(om));", ob).compactMap { $0.string(0) }
                targets += files
                if !files.isEmpty {
                    let fm = files.map { _ in "?" }.joined(separator: ",")
                    targets += try db.query("SELECT id FROM source_versions WHERE logical_source_id IN (\(fm));", files.map { .text($0) }).compactMap { $0.string(0) }
                }
            }
            targets += try db.query("SELECT DISTINCT case_id FROM investigation_subjects WHERE canonical_entity_id IN (\(marks));", binds).compactMap { $0.string(0) }
            targets += try db.query("SELECT DISTINCT case_id FROM case_people WHERE entity_id IN (\(marks));", binds).compactMap { $0.string(0) }
            held = try heldCount(db, targets: targets, logical: [])
        } catch { throw Refused(why: "Not erased: the legal-hold check could not be read (\(error.localizedDescription)). Nothing was deleted.") }
        if held > 0 { throw Refused(why: "Not erased: a document naming this person, or a case they are part of, is under a legal hold. Nothing was deleted.") }

        // A3 — facts are erased only when they are provably this person's: linked by subject, or naming
        // them in documents where only this person (no same-name person) is mentioned. Anything else
        // carrying the name is kept and reported as ambiguous.
        let (theirFacts, ambiguous) = try personFacts(db, ids: ids, name: name)
        let tables = Set(try userTables(db))
        var counts: [String: Int] = [:]
        var steps: [(String, String, [SQLValue])] = [
            ("case_contacts", "person_id IN (SELECT id FROM case_people WHERE entity_id IN (\(marks)))", binds),
            ("case_people", "entity_id IN (\(marks))", binds),
            ("investigation_subjects", "canonical_entity_id IN (\(marks))", binds),
        ]
        for (t, c) in [("entity_aliases", "entity_id"), ("entity_mentions", "entity_id"), ("event_entities", "entity_id"),
                       ("entity_communities", "entity_id"), ("workspace_entities", "entity_id"), ("workspace_derived_entities", "entity_id"),
                       ("email_participant_occurrences", "entity_id"), ("claim_evidence", "entity_id")] {
            steps.append((t, "\(c) IN (\(marks))", binds))
        }
        steps.append(("entity_cooccurrences", "entity_a IN (\(marks)) OR entity_b IN (\(marks))", binds + binds))
        if !theirFacts.isEmpty {
            steps.append(("generic_facts", "id IN (\(theirFacts.map { _ in "?" }.joined(separator: ",")))", theirFacts.map { .text($0) }))
        }
        steps.append(("entities", "id IN (\(marks))", binds))
        for (t, w, b) in steps where tables.contains(t) {
            let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(w);", b)
            try db.exec("DELETE FROM \"\(t)\" WHERE \(w);", b)
            if n > 0 { counts[t, default: 0] += n }
        }
        if try count(db, "SELECT COUNT(*) FROM entities WHERE id IN (\(marks));", binds) > 0 {
            throw Refused(why: "Not erased: the person's record could not be removed. Nothing was deleted.")
        }
        let naming = try count(db, "SELECT COUNT(*) FROM knowledge_objects WHERE instr(lower(content), lower(?)) > 0;", [.text(name)])
        let subject = SHA256.hash(data: Data(name.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        try record(db, id: erasureID, scope: "person", caseID: nil, subject: subject, reason: reason, legalBasis: legalBasis,
                   counts: counts, erased: 0, kept: 0, actor: actor, at: date)
        var report = CaseErasureReport(erasureID: erasureID, refused: nil, rowsErased: counts, sourcesErased: 0, sourcesKeptShared: 0,
                                       sourcesKeptInLibrary: 0, documentsStillNaming: naming, vaultAddresses: [])
        report.ambiguousFactsKept = ambiguous
        // A5 — the complete inventory of what still names them.
        for (kind, sql) in [("studio drafts", "SELECT COUNT(*) FROM studio_records WHERE instr(lower(payload_json), lower(?)) > 0"),
                            ("saved answers", "SELECT COUNT(*) FROM answers WHERE instr(lower(body), lower(?)) > 0"),
                            ("topics", "SELECT COUNT(*) FROM memory_objects WHERE instr(lower(narrative), lower(?)) > 0"),
                            ("conversation turns", "SELECT COUNT(*) FROM conversation_turns WHERE instr(lower(body), lower(?)) > 0"),
                            ("facts kept as ambiguous", "")] where !sql.isEmpty {
            let n = (try? count(db, sql + ";", [.text(name)])) ?? 0
            if n > 0 { report.stillNamedIn[kind] = n }
        }
        if ambiguous > 0 { report.stillNamedIn["facts kept as ambiguous"] = ambiguous }
        return report
    }

    // MARK: - Helpers (inside the savepoint)

    static func userTables(_ db: isolated Database) throws -> [String] {
        try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
            .compactMap { $0.string(0) }
    }

    static func columns(_ db: isolated Database, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\"\(table)\");", []).compactMap { $0.string(1) }
    }

    static func count(_ db: isolated Database, _ sql: String, _ binds: [SQLValue]) throws -> Int {
        Int(try db.query(sql, binds).first?.int(0) ?? 0)
    }

    /// Active hold items on any of `targets` (ids of cases, drafts, source versions, files or knowledge
    /// objects), or on a knowledge object of the `logical` files.
    static func heldCount(_ db: isolated Database, targets: [String], logical: [String]) throws -> Int {
        let all = Array(Set(targets + targets.map { $0.uppercased() } + targets.map { $0.lowercased() }))
        var clauses: [String] = []
        var binds: [SQLValue] = []
        if !all.isEmpty { clauses.append("i.object_id IN (\(all.map { _ in "?" }.joined(separator: ",")))"); binds += all.map { .text($0) } }
        if !logical.isEmpty {
            clauses.append("i.object_id IN (SELECT id FROM knowledge_objects WHERE file_id IN (\(logical.map { _ in "?" }.joined(separator: ","))))")
            binds += logical.map { .text($0) }
        }
        guard !clauses.isEmpty else { return 0 }
        return try count(db, """
            SELECT COUNT(*) FROM legal_hold_items i JOIN legal_holds h ON h.id = i.hold_id
            WHERE h.released_at IS NULL AND i.removed_at IS NULL AND (\(clauses.joined(separator: " OR ")));
            """, binds)
    }

    /// A3 — the ids of the name-carrying facts that are provably this person's, and how many others
    /// carry the name but are kept (a same-name person is mentioned in their documents, or their source
    /// cannot be resolved).
    static func personFacts(_ db: isolated Database, ids: [String], name: String) throws -> ([String], Int) {
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let binds = ids.map { SQLValue.text($0) }
        var theirs = try db.query("SELECT id FROM generic_facts WHERE subject_id IN (\(marks));", binds).compactMap { $0.string(0) }
        let mine = Set(try db.query("SELECT DISTINCT source_object_id FROM entity_mentions WHERE entity_id IN (\(marks));", binds).compactMap { $0.string(0) })
        // Documents where another person with the same name is mentioned.
        let namesakes = Set(try db.query("""
            SELECT DISTINCT m.source_object_id FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
            WHERE e.id NOT IN (\(marks)) AND (e.merged_into IS NULL OR e.merged_into NOT IN (\(marks)))
              AND lower(e.value) = lower(?);
            """, binds + binds + [.text(name)]).compactMap { $0.string(0) })
        var ambiguous = 0
        let candidates = try db.query("SELECT id, source_blocks_json FROM generic_facts WHERE lower(value) = lower(?) AND (subject_id IS NULL OR subject_id NOT IN (\(marks)));",
                                      [.text(name)] + binds)
        for row in candidates {
            guard let id = row.string(0) else { continue }
            let blocks = (row.string(1).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
            var objects = Set<String>()
            for b in blocks {
                objects.formUnion(try db.query("""
                    SELECT ko.id FROM evidence_blocks eb JOIN source_versions sv ON sv.id = eb.source_version_id
                    JOIN knowledge_objects ko ON ko.file_id = sv.logical_source_id WHERE eb.id = ? OR eb.id = ?;
                    """, [.text(b), .text(b.uppercased())]).compactMap { $0.string(0) })
            }
            if !objects.isEmpty, objects.isSubset(of: mine), objects.isDisjoint(with: namesakes) { theirs.append(id) } else { ambiguous += 1 }
        }
        return (Array(Set(theirs)), ambiguous)
    }

    /// A5 — saved answers that cite the documents (their prose quotes them) and topics distilled from
    /// them: removed with the documents. Returns the number of answers removed.
    static func eraseDerivedProse(_ db: isolated Database, logical: [String], tables: Set<String>, counts: inout [String: Int]) throws -> Int {
        let lMarks = logical.map { _ in "?" }.joined(separator: ",")
        let lBinds = logical.map { SQLValue.text($0) }
        let objects = try db.query("SELECT id FROM knowledge_objects WHERE file_id IN (\(lMarks));", lBinds).compactMap { $0.string(0) }
        guard !objects.isEmpty else { return 0 }
        let oMarks = objects.map { _ in "?" }.joined(separator: ",")
        let oBinds = objects.map { SQLValue.text($0) }
        var answers: [String] = []
        if tables.contains("answer_claims") && tables.contains("claim_evidence") {
            answers = try db.query("""
                SELECT DISTINCT c.answer_id FROM answer_claims c JOIN claim_evidence e ON e.claim_id = c.id WHERE e.object_id IN (\(oMarks));
                """, oBinds).compactMap { $0.string(0) }
        }
        if !answers.isEmpty {
            let aMarks = answers.map { _ in "?" }.joined(separator: ",")
            let aBinds = answers.map { SQLValue.text($0) }
            for (t, c) in [("conversation_turns", "answer_ledger_id"), ("answer_revision_events", "answer_id"), ("answer_revisions", "answer_id"),
                           ("answer_claims", "answer_id"), ("answers", "id")] where tables.contains(t) {
                let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(c) IN (\(aMarks));", aBinds)
                try db.exec("DELETE FROM \"\(t)\" WHERE \(c) IN (\(aMarks));", aBinds)
                if n > 0 { counts[t, default: 0] += n }
            }
        }
        if tables.contains("memory_objects") {
            var topics = Set<String>()
            for o in objects {
                topics.formUnion(try db.query("SELECT id FROM memory_objects WHERE instr(upper(source_object_ids_json), upper(?)) > 0;", [.text(o)]).compactMap { $0.string(0) })
            }
            if !topics.isEmpty {
                let tm = topics.map { _ in "?" }.joined(separator: ",")
                let tb = topics.map { SQLValue.text($0) }
                for (t, c) in [("memory_changes", "memory_object_id"), ("memory_objects", "id")] where tables.contains(t) {
                    if t != "memory_objects", !(try columns(db, t)).contains(c) { continue }
                    let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(c) IN (\(tm));", tb)
                    try db.exec("DELETE FROM \"\(t)\" WHERE \(c) IN (\(tm));", tb)
                    if n > 0 { counts[t, default: 0] += n }
                }
            }
        }
        return answers.count
    }

    /// Content addresses of the documents' versions that no remaining version shares.
    static func vaultAddressesOnlyUsedBy(_ db: isolated Database, logical: [String]) throws -> [String] {
        let marks = logical.map { _ in "?" }.joined(separator: ",")
        let binds = logical.map { SQLValue.text($0) }
        return try db.query("""
            SELECT DISTINCT lower(content_hash) FROM source_versions WHERE logical_source_id IN (\(marks))
              AND lower(content_hash) NOT IN (SELECT lower(content_hash) FROM source_versions WHERE logical_source_id NOT IN (\(marks)));
            """, binds + binds).compactMap { $0.string(0) }
    }

    /// Every row derived from the documents: by source version, by logical source / file, and by
    /// their knowledge objects. Repeated because AFTER DELETE triggers can write revision rows.
    static func eraseSources(_ db: isolated Database, logical: [String], tables: [String]) throws -> [String: Int] {
        let lMarks = logical.map { _ in "?" }.joined(separator: ",")
        let lBinds = logical.map { SQLValue.text($0) }
        let versionSQL = "SELECT id FROM source_versions WHERE logical_source_id IN (\(lMarks))"
        let objectSQL = "SELECT id FROM knowledge_objects WHERE file_id IN (\(lMarks))"
        var counts: [String: Int] = [:]
        var plan: [(String, String)] = []   // (table, where)
        for t in tables where !keptTables.contains(t) && t != "source_versions" && t != "files" && t != "knowledge_objects" {
            let cols = Set(try columns(db, t))
            var clauses: [String] = []
            if cols.contains("source_version_id") { clauses.append("source_version_id IN (\(versionSQL))") }
            if cols.contains("logical_source_id") { clauses.append("logical_source_id IN (\(lMarks))") }
            if cols.contains("file_id") { clauses.append("file_id IN (\(lMarks))") }
            for c in ["source_object_id", "knowledge_object_id", "object_id", "source_ko_id"] where cols.contains(c) {
                clauses.append("\(c) IN (\(objectSQL))")
            }
            if !clauses.isEmpty { plan.append((t, clauses.joined(separator: " OR "))) }
        }
        func binds(for clause: String) -> [SQLValue] {
            // Each clause form above uses the logical-id list exactly once.
            let uses = clause.components(separatedBy: "IN (\(lMarks))").count - 1
            return Array(repeating: lBinds, count: uses).flatMap { $0 }
        }
        for _ in 0..<3 {
            for (t, w) in plan {
                let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(w);", binds(for: w))
                if n > 0 { try db.exec("DELETE FROM \"\(t)\" WHERE \(w);", binds(for: w)); counts[t, default: 0] += n }
            }
        }
        for (t, w) in [("knowledge_objects", "file_id IN (\(lMarks))"), ("source_versions", "logical_source_id IN (\(lMarks))"), ("files", "id IN (\(lMarks))")] {
            let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(w);", lBinds)
            try db.exec("DELETE FROM \"\(t)\" WHERE \(w);", lBinds)
            if n > 0 { counts[t, default: 0] += n }
        }
        for (t, w) in plan {
            if try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(w);", binds(for: w)) > 0 {
                throw Refused(why: "Not erased: rows derived from the documents remain in \(t). Nothing was deleted.")
            }
        }
        return counts
    }

    static func record(_ db: isolated Database, id: UUID, scope: String, caseID: UUID?, subject: String?, reason: String,
                       legalBasis: String?, counts: [String: Int], erased: Int, kept: Int, actor: String, at date: Date) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(counts), as: UTF8.self)
        try db.exec("""
            INSERT INTO case_erasures (id, scope, case_id, subject_sha256, reason, legal_basis, rows_json, sources_erased, sources_kept, erased_by, erased_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .text(scope), caseID.map { .uuid($0) } ?? .null, subject.map { .text($0) } ?? .null, .text(reason),
                  legalBasis.map { .text($0) } ?? .null, .text(json), .integer(Int64(erased)), .integer(Int64(kept)), .text(actor), .date(date)])
    }
}
