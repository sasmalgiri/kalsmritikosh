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

        // L2 (universal shape typing) — a PHONE must be phone-shaped. NSDataDetector
        // types bare digit runs as phones; on the owner's ledger 1,765 of 1,817
        // "phone numbers" were IDs like "0000254722" and "434981693797". Kept in
        // the ledger (retired, reversible), never surfaced as a phone.
        if entity.kind == .phoneNumber, !Self.isPhoneShaped(surface) { return "not-phone-shaped" }

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
        // L2 — LAST, after every older class keeps its name: an ORGANISATION
        // name that is only a legal suffix ("Ltd", "Pvt") or has fewer than
        // three letters ("Ag", "X") is a fragment, not a party. Two-letter
        // all-caps acronyms ("EU", "MS") pass — they may be real. NO shape rule
        // beyond that: a first cut retired "DuPont" and "EtOAc" as gibberish,
        // which is the false-rejection the gate must never commit; a doubtful
        // mixed-case token stays live and low-tiered instead.
        if entity.kind == .organization || entity.kind == .vendor || entity.kind == .client {
            if Self.legalSuffixes.contains(lower.trimmingCharacters(in: .punctuationCharacters)) { return "bare-legal-suffix" }
            let letters = surface.filter(\.isLetter)
            let isShortAcronym = letters.count == 2 && surface == surface.uppercased()
            if letters.count < 3, !isShortAcronym { return "too-short-name" }
        }
        return nil
    }

    // MARK: - L2 shape rules (universal)

    public nonisolated static let legalSuffixes: Set<String> = [
        "ltd", "limited", "inc", "llc", "llp", "plc", "pvt", "private", "co", "corp",
        "corporation", "gmbh", "ag", "sa", "bv", "pty", "company",
    ]

    /// Phone-shaped: 7–15 digits, and either phone punctuation (a leading +,
    /// parentheses, dashes or grouping spaces) or a plain run a phone could be —
    /// never a zero-padded record number, never a bare run of 12+ digits with no
    /// grouping (an account or a tracking id), never one repeated digit.
    public nonisolated static func isPhoneShaped(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return false }
        let hasPunct = raw.contains("+") || raw.contains("(") || raw.contains("-") || raw.contains(" ")
        if !hasPunct {
            if digits.hasPrefix("00") { return false }            // "0000254722" — a padded id
            if digits.count >= 12 { return false }                // "434981693797" — no phone is written so
        }
        if Set(digits).count == 1 { return false }               // "0000000000"
        return true
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

    // MARK: - Retroactive retirement (was: purge)

    public struct PurgeReport: Sendable {
        /// Junk entities marked `review_status = 'rejected'`. NOT deleted.
        public let entitiesRetired: Int
        /// Memory rows marked `status = 'retired'`. NOT deleted.
        public let memoryObjectsRetired: Int
        public let totalEntitiesScanned: Int
        /// Entities that FAIL `shouldKeep` but were left live because the user
        /// had restored them by hand. Their judgement outranks the heuristic.
        public let skippedUserRestored: Int
    }

    /// Sweep existing canonical noun entities and RETIRE those that fail
    /// `shouldKeep` — the "Nil Nil" / filename / hostname ghosts.
    ///
    /// OWNER RULING 2026-09-25: THIS NO LONGER DELETES ANYTHING.
    ///
    /// It used to `DELETE FROM entities` (cascading away entity_mentions and
    /// entity_aliases) and `DELETE FROM memory_objects` for each one. Of the 47
    /// delete sites in the app it was the only one that destroyed extracted
    /// knowledge rather than replacing a derived projection or rolling back a
    /// failed commit — so it was the one site in genuine tension with the
    /// preserve-everything directive.
    ///
    /// It now uses the soft-exclude mechanism this app already shipped for the
    /// same purpose (schema v49, whose own comment reads "Honoring the
    /// preserve-everything directive, a rejected entity is NOT deleted"):
    ///
    ///   • entities  → `review_status = 'rejected'`, the SAME value the
    ///     Knowledge browser's Reject button writes. Deliberately not a new
    ///     'retired' value: the ~23 existing read filters are a mix of
    ///     `IS NULL` and `!= 'rejected'`, so a novel value would slip past the
    ///     second kind and leave ghosts in answers. Retrieval already honours
    ///     'rejected' (HybridRetriever, LedgerQuery, the entity/chunk/event/
    ///     relationship repositories), so answers are unchanged.
    ///   • memory    → `MemoryRepository.retireSubjects`, because memory is
    ///     keyed by subject NAME, not entity id; retiring the entity alone
    ///     would not hide it.
    ///   • every action is logged append-only to `fact_reviews` with
    ///     `reviewer = "quality-gate"`, so it appears in the Audit trail,
    ///     is attributable to the machine rather than the user, and is
    ///     reversible from the existing Restore path.
    ///
    /// A USER'S RESTORE NOW WINS. Entities the user has accepted by hand are
    /// skipped, so the next drain cannot silently re-retire something they
    /// deliberately brought back. The old delete had no way to express that.
    ///
    /// Idempotent — already-rejected entities are not rescanned, so a second
    /// run neither re-logs reviews nor changes a row (the Fixed-Point Law).
    /// Pass `dryRun: true` to count without modifying.
    public func purgeGarbage(in database: Database, dryRun: Bool = false) async throws -> PurgeReport {
        // Skip rows already retired so the pass is idempotent, and let a user's
        // own rejection stand without a duplicate audit entry.
        let rows = try await database.query("""
        SELECT id, kind, value, normalized FROM entities
        WHERE kind IN ('person','organization','vendor','client','phoneNumber')
          AND (review_status IS NULL OR review_status != 'rejected');
        """)
        // Entities the user explicitly restored (an `accept` review by a human).
        // The heuristic must not overrule a person.
        var userRestored: Set<UUID> = []
        let restoredRows = try await database.query("""
        SELECT DISTINCT subject_id FROM fact_reviews
        WHERE subject_kind = 'entity' AND action = 'accept' AND reviewer = 'user';
        """)
        for row in restoredRows { if let id = row.uuid(0) { userRestored.insert(id) } }

        // The rejection REASON is captured here, against the entity's real kind,
        // so the audit row records why this specific entity was retired.
        var toRetire: [(id: UUID, value: String, normalized: String, reason: String)] = []
        var skipped = 0
        for row in rows {
            guard let id = row.uuid(0),
                  let kindStr = row.string(1),
                  let value = row.string(2),
                  let normalized = row.string(3),
                  let kind = Entity.Kind(rawValue: kindStr)
            else { continue }
            let entity = Entity(kind: kind, value: value, sourceObjectID: UUID())
            var reason = classify(entity)
            // P1.6 — a BARE digit run passes the shape test but is undecidable
            // by shape ("785718091" is a phone or a record id). Context decides:
            // it stays a phone only when a phone label introduces it somewhere
            // in the text it came from.
            if reason == nil, kind == .phoneNumber, Self.isBareDigitRun(value),
               try await !Self.anySourceLabelsPhone(entityID: id, value: value, in: database) {
                reason = "unlabelled-digit-run"
            }
            if let reason {
                if userRestored.contains(id) { skipped += 1; continue }
                toRetire.append((id, value, normalized, reason))
            }
        }
        guard !toRetire.isEmpty else {
            return PurgeReport(entitiesRetired: 0, memoryObjectsRetired: 0,
                               totalEntitiesScanned: rows.count,
                               skippedUserRestored: skipped)
        }
        if dryRun {
            return PurgeReport(
                entitiesRetired: toRetire.count,
                memoryObjectsRetired: 0,
                totalEntitiesScanned: rows.count,
                skippedUserRestored: skipped
            )
        }

        let memory = MemoryRepository(database: database)
        let reviews = FactReviewsRepository(database: database)
        try await database.beginTransaction()
        var memoryRetired = 0
        do {
            for entry in toRetire {
                // Memory first: keyed by subject NAME, so both the displayed
                // value and its normalized form have to be offered.
                memoryRetired += try await memory.retireSubjects(
                    identifiers: [entry.value, entry.normalized])
                // Soft-exclude the entity. Its mentions and aliases SURVIVE —
                // under the old delete they were cascaded away, which is what
                // made the operation unrecoverable.
                try await database.exec(
                    "UPDATE entities SET review_status = 'rejected' WHERE id = ?;",
                    [.uuid(entry.id)]
                )
                // Append-only audit record, attributable and reversible.
                let why = "Retired by the entity quality gate (\(entry.reason))"
                    + " — excluded from answers, not deleted"
                _ = try await reviews.record(FactReview(
                    subjectKind: .entity,
                    subjectID: entry.id,
                    action: .reject,
                    priorValue: entry.value,
                    reviewer: "quality-gate",
                    reason: why
                ))
            }
            try await database.commitTransaction()
        } catch {
            await database.rollbackTransaction()
            throw error
        }
        KalsmritikoshLog.brain.info("EntityQualityGate: RETIRED (not deleted) \(toRetire.count, privacy: .public) entities + \(memoryRetired, privacy: .public) memory rows; \(skipped, privacy: .public) left live because the user restored them")
        return PurgeReport(
            entitiesRetired: toRetire.count,
            memoryObjectsRetired: memoryRetired,
            totalEntitiesScanned: rows.count,
            skippedUserRestored: skipped
        )
    }

    // MARK: - P1.6 phone context

    /// Digits only (no +, space, dash or brackets) — the undecidable shape.
    public nonisolated static func isBareDigitRun(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy(\.isNumber)
    }

    nonisolated static let phoneLabel: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:^|[^a-z])(?:phone|ph|tel|telephone|mob|mobile|cell|cellphone|contact|fax|call|whatsapp|landline|helpline|m|t|p)\.?\s*(?:no\.?|number|num|#)?\s*[:=\-]?\s*(?:\+?\d[\d\s\-()]*[,/;]\s*)*$"#,
        options: [.caseInsensitive])

    /// True when some occurrence of `value` in `text` is introduced by a phone
    /// label ("Mob: 785718091", "Phone No. 98300…, 785718091").
    public nonisolated static func phoneLabelPrecedes(_ value: String, in text: String) -> Bool {
        guard let regex = phoneLabel, !value.isEmpty else { return false }
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let hit = ns.range(of: value, options: [], range: search)
            guard hit.location != NSNotFound else { return false }
            // Whole digit run only: "785718091" inside "1785718091" is not it.
            let before = hit.location > 0 ? ns.substring(with: NSRange(location: hit.location - 1, length: 1)) : " "
            let afterIdx = hit.location + hit.length
            let after = afterIdx < ns.length ? ns.substring(with: NSRange(location: afterIdx, length: 1)) : " "
            if !(before.first?.isNumber ?? false), !(after.first?.isNumber ?? false) {
                let start = max(0, hit.location - 40)
                let window = ns.substring(with: NSRange(location: start, length: hit.location - start))
                if regex.firstMatch(in: window, range: NSRange(location: 0, length: (window as NSString).length)) != nil {
                    return true
                }
            }
            let next = hit.location + max(hit.length, 1)
            guard next < ns.length else { return false }
            search = NSRange(location: next, length: ns.length - next)
        }
    }

    /// Any document the entity was mentioned in labels it as a phone.
    nonisolated static func anySourceLabelsPhone(entityID: UUID, value: String, in database: Database) async throws -> Bool {
        let rows = try await database.query("""
        SELECT ko.content FROM knowledge_objects ko
        WHERE ko.id IN (SELECT source_object_id FROM entities WHERE id = ?
                        UNION SELECT source_object_id FROM entity_mentions WHERE entity_id = ?);
        """, [.uuid(entityID), .uuid(entityID)])
        for r in rows {
            if let text = r.string(0), phoneLabelPrecedes(value, in: text) { return true }
        }
        return false
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
