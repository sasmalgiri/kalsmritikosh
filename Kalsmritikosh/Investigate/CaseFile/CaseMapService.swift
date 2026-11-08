//
//  CaseMapService.swift
//  Kalsmritikosh
//
//  Living case map, M1 (plan §5.3, §6.1): scoped, authorised loading of the case projection through the
//  EXISTING case services — the case file snapshot and custody manifest (CaseFileService, custody), the
//  contradiction review desk, hypotheses and evidence requests (InvestigationAnalysisService), and the map's
//  own v171 rows. Nothing here sends anything anywhere; opening or refreshing the map reads the ledger only.
//
//  • One revision boundary: the case's revision fence is read before and after; a load that saw the case
//    change is read again once, and if it changes again the result says it may mix two states.
//  • Each part loads or fails on its own; a failed part is shown as not loaded, never as empty.
//  • Every load carries the case id, a generation token and the scope fingerprint, so the screen can drop a
//    late result after a case switch, an erase or a scope change.
//  • Positions are only ever ADDED for new items (existing and pinned positions are never rewritten), and
//    never for a case that no longer exists.
//

import Foundation
import os

/// Where the map reads from: the existing services, as closures (the app passes its live services; tests
/// pass fixtures). Nil means the service is not available in this build/state — reported, not hidden.
public nonisolated struct CaseMapSources: Sendable {
    public var custody: (@Sendable (UUID) async throws -> [CustodyManifestEntry])?
    public var snapshot: @Sendable (UUID, [CustodyManifestEntry]) async throws -> CaseFileSnapshot?
    /// Source version → the document it was read into.
    public var objectsByVersion: @Sendable (Set<UUID>) async throws -> [UUID: UUID]
    public var contradictions: (@Sendable (UUID) async throws -> [CaseContradictionReviewItem])?
    public var hypotheses: (@Sendable (UUID) async throws -> [CaseMapHypothesis])?
    public var requests: (@Sendable (UUID) async throws -> [EvidenceRequestFile])?
    /// v176 — the case's supplied reports, points, qualifications, work links and action contracts.
    public var reports: (@Sendable (UUID) async throws -> CaseReportLedger)?
    /// S3 (MAP-06) — money movements read from the case's documents (the knowledge objects in scope). Nil: not available.
    public var money: (@Sendable (UUID, Set<UUID>) async throws -> [FundsTransaction])? = nil
    /// S7 (MONEY-01) — the case's canonical financial records. Nil: not available.
    public var moneyLedger: (@Sendable (UUID) async throws -> CaseMoneyLedger)? = nil
    public var map: CaseMapRepository

    public init(custody: (@Sendable (UUID) async throws -> [CustodyManifestEntry])?,
                snapshot: @escaping @Sendable (UUID, [CustodyManifestEntry]) async throws -> CaseFileSnapshot?,
                objectsByVersion: @escaping @Sendable (Set<UUID>) async throws -> [UUID: UUID],
                contradictions: (@Sendable (UUID) async throws -> [CaseContradictionReviewItem])?,
                hypotheses: (@Sendable (UUID) async throws -> [CaseMapHypothesis])?,
                requests: (@Sendable (UUID) async throws -> [EvidenceRequestFile])?,
                reports: (@Sendable (UUID) async throws -> CaseReportLedger)? = nil,
                map: CaseMapRepository) {
        self.custody = custody; self.snapshot = snapshot; self.objectsByVersion = objectsByVersion
        self.contradictions = contradictions; self.hypotheses = hypotheses; self.requests = requests; self.reports = reports; self.map = map
    }

    /// The live sources over the app's services. The case file is read as the map shows it, with the journal
    /// read incrementally (M9 §13.3: only rows written since the last read are read again).
    public static func live(database: Database, caseFiles: CaseFileService, custody: InvestigationCustodyService?,
                            analysis: InvestigationAnalysisService?, desk: InvestigationContradictionGapService?,
                            objects: KnowledgeObjectRepository) -> CaseMapSources {
        let journal = CaseMapJournalCache(file: caseFiles.file)
        return CaseMapSources(
            custody: custody.map { c in { id in try await c.manifest(caseID: id) } },
            snapshot: { id, custody in
                // The header first: an erased case reads as "not in the ledger", and its journal is forgotten.
                guard try await caseFiles.caseHeader(id) != nil else { await journal.forget(id); return nil }
                return try await caseFiles.snapshot(caseID: id, custody: custody, journal: try await journal.journal(caseID: id), forMap: true)
            },
            objectsByVersion: { versions in
                var map: [UUID: UUID] = [:]
                for (object, vs) in try await objects.sourceVersionsByObject(inSourceVersionIDs: versions) {
                    for v in vs where map[v] == nil || object.uuidString < (map[v]?.uuidString ?? "") { map[v] = object }
                }
                return map
            },
            contradictions: desk.map { d in { id in try await d.contradictionReviewItems(caseID: id) } },
            hypotheses: analysis.map { a in { id in
                var out: [CaseMapHypothesis] = []
                for h in try await a.hypotheses(caseID: id) { out.append(CaseMapHypothesis(hypothesis: h, evidence: try await a.evidence(hypothesisID: h.id))) }
                return out
            } },
            requests: analysis.map { a in { id in try await a.requestFiles(caseID: id) } },
            reports: { [file = caseFiles.file] id in try await file.reportLedger(caseID: id) },
            map: CaseMapRepository(database: database))
            .withMoney(database: database)
            .withMoneyLedger(caseFiles.file)
    }

    /// S7 (MONEY-01) — the money source over the case's own financial records.
    func withMoneyLedger(_ file: CaseFileRepository) -> CaseMapSources {
        var s = self
        s.moneyLedger = { id in try await file.moneyLedger(caseID: id) }
        return s
    }

    /// S3 (MAP-06) — the money source over FundsTrace: the payments the ledger read, kept to those recorded in the case's
    /// OWN documents, tied to amounts only where FundsTrace can without guessing, and grouped into transactions.
    func withMoney(database: Database) -> CaseMapSources {
        var s = self
        s.money = { _, objects in
            guard !objects.isEmpty else { return [] }
            let inCase = Set(objects.map { $0.uuidString.uppercased() })
            let snap = try await FundsTraceLoader.load(database)
            let edges = snap.edges.compactMap { e -> FundsPaymentEdge? in
                let docs = e.documentIDs.filter { inCase.contains($0.uppercased()) }
                return docs.isEmpty ? nil : FundsPaymentEdge(fromID: e.fromID, fromLabel: e.fromLabel, toID: e.toID, toLabel: e.toLabel, documentIDs: docs)
            }
            let amounts = snap.amounts.filter { inCase.contains($0.documentID.uppercased()) }
            return FundsTrace.transactions(FundsTrace.attribute(edges: edges, amounts: amounts).transfers)
        }
        return s
    }
}

/// M9 (§13.3) — the case journal as the map last read it, so a refresh reads only the rows written since. The
/// rows read before are reused only while their digest (number, verification, removal, review state, citations)
/// is unchanged; any difference, or any failed read, reads the whole journal again. One case is kept at a time.
public actor CaseMapJournalCache {
    private let file: CaseFileRepository
    private var caseID: UUID?
    private var entries: [CaseJournalEntry] = []
    private var maxRowID: Int64 = 0
    private var digest = ""
    /// How the last read was made (tests and the harness read it): rows reused, rows read.
    public private(set) var lastRead: (reused: Int, read: Int) = (0, 0)

    public init(file: CaseFileRepository) { self.file = file }

    public func forget(_ id: UUID) {
        guard caseID == id else { return }
        caseID = nil; entries = []; maxRowID = 0; digest = ""
    }

    /// The case's live journal entries, in the order `CaseFileRepository.journal(caseID:)` returns them.
    public func journal(caseID id: UUID) async throws -> [CaseJournalEntry] {
        if caseID == id {
            do {
                let delta = try await file.journalSince(caseID: id, afterRowID: maxRowID, known: digest)
                if !delta.changed {
                    let reused = entries.count
                    if !delta.entries.isEmpty { entries = Self.merge(entries, Self.ordered(delta.entries)) }
                    maxRowID = delta.maxRowID
                    digest = delta.digest
                    lastRead = (reused, delta.entries.count)
                    return entries
                }
            } catch {
                KalsmritikoshLog.app.error("Case map journal: the incremental read failed, reading it whole: \(error.localizedDescription, privacy: .public)")
            }
        }
        forget(caseID ?? id)
        let all = try await file.journalSince(caseID: id, afterRowID: Int64.min, known: nil)
        caseID = id; entries = Self.ordered(all.entries); maxRowID = all.maxRowID; digest = all.digest
        lastRead = (0, all.entries.count)
        return entries
    }

    /// The order of `CaseFileRepository.journal(caseID:)`: by event date (else when it was written), then when written.
    static func precedes(_ a: CaseJournalEntry, _ b: CaseJournalEntry) -> Bool {
        let ka = a.eventDate ?? a.createdAt, kb = b.eventDate ?? b.createdAt
        if ka != kb { return ka < kb }
        return a.createdAt < b.createdAt
    }
    static func ordered(_ list: [CaseJournalEntry]) -> [CaseJournalEntry] { list.sorted(by: precedes) }

    /// Two ordered lists merged in one pass (a refresh adds a few rows to many).
    static func merge(_ a: [CaseJournalEntry], _ b: [CaseJournalEntry]) -> [CaseJournalEntry] {
        var out: [CaseJournalEntry] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if precedes(b[j], a[i]) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        out += a[i...]; out += b[j...]
        return out
    }
}

/// One load of the case map.
public nonisolated struct CaseMapLoad: Sendable {
    public let caseID: UUID
    public let generation: UInt64
    /// The case scope the load was made under (CaseScopeFingerprinter over the case revision and its versions).
    public let scopeFingerprint: String?
    public let fence: String?
    public let projection: CaseMapProjection?
    public let placements: [CaseMapNodeID: CaseMapPlacement]
    public let views: [CaseMapSavedView]
    public let state: CaseMapLoadState
}

public actor CaseMapService {
    private let sources: CaseMapSources
    /// M9 (§13.3) — what the last projection built per chronology entry (one case; memory only).
    private var memo: CaseMapProjectionMemo?
    /// How many chronology entries the last load reused from the previous projection (tests and the harness).
    public private(set) var lastReusedEntries = 0
    public init(sources: CaseMapSources) { self.sources = sources }

    public nonisolated var repository: CaseMapRepository { sources.map }

    /// Read the case map for one case. Never throws: a failure is the load's state.
    public func load(caseID: UUID, generation: UInt64) async -> CaseMapLoad {
        let read = await loadUncached(caseID: caseID, generation: generation)
        // S3 (branch read path): a load read under one consistent fence is kept for branch reads.
        if let p = read.projection, let fence = read.fence { cached = (caseID, fence, p) } else if cached?.caseID == caseID { cached = nil }
        return read
    }

    private func loadUncached(caseID: UUID, generation: UInt64) async -> CaseMapLoad {
        var last: CaseMapLoad?
        for attempt in 0..<2 {
            let before: String?
            do { before = try await sources.map.revisionFence(caseID: caseID) } catch {
                KalsmritikoshLog.app.error("Case map fence read failed: \(error.localizedDescription, privacy: .public)")
                before = nil
            }
            let read = await readOnce(caseID: caseID, generation: generation, fence: before)
            if read.projection == nil { return read }   // the case itself could not be read
            let after: String?
            do { after = try await sources.map.revisionFence(caseID: caseID) } catch {
                KalsmritikoshLog.app.error("Case map fence read failed: \(error.localizedDescription, privacy: .public)")
                after = nil
            }
            if let before, before == after { return read }
            last = read
            if attempt == 1 { break }
        }
        guard let read = last else {
            return CaseMapLoad(caseID: caseID, generation: generation, scopeFingerprint: nil, fence: nil, projection: nil, placements: [:], views: [],
                               state: .failed("The case map could not be read."))
        }
        return CaseMapLoad(caseID: caseID, generation: generation, scopeFingerprint: read.scopeFingerprint, fence: nil, projection: read.projection,
                           placements: read.placements, views: read.views,
                           state: .stale("The case changed while the map was being read. What is shown may mix two moments — choose Refresh."))
    }

    private func readOnce(caseID: UUID, generation: UInt64, fence: String?) async -> CaseMapLoad {
        func failed(_ why: String) -> CaseMapLoad {
            CaseMapLoad(caseID: caseID, generation: generation, scopeFingerprint: nil, fence: fence, projection: nil, placements: [:], views: [], state: .failed(why))
        }
        var parts: [CaseMapPart: CaseMapPartState] = [:]
        // Custody: the case's documents. A failed read is not an empty case.
        var custody: [CustodyManifestEntry] = []
        if let read = sources.custody {
            do { custody = try await read(caseID) } catch {
                KalsmritikoshLog.app.error("Case map custody read failed: \(error.localizedDescription, privacy: .public)")
                parts[.documents] = .failed("The case's documents could not be read: \(error.localizedDescription)")
            }
        } else {
            parts[.documents] = .unavailable("The custody record is not available yet.")
        }
        let snapshot: CaseFileSnapshot
        do {
            guard let s = try await sources.snapshot(caseID, custody) else {
                if memo?.caseID == caseID { memo = nil }   // an erased case keeps nothing in memory
                return failed("This case is not in the ledger (it may have been erased).")
            }
            snapshot = s
        } catch {
            KalsmritikoshLog.app.error("Case map snapshot read failed: \(error.localizedDescription, privacy: .public)")
            return failed("The case file could not be read: \(error.localizedDescription)")
        }
        parts[.caseFile] = .loaded
        let versions = Set(custody.map(\.sourceVersionID))
        var documents: [CaseMapDocument] = []
        if parts[.documents] == nil {
            do {
                let objects = try await sources.objectsByVersion(versions)
                documents = try await sources.map.documents(versionIDs: versions, objectsByVersion: objects)
                parts[.documents] = .loaded
            } catch {
                KalsmritikoshLog.app.error("Case map documents read failed: \(error.localizedDescription, privacy: .public)")
                parts[.documents] = .failed("The case's documents could not be read: \(error.localizedDescription)")
            }
        }
        func part<T: Sendable>(_ p: CaseMapPart, _ read: (@Sendable (UUID) async throws -> [T])?) async -> [T] {
            guard let read else { parts[p] = .unavailable("Not available yet."); return [] }
            do { let v = try await read(caseID); parts[p] = .loaded; return v } catch {
                KalsmritikoshLog.app.error("Case map \(p.rawValue, privacy: .public) read failed: \(error.localizedDescription, privacy: .public)")
                parts[p] = .failed(error.localizedDescription)
                return []
            }
        }
        let contradictions = await part(.contradictions, sources.contradictions)
        let hypotheses = await part(.hypotheses, sources.hypotheses)
        let requests = await part(.requests, sources.requests)
        let links = await part(.investigatorLinks, { [map = sources.map] id in try await map.links(caseID: id) })
        // S3 (MAP-06): money movements in the case's own documents. A failed read is a part not loaded, never "no money".
        var money: [FundsTransaction] = []
        if let read = sources.money {
            if parts[.documents]?.isLoaded == true {
                do { money = try await read(caseID, Set(documents.compactMap(\.objectID))); parts[.money] = .loaded } catch {
                    KalsmritikoshLog.app.error("Case map money read failed: \(error.localizedDescription, privacy: .public)")
                    parts[.money] = .failed(error.localizedDescription)
                }
            } else {
                parts[.money] = .unavailable("The case's documents could not be read, so their money movements could not be either.")
            }
        } else {
            parts[.money] = .unavailable("Money movements are not available in this build.")
        }
        // S7 (MONEY-01): the case's canonical money records. A failed read is the money part not loaded, never "no money".
        var moneyLedger: CaseMoneyLedger? = nil
        if let read = sources.moneyLedger {
            do { moneyLedger = try await read(caseID) } catch {
                KalsmritikoshLog.app.error("Case map money records read failed: \(error.localizedDescription, privacy: .public)")
                parts[.money] = .failed(error.localizedDescription)
            }
        }
        var reportLedger = CaseReportLedger()
        if let read = sources.reports {
            do { reportLedger = try await read(caseID); parts[.reports] = .loaded } catch {
                KalsmritikoshLog.app.error("Case map reports read failed: \(error.localizedDescription, privacy: .public)")
                parts[.reports] = .failed(error.localizedDescription)
            }
        } else {
            parts[.reports] = .unavailable("Not available yet.")
        }

        // M9 (§13.3): chronology entries unchanged since the last projection of this case are reused, not rebuilt.
        var input = CaseMapInput(snapshot: snapshot, documents: documents, contradictions: contradictions,
                                 hypotheses: hypotheses, requests: requests, investigatorLinks: links,
                                 reportLedger: reportLedger, parts: parts)
        input.money = money
        input.moneyLedger = moneyLedger
        let built = CaseMapProjector.project(input,
                                             reusing: memo?.caseID == caseID ? memo : nil)
        let projection = built.projection
        memo = built.memo
        lastReusedEntries = built.memo.reusedEntries
        let fingerprint = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: snapshot.caseHeader.revision,
                                                             scope: .authorizing(versions)).value
        // Layout: stored positions are kept as they are; only items without one are placed and stored.
        var placements: [CaseMapNodeID: CaseMapPlacement] = [:]
        var views: [CaseMapSavedView] = []
        do {
            let stored = try await sources.map.layout(caseID: caseID)
            placements = CaseMapLayout.placeNew(projection, existing: stored)
            let added = placements.filter { stored[$0.key] == nil }
            if !added.isEmpty {
                do { try await sources.map.savePlacements(caseID: caseID, added) } catch {
                    // Not saved (e.g. the case was erased meanwhile): shown for now, placed again next time.
                    KalsmritikoshLog.app.error("Case map positions not saved: \(error.localizedDescription, privacy: .public)")
                }
            }
            views = try await sources.map.views(caseID: caseID)
        } catch {
            KalsmritikoshLog.app.error("Case map layout read failed: \(error.localizedDescription, privacy: .public)")
            placements = CaseMapLayout.placeNew(projection, existing: [:])
        }
        return CaseMapLoad(caseID: caseID, generation: generation, scopeFingerprint: fingerprint, fence: fence, projection: projection,
                           placements: placements, views: views, state: projection.loadState)
    }

    // MARK: - S3: branch-scoped read path (plan §11; GRAPH-07, MAP-04)

    /// The last projection read under one consistent fence (one case; memory only).
    private var cached: (caseID: UUID, fence: String, projection: CaseMapProjection)?
    /// How the last branch read was answered (tests and the harness).
    public private(set) var lastBranchRead: CaseMapBranchRead.Source?

    /// Read one branch: the frame over `anchor` and its records within `budget`, cycle-safe, with the continuation. When
    /// the case's revision fence is unchanged since the last full read, the branch comes from that read — only the fence's
    /// indexed counts are read, never every table (a pan or an expand does not reload the case). When it changed, or
    /// nothing was read yet, the case is read again first, and the result says so.
    public func branch(caseID: UUID, anchor: CaseMapNodeID, budget: Int = 2_000, generation: UInt64 = 0) async -> CaseMapBranchRead {
        var source: CaseMapBranchRead.Source = .cached
        var fenceNow: String?
        do { fenceNow = try await sources.map.revisionFence(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("Case map branch fence read failed: \(error.localizedDescription, privacy: .public)")
        }
        if cached?.caseID != caseID || fenceNow == nil || cached?.fence != fenceNow {
            source = .reread
            _ = await load(caseID: caseID, generation: generation)
        }
        lastBranchRead = source
        guard let c = cached, c.caseID == caseID else {
            return CaseMapBranchRead(caseID: caseID, anchor: anchor, frame: nil, traversal: nil, source: source,
                                     problem: "The case could not be read in one consistent state; choose Refresh.")
        }
        guard let frame = CaseMapFrames.frame(of: anchor, in: c.projection) else {
            return CaseMapBranchRead(caseID: caseID, anchor: anchor, frame: nil, traversal: nil, source: source,
                                     problem: "That item is not in this case's map (it may have been removed, erased or left the case scope).")
        }
        return CaseMapBranchRead(caseID: caseID, anchor: anchor, frame: frame, traversal: CaseMapFrames.traverse(from: anchor, in: c.projection, budget: budget),
                                 source: source, problem: nil)
    }

    // MARK: - Smart-map M1: open a record as a frame

    /// "Open as frame": the frame over `anchor` in `projection` (a projection — identities only, no copy of a record)
    /// with its own positions: the ones stored for this frame, and new members placed around the anchor and stored
    /// (existing and pinned positions never move). Nil when the record is not in the projection. With `store: false`
    /// (a recorded state is shown read-only) nothing is written.
    public func openFrame(caseID: UUID, anchor: CaseMapNodeID, in projection: CaseMapProjection,
                          store: Bool = true) async -> (frame: CaseMapFrame, placements: [CaseMapNodeID: CaseMapPlacement])? {
        guard projection.caseID == caseID, let frame = CaseMapFrames.frame(of: anchor, in: projection) else { return nil }
        var stored: [CaseMapNodeID: CaseMapPlacement] = [:]
        if store {
            do { stored = try await sources.map.layout(caseID: caseID, frame: frame.key) } catch {
                KalsmritikoshLog.app.error("Case map frame layout read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let placements = CaseMapLayout.placeFrame(frame, existing: stored)
        let added = placements.filter { stored[$0.key] == nil }
        if store, !added.isEmpty {
            do { try await sources.map.savePlacements(caseID: caseID, frame: frame.key, added) } catch {
                KalsmritikoshLog.app.error("Case map frame positions not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (frame, placements)
    }
}

/// S3 — one branch read (CaseMapService.branch).
public nonisolated struct CaseMapBranchRead: Sendable {
    public enum Source: String, Sendable, Equatable {
        /// The case was unchanged since the last full read: only the revision fence was read.
        case cached
        /// The case changed (or was not read yet): it was read again first.
        case reread
    }
    public let caseID: UUID
    public let anchor: CaseMapNodeID
    public let frame: CaseMapFrame?
    public let traversal: CaseMapTraversal?
    public let source: Source
    public let problem: String?
}
