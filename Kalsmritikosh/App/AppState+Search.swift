//
//  AppState+Search.swift
//  Kalsmritikosh
//
//  W1-1 advanced search syntax and W1-2 search coverage, each behind its module.
//

import Foundation
import os

/// W1-2 — what a result list could and could not see.
public struct SearchCoverage: Sendable, Equatable {
    public let totalDocuments: Int
    public let searchableDocuments: Int
    /// Names of sources whose indexing is still running or only partial.
    public let stillIndexing: [String]
    public let stillIndexingCount: Int
    /// The fields the query matched against.
    public let matchedFields: [String]

    public var isComplete: Bool { searchableDocuments >= totalDocuments && stillIndexingCount == 0 }

    public var headline: String {
        let fields = ListFormatter.localizedString(byJoining: matchedFields)
        if totalDocuments == 0 { return "Nothing has been added yet." }
        if isComplete { return "Matched on \(fields) · all \(totalDocuments) documents were searchable." }
        return "Matched on \(fields) · \(searchableDocuments) of \(totalDocuments) documents were searchable."
    }

    public var indexingNote: String? {
        guard stillIndexingCount > 0 else { return nil }
        let names = stillIndexing.joined(separator: ", ")
        let more = stillIndexingCount > stillIndexing.count ? " and \(stillIndexingCount - stillIndexing.count) more" : ""
        return "Still being indexed, so results may be missing from: \(names)\(more)."
    }
}

extension AppState {

    /// W1-1 — compile and run advanced syntax. Returns nil when the module is off
    /// (the caller then uses plain keyword search, as before).
    public func advancedSearch(_ query: String, limit: Int = 40) async -> (compiled: CompiledSearch, hits: [Chunk])? {
        guard ProductModuleFlags.isEnabled(.advancedSearchSyntax), let chunks else { return nil }
        let compiled = AdvancedSearchCompiler.compile(query)
        guard !compiled.isEmpty else { return (compiled, []) }
        do {
            return (compiled, try await chunks.searchAdvanced(compiled, limit: limit))
        } catch {
            KalsmritikoshLog.app.error("Advanced search failed: \(error.localizedDescription, privacy: .public)")
            return (CompiledSearch(ftsExpression: compiled.ftsExpression, filters: compiled.filters,
                                   issues: compiled.issues + ["The search could not run: \(error.localizedDescription)"],
                                   summary: compiled.summary), [])
        }
    }

    /// W1-2 — coverage of the archive for a search. nil when the module is off.
    public func searchCoverage(for compiled: CompiledSearch?) async -> SearchCoverage? {
        guard ProductModuleFlags.isEnabled(.searchCoverageBadge), let database else { return nil }
        do {
            let total = Int(try await database.query("SELECT COUNT(*) FROM knowledge_objects;", []).first?.int(0) ?? 0)
            let searchable = Int(try await database.query("""
                SELECT COUNT(DISTINCT object_id) FROM chunks WHERE review_status IS NULL AND superseded_by_run IS NULL;
                """, []).first?.int(0) ?? 0)
            let pendingRows = try await database.query("""
                SELECT DISTINCT f.url FROM source_readiness_dimensions d
                JOIN source_versions sv ON sv.id = d.source_version_id
                JOIN files f ON f.id = sv.logical_source_id
                WHERE d.dimension = 'indexing' AND d.state IN ('notStarted', 'running', 'partial');
                """, [])
            let names = pendingRows.compactMap { $0.string(0) }.map { URL(string: $0)?.lastPathComponent ?? $0 }
            var fields = ["text"]
            for f in compiled?.filters ?? [] {
                let name: String
                switch f.field {
                case .type: name = "document type"
                case .file: name = "file name"
                case .before, .after: name = "file date"
                case .entity: name = "people and organisations"
                case .tag: name = "tags"
                }
                if !fields.contains(name) { fields.append(name) }
            }
            if compiled?.ftsExpression == nil, compiled?.filters.isEmpty == false { fields.removeFirst() }
            return SearchCoverage(totalDocuments: total, searchableDocuments: min(searchable, total),
                                  stillIndexing: Array(names.prefix(5)), stillIndexingCount: names.count,
                                  matchedFields: fields)
        } catch {
            KalsmritikoshLog.app.error("Search coverage failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
