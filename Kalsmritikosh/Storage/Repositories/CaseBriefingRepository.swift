//
//  CaseBriefingRepository.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), AI-18 — the ledger rows a case briefing is built from,
//  read for exactly the case's cleared documents. Every row keeps the document (KnowledgeObject id) it
//  came from, so the briefing can tie each line to the number the reader and the verifier use. Reads
//  only; nothing here writes.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

public actor CaseBriefingRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The most rows read per section; the briefing states how many more there were (no silent cap).
    public static let rowsPerSection = 600
    /// Ids bound per IN (…) list (SQLite's variable limit is far higher; this keeps statements small).
    static let chunk = 400

    /// Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet. `caseID`: also the case's own work (money,
    /// claims, map, findings, methods review, intake, verified answers); `texts`: the case documents' text, to tie a
    /// quote to the document that holds it.
    public func material(objectIDs: [UUID], versionToObject: [UUID: UUID], caseID: UUID? = nil,
                         texts: [UUID: String] = [:]) async throws -> CaseLedgerBriefing.Material {
        var m = CaseLedgerBriefing.Material()
        guard !objectIDs.isEmpty else { return m }
        let ids = objectIDs.sorted { $0.uuidString < $1.uuidString }
        let idSet = Set(ids)

        // People and organisations (+ aliases, tier).
        var entityIDs: [UUID: CaseLedgerBriefing.Entity] = [:]
        try await each(ids) { list, binds in
            let rows = try await self.database.query("""
            SELECT id, kind, value, quality_tier, source_object_id, confidence FROM entities
            WHERE source_object_id IN (\(list)) ORDER BY value LIMIT \(Self.rowsPerSection + 1);
            """, binds)
            for r in rows {
                guard let id = r.uuid(0), let source = r.uuid(4) else { continue }
                entityIDs[id] = CaseLedgerBriefing.Entity(id: id, kind: r.string(1) ?? "", value: r.string(2) ?? "",
                                                    tier: r.string(3) ?? "T2", source: source, confidence: r.double(5) ?? 0.5,
                                                    aliases: [])
            }
        }
        if !entityIDs.isEmpty {
            let eids = Array(entityIDs.keys).sorted { $0.uuidString < $1.uuidString }
            try await each(eids) { list, binds in
                for r in try await self.database.query("SELECT entity_id, alias_normalized FROM entity_aliases WHERE entity_id IN (\(list));", binds) {
                    guard let id = r.uuid(0), let alias = r.string(1), var e = entityIDs[id] else { continue }
                    if !e.aliases.contains(alias), alias.lowercased() != e.value.lowercased() { e.aliases.append(alias) }
                    entityIDs[id] = e
                }
            }
        }
        m.entities = entityIDs.values.sorted { $0.value.lowercased() != $1.value.lowercased() ? $0.value.lowercased() < $1.value.lowercased() : $0.id.uuidString < $1.id.uuidString }

        // Dated events (date confidence stands for precision: low = approximate).
        try await each(ids) { list, binds in
            for r in try await self.database.query("""
            SELECT id, kind, date, end_date, title, summary, source_object_id, date_confidence, quality_tier FROM events
            WHERE source_object_id IN (\(list)) ORDER BY date LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let id = r.uuid(0), let source = r.uuid(6), let date = r.double(2) else { continue }
                m.events.append(CaseLedgerBriefing.Event(id: id, kind: r.string(1) ?? "", date: Date(timeIntervalSince1970: date),
                                                   endDate: r.double(3).map { Date(timeIntervalSince1970: $0) },
                                                   title: r.string(4) ?? "", summary: r.string(5), source: source,
                                                   dateConfidence: r.double(7) ?? 0.5, tier: r.string(8) ?? "T2"))
            }
        }
        m.events.sort { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }

        // Relationships between the case's entities.
        try await each(ids) { list, binds in
            for r in try await self.database.query("""
            SELECT r.kind, a.value, b.value, r.source_object_id FROM relationships r
            JOIN entities a ON a.id = r.from_entity_id JOIN entities b ON b.id = r.to_entity_id
            WHERE r.source_object_id IN (\(list)) LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let source = r.uuid(3) else { continue }
                m.relationships.append(CaseLedgerBriefing.Relationship(kind: r.string(0) ?? "", from: r.string(1) ?? "", to: r.string(2) ?? "", source: source))
            }
        }

        // Typed fields (document numbers, dates, amounts …), by the version they were read from.
        let versions = versionToObject.keys.sorted { $0.uuidString < $1.uuidString }
        try await each(versions) { list, binds in
            for r in try await self.database.query("""
            SELECT source_version_id, field_type, normalized_value, confidence, extraction_method FROM typed_fields
            WHERE source_version_id IN (\(list)) ORDER BY field_type, normalized_value LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let v = r.uuid(0), let source = versionToObject[v] else { continue }
                m.fields.append(CaseLedgerBriefing.Field(type: r.string(1) ?? "", value: r.string(2) ?? "", confidence: r.double(3) ?? 0.5,
                                                   method: r.string(4) ?? "", source: source))
            }
        }

        // Domain facts — their source blocks resolve to the owning document.
        var blockOwner: [UUID: UUID] = [:]
        try await each(ids) { list, binds in
            for r in try await self.database.query("SELECT id, document_id FROM evidence_blocks WHERE document_id IN (\(list));", binds) {
                if let b = r.uuid(0), let d = r.uuid(1) { blockOwner[b] = d }
            }
        }
        if !blockOwner.isEmpty {
            let rows = try await database.query("""
            SELECT subject_label, field, value, unit, status, confidence, source_blocks_json FROM generic_facts
            ORDER BY subject_label, field LIMIT 20000;
            """)
            for r in rows where m.facts.count <= Self.rowsPerSection {
                let blocks = Self.uuids(json: r.string(6))
                guard let source = blocks.lazy.compactMap({ blockOwner[$0] }).first else { continue }
                m.facts.append(CaseLedgerBriefing.Fact(subject: r.string(0) ?? "", field: r.string(1) ?? "", value: r.string(2) ?? "",
                                                 unit: r.string(3), status: r.string(4) ?? "", confidence: r.double(5) ?? 0.5, source: source))
            }
        }

        // Statements (who said what) — assertions whose evidence is a case document.
        for r in try await database.query("""
        SELECT subject_kind, subject_id, predicate, object_value, evidence_object_ids_json, confidence, agent FROM assertions
        WHERE retracted_at IS NULL ORDER BY recorded_at LIMIT 20000;
        """) where m.statements.count <= Self.rowsPerSection {
            guard let source = Self.uuids(json: r.string(4)).first(where: { idSet.contains($0) }) else { continue }
            let subject = r.uuid(1).flatMap { entityIDs[$0]?.value } ?? (r.string(1) ?? "")
            m.statements.append(CaseLedgerBriefing.Statement(subject: subject, predicate: r.string(2) ?? "", object: r.string(3) ?? "",
                                                       agent: r.string(6) ?? "", confidence: r.double(5) ?? 0.5, source: source))
        }

        // Contradictions already found between case documents.
        for r in try await database.query("""
        SELECT description, claim_a, claim_b, evidence_a, evidence_b, severity, status FROM contradictions
        WHERE status != 'resolved' ORDER BY detected_at LIMIT 20000;
        """) where m.contradictions.count <= Self.rowsPerSection {
            let a = r.string(3).flatMap(UUID.init(uuidString:)), b = r.string(4).flatMap(UUID.init(uuidString:))
            guard let a, idSet.contains(a) || (b.map { idSet.contains($0) } ?? false) else { continue }
            m.contradictions.append(CaseLedgerBriefing.Contradiction(description: r.string(0) ?? "", claimA: r.string(1) ?? "", claimB: r.string(2) ?? "",
                                                               sourceA: a, sourceB: b.flatMap { idSet.contains($0) ? $0 : nil },
                                                               severity: r.string(5) ?? ""))
        }

        // Memory objects and summaries scoped to case documents.
        for r in try await database.query("""
        SELECT subject_kind, subject_identifier, narrative, source_object_ids_json, confidence FROM memory_objects
        WHERE status = 'active' AND narrative != '' ORDER BY subject_identifier LIMIT 20000;
        """) where m.memory.count <= Self.rowsPerSection {
            let sources = Self.uuids(json: r.string(3)).filter { idSet.contains($0) }
            guard !sources.isEmpty else { continue }
            m.memory.append(CaseLedgerBriefing.Memory(subject: (r.string(0) ?? "") + " " + (r.string(1) ?? ""), narrative: r.string(2) ?? "",
                                                sources: sources, confidence: r.double(4) ?? 0.5))
        }
        for r in try await database.query("SELECT level, scope_json, body, confidence FROM summaries ORDER BY produced_at DESC LIMIT 20000;")
        where m.summaries.count <= Self.rowsPerSection {
            let sources = Self.uuids(json: r.string(1)).filter { idSet.contains($0) }
            guard !sources.isEmpty, let body = r.string(2), !body.isEmpty else { continue }
            m.summaries.append(CaseLedgerBriefing.Summary(level: r.string(0) ?? "", body: body, sources: sources, confidence: r.double(3) ?? 0.5))
        }
        // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet. Every other source the ledger holds for
        // the case. Each section reads on its own: one that cannot be read is logged and left out, never fatal.
        await addHistory(&m, ids: ids)
        await addShelf(&m)
        if let caseID { await addCaseWork(&m, caseID: caseID, idSet: idSet, versionToObject: versionToObject, texts: texts) }
        return m
    }

    // MARK: - AI-38: every source (owner 2026-11-22, round 2) — not tested yet

    /// The case id as stored: case tables hold it upper- or lower-case.
    private static func caseBinds(_ caseID: UUID) -> [SQLValue] { [.text(caseID.uuidString), .text(caseID.uuidString.lowercased())] }

    /// The case documents a row names: ids or source versions written anywhere in `texts`, then quotes found verbatim.
    static func resolve(_ texts: [String?], quotes: [String] = [], idSet: Set<UUID>, versionToObject: [UUID: UUID],
                        documentTexts: [UUID: String]) -> [UUID] {
        var out: [UUID] = []
        for t in texts {
            for id in uuids(json: t) {
                let o = idSet.contains(id) ? id : versionToObject[id]
                if let o, !out.contains(o) { out.append(o) }
            }
        }
        let ordered = documentTexts.keys.sorted { $0.uuidString < $1.uuidString }
        for q in quotes {
            let needle = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard needle.count >= 12 else { continue }
            if let o = ordered.first(where: { documentTexts[$0]?.contains(needle) == true }), !out.contains(o) { out.append(o) }
        }
        return out
    }

    private func addHistory(_ m: inout CaseLedgerBriefing.Material, ids: [UUID]) async {
        do {
            var versions: [String: Int] = [:]
            for r in try await database.query("SELECT subject_label, COUNT(*) FROM history_artifacts GROUP BY subject_label;") {
                if let l = r.string(0) { versions[l] = Int(r.int(1) ?? 1) }
            }
            var byItem: [String: CaseLedgerBriefing.HistoryLine] = [:]
            try await each(ids) { list, binds in
                for r in try await self.database.query("""
                SELECT hi.id, ha.subject_label, ha.title, hi.title, hi.description, hie.knowledge_object_id
                FROM history_items hi JOIN history_artifacts ha ON ha.id = hi.artifact_id
                JOIN history_item_evidence hie ON hie.history_item_id = hi.id
                WHERE ha.superseded_by IS NULL AND hie.knowledge_object_id IN (\(list))
                ORDER BY ha.subject_label, hi.id LIMIT \(Self.rowsPerSection * 4);
                """, binds) {
                    guard let key = r.string(0), let doc = r.uuid(5) else { continue }
                    if var h = byItem[key] {
                        if !h.sources.contains(doc) { h.sources.append(doc) }
                        byItem[key] = h
                        continue
                    }
                    let label = r.string(1) ?? ""
                    let n = versions[label] ?? 1
                    let item = (r.string(3) ?? "") + (r.string(4).map { " — " + $0 } ?? "")
                    byItem[key] = CaseLedgerBriefing.HistoryLine(story: r.string(2) ?? label, item: item, version: n, versions: n, sources: [doc])
                }
            }
            m.history = Array(byItem.sorted { a, b in
                a.value.story != b.value.story ? a.value.story < b.value.story : (a.value.item != b.value.item ? a.value.item < b.value.item : a.key < b.key)
            }.map(\.value).prefix(Self.rowsPerSection))
        } catch {
            KalsmritikoshLog.storage.error("case briefing: history unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    private func addShelf(_ m: inout CaseLedgerBriefing.Material) async {
        do {
            for r in try await database.query("""
            SELECT d.title, COUNT(p.id) FROM reference_shelf_documents d LEFT JOIN reference_shelf_passages p ON p.document_id = d.id
            WHERE d.status = 'read' GROUP BY d.id ORDER BY d.title, d.id LIMIT 60;
            """) {
                m.shelf.append(CaseLedgerBriefing.ShelfDocument(title: r.string(0) ?? "a reference document", passages: Int(r.int(1) ?? 0)))
            }
        } catch {
            KalsmritikoshLog.storage.error("case briefing: reference shelf unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    private func addCaseWork(_ m: inout CaseLedgerBriefing.Material, caseID: UUID, idSet: Set<UUID>, versionToObject: [UUID: UUID],
                             texts: [UUID: String]) async {
        let cb = Self.caseBinds(caseID)
        let cap = Self.rowsPerSection
        func docs(_ t: [String?], quotes: [String] = []) -> [UUID] {
            Self.resolve(t, quotes: quotes, idSet: idSet, versionToObject: versionToObject, documentTexts: texts)
        }
        // Money records (withdrawn ones left out; an amendment is its own row).
        do {
            for r in try await database.query("""
            SELECT kind, amount_text, currency, record_date, date_text, payer_name, payee_name, reference, disputed_at, source_version_id, quote, id
            FROM case_money_records WHERE case_id IN (?, ?) AND withdrawn_at IS NULL ORDER BY record_date, id LIMIT \(cap + 1);
            """, cb) {
                guard let source = docs([r.string(9)], quotes: [r.string(10) ?? ""]).first else { continue }
                m.money.append(CaseLedgerBriefing.Money(kind: r.string(0) ?? "", amount: r.string(1) ?? "", currency: r.string(2) ?? "",
                                                        date: r.string(3) ?? r.string(4), payer: r.string(5), payee: r.string(6),
                                                        reference: r.string(7), disputed: r.double(8) != nil, source: source))
            }
        } catch { KalsmritikoshLog.storage.error("case briefing: money unreadable: \(String(describing: error), privacy: .public)") }
        // The claims register: claims whose evidence is a case document.
        do {
            var claims: [String: CaseLedgerBriefing.Claim] = [:]
            try await each(idSet.sorted { $0.uuidString < $1.uuidString }) { list, binds in
                for r in try await self.database.query("""
                SELECT c.id, c.subject_label, c.statement, c.review_disposition, c.conflict_status, e.knowledge_object_id
                FROM claims c JOIN claim_evidence_ref e ON e.claim_id = c.id
                WHERE e.knowledge_object_id IN (\(list)) ORDER BY c.subject_label, c.id LIMIT \(cap * 4);
                """, binds) {
                    guard let id = r.string(0), let doc = r.uuid(5) else { continue }
                    if var c = claims[id] {
                        if !c.sources.contains(doc) { c.sources.append(doc) }
                        claims[id] = c
                        continue
                    }
                    claims[id] = CaseLedgerBriefing.Claim(subject: r.string(1) ?? "", statement: r.string(2) ?? "", review: r.string(3) ?? "",
                                                          conflict: r.string(4) ?? "", sources: [doc])
                }
            }
            m.claims = Array(claims.sorted { a, b in a.value.subject != b.value.subject ? a.value.subject < b.value.subject : a.key < b.key }
                .map(\.value).prefix(cap))
        } catch { KalsmritikoshLog.storage.error("case briefing: claims unreadable: \(String(describing: error), privacy: .public)") }
        // Findings: journal entries (notes and chronology — the map's items) with their verification and review, and
        // the review decisions on reliability / conflict / gap items.
        var journalDocs: [String: [UUID]] = [:], journalText: [String: String] = [:]
        do {
            for r in try await database.query("""
            SELECT id, entry_kind, text, evidence_ref, quote, citations_json, verification, review_state
            FROM case_journal WHERE case_id IN (?, ?) AND removed_at IS NULL ORDER BY created_at, id LIMIT \(cap * 2);
            """, cb) {
                guard let id = r.string(0) else { continue }
                let sources = docs([r.string(3), r.string(5)], quotes: [r.string(4) ?? ""])
                journalText[id.uppercased()] = String((r.string(2) ?? "").prefix(80))
                guard !sources.isEmpty else { continue }
                journalDocs[id.uppercased()] = sources
                let review = [r.string(6), r.string(7)].compactMap { $0 }.joined(separator: ", ")
                m.findings.append(CaseLedgerBriefing.Finding(kind: r.string(1) ?? "note", text: r.string(2) ?? "",
                                                             review: review.isEmpty ? "not reviewed" : review, sources: sources))
            }
            for r in try await database.query("""
            SELECT item_kind, decision, reason, note, source_versions_json, passages_json FROM investigation_review_decisions
            WHERE case_id IN (?, ?) ORDER BY decided_at, id LIMIT \(cap + 1);
            """, cb) {
                let sources = docs([r.string(4), r.string(5)])
                guard !sources.isEmpty else { continue }
                let text = (r.string(3) ?? "") + (r.string(2).map { " (" + $0 + ")" } ?? "")
                m.findings.append(CaseLedgerBriefing.Finding(kind: (r.string(0) ?? "item") + " review", text: text.isEmpty ? "decision recorded" : text,
                                                             review: r.string(1) ?? "", sources: sources))
            }
        } catch { KalsmritikoshLog.storage.error("case briefing: findings unreadable: \(String(describing: error), privacy: .public)") }
        // Case map links: an end that is a case document, or a journal entry tied to one.
        do {
            for r in try await database.query("""
            SELECT link_type, from_kind, from_id, to_kind, to_id, rationale, certainty FROM case_map_links
            WHERE case_id IN (?, ?) AND withdrawn_at IS NULL ORDER BY created_at, id LIMIT \(cap + 1);
            """, cb) {
                let fromID = r.string(2) ?? "", toID = r.string(4) ?? ""
                var sources = docs([fromID, toID])
                for end in [fromID.uppercased(), toID.uppercased()] {
                    for d in journalDocs[end] ?? [] where !sources.contains(d) { sources.append(d) }
                }
                guard !sources.isEmpty else { continue }
                func name(_ kind: String?, _ id: String) -> String { journalText[id.uppercased()].map { "\"" + $0 + "\"" } ?? (kind ?? "item") }
                m.mapLinks.append(CaseLedgerBriefing.MapLink(type: r.string(0) ?? "", from: name(r.string(1), fromID), to: name(r.string(3), toID),
                                                             rationale: r.string(5) ?? "", certainty: r.string(6), sources: sources))
            }
        } catch { KalsmritikoshLog.storage.error("case briefing: map links unreadable: \(String(describing: error), privacy: .public)") }
        // Methods review results: the checks the app kept, tied to documents by their quotes.
        do {
            let dec = JSONDecoder()
            for r in try await database.query("SELECT result_json FROM case_ai_method_reviews WHERE case_id IN (?, ?) ORDER BY recorded_at, id LIMIT 20;", cb) {
                guard let data = r.string(0)?.data(using: .utf8) else { continue }
                let rec: CaseAIMethodReviewRecord
                do { rec = try dec.decode(CaseAIMethodReviewRecord.self, from: data) } catch {
                    KalsmritikoshLog.storage.error("case briefing: a methods review record is unreadable: \(String(describing: error), privacy: .public)")
                    continue
                }
                let labels = Dictionary(rec.assessments.map { ($0.methodID, $0.label) }, uniquingKeysWith: { a, _ in a })
                for c in rec.checks where !c.ungrounded {
                    let sources = docs([], quotes: c.quotes)
                    guard !sources.isEmpty else { continue }
                    m.methodChecks.append(CaseLedgerBriefing.MethodCheck(method: labels[c.methodID] ?? c.methodID,
                                                                         observation: c.observation, sources: sources))
                }
            }
            if m.methodChecks.count > cap { m.methodChecks = Array(m.methodChecks.prefix(cap)) }
        } catch { KalsmritikoshLog.storage.error("case briefing: methods review unreadable: \(String(describing: error), privacy: .public)") }
        // Intake: who supplied each document (the intake record, then later attributions).
        do {
            for r in try await database.query("""
            SELECT label, channel, supplied_by, claimed_author, captured_text, decision, source_version_id FROM case_intake_items
            WHERE case_id IN (?, ?) AND source_version_id IS NOT NULL ORDER BY received_at, id LIMIT \(cap + 1);
            """, cb) {
                guard let v = r.uuid(6), let source = versionToObject[v] else { continue }
                m.intake.append(CaseLedgerBriefing.Intake(label: r.string(0) ?? "", channel: r.string(1) ?? "", suppliedBy: r.string(2),
                                                          claimedAuthor: r.string(3), captured: r.string(4), decision: r.string(5), source: source))
            }
            for r in try await database.query("""
            SELECT supplied_by, claimed_author, captured_text, note, source_version_id FROM case_document_attributions
            WHERE case_id IN (?, ?) ORDER BY recorded_at, id LIMIT \(cap + 1);
            """, cb) {
                guard let v = r.uuid(4), let source = versionToObject[v] else { continue }
                m.intake.append(CaseLedgerBriefing.Intake(label: r.string(3) ?? "later statement", channel: "attribution", suppliedBy: r.string(0),
                                                          claimedAuthor: r.string(1), captured: r.string(2), decision: nil, source: source))
            }
        } catch { KalsmritikoshLog.storage.error("case briefing: intake unreadable: \(String(describing: error), privacy: .public)") }
        // The answer journal: supported answers asked in this case, with the case documents their claims cite.
        do {
            var answers: [String: CaseLedgerBriefing.VerifiedAnswer] = [:], order: [String] = []
            for r in try await database.query("""
            SELECT a.id, a.question, a.body, a.answer_state, ce.object_id FROM answers a
            JOIN answer_claims c ON c.answer_id = a.id JOIN claim_evidence ce ON ce.claim_id = c.id
            WHERE a.origin_scope_id IN (?, ?) AND a.answer_state IN ('supported','partially_supported')
            ORDER BY a.created_at, a.id LIMIT \(cap * 4);
            """, cb) {
                guard let id = r.string(0), let o = r.uuid(4), idSet.contains(o) else { continue }
                if var a = answers[id] {
                    if !a.sources.contains(o) { a.sources.append(o) }
                    answers[id] = a
                    continue
                }
                answers[id] = CaseLedgerBriefing.VerifiedAnswer(question: r.string(1) ?? "", answer: String((r.string(2) ?? "").prefix(200)),
                                                                state: r.string(3) ?? "", sources: [o])
                order.append(id)
            }
            m.verifiedAnswers = order.prefix(cap).compactMap { answers[$0] }
        } catch { KalsmritikoshLog.storage.error("case briefing: answer journal unreadable: \(String(describing: error), privacy: .public)") }
    }

    /// Run `body` over `ids` in chunks, with the "?, ?, …" list and its bindings.
    private func each(_ ids: [UUID], _ body: (String, [SQLValue]) async throws -> Void) async throws {
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(ids.count, start + Self.chunk)])
            try await body(Array(repeating: "?", count: slice.count).joined(separator: ", "), slice.map { .uuid($0) })
            start += Self.chunk
        }
    }

    /// Every UUID written anywhere in a JSON text (arrays of ids, or objects carrying them).
    static func uuids(json: String?) -> [UUID] {
        guard let json, !json.isEmpty else { return [] }
        var out: [UUID] = [], seen = Set<UUID>()
        let pattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        for match in json.matches(of: pattern) {
            if let id = UUID(uuidString: String(match.output)), seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}
