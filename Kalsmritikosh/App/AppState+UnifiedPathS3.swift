//
//  AppState+UnifiedPathS3.swift
//  Kalsmritikosh
//
//  Unified-path program S3 (owner 2026-11-22) — the app-side helpers that connect built-but-unused
//  pieces to the live product: deep study on demand (AI-28) and the case's local enrichment check
//  (IN-20). Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

extension AppState {

    // MARK: - AI-28 Study deeper

    /// Unified path AI-28 (owner 2026-11-22) — not tested yet. Deep study (Tier 3) for the named
    /// subjects, on demand. When ingest-time distillation runs, the Tier3Escalator drops each
    /// subject into the updater's stream; otherwise the memory distiller runs for each subject now
    /// (the person asked). Without AI the distiller writes what its deterministic path can.
    /// Returns how many subjects were queued or distilled.
    @discardableResult
    public func studyDeeper(subjects: [(kind: MemoryObject.SubjectKind, identifier: String)],
                            triggeringObjectID: UUID?) async -> Int {
        let wanted = subjects.filter { !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(25)
        guard !wanted.isEmpty else { return 0 }
        if let tier3Escalator, let trigger = triggeringObjectID {
            for s in wanted {
                await tier3Escalator.forceEscalate(subjectKind: s.kind, subjectIdentifier: s.identifier, triggeringObjectID: trigger)
            }
            return wanted.count
        }
        guard let memoryDistiller else { return 0 }
        let activity = beginProcess("Studying deeper")
        defer { finishProcess(activity) }
        var done = 0
        for s in wanted {
            do {
                if try await memoryDistiller.distill(.init(kind: s.kind, identifier: s.identifier),
                                                     triggeredBy: triggeringObjectID) != nil { done += 1 }
            } catch {
                KalsmritikoshLog.knowledge.error("Study deeper: distillation failed: \(String(describing: error), privacy: .public)")
            }
        }
        return done
    }

    // MARK: - IN-20 local enrichment

    /// Unified path IN-20 (owner 2026-11-22) — not tested yet. The LOCAL enrichment adapter: the
    /// sanctions lists already saved on this Mac (by an earlier Online lookup), matched here; nothing
    /// is sent. A list never saved is reported as not searched (the result says partial or failed,
    /// never "no match"). Registry and court lookups stay in Online tools (outside providers).
    public func localSanctionsCheck(_ name: String) async -> CaseEnrichmentResult {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder: URL?
        do { folder = try ScanRescue.folder().deletingLastPathComponent().appendingPathComponent("Public lists", isDirectory: true) } catch {
            KalsmritikoshLog.app.error("Local sanctions check: list folder not found: \(String(describing: error), privacy: .public)")
            folder = nil
        }
        let sources: [PublicSource] = SanctionsLists.requests().map(\.0)
        let loaded: [(PublicSource, Data)] = await Task.detached(priority: .userInitiated) {
            sources.compactMap { source -> (PublicSource, Data)? in
                guard let file = folder?.appendingPathComponent("\(source.rawValue).data"),
                      let data = try? Data(contentsOf: file) else { return nil }
                return (source, data)
            }
        }.value
        var entries: [SanctionsLists.Entry] = []
        for (source, data) in loaded {
            switch source {
            case .ofacSDN: entries += SanctionsLists.parseSDN(data)
            case .ofacAliases: entries += SanctionsLists.parseAliases(data)
            default: entries += SanctionsLists.parseUN(data)
            }
        }
        let searched = loaded.map(\.0)
        let missing = sources.filter { s in !searched.contains(s) }
        return CaseEnrichmentAdapters.sanctions(query: query, matches: SanctionsLists.match(query, in: entries),
                                                searched: searched, failedLists: missing, at: Date())
    }
}
