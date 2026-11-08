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
//   • Candidate review LB1/PB2 — the text the case sent to the AI ("What was sent", `outbound_log`:
//     whole-case copies and the passages and questions of sends cleared for the case, and — LN1 — the
//     question-only sends made while asking in the case, CaseSendScope) is replaced by an erasure line; each entry keeps its time, destination, size and SHA-256 (the audit value), never
//     the content.
//

import Foundation
import os

public nonisolated enum CaseErasureError: Error, Equatable, LocalizedError {
    case blankActor, blankReason, caseNotFound, entityNotFound
    /// B1 — a step that must succeed before anything is deleted did not (nothing was erased).
    case preparationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .preparationFailed(let why): return "Nothing was erased: \(why)."
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
    nonisolated static let keptTables: Set<String> = ["case_erasures", "studio_erasures", "ledger_case_erase", "ledger_full_erase", "ledger_person_erase"]

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
        // LS24 — what was asked in the case: its Ask conversations' turns and every answer made in the case
        // (refused, not found, or citing documents other cases share), before the conversations themselves go
        // with the other case tables below. Questions asked in the library or in another case are not touched.
        let ask = try eraseCaseAsk(db, caseID: caseID, tables: Set(tables), counts: &counts)
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
        // LB1 — what the case sent to the AI, kept in the outbound record: the text goes, the audit line stays.
        if tables.contains("outbound_log") {
            let n = try eraseOutboundText(db, caseID: caseID, erasureID: erasureID, at: date)
            if n > 0 { counts["outbound_log (text removed)"] = n }
        }

        // 4. The documents only this case used, when asked: every row derived from them.
        var vault: [String] = []
        var answersRemoved = ask.answers.count
        if eraseExclusive && !exclusive.isEmpty {
            vault = try vaultAddressesOnlyUsedBy(db, logical: exclusive)
            answersRemoved += try eraseDerivedProse(db, logical: exclusive, tables: Set(tables), counts: &counts)
            for (t, n) in try eraseSources(db, logical: exclusive, tables: tables) { counts[t, default: 0] += n }
        }

        // 5. Count back inside the boundary: anything left rolls everything back.
        var left: [String] = []
        for t in caseTables {
            if try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE case_id = ?;", [.uuid(caseID)]) > 0 { left.append(t) }
        }
        if try count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]) > 0 { left.append("investigation_cases") }
        if tables.contains("outbound_log"), try count(db, "SELECT COUNT(*) FROM outbound_log WHERE (instr(detail, ?) > 0 OR instr(payload_text, ?) > 0) AND payload_text NOT LIKE ?;",
                                                      [.text(caseMarker(caseID)), .text(caseMarker(caseID)), .text(erasedOutboundPrefix + "%")]) > 0 {
            left.append("outbound_log")
        }
        if eraseExclusive, !exclusive.isEmpty {
            let marks = exclusive.map { _ in "?" }.joined(separator: ",")
            if try count(db, "SELECT COUNT(*) FROM files WHERE id IN (\(marks));", exclusive.map { .text($0) }) > 0 { left.append("files") }
            if try count(db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id IN (\(marks));", exclusive.map { .text($0) }) > 0 { left.append("source_versions") }
        }
        left += try askLeft(db, ask, tables: Set(tables))
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

    // MARK: - The outbound record (LB1)

    /// The start of the line that replaces an erased case's text in the outbound record.
    nonisolated static let erasedOutboundPrefix = "[Erased with case "

    nonisolated static func caseMarker(_ caseID: UUID) -> String { OnlineCloudProvider.caseMarker(caseID) }

    /// The line kept in place of the text (no content): which case, which erasure, when.
    nonisolated static func erasedOutboundText(caseID: UUID, erasureID: UUID, at date: Date) -> String {
        "\(erasedOutboundPrefix)\(caseID.uuidString) (erasure \(erasureID.uuidString), \(ISO8601DateFormatter().string(from: date))): the text sent was removed. The time, destination, size and SHA-256 of what was sent are kept.]"
    }

    /// Replace the text of every outbound entry of this case: entries carrying its marker (whole-case
    /// reads, their references, and sends whose passages were cleared for the case) and the full copies
    /// of the case texts its references point to. Returns how many entries lost their text.
    static func eraseOutboundText(_ db: isolated Database, caseID: UUID, erasureID: UUID, at date: Date) throws -> Int {
        let marker = caseMarker(caseID)
        var digests = Set<String>()
        let digest = try NSRegularExpression(pattern: #"case text (?:SHA-256 )?([0-9a-f]{64})"#)
        for row in try db.query("SELECT detail, payload_text FROM outbound_log WHERE instr(detail, ?) > 0 OR instr(payload_text, ?) > 0;",
                                [.text(marker), .text(marker)]) {
            for text in [row.string(0), row.string(1)].compactMap({ $0 }) {
                let ns = text as NSString
                for m in digest.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    digests.insert(ns.substring(with: m.range(at: 1)))
                }
            }
        }
        var conditions = ["instr(detail, ?) > 0", "instr(payload_text, ?) > 0"]
        var binds: [SQLValue] = [.text(marker), .text(marker)]
        for d in digests.sorted() {
            conditions.append("instr(detail, ?) > 0")
            binds.append(.text(OnlineCloudProvider.caseTextFullTag(d)))
        }
        let filter = "(\(conditions.joined(separator: " OR "))) AND payload_text NOT LIKE ?"
        binds.append(.text(erasedOutboundPrefix + "%"))
        let n = try count(db, "SELECT COUNT(*) FROM outbound_log WHERE \(filter);", binds)
        if n > 0 {
            try db.exec("UPDATE outbound_log SET payload_text = ? WHERE \(filter);",
                        [.text(erasedOutboundText(caseID: caseID, erasureID: erasureID, at: date))] + binds)
        }
        return n
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
        // LS19 — the words that name the person in free text: their name and every alias (read before the
        // aliases go below). Matched with `names(_:_:)`: case- and diacritic-insensitive in any script, so
        // "Zoë Müller" is found as "zoe muller" or "ZOË MÜLLER" (SQLite's lower() folds ASCII only).
        let personIDs = try db.query("SELECT lower(id) FROM case_people WHERE entity_id IN (\(marks));", binds).compactMap { $0.string(0) }
        let nameTerms = Array(Set(([name] + (try db.query("SELECT alias_normalized FROM entity_aliases WHERE entity_id IN (\(marks));", binds).compactMap { $0.string(0) }))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 1 })).sorted()
        let historyTerms = Array(Set(nameTerms + personIDs)).sorted()
        // v173 — the case history: recorded map states that name the person (by name, alias or case-person row, in
        // their content or their milestone name) keep a stub marked erased and lose their content and their name;
        // before/after copies of their case-person rows or naming them go. The guards on both stand aside for this
        // act only (ledger_person_erase, removed again below).
        if tables.contains("ledger_person_erase") {
            try db.exec("INSERT INTO ledger_person_erase (erasure_id) VALUES (?);", [.uuid(erasureID)])
            if !historyTerms.isEmpty, tables.contains("case_checkpoints") {
                let ids = try matchingIDs(db, table: "case_checkpoints", columns: ["name", "payload_json", "manifest_json"],
                                          where: "erased_at IS NULL", terms: historyTerms)
                for chunk in chunked(ids) {
                    try db.exec("""
                        UPDATE case_checkpoints SET payload_json = '{}', manifest_json = '{}', content_digest = 'erased',
                            name = CASE WHEN name IS NULL THEN NULL ELSE ? END, erased_at = ?, erased_reason = ?
                        WHERE erased_at IS NULL AND id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));
                        """, [.text(erasedCheckpointName), .date(date), .text("person erasure \(erasureID.uuidString)")] + chunk.map { .text($0) })
                }
                if !ids.isEmpty { counts["case_checkpoints (content cleared)"] = ids.count }
            }
            if tables.contains("case_record_revisions") {
                var ids = Set(try matchingIDs(db, table: "case_record_revisions", columns: ["before_json", "after_json"], where: nil, terms: historyTerms))
                if !personIDs.isEmpty {
                    ids.formUnion(try db.query("SELECT id FROM case_record_revisions WHERE record_kind = 'person' AND record_id IN (\(personIDs.map { _ in "?" }.joined(separator: ",")));",
                                               personIDs.map { .text($0) }).compactMap { $0.string(0) })
                }
                for chunk in chunked(ids.sorted()) {
                    try db.exec("DELETE FROM case_record_revisions WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));", chunk.map { .text($0) })
                }
                if !ids.isEmpty { counts["case_record_revisions"] = ids.count }
            }
            try db.exec("DELETE FROM ledger_person_erase WHERE erasure_id = ?;", [.uuid(erasureID)])
        }
        // v171 / v172 — saved map views whose name or filters (the person's search words) name the person, and saved
        // case searches whose name, words or saved results name them, go whole (a view or a search is the person's
        // own working aid, not evidence; nothing else refers to it).
        for (table, cols) in [("case_map_views", ["name", "filters_json"]), ("case_saved_searches", ["name", "query_text", "result_json"])]
        where tables.contains(table) && !nameTerms.isEmpty {
            let ids = try matchingIDs(db, table: table, columns: cols, where: nil, terms: nameTerms)
            for chunk in chunked(ids) {
                try db.exec("DELETE FROM \"\(table)\" WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));", chunk.map { .text($0) })
            }
            if !ids.isEmpty { counts[table, default: 0] += ids.count }
        }
        // v171 — the case map's positions and links that point at the person's case-person rows go first
        // (map identities keep record ids lower-case).
        let personRows = "SELECT lower(id) FROM case_people WHERE entity_id IN (\(marks))"
        var steps: [(String, String, [SQLValue])] = [
            // v176 — and every position inside a frame anchored on one of those rows (frame_key "person:<id>").
            ("case_map_layout", "(record_kind = 'person' AND record_id IN (\(personRows))) OR frame_key IN (SELECT 'person:' || lower(id) FROM case_people WHERE entity_id IN (\(marks)))", binds + binds),
            ("case_map_links", "(from_kind = 'person' AND from_id IN (\(personRows))) OR (to_kind = 'person' AND to_id IN (\(personRows)))", binds + binds),
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
        // LS23 — the documents and other free text that still name them are counted with the same Unicode
        // matcher (case-, diacritic- and width-insensitive), read a page at a time. No SQL prefilter: lower()/LIKE
        // fold ASCII only and would miss "zoe muller" for "Zoë Müller".
        let naming = try matchingCount(db, table: "knowledge_objects", columns: ["content"], where: nil, terms: [name])
        let subject = StudioRecordRepository.sha256(Data(name.lowercased().utf8))
        try record(db, id: erasureID, scope: "person", caseID: nil, subject: subject, reason: reason, legalBasis: legalBasis,
                   counts: counts, erased: 0, kept: 0, actor: actor, at: date)
        var report = CaseErasureReport(erasureID: erasureID, refused: nil, rowsErased: counts, sourcesErased: 0, sourcesKeptShared: 0,
                                       sourcesKeptInLibrary: 0, documentsStillNaming: naming, vaultAddresses: [])
        report.ambiguousFactsKept = ambiguous
        // A5 — the complete inventory of what still names them.
        for (kind, table, column) in [("studio drafts", "studio_records", "payload_json"), ("saved answers", "answers", "body"),
                                      ("topics", "memory_objects", "narrative"), ("conversation turns", "conversation_turns", "body")]
        where tables.contains(table) {
            do {
                let n = try matchingCount(db, table: table, columns: [column], where: nil, terms: [name])
                if n > 0 { report.stillNamedIn[kind] = n }
            } catch {
                KalsmritikoshLog.app.error("Person erasure: the \(table, privacy: .public) inventory could not be read: \(error.localizedDescription, privacy: .public)")
            }
        }
        if ambiguous > 0 { report.stillNamedIn["facts kept as ambiguous"] = ambiguous }
        // LS19 — free text the erasure keeps by design and reports: the reasons on map links between other
        // records (a link is withdrawn with a reason, never edited), and the names of recorded states already
        // erased before (a stub is never edited again).
        for (kind, table, cols, filter) in [("case map link reasons", "case_map_links", ["rationale", "withdrawn_reason"], nil as String?),
                                            ("erased recorded-state names", "case_checkpoints", ["name"], "erased_at IS NOT NULL"),
                                            // LS25 — derived contradictions quote both documents; a rescan rebuilds them.
                                            ("contradiction quotes", "contradictions", ["claim_a", "claim_b", "description"], nil),
                                            // v176 — case records the investigator made from reports: kept (a point is a case
                                            // record, like a chronology entry) and listed so the person can decide on each.
                                            ("report points", "case_report_points", ["statement", "quote", "locator_note"], nil),
                                            ("report qualifications", "case_report_qualifications", ["text", "quote"], nil),
                                            ("supplied reports", "case_reports", ["title", "producer", "author", "examined_material"], nil)]
        where tables.contains(table) && !nameTerms.isEmpty {
            do {
                let n = try matchingIDs(db, table: table, columns: cols, where: filter, terms: nameTerms).count
                if n > 0 { report.stillNamedIn[kind] = n }
            } catch {
                KalsmritikoshLog.app.error("Person erasure: the \(table, privacy: .public) inventory could not be read: \(error.localizedDescription, privacy: .public)")
            }
        }
        return report
    }

    // MARK: - LS19 name matching (inside the savepoint)

    /// The label a recorded state's name is replaced with when a person erasure clears it.
    nonisolated static let erasedCheckpointName = "Recorded state (content erased)"

    /// Whether `text` contains any of `terms`, ignoring case and diacritics in any script (so "zoe muller"
    /// and "ZOË MÜLLER" both name "Zoë Müller"); composed and decomposed forms compare equal.
    nonisolated static func names(_ text: String?, _ terms: [String]) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return terms.contains { !$0.isEmpty && text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }

    /// The ids of `table`'s rows (optionally narrowed by `filter`) whose `columns` name any of `terms`.
    /// LN7 — rows are read a page at a time (keyset on rowid), so only the matching ids, not every row's
    /// text, are held in memory.
    static func matchingIDs(_ db: isolated Database, table: String, columns: [String], where filter: String?, terms: [String]) throws -> [String] {
        var ids: [String] = []
        try scanNaming(db, table: table, columns: columns, where: filter, terms: terms) { ids.append($0) }
        return ids
    }

    /// LS23 — how many of `table`'s rows (optionally narrowed by `filter`) have `columns` naming any of `terms`.
    static func matchingCount(_ db: isolated Database, table: String, columns: [String], where filter: String?, terms: [String]) throws -> Int {
        var n = 0
        try scanNaming(db, table: table, columns: columns, where: filter, terms: terms) { _ in n += 1 }
        return n
    }

    /// Rows read per page by `scanNaming` (bounded memory on a large ledger).
    nonisolated static let namingPageSize = 256

    /// Calls `found` with the id of every row whose `columns` name any of `terms`, reading `namingPageSize`
    /// rows at a time in rowid order.
    static func scanNaming(_ db: isolated Database, table: String, columns: [String], where filter: String?, terms: [String],
                           found: (String) -> Void) throws {
        let terms = terms.filter { !$0.isEmpty }
        guard !terms.isEmpty, !columns.isEmpty else { return }
        let cols = columns.map { "coalesce(\"\($0)\", '')" }.joined(separator: ", ")
        let narrowed = filter.map { " AND (\($0))" } ?? ""
        var after: Int64 = Int64.min
        while true {
            let rows = try db.query("SELECT rowid, id, \(cols) FROM \"\(table)\" WHERE rowid > ?\(narrowed) ORDER BY rowid LIMIT ?;",
                                    [.integer(after), .integer(Int64(namingPageSize))])
            for row in rows {
                guard let id = row.string(1) else { continue }
                if (2...(columns.count + 1)).contains(where: { names(row.string($0), terms) }) { found(id) }
            }
            guard rows.count == namingPageSize, let last = rows.last?.int(0) else { return }
            after = last
        }
    }

    nonisolated static func chunked(_ ids: [String], size: Int = 400) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
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
        try eraseAnswers(db, ids: answers, tables: tables, counts: &counts)
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

    /// The answer tables, children first: (table, column holding the answer id).
    nonisolated static let answerTables: [(String, String)] = [
        ("conversation_turns", "answer_ledger_id"), ("answer_revision_events", "answer_id"), ("answer_revisions", "answer_id"),
        ("answer_claims", "answer_id"), ("answers", "id")]

    /// Remove saved answers (their revisions, claims and the conversation turns linked to them), 400 ids at a time.
    static func eraseAnswers(_ db: isolated Database, ids: [String], tables: Set<String>, counts: inout [String: Int]) throws {
        for chunk in chunked(ids) {
            let aMarks = chunk.map { _ in "?" }.joined(separator: ",")
            let aBinds = chunk.map { SQLValue.text($0) }
            for (t, c) in answerTables where tables.contains(t) {
                let n = try count(db, "SELECT COUNT(*) FROM \"\(t)\" WHERE \(c) IN (\(aMarks));", aBinds)
                try db.exec("DELETE FROM \"\(t)\" WHERE \(c) IN (\(aMarks));", aBinds)
                if n > 0 { counts[t, default: 0] += n }
            }
        }
    }

    /// What a case erasure removed from Ask (LS24): the case's conversations and the answers made in it.
    struct CaseAsk { var conversations: [String] = []; var answers: [String] = [] }

    /// LS24 — the case's Ask conversations (v174 `conversations.case_id`) lose their turns, and every answer
    /// made in the case goes: stamped with the case (`answers.origin_scope_id`) or linked from one of its
    /// turns — refused and not-found answers and answers citing shared documents included. The conversation
    /// rows themselves go with the other case tables.
    static func eraseCaseAsk(_ db: isolated Database, caseID: UUID, tables: Set<String>, counts: inout [String: Int]) throws -> CaseAsk {
        var ask = CaseAsk()
        guard tables.contains("conversations"), tables.contains("conversation_turns"), tables.contains("answers") else { return ask }
        ask.conversations = try db.query("SELECT id FROM conversations WHERE case_id = ?;", [.uuid(caseID)]).compactMap { $0.string(0) }
        var answers = Set(try db.query("SELECT id FROM answers WHERE origin_scope_id = ?;", [.uuid(caseID)]).compactMap { $0.string(0) })
        for chunk in chunked(ask.conversations) {
            // Only links to answers still saved (a turn's link may point at an answer removed earlier).
            answers.formUnion(try db.query("""
                SELECT DISTINCT a.id FROM conversation_turns t JOIN answers a ON a.id = t.answer_ledger_id
                WHERE t.conversation_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));
                """, chunk.map { .text($0) }).compactMap { $0.string(0) })
        }
        ask.answers = answers.sorted()
        try eraseAnswers(db, ids: ask.answers, tables: tables, counts: &counts)
        for chunk in chunked(ask.conversations) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let binds = chunk.map { SQLValue.text($0) }
            let n = try count(db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id IN (\(marks));", binds)
            try db.exec("DELETE FROM conversation_turns WHERE conversation_id IN (\(marks));", binds)
            if n > 0 { counts["conversation_turns", default: 0] += n }
        }
        return ask
    }

    /// The Ask rows a case erasure must have removed and did not (counted back inside the savepoint).
    static func askLeft(_ db: isolated Database, _ ask: CaseAsk, tables: Set<String>) throws -> [String] {
        var left: [String] = []
        for chunk in chunked(ask.conversations) {
            if try count(db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                         chunk.map { .text($0) }) > 0 { left.append("conversation_turns"); break }
        }
        for chunk in chunked(ask.answers) {
            if try count(db, "SELECT COUNT(*) FROM answers WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                         chunk.map { .text($0) }) > 0 { left.append("answers"); break }
        }
        return left
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
            // LS25: contradictions name their two documents in evidence_a / evidence_b and quote both sides.
            for c in ["source_object_id", "knowledge_object_id", "object_id", "source_ko_id", "evidence_a", "evidence_b"] where cols.contains(c) {
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
