//
//  HostArtifactRepository.swift
//  Kalsmritikosh
//
//  Unified path SRC-11 (owner 2026-11-22) — not tested yet. Lists the machine (host) artifacts among a
//  set of documents — registry hives, event logs, $MFT, shortcuts, jump lists, Prefetch, Amcache, login
//  records, shell history, knowledgeC, extraction manifests — for the case's "Machine artifacts" list.
//  Read-only.
//

import Foundation

public actor HostArtifactRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public struct Row: Sendable, Hashable, Identifiable {
        public let id: UUID            // knowledge object
        public let sourceType: SourceType
        public let fileName: String
    }

    public func hostArtifacts(objectIDs: Set<UUID>) async throws -> [Row] {
        var out: [Row] = []
        let ids = Array(objectIDs)
        for start in stride(from: 0, to: ids.count, by: 300) {
            let chunk = Array(ids[start..<min(start + 300, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.query("""
                SELECT ko.id, ko.source_type, f.url FROM knowledge_objects ko
                JOIN files f ON f.id = ko.file_id WHERE ko.id IN (\(marks));
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let raw = r.string(1), let type = SourceType(rawValue: raw),
                      type.category == .hostArtifact else { continue }
                let name = r.string(2).flatMap { URL(string: $0)?.lastPathComponent ?? ($0 as NSString).lastPathComponent } ?? "(unnamed)"
                out.append(Row(id: id, sourceType: type, fileName: name))
            }
        }
        return out.sorted { ($0.sourceType.rawValue, $0.fileName) < ($1.sourceType.rawValue, $1.fileName) }
    }
}
