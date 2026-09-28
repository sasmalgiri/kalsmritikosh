//
//  GenericFactRepository.swift
//  Kalsmritikosh
//
//  SEM — durable store for domain-pack GenericFacts. Facts are derived projections (never
//  primary evidence): each row keeps its source-block ids so it always drills back to
//  evidence. Idempotent upsert by fact id; lookup by subject+field for the answer layer.
//
//  Raw sqlite3 C-API repository style (exec/query + SQLValue/SQLRow).
//

import Foundation
import OSLog

public actor GenericFactRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    public func upsert(_ fact: GenericFact) async throws {
        let blocksJSON = String(data: try Self.encoder.encode(fact.sourceBlockIDs), encoding: .utf8) ?? "[]"
        // Write from the CANONICAL assessment (S0.5 item 2, Commit C): dimension columns ←
        // assessment; status ← the compatibility encoding; legacy_status ← the preserved
        // original raw value (or the compatibility encoding when none). The dimensions are
        // NOT derived back from the compatibility status — that would discard explicit
        // review/origin/availability/conflict.
        let a = fact.assessment
        let enc = LegacyEvidenceStatusAdapter.encode(a)
        try await database.exec("""
        INSERT OR REPLACE INTO generic_facts
            (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at,
             evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
             producer_version, raw_match, source_count, reassigned_from, derivation)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(fact.id),
            fact.subjectID.map { SQLValue.uuid($0) } ?? .null,
            .text(fact.subjectLabel), .text(fact.field), .text(fact.value),
            fact.unit.map { SQLValue.text($0) } ?? .null,
            .text(enc.rawValue), .real(fact.confidence),
            .text(blocksJSON), .real(Date().timeIntervalSince1970),
            .text(a.basis.rawValue), .text(a.review.rawValue), .text(a.origin.rawValue),
            .text(a.availability.rawValue), .text(a.conflict.rawValue),
            .text((a.legacyStatus ?? enc).rawValue),
            // V1: the row records the version the fact DECLARES (the pack
            // stamps its own DerivedProducerVersions value), defaulting to the
            // current era only when the fact is silent — so a v0 fact over a
            // NULL archive stays 0 ≡ NULL ≡ current, and a v1 fact round-trips
            // as v1. raw_match/source_count are receipts: the pre-normalized
            // surface and the distinct-document corroboration count.
            .integer(Int64(fact.producerVersion ?? DerivedProducerVersions.facts)),
            fact.rawMatch.map { SQLValue.text($0) } ?? .null,
            fact.sourceCount.map { SQLValue.integer(Int64($0)) } ?? .null,
            // V2 gate-3: advisory origin field a reassigned mislabel came from.
            fact.reassignedFrom.map { SQLValue.text($0) } ?? .null,
            // C-4/OCR: NULL means the value was read verbatim from one block.
            fact.derivation.map { SQLValue.text($0.rawValue) } ?? .null
        ])
    }

    public func upsert(_ facts: [GenericFact]) async throws {
        for f in facts { try await upsert(f) }
    }

    /// Topic-Ledger Rebuild U1 (owner rule 1) — write ONE canonical row per fact
    /// natural key (subject+field+value+unit). If the fact already exists, MERGE
    /// the new occurrence into it (union source blocks, bump the distinct-document
    /// count, keep the higher confidence) instead of minting a duplicate row; any
    /// stray duplicate rows already present are collapsed into the canonical one.
    /// This replaces the id-keyed `upsert` on the extraction write path, so
    /// re-extracting the same fact can no longer inflate the ledger.
    public func mergeUpsert(_ fact: GenericFact) async throws {
        // Topic-Ledger U4 — keep extraction noise out of the ledger (the live
        // audit found `amount="rs,"`, `"$0"`, `"$1"`). Degenerate values are
        // dropped at the write path, never stored.
        guard FactValuePlausibility.isAcceptable(field: fact.field, value: fact.value) else { return }
        let subjectClause: String
        var binds: [SQLValue] = [.text(fact.field.lowercased()), .text(fact.value.lowercased())]
        if let sid = fact.subjectID {
            subjectClause = "subject_id = ?"
            binds.insert(.uuid(sid), at: 0)
        } else {
            subjectClause = "subject_id IS NULL AND lower(subject_label) = ?"
            binds.insert(.text(fact.subjectLabel.lowercased()), at: 0)
        }
        let unitClause: String
        if let u = fact.unit {
            unitClause = "lower(unit) = ?"; binds.append(.text(u.lowercased()))
        } else {
            unitClause = "unit IS NULL"
        }
        let rows = try await database.query("""
        SELECT id, source_blocks_json, confidence, derivation FROM generic_facts
        WHERE \(subjectClause) AND lower(field) = ? AND lower(value) = ? AND \(unitClause)
        ORDER BY created_at ASC;
        """, binds)

        guard let firstRow = rows.first, let canonicalID = firstRow.uuid(0) else {
            try await upsert(fact)   // brand-new fact
            return
        }
        // Merge into the earliest (canonical) row; carry its id AND its existing
        // confidence so the merge keeps the highest across occurrences.
        var existingBlocks: [UUID] = []
        if let json = firstRow.string(1),
           let data = json.data(using: .utf8),
           let decoded = try? Self.decoder.decode([UUID].self, from: data) {
            existingBlocks = decoded
        }
        let existingConfidence = firstRow.double(2) ?? fact.confidence
        // Read the STORED derivation, do not assume the incoming one. The seed
        // takes most of its fields from `fact`, so seeding this from `fact`
        // would let a repaired occurrence overwrite an already-verbatim row and
        // defeat the verbatim-wins rule in `mergedWith` — the stored NULL is the
        // assertion "some block states this value exactly", and it must survive.
        let existingDerivation = firstRow.string(3).flatMap { FactDerivation(rawValue: $0) }
        let canonicalSeed = GenericFact(
            id: canonicalID, subjectID: fact.subjectID, subjectLabel: fact.subjectLabel,
            field: fact.field, value: fact.value, unit: fact.unit,
            assessment: fact.assessment, confidence: existingConfidence,
            sourceBlockIDs: existingBlocks, producerVersion: fact.producerVersion,
            rawMatch: fact.rawMatch, sourceCount: nil, reassignedFrom: fact.reassignedFrom,
            derivation: existingDerivation)
        var merged = canonicalSeed.mergedWith(fact)
        // Collapse any stray duplicate rows (older schema/pre-merge writes) —
        // P4.2: their source blocks join the canonical row first. Deleting them
        // bare dropped provenance: a document whose only row was a stray lost
        // its facts, re-derived them next boot, and lost them again.
        let strayRows = rows.dropFirst()
        for row in strayRows {
            guard let json = row.string(1), let data = json.data(using: .utf8),
                  let blocks = try? Self.decoder.decode([UUID].self, from: data), !blocks.isEmpty else { continue }
            merged = merged.mergedWith(GenericFact(
                subjectID: merged.subjectID, subjectLabel: merged.subjectLabel, field: merged.field,
                value: merged.value, unit: merged.unit, assessment: merged.assessment,
                confidence: row.double(2) ?? merged.confidence, sourceBlockIDs: blocks,
                producerVersion: merged.producerVersion,
                derivation: row.string(3).flatMap { FactDerivation(rawValue: $0) }))
        }
        try await upsert(merged)
        let strays = strayRows.compactMap { $0.uuid(0) }
        if !strays.isEmpty { try await delete(ids: strays) }
    }

    public func mergeUpsert(_ facts: [GenericFact]) async throws {
        for f in facts { try await mergeUpsert(f) }
    }

    /// Topic-Ledger U3 — one-time cleanup of an ALREADY-inflated ledger: collapse
    /// every duplicate to one canonical row per natural key (union source blocks,
    /// distinct-document count, highest confidence) and drop degenerate junk
    /// values (U4). Facts are derived projections, so rewriting them is safe (the
    /// no-delete law protects sources/evidence). Returns (before, after) counts.
    /// Idempotent: a second run is a no-op.
    @discardableResult
    public func dedupExisting() async throws -> (before: Int, after: Int) {
        let before = try await count()
        var everything: [GenericFact] = []
        var offset = 0
        while true {
            let page = try await all(offset: offset, pageSize: 1_000)
            if page.isEmpty { break }
            everything.append(contentsOf: page)
            offset += page.count
            if page.count < 1_000 { break }
        }
        let canonical = GenericFact.canonicalize(everything)
            .filter { FactValuePlausibility.isAcceptable(field: $0.field, value: $0.value) }
        let keep = Set(canonical.map(\.id))
        let drop = everything.map(\.id).filter { !keep.contains($0) }
        try await delete(ids: drop)
        for f in canonical { try await upsert(f) }   // rewrite canonical rows (merged blocks/count)
        let after = try await count()
        return (before, after)
    }

    /// L5 — subjects whose facts STATE a value (e.g. a résumé stating the
    /// owner's own email address). Case-insensitive exact value match.
    public func subjectLabels(statingValue value: String, limit: Int = 20) async throws -> [String] {
        let rows = try await database.query("""
        SELECT subject_label, COUNT(*) FROM generic_facts
        WHERE lower(trim(value)) = lower(trim(?)) GROUP BY subject_label ORDER BY 2 DESC LIMIT ?;
        """, [.text(value), .integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    /// L5 — subjects with a fact whose value CONTAINS `token` as a whole token
    /// (a résumé contact line "9960270472 : owner@example.com"). A truncated
    /// or embedded-in-a-word occurrence does not count.
    public func subjectLabels(containingToken token: String, limit: Int = 20) async throws -> [String] {
        let t = token.lowercased()
        let rows = try await database.query("""
        SELECT subject_label, value FROM generic_facts WHERE lower(value) LIKE ? LIMIT 500;
        """, [.text("%\(t)%")])
        var counts: [String: Int] = [:]
        for r in rows {
            guard let label = r.string(0), let value = r.string(1)?.lowercased(),
                  let range = value.range(of: t) else { continue }
            let before = range.lowerBound == value.startIndex ? " " : value[value.index(before: range.lowerBound)]
            let after = range.upperBound == value.endIndex ? " " : value[range.upperBound]
            let edge: (Character) -> Bool = { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "@" || $0 == "_") }
            if edge(before), edge(after) { counts[label, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// L5 — subject labels equal (case-insensitively) to a name.
    public func subjectLabels(named name: String) async throws -> [String] {
        let rows = try await database.query("""
        SELECT DISTINCT subject_label FROM generic_facts WHERE lower(trim(subject_label)) = lower(trim(?));
        """, [.text(name)])
        return rows.compactMap { $0.string(0) }
    }

    /// L5 — every fact of the given subject labels, restricted to fields.
    public func facts(subjectLabels: [String], fields: Set<String>) async throws -> [GenericFact] {
        guard !subjectLabels.isEmpty, !fields.isEmpty else { return [] }
        let wanted = fields.map { FactSchemaRegistry.normalizeField($0) }
        let ls = subjectLabels.map { _ in "?" }.joined(separator: ",")
        let fs = wanted.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts WHERE subject_label IN (\(ls)) AND field IN (\(fs))
        ORDER BY confidence DESC, id ASC;
        """, subjectLabels.map { .text($0) } + wanted.map { .text($0) })
        return rows.compactMap(Self.decode)
    }

    /// Facts about a subject for a field (e.g. all "employer" facts for "Sasmal").
    public func facts(subjectLabel: String, field: String) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts WHERE subject_label = ? AND field = ? ORDER BY confidence DESC;
        """, [.text(subjectLabel), .text(FactSchemaRegistry.normalizeField(field))])
        return rows.compactMap(Self.decode)
    }

    /// HIST-033 — all typed facts about one canonical subject id, for history
    /// materialisation. Deterministic order (confidence desc, then id). Optional
    /// field filter (normalized). Facts whose subject_id is NULL are label-only
    /// and excluded from ID-scoped collection.
    public func facts(subjectID: UUID, fields: Set<String>? = nil) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts WHERE subject_id = ? ORDER BY confidence DESC, id ASC;
        """, [.uuid(subjectID)])
        let all = rows.compactMap(Self.decode)
        guard let fields, !fields.isEmpty else { return all }
        let wanted = Set(fields.map { FactSchemaRegistry.normalizeField($0) })
        return all.filter { wanted.contains(FactSchemaRegistry.normalizeField($0.field)) }
    }

    /// Facts whose evidence intersects ANY of `blockIDs` — the query-time join
    /// (option A): once retrieval surfaces authoritative blocks, the facts derived
    /// from those exact blocks ride along. Matches on the JSON-encoded block-id
    /// array (uppercased UUID strings, as Foundation encodes them). Returns
    /// highest-confidence first, deduped by fact id.
    /// A3 — the lookupField tool's read: every fact carrying a field,
    /// deterministic order, bounded.
    public func facts(field: String, limit: Int = 50) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts WHERE field = ? ORDER BY confidence DESC, id LIMIT ?;
        """, [.text(field), .integer(Int64(limit))])
        return rows.compactMap(Self.decode)
    }

    public func facts(forBlockIDs blockIDs: [UUID]) async throws -> [GenericFact] {
        // P4.2 — was `Array(Set(blockIDs)).prefix(64)` OR'd LIKE scans: a RANDOM
        // 64 of the blocks (Set order changes per process), so a large document
        // found "no facts" on some runs and the drain re-derived it on every
        // boot (the owner copy's fixed-point violation). Batching the LIKE scans
        // fixed that but cost one full-table scan per 64 blocks — a real mbox
        // drain blew its 45-minute budget. ONE query now: each fact's own block
        // list joined against the requested set — complete, deterministic, one
        // pass over the table, no cap.
        let unique = Array(Set(blockIDs.map(\.uuidString)))
        guard !unique.isEmpty else { return [] }
        let wanted = (try? String(data: JSONEncoder().encode(unique), encoding: .utf8)) ?? "[]"
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts
        WHERE id IN (
            SELECT DISTINCT f.id FROM generic_facts f,
                   json_each(CASE WHEN json_valid(f.source_blocks_json) THEN f.source_blocks_json ELSE '[]' END) j
            WHERE upper(j.value) IN (SELECT upper(value) FROM json_each(?))
        )
        ORDER BY confidence DESC, id;
        """, [.text(wanted)])
        return rows.compactMap(Self.decode)
    }

    /// V5 DRAIN ONLY — remove stale derived fact rows so the drain can replace
    /// them with the current-era derivation. Facts are derived projections; the
    /// no-delete law protects sources/evidence, not stale derivations. Never
    /// called from the answer path.
    public func delete(ids: [UUID]) async throws {
        for id in ids {
            try await database.exec("DELETE FROM generic_facts WHERE id = ?;", [.uuid(id)])
        }
    }

    // MARK: - P3.4 · the ledger's OWN field inventory
    //
    // With P3.1's open-field extractor the set of fields the ledger holds is no
    // longer knowable in advance — `chassisnumber`, `policynumber`,
    // `containerid` arrive from documents nobody wrote a pack for. The ask side
    // resolves against THIS, so a question can reach a field that exists
    // without anyone having enumerated it.
    //
    // Bounded and ordered by frequency: a field asserted by many facts is more
    // likely to be what a question means than one asserted once, and the cap
    // keeps the set small enough to hold in memory per ask.
    public func distinctFields(limit: Int = 500) async throws -> [String] {
        let rows = try await database.query("""
        SELECT lower(field), COUNT(*) AS n FROM generic_facts
        GROUP BY lower(field) ORDER BY n DESC, lower(field) ASC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM generic_facts;", [])).first?.int(0) ?? 0)
    }

    /// Slot-aware retrieval (D-11..D-16 support): the distinct source-block ids
    /// of every fact whose field is one of `fields` (normalized lowercase ids,
    /// e.g. "patentnumber"). Used to pull the block that CARRIES a requested
    /// slot value into retrieval directly, so a registered fact field is
    /// answered from the ledger even when bm25 buries its chunk under keyword
    /// co-mentions. The returned blocks still flow through the caller's scope
    /// filter — this widens recall, not the trust boundary.
    public func sourceBlocks(forFields fields: [String], limit: Int = 200) async throws -> [UUID] {
        let norm = Array(Set(fields.map { $0.lowercased() }))
        guard !norm.isEmpty else { return [] }
        let placeholders = norm.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT source_blocks_json FROM generic_facts
        WHERE lower(field) IN (\(placeholders)) ORDER BY confidence DESC LIMIT ?;
        """, norm.map { SQLValue.text($0) } + [.integer(Int64(limit))])
        var out: [UUID] = []
        var seen = Set<UUID>()
        for row in rows {
            guard let json = row.string(0), let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { continue }
            for s in ids {
                guard let id = UUID(uuidString: s), seen.insert(id).inserted else { continue }
                out.append(id)
            }
        }
        return out
    }

    /// Deterministic paged enumeration of ALL facts (for the Claim-producer backfill).
    public func all(offset: Int = 0, pageSize: Int = 1_000) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts ORDER BY id ASC LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap(Self.decode)
    }

    /// Keyset page (`id > afterID ORDER BY id`) for the resumable projection backfill.
    public func page(afterID: UUID?, pageSize: Int) async throws -> [GenericFact] {
        let cols = """
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status,
               producer_version, raw_match, source_count, reassigned_from, derivation
        FROM generic_facts
        """
        let rows: [SQLRow]
        if let afterID {
            rows = try await database.query("\(cols) WHERE id > ? ORDER BY id ASC LIMIT ?;",
                                            [.uuid(afterID), .integer(Int64(pageSize))])
        } else {
            rows = try await database.query("\(cols) ORDER BY id ASC LIMIT ?;", [.integer(Int64(pageSize))])
        }
        return rows.compactMap(Self.decode)
    }

    private nonisolated static func decode(_ r: SQLRow) -> GenericFact? {
        // A row is only dropped when its IDENTITY/content is unusable — never because one
        // evidence DIMENSION is malformed (the decoder falls back per field).
        guard let id = r.uuid(0), let label = r.string(2), let field = r.string(3),
              let value = r.string(4) else { return nil }
        let blocks = (r.string(8)).flatMap { try? decoder.decode([UUID].self, from: Data($0.utf8)) } ?? []
        let assessment = EvidenceAssessmentRowDecoder.decode(.init(
            evidenceBasis: r.string(9), reviewDisposition: r.string(10), proposalOrigin: r.string(11),
            availabilityStatus: r.string(12), conflictStatus: r.string(13),
            legacyStatus: r.string(14), status: r.string(6)))
        // Cols 15/16/17: producer_version, raw_match, source_count. NULL columns
        // decode to nil — a legacy row (written before v121, or by a producer
        // that leaves them unset) reads back as producerVersion == nil ≡ v0 and
        // renders legacy. The version dialect is proven end-to-end here, at the
        // SQL read path, not inferred from the model layer.
        return GenericFact(id: id, subjectID: r.uuid(1), subjectLabel: label, field: field,
                           value: value, unit: r.string(5), assessment: assessment,
                           confidence: r.double(7) ?? 0, sourceBlockIDs: blocks,
                           producerVersion: r.int(15).map(Int.init),
                           rawMatch: r.string(16),
                           sourceCount: r.int(17).map(Int.init),
                           reassignedFrom: r.string(18),   // col 18 (v122): advisory reassignment origin
                           // Col 19 (v129): how the value was recovered. NULL —
                           // every row written before v129, and the ordinary
                           // case since — decodes to nil, meaning VERBATIM. An
                           // unrecognized string also decodes to nil rather
                           // than dropping the row: a fact must never be lost
                           // because an advisory column is unreadable.
                           derivation: r.string(19).flatMap { FactDerivation(rawValue: $0) })
    }
}
