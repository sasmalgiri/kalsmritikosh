//
//  SummariesRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor SummariesRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ summary: Summary) async throws {
        let scope = try encoder.encode(summary.scope)
        try await database.exec("""
        INSERT INTO summaries (id, level, length, scope_json, body, produced_at, model_id, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(summary.id),
            .text(summary.level.rawValue),
            .text(summary.length.rawValue),
            .text(String(data: scope, encoding: .utf8) ?? "null"),
            .text(summary.body),
            .date(summary.producedAt),
            .optionalText(summary.modelID),
            .real(summary.confidence.value)
        ])
    }

    public func listByLevel(_ level: Summary.Level, limit: Int = 200) async throws -> [Summary] {
        let rows = try await database.query("""
        SELECT id, level, length, scope_json, body, produced_at, model_id, confidence
        FROM summaries WHERE level = ?
        ORDER BY produced_at DESC
        LIMIT ?;
        """, [.text(level.rawValue), .integer(Int64(limit))])
        return rows.compactMap(decodeRow)
    }

    private func decodeRow(_ row: SQLRow) -> Summary? {
        guard
            let id = row.uuid(0),
            let levelRaw = row.string(1),
            let level = Summary.Level(rawValue: levelRaw),
            let lengthRaw = row.string(2),
            let length = Summary.Length(rawValue: lengthRaw),
            let scopeJSON = row.string(3),
            let body = row.string(4),
            let produced = row.date(5),
            let conf = row.double(7),
            let data = scopeJSON.data(using: .utf8),
            let scope = try? decoder.decode(Summary.Scope.self, from: data)
        else { return nil }
        return Summary(
            id: id,
            level: level,
            length: length,
            scope: scope,
            body: body,
            producedAt: produced,
            modelID: row.string(6),
            confidence: Confidence(conf)
        )
    }
}
