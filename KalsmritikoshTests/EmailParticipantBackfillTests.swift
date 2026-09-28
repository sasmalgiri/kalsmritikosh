//
//  EmailParticipantBackfillTests.swift
//  KalsmritikoshTests
//
//  P1.9 — the participant backfill had no app caller AND queried a column that
//  does not exist (ko.metadata; the column is metadata_json), so mail ingested
//  before OPS-005 never got occurrence rows (owner copy: 0). A mailbox THREAD
//  keeps its messages' headers inside t_threadMessages.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.9 — email participant backfill", .serialized)
struct EmailParticipantBackfillTests {

    @Test("A legacy mbox thread gets its participants from t_threadMessages; a second run writes nothing")
    func threadParticipants() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///Sent.mbox"), .text("mbox")])
        let messages = #"[{"from":"Lalan <lalan@khuranaandkhurana.com>","to":"owner@example.com"},{"from":"owner@example.com","cc":"docket@khuranaandkhurana.com"}]"#
        let meta = try String(data: JSONSerialization.data(withJSONObject: [
            "loader": "mbox-thread", "subject": "Hearing notice", "t_threadMessages": messages]), encoding: .utf8)!
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, created_at, updated_at)
        VALUES (?, ?, 'mbox', 'body', ?, 0, 0);
        """, [.uuid(ko), .uuid(fileID), .text(meta)])
        for address in ["lalan@khuranaandkhurana.com", "owner@example.com", "docket@khuranaandkhurana.com"] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, 'emailAddress', ?, ?, ?, 0.9);
            """, [.uuid(UUID()), .text(address), .text(address), .uuid(ko)])
        }

        let backfill = EmailParticipantBackfill(occurrences: EmailParticipantRepository(database: db),
                                                entities: EntitiesRepository(database: db), database: db)
        let first = await backfill.run()
        #expect(first >= 4, "from ×2, to, cc across the thread's messages (got \(first))")
        let roles = Set(try await db.query("SELECT role FROM email_participant_occurrences;", []).compactMap { $0.string(0) })
        #expect(roles.isSuperset(of: ["from", "to", "cc"]))
        #expect(await backfill.run() == 0, "an email that already has occurrences is skipped")
    }
}
