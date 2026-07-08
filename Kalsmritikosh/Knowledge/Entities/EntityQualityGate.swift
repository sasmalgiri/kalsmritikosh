//
//  EntityQualityGate.swift
//  Kalsmritikosh
//
//  T13 secondary safety net — reject the entity shapes NER reliably emits
//  on email archives but never represent real people / organizations:
//  weekday + month tokens, mail/header keywords (editable Resources
//  stoplist), the app's own internal identifiers, single common-noun
//  lowercased tokens, and hostname-shaped strings. Applies to BOTH the
//  NLTagger path and the future guided-generation path, before insert.
//

import Foundation
import OSLog

public struct EntityQualityGate: Sendable {
    public let stoplist: Set<String>

    public nonisolated init(stoplist: Set<String> = []) {
        self.stoplist = stoplist
    }

    /// Loads the editable stoplist shipped at
    /// `Resources/EntityStoplist.json` (root key "stoplist" → [String]).
    /// Falls back to an empty stoplist when the resource is missing; the
    /// hardcoded weekday/month/internal checks still apply.
    public nonisolated static func bundled() -> EntityQualityGate {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "EntityStoplist", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return EntityQualityGate(stoplist: [])
        }
        struct Envelope: Decodable { let stoplist: [String] }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return EntityQualityGate(stoplist: [])
        }
        return EntityQualityGate(stoplist: Set(env.stoplist.map { $0.lowercased() }))
    }

    // MARK: - Hardcoded rejects

    public nonisolated static let weekdays: Set<String> = [
        "mon", "tue", "wed", "thu", "fri", "sat", "sun",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    public nonisolated static let months: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul",
        "aug", "sep", "sept", "oct", "nov", "dec",
        "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november", "december"
    ]

    /// Identifiers the app's own pipeline emits when NLTagger reads its
    /// internal class names off log strings the entity extractor
    /// inadvertently sees.
    public nonisolated static let internalIdentifiers: Set<String> = [
        "apple naturallanguage", "apple ai", "apple intelligence",
        "natural language", "nltagger", "nlembedding"
    ]

    // MARK: - API

    /// `true` iff the entity passes every gate. Per-kind rules apply
    /// only to person / organization / vendor / client (the categories
    /// that NER pollutes); other kinds (date, money, location, …) are
    /// untouched.
    public nonisolated func shouldKeep(_ entity: Entity) -> Bool {
        let surface = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = surface.lowercased()

        if surface.count < 2 { return false }
        if Self.weekdays.contains(lower) { return false }
        if Self.months.contains(lower) { return false }
        if stoplist.contains(lower) { return false }
        if Self.internalIdentifiers.contains(lower) { return false }

        let isNameKind = isNounKind(entity.kind)

        if isNameKind, lower.contains("worker") {
            return false
        }

        // Single all-lowercase word of person/org kind — almost always a
        // common-noun false positive ("category", "ref", "urls").
        if isNameKind,
           surface.allSatisfy({ $0.isLetter || $0 == "-" }),
           surface == lower {
            return false
        }

        // Hostname-shaped (mixed letters + digits, no spaces, ≥6 chars):
        // "tyzpr01mb4530", "seqmbx01", "d22rediffmail".
        if isNameKind, isHostnameShape(surface) {
            return false
        }

        return true
    }

    // (NOTE: per real-archive validation + user directive "keep all data,
    // arrange don't filter", the previous mid-cap / vowel-less / 2-char
    // rejection rules have been REMOVED. Tokens like "AeTnFNkZQOTRtCqBk"
    // or "rMsPWt" are real bytes from DKIM/ARC headers and have query
    // value for "what email systems delivered my mail?" / "show the
    // routing chain". Filtering them at storage was lossy. The redesign
    // tiers them by confidence at extraction time — tracked as a follow-
    // on commit.)

    public nonisolated func filter(_ entities: [Entity]) -> [Entity] {
        let kept = entities.filter(shouldKeep)
        let dropped = entities.count - kept.count
        if dropped > 0 {
            KalsmritikoshLog.brain.info("EntityQualityGate dropped \(dropped, privacy: .public) of \(entities.count, privacy: .public)")
        }
        return kept
    }

    // MARK: - Retroactive purge

    public struct PurgeReport: Sendable {
        public let entitiesDeleted: Int
        public let memoryObjectsDeleted: Int
        public let totalEntitiesScanned: Int
    }

    /// Sweep existing canonical noun entities, drop those that fail
    /// `shouldKeep`, and cascade-delete any memory_objects whose
    /// subject_identifier matches a dropped entity's value or
    /// normalized form. Idempotent — running it twice on the same DB
    /// is a no-op the second time. Pass `dryRun: true` to count without
    /// modifying.
    public func purgeGarbage(in database: Database, dryRun: Bool = false) async throws -> PurgeReport {
        let rows = try await database.query("""
        SELECT id, kind, value, normalized FROM entities
        WHERE kind IN ('person','organization','vendor','client');
        """)
        var toDelete: [(id: UUID, value: String, normalized: String)] = []
        for row in rows {
            guard let id = row.uuid(0),
                  let kindStr = row.string(1),
                  let value = row.string(2),
                  let normalized = row.string(3),
                  let kind = Entity.Kind(rawValue: kindStr)
            else { continue }
            let entity = Entity(kind: kind, value: value, sourceObjectID: UUID())
            if !shouldKeep(entity) {
                toDelete.append((id, value, normalized))
            }
        }
        guard !toDelete.isEmpty else {
            return PurgeReport(entitiesDeleted: 0, memoryObjectsDeleted: 0, totalEntitiesScanned: rows.count)
        }
        if dryRun {
            return PurgeReport(
                entitiesDeleted: toDelete.count,
                memoryObjectsDeleted: 0,
                totalEntitiesScanned: rows.count
            )
        }
        try await database.beginTransaction()
        var memoryDeleted = 0
        do {
            for entry in toDelete {
                // Delete memory_objects matching value OR normalized (case-insensitive).
                let res = try await database.query("""
                SELECT id FROM memory_objects
                WHERE lower(subject_identifier) IN (?, ?);
                """, [.text(entry.value.lowercased()), .text(entry.normalized.lowercased())])
                memoryDeleted += res.count
                if !res.isEmpty {
                    try await database.exec("""
                    DELETE FROM memory_objects
                    WHERE lower(subject_identifier) IN (?, ?);
                    """, [.text(entry.value.lowercased()), .text(entry.normalized.lowercased())])
                }
                // Delete the canonical entity (FK cascade removes
                // entity_mentions + entity_aliases automatically).
                try await database.exec(
                    "DELETE FROM entities WHERE id = ?;",
                    [.uuid(entry.id)]
                )
            }
            try await database.commitTransaction()
        } catch {
            await database.rollbackTransaction()
            throw error
        }
        KalsmritikoshLog.brain.info("EntityQualityGate purge: removed \(toDelete.count, privacy: .public) entities + \(memoryDeleted, privacy: .public) memory rows")
        return PurgeReport(
            entitiesDeleted: toDelete.count,
            memoryObjectsDeleted: memoryDeleted,
            totalEntitiesScanned: rows.count
        )
    }

    // MARK: - Heuristics

    private nonisolated func isNounKind(_ kind: Entity.Kind) -> Bool {
        switch kind {
        case .person, .organization, .vendor, .client: return true
        default: return false
        }
    }

    private nonisolated func isHostnameShape(_ s: String) -> Bool {
        guard s.count >= 6 else { return false }
        if s.contains(" ") { return false }
        let hasLetter = s.contains(where: \.isLetter)
        let hasDigit = s.contains(where: \.isNumber)
        guard hasLetter, hasDigit else { return false }
        // A real product name like "iPhone15" is rare for a person/org;
        // "M4 Pro" has a space so it escapes; we err on the strict side
        // because false-positive cost (one rejected entity) ≪ false-
        // negative cost (graph poisoned by a hostname).
        return true
    }
}
