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

    /// Bare prepositions/conjunctions that a real person/org name never STARTS
    /// with. Articles (the/a/an) are intentionally omitted — "The Home Depot".
    public nonisolated static let leadingStopWords: Set<String> = [
        "of", "and", "for", "to", "in", "on", "at", "with", "by", "from", "or", "as"
    ]

    /// Identifiers the app's own pipeline emits when NLTagger reads its
    /// internal class names off log strings the entity extractor
    /// inadvertently sees.
    public nonisolated static let internalIdentifiers: Set<String> = [
        "apple naturallanguage", "apple ai", "apple intelligence",
        "natural language", "nltagger", "nlembedding"
    ]

    /// D-13 — mail/infrastructure brand names that are real strings from
    /// real headers (they STAY in the ledger) but never belong on the
    /// rendered "Subjects in scope" line: they are the plumbing the mail
    /// travelled through, not who the archive is about.
    public nonisolated static let mailInfraBrands: Set<String> = [
        "gmail", "google", "outlook", "yahoo", "hotmail", "rediffmail",
        "aol", "icloud", "protonmail", "zoho", "live", "msn",
        "mailer-daemon", "postmaster", "noreply", "no-reply", "donotreply",
    ]

    /// Host-fragment prefixes ("smtpnet", "imap01", "mx2", "pop3srv"…).
    public nonisolated static let mailInfraPrefixes: [String] = [
        "smtp", "imap", "pop3", "mx", "mailer-daemon", "noreply", "no-reply",
    ]

    /// D-13 — presentation-only hygiene for the answer footer. STRICTER than
    /// `shouldKeep` (which also guards ingestion): a name may be worth
    /// KEEPING in the ledger yet not worth PRINTING as a subject. Nothing is
    /// deleted — this filters the rendered line only.
    public nonisolated func keepsForPresentation(_ entity: Entity) -> Bool {
        guard shouldKeep(entity) else { return false }
        return !Self.isMailInfraName(entity.value)
    }

    public nonisolated static func isMailInfraName(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mailInfraBrands.contains(lower) { return true }
        for prefix in mailInfraPrefixes where lower.hasPrefix(prefix) {
            // "smtpnet", "imap01", "mx2" — technical host fragments are the
            // prefix plus a short suffix with no space. A multi-word org
            // name that happens to share the letters keeps its space and
            // survives.
            let rest = lower.dropFirst(prefix.count)
            if rest.count <= 6 && !rest.contains(" ") { return true }
        }
        return false
    }

    // MARK: - API

    /// `true` iff the entity passes every gate.
    public nonisolated func shouldKeep(_ entity: Entity) -> Bool {
        classify(entity) == nil
    }

    /// The rejection CLASS an entity fails on, or nil if it passes — the single
    /// authority `shouldKeep` and the rejection counters both read. Per-kind
    /// rules apply only to person / organization / vendor / client (the
    /// categories NER pollutes); other kinds (date, money, location, the V3
    /// identifierAnchor…) are untouched.
    public nonisolated func classify(_ entity: Entity) -> String? {
        let surface = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = surface.lowercased()

        if surface.count < 2 { return "too-short" }
        if Self.weekdays.contains(lower) { return "weekday" }
        if Self.months.contains(lower) { return "month" }
        if stoplist.contains(lower) { return "stoplist" }
        if Self.internalIdentifiers.contains(lower) { return "internal-id" }

        let isNameKind = isNounKind(entity.kind)
        guard isNameKind else { return nil }   // non-name kinds are untouched

        // E-1 (V3 3b): the Nil-family — "Nil", "Nil Nil", "nil / nil" — a header
        // placeholder NER promotes to a person; never a real name.
        if Self.isNilFamily(lower) { return "nil-family" }

        // E-1: an email address mis-tagged as a person ("s.khan@example.com").
        // A real person/org name never contains "@".
        if surface.contains("@") { return "email-as-person" }

        // V3 3d (E-1): an AUTOMATED SENDER promoted to a person by header
        // parsing ("File Processing Bot", "no-reply", "Mailer-Daemon"). PERSON
        // kind ONLY (an org legitimately named "Notification Systems Inc" is
        // safe) and HIGH-PRECISION WHOLE-TOKEN match ONLY, so a real human with
        // a bot-adjacent name or title passes ("Robert Botha", "Automation Lead,
        // Priya Nair") — false-rejecting a person is the E-2 sin in a new
        // costume. Ships with its innocence fixture.
        if entity.kind == .person, Self.isAutomatedSender(lower) { return "automated-sender" }

        // E-1: a filename mis-tagged as a subject ("RESPONSE_29.08.2024.pdf").
        if Self.isFilenameShaped(lower) { return "filename-shaped" }

        if lower.contains("worker") { return "worker" }

        // Single all-lowercase word — common-noun false positive.
        if surface.allSatisfy({ $0.isLetter || $0 == "-" }), surface == lower {
            return "lowercase-common-noun"
        }
        // Hostname-shaped (mixed letters + digits, no spaces, ≥6 chars).
        if isHostnameShape(surface) { return "hostname-shape" }
        // First token a bare preposition/conjunction → mis-tagged sentence fragment.
        if let first = surface.split(whereSeparator: { $0.isWhitespace }).first,
           Self.leadingStopWords.contains(String(first).lowercased()) {
            return "leading-stopword"
        }
        // P3-U0 (GO2R): TITLE-SHAPED — a web-page/job-portal title fragment
        // promoted to a subject ("Auro Laboratories Ltd - Career"). The
        // trailing navigation token gives it away; witnessed on the owner's
        // live archive. REJECTED (it is a page title, not a party).
        if Self.isTitleShaped(surface) { return "title-shaped" }
        return nil
    }

    /// P3-U0 — trailing navigation/page tokens that mark a TITLE, not a name.
    /// Checked after " - " / " – " / " | " separators so a person legitimately
    /// named e.g. "Homer Career" (no separator) passes.
    nonisolated static let titleNavigationTails: Set<String> = [
        "career", "careers", "home", "about", "login", "jobs", "profile",
        "contact", "signin", "sign in", "apply",
    ]
    nonisolated static func isTitleShaped(_ surface: String) -> Bool {
        for sep in [" - ", " – ", " — ", " | "] {
            if let tail = surface.components(separatedBy: sep).last,
               surface.contains(sep),
               titleNavigationTails.contains(tail.trimmingCharacters(in: .whitespaces).lowercased()) {
                return true
            }
        }
        return false
    }

    /// P3-U0 — PLACE-NAME SURNAME suspect: a "First Last" person whose last
    /// token is a well-known place ("Bill Delhi") is DEMOTED (suspect flag for
    /// review + never surfaced unasked), NEVER deleted — real people carry
    /// place surnames ("Jack London"). Advisory, not a rejection class.
    nonisolated static let placeSurnames: Set<String> = [
        "delhi", "mumbai", "london", "paris", "berlin", "tokyo", "sydney",
        "chicago", "houston", "austin", "dallas", "phoenix", "denver",
    ]
    public nonisolated func isPlaceNameSurnameSuspect(_ entity: Entity) -> Bool {
        guard entity.kind == .person else { return false }
        let tokens = entity.value.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2, let last = tokens.last else { return false }
        return Self.placeSurnames.contains(String(last).lowercased())
    }

    /// V3 3d — high-precision automated-sender tokens. WHOLE-TOKEN match only
    /// (never substring — "Botha" must not match "bot"); each token's edges are
    /// trimmed of punctuation but interior hyphens are kept ("no-reply").
    public nonisolated static let automatedSenderTokens: Set<String> = [
        "bot", "noreply", "no-reply", "donotreply", "do-not-reply",
        "mailer-daemon", "daemon", "postmaster", "notification", "notifications"
    ]
    /// True iff any whole token of the (lowercased) name is an automation marker.
    public nonisolated static func isAutomatedSender(_ lower: String) -> Bool {
        let edges = CharacterSet.alphanumerics.inverted
        for token in lower.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let clean = String(token).trimmingCharacters(in: edges)
            if automatedSenderTokens.contains(clean) { return true }
        }
        return false
    }

    /// "Nil", "Nil Nil", "nil, nil" — every alnum token is the literal "nil".
    public nonisolated static func isNilFamily(_ lower: String) -> Bool {
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0 == "nil" }
    }

    /// A common file-extension suffix — the string is a filename, not a subject.
    public nonisolated static let fileExtensions: Set<String> = [
        "pdf", "eml", "msg", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "csv", "txt", "png", "jpg", "jpeg", "gif", "zip", "rar", "html", "htm"
    ]
    public nonisolated static func isFilenameShaped(_ lower: String) -> Bool {
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return false }
        let ext = String(lower[lower.index(after: dot)...])
        return fileExtensions.contains(ext)
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
        var kept: [Entity] = []
        var byClass: [String: Int] = [:]
        for e in entities {
            if let reason = classify(e) { byClass[reason, default: 0] += 1 } else { kept.append(e) }
        }
        if !byClass.isEmpty {
            let breakdown = byClass.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            KalsmritikoshLog.brain.info("EntityQualityGate dropped \(entities.count - kept.count, privacy: .public) of \(entities.count, privacy: .public): \(breakdown, privacy: .public)")
        }
        return kept
    }

    /// Computed rejection counters (V3 3b, C-ii completeness-audit pattern): the
    /// by-class rejection tally over a set of entities — no stored table, so
    /// it's available "from day one" and never drifts from `classify`. Callers
    /// group by producer_version to key counters per era (V6 guard-silence).
    /// EXPECTATION (owner, logged beside "staleness lights to 716"): once the
    /// gate-then-fold reorder lands, the idle reconcile pass counts rejections
    /// against the EXISTING live 4,343's junk on every cycle — counters climbing
    /// pre-drain is the gate WORKING, a free preview of the inventory V5 retires.
    public nonisolated func rejectionAudit(_ entities: [Entity]) -> [String: Int] {
        var byClass: [String: Int] = [:]
        for e in entities {
            if let reason = classify(e) { byClass[reason, default: 0] += 1 }
        }
        return byClass
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
