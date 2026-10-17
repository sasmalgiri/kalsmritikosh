//
//  RiskScoring.swift
//  Kalsmritikosh
//
//  N-13 — "what to read first": a deterministic score per document, where every
//  point is explained. Components:
//    contradictions that cite the document     +3 each (max 9)
//    watchlist names it mentions                +3 each (max 9)
//    gaps found on it                           +1 each (max 3)
//    added in the last 7 days                   +1
//  Reproducible: same ledger, same score.
//

import Foundation
import os

public nonisolated struct RiskScore: Sendable, Equatable {
    public let total: Int
    public let parts: [String]
    public var explanation: String { parts.joined(separator: "; ") }
}

extension AppState {

    public func riskScores(for objectIDs: [UUID]) async -> [UUID: RiskScore] {
        guard ProductModuleFlags.isEnabled(.riskScore), let database, !objectIDs.isEmpty else { return [:] }
        let terms = ((try? await watchlists?.all()) ?? []).flatMap(\.terms).map { WatchlistMatcher.normalize($0) }
        var out: [UUID: RiskScore] = [:]
        let weekAgo = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        for id in objectIDs {
            var total = 0
            var parts: [String] = []
            do {
                let c = Int(try await database.query(
                    "SELECT COUNT(*) FROM contradictions WHERE evidence_a LIKE ? OR evidence_b LIKE ?;",
                    [.text("%\(id.uuidString)%"), .text("%\(id.uuidString)%")]).first?.int(0) ?? 0)
                if c > 0 { total += min(9, c * 3); parts.append("\(c) contradiction\(c == 1 ? "" : "s")") }
                let g = Int(try await database.query(
                    "SELECT COUNT(*) FROM gap_nodes WHERE evidence_object_id = ? AND dismissed = 0;", [.uuid(id)]).first?.int(0) ?? 0)
                if g > 0 { total += min(3, g); parts.append("\(g) possible gap\(g == 1 ? "" : "s")") }
                if !terms.isEmpty {
                    let names = try await database.query("""
                        SELECT DISTINCT e.value FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
                        WHERE m.source_object_id = ?;
                        """, [.uuid(id)]).compactMap { $0.string(0) }.map(WatchlistMatcher.normalize)
                    let hits = Set(names).intersection(terms).count
                    if hits > 0 { total += min(9, hits * 3); parts.append("\(hits) watchlist name\(hits == 1 ? "" : "s")") }
                }
                if let created = try await database.query("SELECT created_at FROM knowledge_objects WHERE id = ?;", [.uuid(id)]).first?.double(0),
                   created >= weekAgo {
                    total += 1; parts.append("added this week")
                }
            } catch {
                KalsmritikoshLog.app.error("Risk score failed: \(error.localizedDescription, privacy: .public)")
            }
            out[id] = RiskScore(total: total, parts: parts)
        }
        return out
    }
}
