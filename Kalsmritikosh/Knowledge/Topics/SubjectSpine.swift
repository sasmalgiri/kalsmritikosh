//
//  SubjectSpine.swift
//  Kalsmritikosh
//
//  The missing trunk of the "upside-down tree". Leaves (facts, events) were
//  meant to roll up into topics and topics into real-world SUBJECTS, but the
//  owner's real ledger (2026-09-25 audit) showed the trunk was never grown:
//
//    • identifier anchors were ISLANDS — "Application No. 202331019665" is
//      written in the text of 31 documents, yet its anchor had 0 mentions and
//      1 bound fact, because an anchor is only bound when a document states it
//      as a labelled field;
//    • one patent lived under FOUR anchors — the application number and the
//      patent number filed under two field names, the grant number, and a
//      report's truncated "Application-2023310" — with nothing joining them;
//    • so every fact kept its FILE name as its subject ("Sent", "Resume-4c21…"),
//      and one patent became ~15 per-file topics.
//
//  This grows the trunk, deterministically and without a model:
//
//    1. REACH — find every document whose text (or file name) names each
//       anchor's value as a whole token, and record it as an anchor mention.
//    2. FAMILY — join anchors that denote one subject: the same value under
//       two subject-grade fields; two subject-grade anchors written in the
//       same chunk (the grant letter names both numbers); a truncated copy
//       that is a strict prefix of exactly one longer sibling.
//    3. RESOLUTION — give each document the ONE subject family it is about
//       (the family it names most; a tie is left unresolved, never guessed).
//
//  Derived and rebuildable: mention rows carry a deterministic id, so a rerun
//  writes nothing new; no fact, anchor or document is changed or deleted.
//

import CryptoKit
import Foundation
import os

public struct SubjectSpine: Sendable {
    private let database: Database
    private static let log = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Types

    public struct Anchor: Sendable, Hashable {
        public let id: UUID
        public let field: String
        public let canon: String
        public let value: String
        public let sourceObjectID: UUID
        public init(id: UUID, field: String, canon: String, value: String, sourceObjectID: UUID) {
            self.id = id; self.field = field; self.canon = canon
            self.value = value; self.sourceObjectID = sourceObjectID
        }
    }

    /// One document naming one anchor: how many of its chunks carry the value.
    public struct Reach: Sendable, Hashable {
        public let anchorID: UUID
        public let objectID: UUID
        public let hits: Int
    }

    /// The resolved trunk: anchor → family root, family → display label,
    /// document → the one family it is about.
    public struct Resolution: Sendable {
        public var familyOf: [UUID: UUID] = [:]
        public var label: [UUID: String] = [:]
        public var subjectOfObject: [UUID: UUID] = [:]
        public var objectsOfFamily: [UUID: Set<UUID>] = [:]
        /// Subject-grade anchor values (≥ 6 chars) → their family, for labels
        /// that name a matter ("…Patent Application-202331019665").
        public var canonFamily: [(canon: String, root: UUID)] = []

        /// The subject label a fact should be grouped under, or nil to keep its
        /// own. In order: the fact's own anchor; a label that names exactly one
        /// matter's number (an email's Subject line); the one matter its
        /// document is about.
        public func subjectLabel(anchorID: UUID?, currentLabel: String = "", objectIDs: [UUID]) -> String? {
            if let a = anchorID, let root = familyOf[a], let l = label[root] { return l }
            if !currentLabel.isEmpty {
                let named = Set(canonFamily.filter { SubjectSpine.containsToken($0.canon, in: currentLabel) }.map(\.root))
                if named.count == 1, let root = named.first, let l = label[root] { return l }
            }
            let roots = Set(objectIDs.compactMap { subjectOfObject[$0] })
            guard roots.count == 1, let root = roots.first else { return nil }
            return label[root]
        }
    }

    public struct Receipt: Sendable {
        public var anchors = 0
        public var reachedDocuments = 0
        public var mentionsWritten = 0
        public var families = 0
        public var resolvedDocuments = 0
    }

    // MARK: - Pure core (unit-tested)

    /// Fields that name a SUBJECT a history can be about — a matter, not an
    /// attribute. Bank accounts, tax ids and personal ids appear on letterheads
    /// and receipts across unrelated matters; joining on them is how the topic
    /// tree collapsed 332 of 340 members under one account number.
    nonisolated static let subjectGradeFields: Set<String> = [
        "patentnumber", "applicationnumber", "casenumber",
        "contractnumber", "registrationnumber",
    ]

    /// Fields that are one identity under two names (an Indian patent keeps its
    /// application number as the patent number until grant).
    nonisolated static let sameIdentityFields: [Set<String>] = [
        ["patentnumber", "applicationnumber"],
    ]

    /// A whole-token occurrence of `canon` in `text`: not preceded or followed by
    /// a letter or digit, so "2023310" never matches inside "202331019665".
    nonisolated static func containsToken(_ canon: String, in text: String) -> Bool {
        guard !canon.isEmpty else { return false }
        let hay = text.lowercased()
        var searchStart = hay.startIndex
        while let r = hay.range(of: canon, range: searchStart..<hay.endIndex) {
            let beforeOK = r.lowerBound == hay.startIndex
                || !isAlnum(hay[hay.index(before: r.lowerBound)])
            let afterOK = r.upperBound == hay.endIndex || !isAlnum(hay[r.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = hay.index(after: r.lowerBound)
        }
        return false
    }

    nonisolated private static func isAlnum(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// The text with quoted "Subject: …" spans removed (up to the next
    /// From/To/Cc/Date/Sent header or the line end). A report that LISTS
    /// messages names every matter those messages were about; on the owner's
    /// archive the GDPR and investigation reports named the patent only inside
    /// such listings, and resolving them to it filed "Average sentiment" and
    /// "Credit card pattern" under the patent. Mentions still count every hit;
    /// only the question "what is this document ABOUT" ignores listings.
    ///
    /// Also removed: a reply/forward-prefixed subject quoted inline — the same
    /// reports wrote "Credit Card Pattern in Plain Body of 'RE: [Our Ref…]
    /// Hearing Notice of Patent Application-202331019665'", naming an EMAIL
    /// about the patent, not being about it.
    nonisolated static func withoutQuotedSubjects(_ text: String) -> String {
        var out = text
        let patterns = [
            #"subject\s*:[^\n]*?(?=\s(?:from|to|cc|date|sent)\s*:|\n|$)"#,
            #"\b(?:re|fwd?|fw)\s*:\s*[^'"“”‘’\n]{0,240}"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        return out
    }

    /// Union anchors into subject families. `coChunk` lists, per chunk, the
    /// anchors it names. Deterministic: edges applied in sorted order and the
    /// root is the lexicographically smallest id.
    nonisolated static func families(anchors: [Anchor], coChunk: [Set<UUID>]) -> [UUID: UUID] {
        var parent: [UUID: UUID] = [:]
        for a in anchors { parent[a.id] = a.id }
        func find(_ x: UUID) -> UUID {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra.uuidString < rb.uuidString { parent[rb] = ra } else { parent[ra] = rb }
        }
        let byID = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })
        let sorted = anchors.sorted { $0.id.uuidString < $1.id.uuidString }
        let grade = sorted.filter { subjectGradeFields.contains($0.field) }

        for i in 0..<grade.count {
            for j in (i + 1)..<grade.count {
                let a = grade[i], b = grade[j]
                // R1 — one value under two names of the same identity.
                let identityPair = a.field == b.field
                    || sameIdentityFields.contains { set in set.contains(a.field) && set.contains(b.field) }
                if a.canon == b.canon && identityPair { union(a.id, b.id) }
            }
        }
        // R2 — two subject-grade anchors written in one chunk. Chunks naming
        // more than 3 distinct subject anchors are lists (a report's table of
        // matters), not a statement that they are one subject.
        for set in coChunk.map({ $0.filter { byID[$0].map { subjectGradeFields.contains($0.field) } ?? false } })
            where set.count >= 2 && set.count <= 3 {
            let ids = set.sorted { $0.uuidString < $1.uuidString }
            for k in 1..<ids.count { union(ids[0], ids[k]) }
        }
        // R3 — a truncated copy: a strict prefix (≥ 6 chars) of exactly ONE
        // longer anchor in the same identity family.
        func sameIdentity(_ x: Anchor, _ y: Anchor) -> Bool {
            x.field == y.field
                || sameIdentityFields.contains { set in set.contains(x.field) && set.contains(y.field) }
        }
        for a in grade where a.canon.count >= 6 {
            let longer = grade.filter { other in
                other.id != a.id && other.canon.count > a.canon.count
                    && other.canon.hasPrefix(a.canon) && sameIdentity(a, other)
            }
            let distinctCanons = Set(longer.map(\.canon))
            if distinctCanons.count == 1, let target = longer.first { union(a.id, target.id) }
        }
        var out: [UUID: UUID] = [:]
        for a in anchors { out[a.id] = find(a.id) }
        return out
    }

    /// The document → family assignment: the subject-grade family the document
    /// names in the most chunks. A tie is left unresolved (never guessed).
    nonisolated static func resolveObjects(
        reach: [Reach], familyOf: [UUID: UUID], anchors: [UUID: Anchor]
    ) -> [UUID: UUID] {
        var score: [UUID: [UUID: Int]] = [:]   // object → family → hits
        for r in reach {
            guard let a = anchors[r.anchorID], subjectGradeFields.contains(a.field),
                  let root = familyOf[r.anchorID] else { continue }
            score[r.objectID, default: [:]][root, default: 0] += r.hits
        }
        var out: [UUID: UUID] = [:]
        for (object, fams) in score {
            let ranked = fams.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
            guard let top = ranked.first else { continue }
            if ranked.count > 1, ranked[1].value == top.value { continue }
            out[object] = top.key
        }
        return out
    }

    /// "Patent No. 555489 (Application 202331019665)" — patent number first,
    /// then the rest; truncated prefixes are omitted from the label.
    nonisolated static func label(for members: [Anchor]) -> String {
        let canons = Set(members.map(\.canon))
        let kept = members.filter { m in !canons.contains { $0 != m.canon && $0.hasPrefix(m.canon) } }
        let order = ["patentnumber", "applicationnumber", "casenumber", "contractnumber", "registrationnumber"]
        func rank(_ field: String) -> Int { order.firstIndex(of: field) ?? order.count }
        // One entry per VALUE. A value also filed as an application number IS
        // the application (it was reused as the patent number before grant),
        // so it renders as "Application", and the granted number leads.
        var fieldOf: [String: String] = [:]
        for m in kept {
            if let cur = fieldOf[m.canon] {
                if m.field == "applicationnumber" || (cur != "applicationnumber" && rank(m.field) < rank(cur)) {
                    fieldOf[m.canon] = m.field
                }
            } else {
                fieldOf[m.canon] = m.field
            }
        }
        let rendered = fieldOf
            .sorted { l, r in rank(l.value) != rank(r.value) ? rank(l.value) < rank(r.value) : l.key < r.key }
            .map { canon, field in "\(SubjectResolver.anchorLabels[field] ?? field) \(canon)" }
        guard let head = rendered.first else { return members.first?.value ?? "" }
        let tail = rendered.dropFirst()
        return tail.isEmpty ? head : "\(head) (\(tail.joined(separator: "; ")))"
    }

    /// Deterministic mention id: the same anchor in the same document always
    /// maps to the same row, so reruns are no-ops.
    nonisolated static func mentionID(anchorID: UUID, objectID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("anchor-reach|\(anchorID.uuidString)|\(objectID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50     // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80     // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Ledger runner

    /// Evidence block → the KnowledgeObject(s) that own it, so a fact (which
    /// cites blocks) can be placed in the document it was read from.
    public func blockOwners() async throws -> [UUID: [UUID]] {
        let rows = try await database.query(
            "SELECT evidence_block_id, knowledge_object_id FROM evidence_block_objects;", [])
        var out: [UUID: [UUID]] = [:]
        for r in rows {
            guard let b = r.uuid(0), let k = r.uuid(1) else { continue }
            out[b, default: []].append(k)
        }
        return out
    }

    /// Grow the trunk over the current ledger and return the resolution the
    /// topic and history builders group by.
    public func run() async throws -> (Resolution, Receipt) {
        var receipt = Receipt()
        let anchorRows = try await database.query("""
        SELECT id, value, normalized, source_object_id FROM entities
        WHERE kind = 'identifierAnchor' AND merged_into IS NULL
          AND COALESCE(review_status, '') <> 'retired';
        """, [])
        var anchors: [Anchor] = []
        for r in anchorRows {
            guard let id = r.uuid(0), let value = r.string(1), let key = r.string(2),
                  let source = r.uuid(3) else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            anchors.append(Anchor(id: id, field: parts[0], canon: parts[1].lowercased(),
                                  value: value, sourceObjectID: source))
        }
        receipt.anchors = anchors.count
        guard !anchors.isEmpty else { return (Resolution(), receipt) }
        let anchorByID = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })

        // 1 — REACH. The SQL LIKE is a cheap superset; the whole-token check
        //     in Swift is the truth.
        var named: [UUID: Set<UUID>] = [:]         // anchor → objects naming it anywhere
        var about: [UUID: [UUID: Int]] = [:]       // anchor → object → hits that say what it is ABOUT
        var chunkAnchors: [UUID: Set<UUID>] = [:]  // chunk → anchors named
        for a in anchors {
            let rows = try await database.query("""
            SELECT id, object_id, text FROM chunks WHERE instr(lower(text), ?) > 0;
            """, [.text(a.canon)])
            for row in rows {
                guard let cid = row.uuid(0), let oid = row.uuid(1), let text = row.string(2),
                      Self.containsToken(a.canon, in: text) else { continue }
                named[a.id, default: []].insert(oid)
                chunkAnchors[cid, default: []].insert(a.id)
                if Self.containsToken(a.canon, in: Self.withoutQuotedSubjects(text)) {
                    about[a.id, default: [:]][oid, default: 0] += 1
                }
            }
            // A file NAMED for the matter ("Hearing Notice_202331019665.pdf"),
            // or an email thread whose own Subject names it.
            let titled = try await database.query("""
            SELECT k.id, f.url, COALESCE(json_extract(k.metadata_json, '$.threadSubject'), '')
            FROM knowledge_objects k JOIN files f ON f.id = k.file_id
            WHERE instr(lower(f.url), ?) > 0
               OR instr(lower(COALESCE(json_extract(k.metadata_json, '$.threadSubject'), '')), ?) > 0;
            """, [.text(a.canon), .text(a.canon)])
            for row in titled {
                guard let oid = row.uuid(0), let url = row.string(1) else { continue }
                let title = (url.removingPercentEncoding ?? url) + " " + (row.string(2) ?? "")
                guard Self.containsToken(a.canon, in: title) else { continue }
                named[a.id, default: []].insert(oid)
                about[a.id, default: [:]][oid, default: 0] += 2   // a title outweighs a passing mention
            }
            // The anchor's birth document NAMES it (a mention), but is only
            // ABOUT it if the text above said so — the truncated
            // "Application-2023310" was born in a report that merely listed it.
            named[a.id, default: []].insert(a.sourceObjectID)
        }
        var reach: [Reach] = []
        for (aid, objs) in about {
            for (oid, n) in objs { reach.append(Reach(anchorID: aid, objectID: oid, hits: n)) }
        }
        receipt.reachedDocuments = Set(named.values.flatMap { $0 }).count

        // Record each reach as an anchor mention (derived; idempotent by id).
        var mentionRows: [[SQLValue]] = []
        for (aid, objects) in named.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let a = anchorByID[aid] else { continue }
            for oid in objects.sorted(by: { $0.uuidString < $1.uuidString }) {
                mentionRows.append([.uuid(Self.mentionID(anchorID: aid, objectID: oid)),
                                    .uuid(aid), .text(a.value), .text("\(a.field)|\(a.canon)"), .uuid(oid)])
            }
        }
        let finalMentionRows = mentionRows
        // F28 — all reach mentions in ONE isolated savepoint.
        receipt.mentionsWritten += try await database.withSavepoint("subject_spine") { db -> Int in
            var written = 0
            for binds in finalMentionRows {
                written += try db.query("""
                INSERT OR IGNORE INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
                VALUES (?, ?, 'identifierAnchor', ?, ?, ?, 0.9) RETURNING id;
                """, binds).count
            }
            return written
        }

        // 2 — FAMILY.  3 — RESOLUTION.
        var resolution = Resolution()
        resolution.familyOf = Self.families(anchors: anchors, coChunk: Array(chunkAnchors.values))
        var members: [UUID: [Anchor]] = [:]
        for a in anchors { members[resolution.familyOf[a.id] ?? a.id, default: []].append(a) }
        for (root, ms) in members { resolution.label[root] = Self.label(for: ms) }
        resolution.subjectOfObject = Self.resolveObjects(reach: reach, familyOf: resolution.familyOf, anchors: anchorByID)
        for (oid, root) in resolution.subjectOfObject { resolution.objectsOfFamily[root, default: []].insert(oid) }
        resolution.canonFamily = anchors
            .filter { Self.subjectGradeFields.contains($0.field) && $0.canon.count >= 6 }
            .sorted { $0.canon < $1.canon }
            .map { (canon: $0.canon, root: resolution.familyOf[$0.id] ?? $0.id) }
        receipt.families = members.count
        receipt.resolvedDocuments = resolution.subjectOfObject.count
        Self.log.info("SubjectSpine: \(receipt.anchors) anchors reach \(receipt.reachedDocuments) documents (\(receipt.mentionsWritten) new mentions) → \(receipt.families) families; \(receipt.resolvedDocuments) documents resolved to a subject")
        return (resolution, receipt)
    }
}
