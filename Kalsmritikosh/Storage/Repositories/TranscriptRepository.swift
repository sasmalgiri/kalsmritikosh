//
//  TranscriptRepository.swift
//  Kalsmritikosh
//
//  Persona features (F8). Persists timecoded transcript segments produced on
//  demand from the transcript UI. A re-transcription REPLACES a source's
//  segments wholesale (deterministic). Speaker assignment, quote marking, and
//  review state are user edits — low-confidence ASR stays visible and is never
//  promoted to fact (§13).
//

import Foundation

public actor TranscriptRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Replace all segments for a source (a fresh transcription supersedes the
    /// previous one). User edits are lost on re-transcribe by design — the raw
    /// audio is the source of truth.
    public func replaceSegments(forSource fileID: UUID, _ segments: [TranscriptSegment]) async throws {
        try await database.exec("DELETE FROM transcript_segments WHERE source_file_id = ?;", [.uuid(fileID)])
        for seg in segments { try await insert(seg) }
    }

    public func insert(_ seg: TranscriptSegment) async throws {
        try await database.exec("""
        INSERT INTO transcript_segments
            (id, source_file_id, source_url, ordinal, start_time, end_time, speaker,
             speaker_confidence, text, asr_confidence, review_state, marked_quote, engine, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(seg.id),
            .uuid(seg.sourceFileID),
            .text(seg.sourceURL),
            .integer(Int64(seg.ordinal)),
            .real(seg.start),
            .real(seg.end),
            seg.speaker.map { .text($0) } ?? .null,
            seg.speakerConfidence.map { .real($0) } ?? .null,
            .text(seg.text),
            .real(seg.asrConfidence),
            .text(seg.reviewState),
            .integer(seg.markedQuote ? 1 : 0),
            .text(seg.engine),
            .real(seg.createdAt.timeIntervalSince1970)
        ])
    }

    public func segments(forSource fileID: UUID) async throws -> [TranscriptSegment] {
        let rows = try await database.query("""
        SELECT id, source_file_id, source_url, ordinal, start_time, end_time, speaker,
               speaker_confidence, text, asr_confidence, review_state, marked_quote, engine, created_at
        FROM transcript_segments WHERE source_file_id = ? ORDER BY ordinal ASC;
        """, [.uuid(fileID)])
        return rows.compactMap(decode)
    }

    /// Distinct transcribed sources (for the picker): file id, url, segment count.
    public func transcribedSources() async throws -> [(fileID: UUID, url: String, count: Int)] {
        let rows = try await database.query("""
        SELECT source_file_id, source_url, COUNT(*) AS c
        FROM transcript_segments
        GROUP BY source_file_id
        ORDER BY MAX(created_at) DESC;
        """)
        return rows.compactMap { row in
            guard let id = row.uuid(0), let url = row.string(1), let c = row.int(2) else { return nil }
            return (id, url, Int(c))
        }
    }

    /// FTS search over segment text (optionally within one source).
    public func search(_ query: String, inSource fileID: UUID? = nil, limit: Int = 100) async throws -> [TranscriptSegment] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var sql = """
        SELECT s.id, s.source_file_id, s.source_url, s.ordinal, s.start_time, s.end_time, s.speaker,
               s.speaker_confidence, s.text, s.asr_confidence, s.review_state, s.marked_quote, s.engine, s.created_at
        FROM transcript_segments s
        JOIN transcript_segments_fts ON transcript_segments_fts.rowid = s.rowid
        WHERE transcript_segments_fts.text MATCH ?
        """
        var binds: [SQLValue] = [.text(trimmed)]
        if let fileID { sql += " AND s.source_file_id = ?"; binds.append(.uuid(fileID)) }
        sql += " ORDER BY rank LIMIT ?;"
        binds.append(.integer(Int64(limit)))
        let rows = try await database.query(sql, binds)
        return rows.compactMap(decode)
    }

    public func setSpeaker(segmentID: UUID, speaker: String?) async throws {
        try await database.exec(
            "UPDATE transcript_segments SET speaker = ? WHERE id = ?;",
            [speaker.map { .text($0) } ?? .null, .uuid(segmentID)]
        )
    }

    /// Rename / merge a speaker across a whole source (§13 rename/merge).
    public func renameSpeaker(forSource fileID: UUID, from old: String?, to new: String) async throws {
        if let old {
            try await database.exec(
                "UPDATE transcript_segments SET speaker = ? WHERE source_file_id = ? AND speaker = ?;",
                [.text(new), .uuid(fileID), .text(old)]
            )
        } else {
            try await database.exec(
                "UPDATE transcript_segments SET speaker = ? WHERE source_file_id = ? AND speaker IS NULL;",
                [.text(new), .uuid(fileID)]
            )
        }
    }

    public func setMarkedQuote(segmentID: UUID, _ marked: Bool) async throws {
        try await database.exec(
            "UPDATE transcript_segments SET marked_quote = ? WHERE id = ?;",
            [.integer(marked ? 1 : 0), .uuid(segmentID)]
        )
    }

    public func setReviewState(segmentID: UUID, _ state: String) async throws {
        try await database.exec(
            "UPDATE transcript_segments SET review_state = ? WHERE id = ?;",
            [.text(state), .uuid(segmentID)]
        )
    }

    public func markedQuotes(forSource fileID: UUID) async throws -> [TranscriptSegment] {
        let rows = try await database.query("""
        SELECT id, source_file_id, source_url, ordinal, start_time, end_time, speaker,
               speaker_confidence, text, asr_confidence, review_state, marked_quote, engine, created_at
        FROM transcript_segments WHERE source_file_id = ? AND marked_quote = 1 ORDER BY ordinal ASC;
        """, [.uuid(fileID)])
        return rows.compactMap(decode)
    }

    private func decode(_ row: SQLRow) -> TranscriptSegment? {
        guard
            let id = row.uuid(0),
            let fileID = row.uuid(1),
            let url = row.string(2),
            let ordinal = row.int(3),
            let start = row.double(4),
            let end = row.double(5),
            let text = row.string(8),
            let createdRaw = row.double(13)
        else { return nil }
        return TranscriptSegment(
            id: id,
            sourceFileID: fileID,
            sourceURL: url,
            ordinal: Int(ordinal),
            start: start,
            end: end,
            speaker: row.string(6),
            speakerConfidence: row.double(7),
            text: text,
            asrConfidence: row.double(9) ?? 0,
            reviewState: row.string(10) ?? "unreviewed",
            markedQuote: (row.int(11) ?? 0) != 0,
            engine: row.string(12) ?? "",
            createdAt: Date(timeIntervalSince1970: createdRaw)
        )
    }
}
