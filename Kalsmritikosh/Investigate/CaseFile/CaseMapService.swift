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
    public var map: CaseMapRepository

    public init(custody: (@Sendable (UUID) async throws -> [CustodyManifestEntry])?,
                snapshot: @escaping @Sendable (UUID, [CustodyManifestEntry]) async throws -> CaseFileSnapshot?,
                objectsByVersion: @escaping @Sendable (Set<UUID>) async throws -> [UUID: UUID],
                contradictions: (@Sendable (UUID) async throws -> [CaseContradictionReviewItem])?,
                hypotheses: (@Sendable (UUID) async throws -> [CaseMapHypothesis])?,
                requests: (@Sendable (UUID) async throws -> [EvidenceRequestFile])?,
                map: CaseMapRepository) {
        self.custody = custody; self.snapshot = snapshot; self.objectsByVersion = objectsByVersion
        self.contradictions = contradictions; self.hypotheses = hypotheses; self.requests = requests; self.map = map
    }

    /// The live sources over the app's services.
    public static func live(database: Database, caseFiles: CaseFileService, custody: InvestigationCustodyService?,
                            analysis: InvestigationAnalysisService?, desk: InvestigationContradictionGapService?,
                            objects: KnowledgeObjectRepository) -> CaseMapSources {
        CaseMapSources(
            custody: custody.map { c in { id in try await c.manifest(caseID: id) } },
            snapshot: { id, custody in try await caseFiles.snapshot(caseID: id, custody: custody) },
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
            map: CaseMapRepository(database: database))
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
    public init(sources: CaseMapSources) { self.sources = sources }

    public nonisolated var repository: CaseMapRepository { sources.map }

    /// Read the case map for one case. Never throws: a failure is the load's state.
    public func load(caseID: UUID, generation: UInt64) async -> CaseMapLoad {
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
            guard let s = try await sources.snapshot(caseID, custody) else { return failed("This case is not in the ledger (it may have been erased).") }
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

        let projection = CaseMapProjector.project(CaseMapInput(snapshot: snapshot, documents: documents, contradictions: contradictions,
                                                               hypotheses: hypotheses, requests: requests, investigatorLinks: links, parts: parts))
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
}
