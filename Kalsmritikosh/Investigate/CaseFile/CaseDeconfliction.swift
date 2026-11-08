//
//  CaseDeconfliction.swift
//  Kalsmritikosh
//
//  N1 — cross-case deconfliction (the Cellebrite Pathfinder / OCCRP Aleph "also seen in" check). For one
//  case: the people, organisations, phone numbers and email addresses its in-scope documents mention,
//  and for each, the OTHER cases on this Mac whose in-scope documents mention the same canonical entity
//  (name, stage, document count) and how many documents in the archive sit in no case at all.
//
//  COUNTS AND CASE NAMES ONLY. Nothing here returns a passage, a quote, a file name or any other text from
//  a document outside this case's scope — only the entity as this case's own documents name it, the other
//  case's title and stage, and document counts.
//
//  Scope semantics are the ONE case→version authority (`CaseRetrievalScopeResolver`): in-scope bindings
//  only, current version only, fail closed. A document belongs to a case when its file's CURRENT source
//  version is in that case's allow-set — the same object→version path `CaseScopedEntityResolver` and the
//  scoped retriever use. An erased case no longer exists (its rows are deleted), so it can never appear.
//  Entities are canonical: a mention of an entity merged into another counts for the winner; an entity a
//  person rejected is never listed. A "document" is one source file (a mailbox counts once).
//

import Foundation
import os

/// One other case that mentions the entity: its name, stage and how many of its in-scope documents do.
public nonisolated struct CaseOverlapCase: Sendable, Equatable, Identifiable, Hashable {
    public let caseID: UUID
    public let workspaceID: UUID
    public let title: String
    /// The stage as the caseload shows it, in lower case ("open", "in progress", "closed"…).
    public let status: String
    public let closed: Bool
    public let archived: Bool
    /// The case's in-scope documents that mention the entity.
    public let documents: Int
    public var id: UUID { caseID }

    /// "Case B (open, 3 documents)".
    public var phrase: String {
        let state = archived ? "\(status), archived" : status
        return "\(title) (\(state), \(documents) document\(documents == 1 ? "" : "s"))"
    }
}

/// One entity of this case that is also seen elsewhere.
public nonisolated struct CaseOverlapEntity: Sendable, Equatable, Identifiable, Hashable {
    public let entityID: UUID
    /// The entity kind's raw value ("person", "organization", "phoneNumber", "emailAddress").
    public let kind: String
    public let value: String
    /// This case's own in-scope documents that mention it.
    public let documentsInThisCase: Int
    /// Other cases whose in-scope documents mention it, most documents first.
    public let otherCases: [CaseOverlapCase]
    /// Documents in the archive that are in no case's scope and mention it (a count only).
    public let documentsInNoCase: Int
    public var id: UUID { entityID }

    public var isOnlyInThisCase: Bool { otherCases.isEmpty && documentsInNoCase == 0 }

    public var kindLabel: String { CaseDeconfliction.kindLabel(kind) }

    /// "Case B (open, 3 documents) · Case C (closed, 1 document) · 12 documents in no case".
    public var summary: String {
        var parts = otherCases.map(\.phrase)
        if documentsInNoCase > 0 { parts.append("\(documentsInNoCase) document\(documentsInNoCase == 1 ? "" : "s") in no case") }
        return parts.isEmpty ? "Only in this case" : parts.joined(separator: " · ")
    }
}

public nonisolated struct CaseDeconflictionReport: Sendable, Equatable {
    public let caseID: UUID
    /// Ranked: most other cases first, then most documents elsewhere.
    public let entities: [CaseOverlapEntity]
    /// How many of this case's entities are also seen elsewhere (before the cap).
    public let totalOverlapping: Int
    /// How many canonical entities of the checked kinds this case's documents mention.
    public let entitiesChecked: Int
    public let capped: Bool
    public static func empty(_ caseID: UUID) -> CaseDeconflictionReport {
        CaseDeconflictionReport(caseID: caseID, entities: [], totalOverlapping: 0, entitiesChecked: 0, capped: false)
    }
}

/// A canonical entity this case's in-scope documents mention (a link target for a case person).
public nonisolated struct CaseEntityCandidate: Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let kind: String
    public let value: String
    public var kindLabel: String { CaseDeconfliction.kindLabel(kind) }
}

/// The case's scope and every other case's, read once; reused while the case file is open.
public nonisolated struct CaseDeconflictionContext: Sendable {
    public let caseID: UUID
    /// This case's authorised source versions.
    let scope: Set<UUID>
    /// Source version → the cases (this one included) that authorise it.
    let versionCases: [UUID: Set<UUID>]
    /// Every other case that exists (erased cases do not).
    let cases: [UUID: CaseInfo]
    /// Canonical entities of the checked kinds this case's documents mention → how many of its documents do.
    public let inScope: [UUID: CaseEntityCandidate]
    let inScopeDocuments: [UUID: Int]

    struct CaseInfo: Sendable {
        let workspaceID: UUID
        let title: String
        let status: String
        let closed: Bool
        let archived: Bool
    }
}

public actor CaseDeconfliction {
    private let database: Database
    private let cases: InvestigationCaseRepository

    /// The kinds checked: who and how to reach them.
    public nonisolated static let kinds: [String] = ["person", "organization", "phoneNumber", "emailAddress"]

    public init(database: Database) {
        self.database = database
        self.cases = InvestigationCaseRepository(database: database)
    }

    public nonisolated static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "person": return "Person"
        case "organization": return "Organisation"
        case "phoneNumber": return "Phone"
        case "emailAddress": return "Email"
        default: return kind
        }
    }

    // MARK: - Context

    /// Read every case's scope and this case's entities. A case that cannot be read contributes nothing.
    public func prepare(caseID: UUID) async throws -> CaseDeconflictionContext {
        let profiles = Dictionary(try await CaseFileRepository(database: database).allProfiles().map { ($0.caseID, $0) },
                                  uniquingKeysWith: { a, _ in a })
        var versionCases: [UUID: Set<UUID>] = [:]
        var infos: [UUID: CaseDeconflictionContext.CaseInfo] = [:]
        var scope = Set<UUID>()
        let db = database
        let resolver = await MainActor.run { CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db)) }
        let ids = try await database.query("SELECT id FROM investigation_cases ORDER BY created_at, id;", []).compactMap { $0.uuid(0) }
        for id in ids {
            guard let record = try await cases.fetch(caseID: id) else { continue }
            let versions = Set(try await resolver.scope(for: record).authorizedSourceVersionIDs)
            for v in versions { versionCases[v, default: []].insert(id) }
            if id == caseID { scope = versions; continue }
            let header = record.caseHeader
            let profile = profiles[id]
            let closed = header.status == .closed
            let stage: CaseStage = closed ? .closed : (profile?.stage ?? .open)
            infos[id] = .init(workspaceID: header.workspaceID, title: header.title, status: stage.label.lowercased(),
                              closed: closed || stage == .closed, archived: profile?.archivedAt != nil)
        }
        // This case's canonical entities, with how many of its documents mention each.
        var raw: [UUID: Set<UUID>] = [:]   // mentioned entity id → files
        let marks = Self.kinds.map { _ in "?" }.joined(separator: ",")
        for chunk in Self.chunks(Array(scope)) {
            let rows = try await database.query("""
                SELECT m.entity_id, ko.file_id
                FROM entity_mentions m
                JOIN entities e ON e.id = m.entity_id
                JOIN knowledge_objects ko ON ko.id = m.source_object_id
                JOIN source_versions sv ON sv.logical_source_id = ko.file_id AND sv.is_current = 1
                WHERE sv.id IN (\(chunk.map { _ in "?" }.joined(separator: ","))) AND e.kind IN (\(marks));
                """, chunk.map { SQLValue.uuid($0) } + Self.kinds.map { SQLValue.text($0) })
            for r in rows { if let e = r.uuid(0), let f = r.uuid(1) { raw[e, default: []].insert(f) } }
        }
        let canonical = try await canonicalize(Set(raw.keys))
        var files: [UUID: Set<UUID>] = [:]
        for (mentioned, fs) in raw { if let c = canonical[mentioned] { files[c, default: []].formUnion(fs) } }
        let described = try await describe(Set(files.keys))
        var inScope: [UUID: CaseEntityCandidate] = [:]
        var docs: [UUID: Int] = [:]
        for (id, fs) in files {
            guard let d = described[id], d.rejected == false, Self.kinds.contains(d.kind) else { continue }
            inScope[id] = CaseEntityCandidate(id: id, kind: d.kind, value: d.value)
            docs[id] = fs.count
        }
        return CaseDeconflictionContext(caseID: caseID, scope: scope, versionCases: versionCases, cases: infos,
                                        inScope: inScope, inScopeDocuments: docs)
    }

    // MARK: - Report

    /// This case's entities also seen in another case or in documents in no case, ranked, capped at `limit`.
    public func report(caseID: UUID, limit: Int = 200) async throws -> CaseDeconflictionReport {
        try await report(try await prepare(caseID: caseID), limit: limit)
    }

    public func report(_ ctx: CaseDeconflictionContext, limit: Int = 200) async throws -> CaseDeconflictionReport {
        guard !ctx.inScope.isEmpty else { return .empty(ctx.caseID) }
        let all = try await overlaps(ctx, entityIDs: Set(ctx.inScope.keys)).values.filter { !$0.isOnlyInThisCase }
        let ranked = all.sorted { a, b in
            if a.otherCases.count != b.otherCases.count { return a.otherCases.count > b.otherCases.count }
            let elsewhereA = a.otherCases.reduce(a.documentsInNoCase) { $0 + $1.documents }
            let elsewhereB = b.otherCases.reduce(b.documentsInNoCase) { $0 + $1.documents }
            if elsewhereA != elsewhereB { return elsewhereA > elsewhereB }
            return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
        }
        let cap = max(0, limit)
        return CaseDeconflictionReport(caseID: ctx.caseID, entities: Array(ranked.prefix(cap)), totalOverlapping: ranked.count,
                                       entitiesChecked: ctx.inScope.count, capped: ranked.count > cap)
    }

    /// The overlap of specific canonical entities of this case (a linked case person, a subject). An id that
    /// was merged into another resolves to the winner; an entity the case's documents do not mention, or one
    /// a person rejected, is left out. Entities seen only in this case are included (`isOnlyInThisCase`).
    public func overlaps(_ ctx: CaseDeconflictionContext, entityIDs: Set<UUID>) async throws -> [UUID: CaseOverlapEntity] {
        guard !entityIDs.isEmpty else { return [:] }
        let canonical = try await canonicalize(entityIDs)
        let wanted = Set(canonical.values).filter { ctx.inScope[$0] != nil }
        guard !wanted.isEmpty else { return [:] }
        let members = try await members(of: wanted)          // entity id → its canonical (itself included)
        var filesByEntity: [UUID: [UUID: UUID?]] = [:]       // canonical → file → current version
        for chunk in Self.chunks(Array(members.keys)) {
            let rows = try await database.query("""
                SELECT m.entity_id, ko.file_id, sv.id
                FROM entity_mentions m
                JOIN knowledge_objects ko ON ko.id = m.source_object_id
                LEFT JOIN source_versions sv ON sv.logical_source_id = ko.file_id AND sv.is_current = 1
                WHERE m.entity_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));
                """, chunk.map { SQLValue.uuid($0) })
            for r in rows {
                guard let e = r.uuid(0), let c = members[e], let f = r.uuid(1) else { continue }
                let v = r.uuid(2)
                if filesByEntity[c]?[f] == nil || v != nil { filesByEntity[c, default: [:]][f] = v }
            }
        }
        // S7 (HISTORY-07): a document labelled privileged or restricted is not counted in another case or in "no case" — the
        // counts never reveal material this case may not read (and they never say how much was left out).
        let elsewhere = Set(filesByEntity.values.flatMap { $0.values.compactMap { $0 } })
        let countable = try await CaseCrossCaseAccess.permitted(elsewhere, database: database)
        var out: [UUID: CaseOverlapEntity] = [:]
        for (asked, c) in canonical where wanted.contains(c) {
            guard let candidate = ctx.inScope[c] else { continue }
            var perCase: [UUID: Int] = [:]
            var inNoCase = 0
            for (_, version) in filesByEntity[c] ?? [:] {
                if let v = version, !countable.contains(v), !ctx.scope.contains(v) { continue }
                let owners = version.flatMap { ctx.versionCases[$0] } ?? []
                if owners.isEmpty { inNoCase += 1; continue }
                for o in owners where o != ctx.caseID && ctx.cases[o] != nil { perCase[o, default: 0] += 1 }
            }
            let others = perCase.compactMap { id, n -> CaseOverlapCase? in
                guard let info = ctx.cases[id] else { return nil }
                return CaseOverlapCase(caseID: id, workspaceID: info.workspaceID, title: info.title, status: info.status,
                                       closed: info.closed, archived: info.archived, documents: n)
            }.sorted { ($0.documents, $1.title) > ($1.documents, $0.title) }
            let entity = CaseOverlapEntity(entityID: c, kind: candidate.kind, value: candidate.value,
                                           documentsInThisCase: ctx.inScopeDocuments[c] ?? 0, otherCases: others, documentsInNoCase: inNoCase)
            out[c] = entity
            if asked != c { out[asked] = entity }
        }
        return out
    }

    // MARK: - Linking a case person to an entity

    /// The in-scope canonical entities a case person EXACTLY matches: the name against a person's or
    /// organisation's value, normalised form or alias (case-insensitive); a given contact against an email
    /// address, or a phone number digit for digit. Never a partial or fuzzy match.
    public func matches(_ ctx: CaseDeconflictionContext, name: String, contact: String?) async throws -> (byName: [CaseEntityCandidate], byContact: [CaseEntityCandidate]) {
        let byName = try await exactMatches(ctx, text: name, kinds: ["person", "organization"])
        var byContact: [CaseEntityCandidate] = []
        if let contact = contact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty {
            byContact = try await exactMatches(ctx, text: contact, kinds: ["emailAddress"])
            let digits = contact.filter(\.isNumber)
            if digits.count >= 6 {
                byContact += ctx.inScope.values.filter { $0.kind == "phoneNumber" && $0.value.filter(\.isNumber) == digits }
            }
        }
        let sort: (CaseEntityCandidate, CaseEntityCandidate) -> Bool = { ($0.value, $0.id.uuidString) < ($1.value, $1.id.uuidString) }
        return (Array(Set(byName)).sorted(by: sort), Array(Set(byContact)).sorted(by: sort))
    }

    /// The entity to store when a person is added: the name's ONE exact match; with no name match, the
    /// contact's one exact match; nil when nothing matches or several do (the person then chooses).
    public nonisolated static func autoLink(byName: [CaseEntityCandidate], byContact: [CaseEntityCandidate]) -> UUID? {
        if byName.count == 1 { return byName[0].id }
        if byName.isEmpty, byContact.count == 1 { return byContact[0].id }
        return nil
    }

    /// `matches` then `autoLink`: the entity a newly added case person is stored with, or nil.
    public func autoLinkEntity(_ ctx: CaseDeconflictionContext, name: String, contact: String?) async throws -> UUID? {
        let m = try await matches(ctx, name: name, contact: contact)
        return Self.autoLink(byName: m.byName, byContact: m.byContact)
    }

    /// Every candidate a person could be linked to (name matches first).
    public nonisolated static func choices(byName: [CaseEntityCandidate], byContact: [CaseEntityCandidate]) -> [CaseEntityCandidate] {
        var seen = Set<UUID>()
        return (byName + byContact).filter { seen.insert($0.id).inserted }
    }

    private func exactMatches(_ ctx: CaseDeconflictionContext, text: String, kinds: [String]) async throws -> [CaseEntityCandidate] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        let collapsed = key.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let rows = try await database.query("""
            SELECT id FROM entities WHERE lower(value) = ? OR lower(value) = ? OR lower(normalized) = ? OR lower(normalized) = ?
            UNION SELECT entity_id FROM entity_aliases WHERE lower(alias_normalized) = ? OR lower(alias_normalized) = ?;
            """, [.text(key), .text(collapsed), .text(key), .text(collapsed), .text(key), .text(collapsed)])
        let ids = Set(rows.compactMap { $0.uuid(0) })
        let canonical = try await canonicalize(ids)
        return Set(canonical.values).compactMap { ctx.inScope[$0] }.filter { kinds.contains($0.kind) }
    }

    // MARK: - Canonical entities

    /// Follow each id's `merged_into` chain to its canonical id (depth-capped, cycle-safe). Unknown ids are dropped.
    private func canonicalize(_ ids: Set<UUID>) async throws -> [UUID: UUID] {
        var parent: [UUID: UUID?] = [:]
        var frontier = ids
        for _ in 0..<16 where !frontier.isEmpty {
            var next = Set<UUID>()
            for chunk in Self.chunks(Array(frontier)) {
                let rows = try await database.query("SELECT id, merged_into FROM entities WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                                                    chunk.map { SQLValue.uuid($0) })
                for r in rows {
                    guard let id = r.uuid(0) else { continue }
                    let up = r.uuid(1)
                    parent[id] = up
                    if let up, parent[up] == nil { next.insert(up) }
                }
            }
            frontier = next
        }
        var out: [UUID: UUID] = [:]
        for id in ids where parent[id] != nil {
            var current = id
            var seen: Set<UUID> = [id]
            while let up = parent[current] ?? nil, parent[up] != nil, seen.insert(up).inserted { current = up }
            out[id] = current
        }
        return out
    }

    /// The canonical ids plus every entity merged into them (transitively) → their canonical.
    private func members(of canonicals: Set<UUID>) async throws -> [UUID: UUID] {
        var out: [UUID: UUID] = Dictionary(uniqueKeysWithValues: canonicals.map { ($0, $0) })
        var frontier = canonicals
        for _ in 0..<16 where !frontier.isEmpty {
            var next = Set<UUID>()
            for chunk in Self.chunks(Array(frontier)) {
                let rows = try await database.query("SELECT id, merged_into FROM entities WHERE merged_into IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                                                    chunk.map { SQLValue.uuid($0) })
                for r in rows {
                    guard let id = r.uuid(0), let up = r.uuid(1), let root = out[up], out[id] == nil else { continue }
                    out[id] = root; next.insert(id)
                }
            }
            frontier = next
        }
        return out
    }

    private func describe(_ ids: Set<UUID>) async throws -> [UUID: (kind: String, value: String, rejected: Bool)] {
        var out: [UUID: (kind: String, value: String, rejected: Bool)] = [:]
        for chunk in Self.chunks(Array(ids)) {
            let rows = try await database.query("SELECT id, kind, value, review_status FROM entities WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                                                chunk.map { SQLValue.uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let kind = r.string(1), let value = r.string(2) else { continue }
                out[id] = (kind, value, !r.isNull(3))   // review_status IS NULL is the live entity, as everywhere else
            }
        }
        return out
    }

    nonisolated static func chunks(_ ids: [UUID], size: Int = 400) -> [[UUID]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }
}
