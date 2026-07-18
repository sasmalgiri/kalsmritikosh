//
//  IngestAttemptsRepository.swift
//  Kalsmritikosh
//
//  A2 §7.3/§7.7 — durable record of each file's ingest outcome, so a failed or
//  skipped ingest is visible and re-tryable instead of silently lost. Append-
//  only: every ingest attempt writes a row; the latest row per URL is the
//  current state. Never throws to the caller — recording is best-effort and
//  must never fail an ingest.
//

import Foundation

public actor IngestAttemptsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The outcome of one ingest attempt for a file.
    public enum Status: String, Sendable {
        case started     // v54 — ingest began; a durable in-progress marker. If
                         // this is still the LATEST status for a URL at boot, the
                         // ingest was interrupted (crash/quit) and is resumable.
        case queryable   // parsed + persisted; answerable
        case unchanged   // hash matched a prior ingest; skipped
        case aliased     // deduped to a canonical copy
        case moved       // same bytes, new location
        case failed      // an error prevented ingest
    }

    public struct Attempt: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let url: String
        public let contentHash: String?
        public let status: String
        public let stage: String?
        public let detail: String?
        public let attemptedAt: Date
    }

    /// Record an attempt outcome. Best-effort; swallows errors.
    public func record(
        url: URL, status: Status, contentHash: String? = nil,
        stage: String? = nil, detail: String? = nil, at when: Date = Date()
    ) async {
        try? await database.exec("""
        INSERT INTO ingest_file_attempts
            (id, url, content_hash, status, stage, detail, attempted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(UUID()),
            .text(url.absoluteString),
            contentHash.map { .text($0) } ?? .null,
            .text(status.rawValue),
            stage.map { .text($0) } ?? .null,
            detail.map { .text($0) } ?? .null,
            .real(when.timeIntervalSince1970)
        ])
    }

    /// v54 resume — URLs whose LATEST attempt is still `.started`, i.e. an
    /// ingest that began but never recorded a terminal outcome (interrupted by a
    /// crash or quit). These are the files to re-ingest on the next launch.
    public func interruptedURLs(limit: Int = 1_000) async -> [URL] {
        let rows = (try? await database.query("""
        SELECT url FROM (
            SELECT url, status,
                   ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
            FROM ingest_file_attempts
        ) WHERE rn = 1 AND status = 'started'
        LIMIT ?;
        """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap { $0.string(0).flatMap(URL.init(string:)) }
    }

    /// Phase 2 recovery — URLs whose LATEST attempt failed and whose extension
    /// is one of `extensions` (lowercased, no dot), e.g. ["doc","xls"]. Used to
    /// re-ingest legacy files that failed before the real OLE2 parsers landed.
    public func failedURLs(matchingExtensions extensions: Set<String>, limit: Int = 5_000) async -> [URL] {
        let rows = (try? await database.query("""
        SELECT url FROM (
            SELECT url, status,
                   ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
            FROM ingest_file_attempts
        ) WHERE rn = 1 AND status = 'failed'
        LIMIT ?;
        """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap { row -> URL? in
            guard let s = row.string(0), let u = URL(string: s) else { return nil }
            return extensions.contains(u.pathExtension.lowercased()) ? u : nil
        }
    }

    /// Count of files whose LATEST attempt failed — a Sources signal.
    public func failedCount() async -> Int {
        let rows = (try? await database.query("""
        SELECT COUNT(*) FROM (
            SELECT url, status,
                   ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
            FROM ingest_file_attempts
        ) WHERE rn = 1 AND status = 'failed';
        """, [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    /// The most recent failed attempts (latest per URL), newest first.
    public func recentFailures(limit: Int = 100) async -> [Attempt] {
        let rows = (try? await database.query("""
        SELECT id, url, content_hash, status, stage, detail, attempted_at FROM (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
            FROM ingest_file_attempts
        ) WHERE rn = 1 AND status = 'failed'
        ORDER BY attempted_at DESC LIMIT ?;
        """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let id = row.uuid(0), let url = row.string(1),
                  let status = row.string(3), let at = row.double(6) else { return nil }
            return Attempt(
                id: id, url: url, contentHash: row.string(2), status: status,
                stage: row.string(4), detail: row.string(5),
                attemptedAt: Date(timeIntervalSince1970: at)
            )
        }
    }
}
