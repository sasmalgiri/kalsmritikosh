//
//  CaseHistoryRepository.swift
//  Kalsmritikosh
//
//  Living case map, M7 (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md §6.4): recorded states of a
//  case map, and nothing invented.
//
//  • Baseline. Case history starts when this build was installed (v173 case_history_install) — or when the case
//    was created, if later. Before that, "full map state not recorded before <baseline>": existing action and
//    approval records stay, but no past map is reconstructed from them.
//  • Checkpoints. A checkpoint is the case map as the map service read it — every item and link with its
//    display text, review state and revision, the layout — with a manifest (the source versions, decisions and
//    record revisions it rests on), the scope fingerprint and a content digest. It is built from one load whose
//    revision fence was the same before and after, and written only if the fence inside the write is still that
//    fence (a validated revision fence): a checkpoint never mixes half of one state with half of the next. It is
//    never edited (the v173 trigger), lives in the encrypted ledger and goes with case erasure; a person erasure
//    clears the content of a checkpoint that names them and keeps a stub saying so.
//  • Reading history is read-only. A retained source version that is no longer in the ledger is shown as
//    unavailable — its quoted words are not shown and the current version is never substituted. A recorded state
//    whose content no longer matches its digest is refused.
//  • Event time and recorded time stay apart: an item carries when it was recorded and, separately, the date of
//    the event it describes. A past "what was known" view is the nearest recorded state at or before that time,
//    so evidence recorded later never appears in it, whatever date the event had.
//

import Foundation
import os

// MARK: - Recorded state

public nonisolated enum CaseCheckpointKind: String, Codable, Sendable, CaseIterable {
    /// Recorded when the map was opened and the case had changed since the last recorded state (at most daily).
    case automatic
    /// Recorded on request.
    case manual
    /// A named milestone ("Interviews done", "Draft to legal").
    case milestone
    public var label: String {
        switch self {
        case .automatic: return "Daily record"
        case .manual: return "Recorded on request"
        case .milestone: return "Milestone"
        }
    }
}

/// The case map as it was recorded: items, links, display text and layout. Codable, deterministic.
public nonisolated struct CaseCheckpointPayload: Codable, Equatable, Sendable {
    public static let format = 1

    public struct Source: Codable, Hashable, Sendable {
        public var sourceVersionID: UUID?, objectID: UUID?, blockID: UUID?, documentName: String?, quote: String?
    }
    public struct Assertion: Codable, Hashable, Sendable { public var kind: String, text: String }
    public struct Node: Codable, Hashable, Sendable {
        public var recordKind: String, recordID: String, revision: String?, kind: String, title: String, wording: String?
        public var statusKind: String, statusText: String, review: String, sources: [Source], author: Assertion?
        public var recordedAt: Date?, eventDate: Date?, history: [String], changedSourceWarning: String?, isDocumentary: Bool
        public var key: String { "\(recordKind):\(recordID)" }
    }
    public struct Origin: Codable, Hashable, Sendable { public var kind: String, recordID: String, revision: String? }
    public struct Link: Codable, Hashable, Sendable {
        public var id: String, fromKind: String, fromID: String, toKind: String, toID: String, type: String
        public var origins: [Origin], sources: [Source], assertedBy: Assertion, review: String, statusKind: String, statusText: String, basis: String
    }
    public struct Place: Codable, Hashable, Sendable { public var x: Double, y: Double, pinned: Bool }

    public var format: Int
    public var caseID: UUID
    public var title: String
    public var stage: String
    public var isClosed: Bool
    public var question: String?
    public var nodes: [Node]
    public var links: [Link]
    public var placements: [String: Place]
    public var danglingLinks: Int
    public var withdrawnLinks: Int

    static func assertion(_ a: CaseMapAssertion) -> Assertion {
        switch a {
        case .investigator(let t): return Assertion(kind: "investigator", text: t)
        case .rule(let t): return Assertion(kind: "rule", text: t)
        case .model(let t): return Assertion(kind: "model", text: t)
        }
    }
    static func assertion(_ a: Assertion) -> CaseMapAssertion {
        switch a.kind {
        case "rule": return .rule(a.text)
        case "model": return .model(a.text)
        default: return .investigator(a.text)
        }
    }
    static func source(_ s: CaseMapSourceRef) -> Source {
        Source(sourceVersionID: s.sourceVersionID, objectID: s.objectID, blockID: s.blockID, documentName: s.documentName, quote: s.quote)
    }

    /// The recorded form of a projection and its layout.
    public static func make(_ p: CaseMapProjection, placements: [CaseMapNodeID: CaseMapPlacement]) -> CaseCheckpointPayload {
        let nodes = p.nodes.map { n in
            Node(recordKind: n.id.kind.rawValue, recordID: n.id.recordID, revision: n.revision, kind: n.kind.rawValue, title: n.title, wording: n.wording,
                 statusKind: n.status.kind.rawValue, statusText: n.status.text, review: n.review.rawValue, sources: n.sources.map(source),
                 author: n.author.map(assertion), recordedAt: n.recordedAt, eventDate: n.eventDate, history: n.history,
                 changedSourceWarning: n.changedSourceWarning, isDocumentary: n.isDocumentary)
        }
        let links = p.links.map { l in
            Link(id: l.id, fromKind: l.from.kind.rawValue, fromID: l.from.recordID, toKind: l.to.kind.rawValue, toID: l.to.recordID, type: l.type.rawValue,
                 origins: l.origins.map { Origin(kind: $0.kind.rawValue, recordID: $0.recordID, revision: $0.revision) }, sources: l.sources.map(source),
                 assertedBy: assertion(l.assertedBy), review: l.review.rawValue, statusKind: l.status.kind.rawValue, statusText: l.status.text, basis: l.basis)
        }
        var places: [String: Place] = [:]
        for n in p.nodes { if let pl = placements[n.id] { places[n.id.key] = Place(x: pl.point.x, y: pl.point.y, pinned: pl.pinned) } }
        return CaseCheckpointPayload(format: format, caseID: p.caseID, title: p.title, stage: p.stage.rawValue, isClosed: p.isClosed, question: p.question,
                                     nodes: nodes, links: links, placements: places, danglingLinks: p.danglingLinks, withdrawnLinks: p.withdrawnLinks)
    }

    /// Every source version the recorded state refers to.
    public var sourceVersions: Set<UUID> {
        Set(nodes.flatMap(\.sources).compactMap(\.sourceVersionID) + links.flatMap(\.sources).compactMap(\.sourceVersionID))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    func encoded() throws -> String { String(decoding: try Self.encoder.encode(self), as: UTF8.self) }
    static func decode(_ json: String) throws -> CaseCheckpointPayload { try decoder.decode(CaseCheckpointPayload.self, from: Data(json.utf8)) }

    /// The recorded state as a read-only projection, with the layout. A source whose retained version is
    /// `unavailable` is shown as unavailable: no quoted words, no document to open, never the current version;
    /// an item resting only on such sources loses the document text it quoted.
    func rebuild(unavailable: Set<UUID>) -> (CaseMapProjection, [CaseMapNodeID: CaseMapPlacement]) {
        let c = caseID
        func id(_ kind: String, _ rid: String) -> CaseMapNodeID? {
            CaseMapRecordKind(rawValue: kind).map { CaseMapNodeID(caseID: c, kind: $0, recordID: rid) }
        }
        func src(_ s: Source) -> CaseMapSourceRef {
            if let v = s.sourceVersionID, unavailable.contains(v) {
                return CaseMapSourceRef(sourceVersionID: v, objectID: nil, blockID: nil, documentName: "Retained version no longer available", quote: nil)
            }
            return CaseMapSourceRef(sourceVersionID: s.sourceVersionID, objectID: s.objectID, blockID: s.blockID, documentName: s.documentName, quote: s.quote)
        }
        var nodes: [CaseMapNode] = []
        for n in self.nodes {
            guard let nid = id(n.recordKind, n.recordID) else { continue }
            let kind = CaseMapNodeKind(rawValue: n.kind) ?? .note
            let lost = n.sources.contains { $0.sourceVersionID.map(unavailable.contains) ?? false }
            let quotesDocument = [.contradiction, .evidence].contains(kind) && nid.kind != .exhibit
            nodes.append(CaseMapNode(id: nid, revision: n.revision, kind: kind, title: n.title,
                                     wording: lost && quotesDocument ? "Not shown: the source version this quoted is no longer available." : n.wording,
                                     status: CaseMapStatus(CaseMapStatus.Kind(rawValue: n.statusKind) ?? .recorded, n.statusText),
                                     review: CaseMapReviewState(rawValue: n.review) ?? .notApplicable, sources: n.sources.map(src),
                                     author: n.author.map(Self.assertion), recordedAt: n.recordedAt, eventDate: n.eventDate, history: n.history,
                                     changedSourceWarning: n.changedSourceWarning, isDocumentary: n.isDocumentary))
        }
        nodes.sort { $0.id < $1.id }
        var links: [CaseMapLink] = []
        for l in self.links {
            guard let from = id(l.fromKind, l.fromID), let to = id(l.toKind, l.toID), let type = CaseMapLinkType(rawValue: l.type) else { continue }
            links.append(CaseMapLink(id: l.id, caseID: c, from: from, to: to, type: type,
                                     origins: l.origins.compactMap { o in CaseMapRecordKind(rawValue: o.kind).map { CaseMapOrigin($0, o.recordID, revision: o.revision) } },
                                     sources: l.sources.map(src), assertedBy: Self.assertion(l.assertedBy),
                                     review: CaseMapReviewState(rawValue: l.review) ?? .notApplicable,
                                     status: CaseMapStatus(CaseMapStatus.Kind(rawValue: l.statusKind) ?? .recorded, l.statusText), basis: l.basis))
        }
        links.sort { $0.id < $1.id }
        var parts: [CaseMapPart: CaseMapPartState] = [:]
        for p in CaseMapPart.allCases { parts[p] = .loaded }
        let projection = CaseMapProjection(caseID: c, title: title, stage: CaseStage(rawValue: stage) ?? .open, isClosed: isClosed, question: question,
                                           nodes: nodes, links: links, groups: CaseMapProjector.groups(nodes, links), parts: parts,
                                           danglingLinks: danglingLinks, withdrawnLinks: withdrawnLinks)
        var places: [CaseMapNodeID: CaseMapPlacement] = [:]
        for n in nodes { if let p = placements[n.id.key] { places[n.id] = CaseMapPlacement(point: CaseMapPoint(x: p.x, y: p.y), pinned: p.pinned) } }
        return (projection, places)
    }
}

/// What a recorded state rests on (kept beside it; references, not copies).
public nonisolated struct CaseCheckpointManifest: Codable, Equatable, Sendable {
    public var format: Int
    public var caseID: UUID
    public var fence: String
    public var scopeFingerprint: String
    /// The retained source versions it cites.
    public var sourceVersions: [UUID]
    /// Items with a recorded decision, as "kind:id@revision".
    public var decisions: [String]
    /// Every item's record revision ("kind:id" → revision).
    public var revisions: [String: String]
    public var links: [String]
    public var layoutDigest: String
    public var nodeCount: Int
    public var linkCount: Int
    public var baseline: Date

    static func make(_ payload: CaseCheckpointPayload, fence: String, scope: String, baseline: Date) throws -> CaseCheckpointManifest {
        let decided: Set<String> = ["confirmed", "dismissed", "accepted", "rejected", "completed", "deferred", "withdrawn"]
        let layout = try CaseCheckpointPayload.encoder.encode(payload.placements)
        var revisions: [String: String] = [:]
        for n in payload.nodes { if let r = n.revision { revisions[n.key] = r } }
        return CaseCheckpointManifest(format: CaseCheckpointPayload.format, caseID: payload.caseID, fence: fence, scopeFingerprint: scope,
                                      sourceVersions: payload.sourceVersions.sorted { $0.uuidString < $1.uuidString },
                                      decisions: payload.nodes.filter { decided.contains($0.review) }.map { "\($0.key)@\($0.revision ?? "-")" }.sorted(),
                                      revisions: revisions, links: payload.links.map(\.id).sorted(), layoutDigest: StudioRecordRepository.sha256(layout),
                                      nodeCount: payload.nodes.count, linkCount: payload.links.count, baseline: baseline)
    }
}

public nonisolated struct CaseCheckpointSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseCheckpointKind
    public let name: String?
    public let recordedAt: Date
    public let recordedBy: String
    public let contentDigest: String
    public let scopeFingerprint: String
    public let fence: String
    public let nodeCount: Int
    public let linkCount: Int
    /// Set when a person erasure cleared its content.
    public let erasedAt: Date?
    public let erasedReason: String?

    public var title: String {
        (name.map { "“\($0)”" } ?? kind.label) + " — " + recordedAt.formatted(date: .abbreviated, time: .shortened)
    }
    /// How an export or a banner names the state it depicts.
    public var stateLabel: String {
        "Recorded state: \(name.map { "“\($0)”, " } ?? "")\(kind.label.lowercased()) recorded \(recordedAt.formatted(date: .long, time: .shortened)) by \(recordedBy)"
            + " (content digest \(contentDigest.prefix(12))…). This is not the case as it is now."
    }
}

/// A recorded state opened for reading.
public nonisolated struct CaseCheckpointView: Sendable {
    public let summary: CaseCheckpointSummary
    public let payload: CaseCheckpointPayload
    public let manifest: CaseCheckpointManifest
    public let projection: CaseMapProjection
    public let placements: [CaseMapNodeID: CaseMapPlacement]
    /// Retained source versions no longer in the ledger (shown as unavailable; never replaced by the current one).
    public let unavailableVersions: Set<UUID>
    /// S5 (TIME-10) — versions still in the ledger but no longer in the case's scope today: withheld from this view (shown
    /// as unavailable), so a recorded state is not a way round today's restrictions.
    public var restrictedVersions: Set<UUID> = []
    /// S7 (HISTORY-07) — versions labelled privileged today: withheld from this view (no cached quote or passage is shown).
    public var privilegedVersions: Set<UUID> = []
    public var accessNote: String? {
        var parts: [String] = []
        if !restrictedVersions.isEmpty {
            parts.append("\(restrictedVersions.count) source\(restrictedVersions.count == 1 ? " is" : "s are") no longer in this case's scope and \(restrictedVersions.count == 1 ? "is" : "are") withheld from this recorded state, as from the case now.")
        }
        if !privilegedVersions.isEmpty {
            parts.append("\(privilegedVersions.count) source\(privilegedVersions.count == 1 ? " is" : "s are") labelled privileged now and \(privilegedVersions.count == 1 ? "is" : "are") withheld from this recorded state.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public nonisolated struct CaseHistoryBaseline: Equatable, Sendable {
    public let installedAt: Date
    public let caseCreatedAt: Date?
    /// The earlier of nothing: map states are recorded from here on.
    public var effective: Date { max(installedAt, caseCreatedAt ?? installedAt) }
    public var label: String {
        "Full map state not recorded before \(effective.formatted(date: .long, time: .shortened)). Earlier actions and decisions are in the case log; no earlier map is reconstructed."
    }
}

/// "What was known" at a moment.
public nonisolated enum CaseKnownAt: Equatable, Sendable {
    /// Before the baseline: no map state was recorded.
    case notRecorded(baseline: Date)
    /// After the baseline but before the first recorded state.
    case noRecordedStateYet(baseline: Date)
    /// The nearest recorded state at or before the moment; `exact` when it was recorded at that moment.
    case recorded(CaseCheckpointSummary, exact: Bool)
}

public nonisolated enum CaseHistoryError: Error, Equatable, LocalizedError {
    case caseNotFound
    case blankActor
    case blankName
    case readFailed(String)
    case incompleteRead([String])
    case keptChanging
    case notFound
    case erased(String)
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .caseNotFound: return "The case was not found (it may have been erased). Nothing was recorded."
        case .blankActor: return "Recording a state needs your name."
        case .blankName: return "A milestone needs a name."
        case .readFailed(let why): return "The case could not be read, so no state was recorded: \(why)"
        case .incompleteRead(let parts): return "Not recorded: \(parts.joined(separator: ", ")) could not be read, and a recorded state must be complete. Try again."
        case .keptChanging: return "Not recorded: the case kept changing while it was being read. Try again when the change has finished."
        case .notFound: return "That recorded state is not in this case."
        case .erased(let why): return "That recorded state's content was erased (\(why)); only the note that it existed is kept."
        case .digestMismatch: return "That recorded state does not match its content digest, so it is not shown."
        }
    }
}

// MARK: - Comparison

public nonisolated struct CaseHistoryComparison: Equatable, Sendable {
    public enum Change: String, Sendable, CaseIterable {
        case added, changed, withdrawn, needsReview
        public var label: String {
            switch self {
            case .added: return "Added"
            case .changed: return "Changed"
            case .withdrawn: return "Withdrawn"
            case .needsReview: return "Needs review"
            }
        }
    }
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let change: Change
        public let isLink: Bool
        public let title: String
        public let detail: String
    }
    public let entries: [Entry]
    public func count(_ c: Change) -> Int { entries.filter { $0.change == c }.count }

    /// Compare two recorded states by stable identity and revision (never by title).
    public static func compare(_ a: CaseCheckpointPayload, _ b: CaseCheckpointPayload) -> CaseHistoryComparison {
        var out: [Entry] = []
        func needsReview(_ statusKind: String, _ review: String) -> Bool { statusKind == CaseMapStatus.Kind.stale.rawValue || review == CaseMapReviewState.reopened.rawValue }
        let an = Dictionary(a.nodes.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
        let bn = Dictionary(b.nodes.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
        for key in Set(an.keys).union(bn.keys).sorted() {
            switch (an[key], bn[key]) {
            case (nil, let n?):
                out.append(Entry(id: "node:\(key)", change: needsReview(n.statusKind, n.review) ? .needsReview : .added, isLink: false, title: n.title,
                                 detail: "Not in the earlier state."))
            case (let o?, nil):
                out.append(Entry(id: "node:\(key)", change: .withdrawn, isLink: false, title: o.title,
                                 detail: "In the earlier state, not in the later one (removed, withdrawn, erased or out of the case's scope)."))
            case (let o?, let n?):
                if needsReview(n.statusKind, n.review), !needsReview(o.statusKind, o.review) {
                    out.append(Entry(id: "node:\(key)", change: .needsReview, isLink: false, title: n.title, detail: "\(n.statusText). The earlier decision stays recorded."))
                    continue
                }
                var what: [String] = []
                if o.revision != n.revision { what.append("revision \(o.revision?.prefix(10) ?? "—") → \(n.revision?.prefix(10) ?? "—")") }
                if o.statusText != n.statusText || o.statusKind != n.statusKind { what.append("state “\(o.statusText)” → “\(n.statusText)”") }
                if o.review != n.review { what.append("review \(o.review) → \(n.review)") }
                if o.wording != n.wording { what.append("wording changed") }
                if o.sources.count != n.sources.count { what.append("sources \(o.sources.count) → \(n.sources.count)") }
                if !what.isEmpty { out.append(Entry(id: "node:\(key)", change: .changed, isLink: false, title: n.title, detail: what.joined(separator: "; "))) }
            case (nil, nil): break
            }
        }
        let al = Dictionary(a.links.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let bl = Dictionary(b.links.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let names = Dictionary((a.nodes + b.nodes).map { ($0.key, $0.title) }, uniquingKeysWith: { _, y in y })
        func linkTitle(_ l: CaseCheckpointPayload.Link) -> String {
            "\(names["\(l.fromKind):\(l.fromID)"] ?? l.fromKind) — \(CaseMapLinkType(rawValue: l.type)?.label ?? l.type) — \(names["\(l.toKind):\(l.toID)"] ?? l.toKind)"
        }
        for key in Set(al.keys).union(bl.keys).sorted() {
            switch (al[key], bl[key]) {
            case (nil, let l?):
                out.append(Entry(id: "link:\(key)", change: needsReview(l.statusKind, l.review) ? .needsReview : .added, isLink: true, title: linkTitle(l), detail: l.basis))
            case (let o?, nil):
                out.append(Entry(id: "link:\(key)", change: .withdrawn, isLink: true, title: linkTitle(o), detail: "Not in the later state."))
            case (let o?, let l?):
                if needsReview(l.statusKind, l.review), !needsReview(o.statusKind, o.review) {
                    out.append(Entry(id: "link:\(key)", change: .needsReview, isLink: true, title: linkTitle(l), detail: l.statusText))
                } else if o.statusText != l.statusText || o.review != l.review || o.basis != l.basis {
                    out.append(Entry(id: "link:\(key)", change: .changed, isLink: true, title: linkTitle(l), detail: "“\(o.statusText)” → “\(l.statusText)”"))
                }
            case (nil, nil): break
            }
        }
        return CaseHistoryComparison(entries: out)
    }
}

// MARK: - The service

public actor CaseHistoryService {
    let database: Database
    private let map: CaseMapService
    /// Test hook: runs after the case was read and before the recorded state is written (attempt number).
    public struct Hooks: Sendable {
        public var beforeCommit: (@Sendable (Int) async -> Void)?
        public init(beforeCommit: (@Sendable (Int) async -> Void)? = nil) { self.beforeCommit = beforeCommit }
    }
    private var hooks = Hooks()

    public init(database: Database, map: CaseMapService) { self.database = database; self.map = map }
    public func setHooks(_ h: Hooks) { hooks = h }

    /// When this build started recording case history. A ledger emptied by a full erase starts a new baseline
    /// the first time it is asked (nothing earlier exists any more).
    public static func installBaseline(_ database: Database) async throws -> Date {
        try await database.withSavepoint("chbase_\(UUID().uuidString.prefix(8))") { db in
            if let d = try db.query("SELECT installed_at FROM case_history_install WHERE id = 1;", []).first?.date(0) { return d }
            let now = Date()
            try db.exec("INSERT OR IGNORE INTO case_history_install (id, installed_at) VALUES (1, ?);", [.date(now)])
            return try db.query("SELECT installed_at FROM case_history_install WHERE id = 1;", []).first?.date(0) ?? now
        }
    }

    public func baseline(caseID: UUID) async throws -> CaseHistoryBaseline {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let installed = try await Self.installBaseline(database)
        let created = try await database.query("SELECT created_at FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.date(0)
        return CaseHistoryBaseline(installedAt: installed, caseCreatedAt: created)
    }

    struct FenceMoved: Error {}

    /// Record the case map as it is now. Built from one consistent load and written only if the case's
    /// revision fence inside the write is the one the load saw; tried three times, then refused.
    @discardableResult
    public func record(caseID: UUID, kind: CaseCheckpointKind, name: String? = nil, actor: String, at date: Date = Date()) async throws -> CaseCheckpointSummary {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseHistoryError.blankActor }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .milestone, (label ?? "").isEmpty { throw CaseHistoryError.blankName }
        let baseline = try await self.baseline(caseID: caseID).effective
        for attempt in 1...3 {
            let load = await map.load(caseID: caseID, generation: UInt64(attempt))
            switch load.state {
            case .failed(let why):
                if load.projection == nil, why.contains("not in the ledger") { throw CaseHistoryError.caseNotFound }
                throw CaseHistoryError.readFailed(why)
            case .partial(let parts): throw CaseHistoryError.incompleteRead(parts.map(\.label))
            case .stale: continue
            case .empty, .complete: break
            }
            guard let p = load.projection, let fence = load.fence, let scope = load.scopeFingerprint else { continue }
            let payload = CaseCheckpointPayload.make(p, placements: load.placements)
            let json = try payload.encoded()
            let digest = StudioRecordRepository.sha256(Data(json.utf8))
            let manifest = try CaseCheckpointManifest.make(payload, fence: fence, scope: scope, baseline: baseline)
            let manifestJSON = String(decoding: try CaseCheckpointPayload.encoder.encode(manifest), as: UTF8.self)
            await hooks.beforeCommit?(attempt)
            let id = UUID()
            do {
                try await database.withSavepoint("chk_\(id.uuidString.prefix(8))") { db in
                    // Late work cannot recreate an erased case's history.
                    guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseHistoryError.caseNotFound }
                    // The validated revision fence: nothing changed between the read and this write.
                    guard try CaseMapRepository.fence(db, caseID: caseID) == fence else { throw FenceMoved() }
                    try db.exec("""
                        INSERT INTO case_checkpoints (id, case_id, kind, name, fence, scope_fingerprint, content_digest, manifest_json, payload_json,
                                                      format_version, recorded_by, recorded_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                        """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .optionalText(label?.isEmpty == false ? label : nil), .text(fence), .text(scope),
                              .text(digest), .text(manifestJSON), .text(json), .integer(Int64(CaseCheckpointPayload.format)), .text(who), .date(date)])
                }
            } catch is FenceMoved {
                KalsmritikoshLog.app.notice("Case checkpoint: the case changed between the read and the write (attempt \(attempt, privacy: .public)); reading again")
                continue
            }
            return CaseCheckpointSummary(id: id, caseID: caseID, kind: kind, name: label?.isEmpty == false ? label : nil, recordedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970), recordedBy: who,
                                         contentDigest: digest, scopeFingerprint: scope, fence: fence, nodeCount: payload.nodes.count,
                                         linkCount: payload.links.count, erasedAt: nil, erasedReason: nil)
        }
        throw CaseHistoryError.keptChanging
    }

    /// The daily record: written when the map is opened, the case changed since its newest recorded state, and
    /// no daily record was made today. Never throws; nil when nothing was recorded (with the reason logged).
    @discardableResult
    public func recordAutomaticIfChanged(caseID: UUID, actor: String, at date: Date = Date(), calendar: Calendar = .current) async -> CaseCheckpointSummary? {
        do {
            try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .read)
            let list = try await checkpoints(caseID: caseID)
            let fence = try await map.repository.revisionFence(caseID: caseID)
            if let newest = list.last, newest.fence == fence { return nil }
            if let auto = list.last(where: { $0.kind == .automatic }), calendar.isDate(auto.recordedAt, inSameDayAs: date) { return nil }
            return try await record(caseID: caseID, kind: .automatic, actor: actor, at: date)
        } catch {
            KalsmritikoshLog.app.error("Case daily record not made: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The case's recorded states, oldest first (erased ones are listed as erased).
    public func checkpoints(caseID: UUID) async throws -> [CaseCheckpointSummary] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, kind, name, recorded_at, recorded_by, content_digest, scope_fingerprint, fence, manifest_json, erased_at, erased_reason
            FROM case_checkpoints WHERE case_id = ? ORDER BY recorded_at ASC, rowid ASC;
            """, [.uuid(caseID)]).compactMap(Self.summary)
    }

    static func summary(_ r: SQLRow) -> CaseCheckpointSummary? {
        guard let id = r.uuid(0), let c = r.uuid(1), let kind = r.string(2).flatMap(CaseCheckpointKind.init(rawValue:)), let at = r.date(4),
              let by = r.string(5), let digest = r.string(6), let scope = r.string(7), let fence = r.string(8) else { return nil }
        let manifest = r.string(9).flatMap { try? CaseCheckpointPayload.decoder.decode(CaseCheckpointManifest.self, from: Data($0.utf8)) }
        return CaseCheckpointSummary(id: id, caseID: c, kind: kind, name: r.string(3), recordedAt: at, recordedBy: by, contentDigest: digest,
                                     scopeFingerprint: scope, fence: fence, nodeCount: manifest?.nodeCount ?? 0, linkCount: manifest?.linkCount ?? 0,
                                     erasedAt: r.date(10), erasedReason: r.string(11))
    }

    /// Open a recorded state for reading. Its content must match its digest; retained versions no longer in the
    /// ledger are named and shown as unavailable.
    public func open(id: UUID, caseID: UUID) async throws -> CaseCheckpointView {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        guard let r = try await database.query("""
            SELECT id, case_id, kind, name, recorded_at, recorded_by, content_digest, scope_fingerprint, fence, manifest_json, erased_at, erased_reason, payload_json
            FROM case_checkpoints WHERE id = ? AND case_id = ?;
            """, [.uuid(id), .uuid(caseID)]).first, let summary = Self.summary(r) else { throw CaseHistoryError.notFound }
        if summary.erasedAt != nil { throw CaseHistoryError.erased(summary.erasedReason ?? "erasure") }
        guard let json = r.string(12), StudioRecordRepository.sha256(Data(json.utf8)) == summary.contentDigest else { throw CaseHistoryError.digestMismatch }
        let payload = try CaseCheckpointPayload.decode(json)
        guard payload.caseID == caseID else { throw CaseHistoryError.notFound }
        let manifest = try CaseCheckpointPayload.decoder.decode(CaseCheckpointManifest.self, from: Data((r.string(9) ?? "{}").utf8))
        let wanted = payload.sourceVersions.sorted { $0.uuidString < $1.uuidString }
        var present = Set<UUID>()
        for chunk in stride(from: 0, to: wanted.count, by: 400).map({ Array(wanted[$0..<min($0 + 400, wanted.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try await database.query("SELECT id FROM source_versions WHERE id IN (\(marks));", chunk.map { .uuid($0) }) {
                if let v = row.uuid(0) { present.insert(v) }
            }
        }
        let unavailable = Set(wanted).subtracting(present)
        // S5 (TIME-10) — today's scope applies to an older state: a source taken out of the case since is withheld.
        let authorized = try await currentScope(caseID)
        let restricted = present.subtracting(authorized)
        // S7 (HISTORY-07) — and today's privilege labels: a source labelled privileged since the state was recorded is withheld
        // from the recorded state (its cached quote and passage are not shown), as an export of the case would withhold it.
        let privileged = try await privilegedNow(present.intersection(authorized))
        let (projection, placements) = payload.rebuild(unavailable: unavailable.union(restricted).union(privileged))
        var view = CaseCheckpointView(summary: summary, payload: payload, manifest: manifest, projection: projection, placements: placements,
                                      unavailableVersions: unavailable)
        view.restrictedVersions = restricted
        view.privilegedVersions = privileged
        return view
    }

    /// The versions among `versions` that carry a privileged label today (an unresolvable label counts as privileged: withheld).
    func privilegedNow(_ versions: Set<UUID>) async throws -> Set<UUID> {
        let repo = SensitiveScopeRepository(database: database)
        var out = Set<UUID>()
        for v in versions {
            switch try await repo.effectiveLabel(for: SensitiveScopeTarget(kind: .sourceVersion, id: v)) {
            case .brokenLineage: out.insert(v)
            case .resolved(let label): if label.privileged { out.insert(v) }
            }
        }
        return out
    }

    /// The source versions the case authorizes now (its scope as it is today).
    func currentScope(_ caseID: UUID) async throws -> Set<UUID> {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        guard let record = try await InvestigationCaseRepository(database: database).fetch(caseID: caseID) else { throw CaseHistoryError.notFound }
        return Set(try await CaseRetrievalScopeResolver(evidence: EvidenceStore(database: database)).scope(for: record).authorizedSourceVersionIDs)
    }

    /// What was known at `moment`: the nearest recorded state at or before it — never a reconstruction.
    public func knownAt(caseID: UUID, _ moment: Date) async throws -> CaseKnownAt {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let base = try await baseline(caseID: caseID).effective
        if moment < base { return .notRecorded(baseline: base) }
        // Times are stored as seconds since 1970 in a REAL, so a time read back can differ from the one
        // written by a fraction of a microsecond: a state recorded at exactly this moment still counts.
        let list = try await checkpoints(caseID: caseID).filter { $0.erasedAt == nil && $0.recordedAt <= moment.addingTimeInterval(0.001) }
        guard let nearest = list.last else { return .noRecordedStateYet(baseline: base) }
        return .recorded(nearest, exact: abs(nearest.recordedAt.timeIntervalSince(moment)) < 0.001)
    }
}
