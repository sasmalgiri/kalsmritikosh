//
//  OutboundLogRepository.swift
//  Kalsmritikosh
//
//  O-5 — append-only record of every online send (schema v143).
//

import Foundation

public nonisolated struct OutboundLogEntry: Sendable, Identifiable {
    public let id: UUID
    public let sentAt: Date
    public let provider: String
    public let model: String
    public let host: String
    public let bytesSent: Int
    public let maskedCount: Int
    public let payloadSHA256: String
    public let payloadText: String
    public let responseBytes: Int?
    public let outcome: String
    public let detail: String?
}

public actor OutboundLogRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    public func record(_ e: OutboundLogEntry) async throws {
        try await database.exec("""
            INSERT INTO outbound_log (id, sent_at, provider, model, host, bytes_sent, masked_count,
                                      payload_sha256, payload_text, response_bytes, outcome, detail)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(e.id), .date(e.sentAt), .text(e.provider), .text(e.model), .text(e.host),
                  .integer(Int64(e.bytesSent)), .integer(Int64(e.maskedCount)), .text(e.payloadSHA256),
                  .text(e.payloadText), e.responseBytes.map { .integer(Int64($0)) } ?? .null,
                  .text(e.outcome), e.detail.map { .text($0) } ?? .null])
    }

    /// Bytes actually sent since local midnight (declined/blocked sends count zero).
    public func bytesSentToday() async throws -> Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let v = try await database.query(
            "SELECT COALESCE(SUM(bytes_sent), 0) FROM outbound_log WHERE sent_at >= ? AND outcome IN ('sent','failed');",
            [.real(start)]).first?.int(0) ?? 0
        return Int(v)
    }

    public func recent(limit: Int = 200) async throws -> [OutboundLogEntry] {
        let rows = try await database.query("""
            SELECT id, sent_at, provider, model, host, bytes_sent, masked_count, payload_sha256, payload_text,
                   response_bytes, outcome, detail
            FROM outbound_log ORDER BY sent_at DESC LIMIT ?;
            """, [.integer(Int64(limit))])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let t = r.double(1) else { return nil }
            return OutboundLogEntry(id: id, sentAt: Date(timeIntervalSince1970: t), provider: r.string(2) ?? "",
                                    model: r.string(3) ?? "", host: r.string(4) ?? "", bytesSent: Int(r.int(5) ?? 0),
                                    maskedCount: Int(r.int(6) ?? 0), payloadSHA256: r.string(7) ?? "",
                                    payloadText: r.string(8) ?? "", responseBytes: r.int(9).map { Int($0) },
                                    outcome: r.string(10) ?? "", detail: r.string(11))
        }
    }
}
