//
//  InvestigationsRepository.swift
//  Kalsmritikosh
//
//  HISTORY Phase I.B — persisted Plan-and-Solve investigations.
//  Every finished investigation (from InvestigationRunner) lands in
//  this store so the user can re-read past inquiries in the Notebook
//  tab without re-running the LLM.
//
//  Storage shape (see v25 migration):
//    investigations(id, question, synthesis, created_at, finished_at)
//    investigation_steps(id, investigation_id, ordinal, question,
//                        answer_body, answer_confidence,
//                        answer_citations_json, created_at)
//
//  The per-step VerifiedAnswer is stored denormalized — just enough
//  for the notebook detail view to show the body, confidence, and
//  citation object IDs. Re-running an investigation to refresh the
//  state lives outside the repository.
//

import Foundation

public actor InvestigationsRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Writes

    /// Persist a finished investigation. Idempotent on `id`: if the
    /// investigation already exists, its rows are replaced (the
    /// cascade on `investigations.id` drops the old step rows).
    public func save(_ investigation: Investigation) async throws {
        try await database.exec("SAVEPOINT atlas_investigation_save;")
        do {
            try await database.exec(
                "DELETE FROM investigations WHERE id = ?;",
                [.uuid(investigation.id)]
            )
            try await database.exec("""
            INSERT INTO investigations (id, question, synthesis, created_at, finished_at)
            VALUES (?, ?, ?, ?, ?);
            """, [
                .uuid(investigation.id),
                .text(investigation.question),
                investigation.synthesis.map { .text($0) } ?? .null,
                .real(investigation.createdAt.timeIntervalSince1970),
                investigation.synthesis != nil
                    ? .real(Date().timeIntervalSince1970)
                    : .null
            ])
            for (idx, step) in investigation.steps.enumerated() {
                let body = step.answer.map { $0.answerText ?? $0.body }
                let confidence = step.answer?.confidence.value
                let citationIDs = step.answer?.citations.map(\.objectID) ?? []
                let citationsData = (try? encoder.encode(citationIDs)) ?? Data("[]".utf8)
                let citationsJSON = String(data: citationsData, encoding: .utf8) ?? "[]"
                try await database.exec("""
                INSERT INTO investigation_steps
                    (id, investigation_id, ordinal, question, answer_body,
                     answer_confidence, answer_citations_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, [
                    .uuid(step.id),
                    .uuid(investigation.id),
                    .integer(Int64(idx)),
                    .text(step.question),
                    body.map { .text($0) } ?? .null,
                    confidence.map { .real($0) } ?? .null,
                    .text(citationsJSON),
                    .real(step.createdAt.timeIntervalSince1970)
                ])
            }
            try await database.exec("RELEASE SAVEPOINT atlas_investigation_save;")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT atlas_investigation_save;")
            try? await database.exec("RELEASE SAVEPOINT atlas_investigation_save;")
            throw error
        }
    }

    public func delete(_ id: UUID) async throws {
        // Cascade drops the step rows.
        try await database.exec(
            "DELETE FROM investigations WHERE id = ?;",
            [.uuid(id)]
        )
    }

    // MARK: - Reads

    /// Lightweight list — header rows only (id + question + synthesis
    /// + timestamps). The Notebook list view uses this; the detail
    /// view calls `load(_:)` for the full record including steps.
    public func recent(limit: Int = 100) async throws -> [InvestigationHeader] {
        let rows = try await database.query("""
        SELECT id, question, synthesis, created_at, finished_at
        FROM investigations
        ORDER BY created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { row -> InvestigationHeader? in
            guard let id = row.uuid(0),
                  let question = row.string(1),
                  let createdAtRaw = row.double(3) else { return nil }
            let finishedAt = row.double(4).map { Date(timeIntervalSince1970: $0) }
            return InvestigationHeader(
                id: id,
                question: question,
                synthesis: row.string(2),
                createdAt: Date(timeIntervalSince1970: createdAtRaw),
                finishedAt: finishedAt
            )
        }
    }

    /// Full hydrate — investigation + ordered steps. The step rows
    /// recreate a VerifiedAnswer only deep enough for the notebook
    /// detail view (body + confidence + citation object IDs); the
    /// full retrieval set is NOT re-materialized.
    public func load(_ id: UUID) async throws -> Investigation? {
        let invRows = try await database.query("""
        SELECT question, synthesis, created_at
        FROM investigations WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        guard let inv = invRows.first,
              let question = inv.string(0),
              let createdAtRaw = inv.double(2) else { return nil }
        let synthesis = inv.string(1)

        let stepRows = try await database.query("""
        SELECT id, ordinal, question, answer_body, answer_confidence,
               answer_citations_json, created_at
        FROM investigation_steps
        WHERE investigation_id = ?
        ORDER BY ordinal ASC;
        """, [.uuid(id)])
        let steps: [InvestigationStep] = stepRows.compactMap { row in
            guard let stepID = row.uuid(0),
                  let qText = row.string(2),
                  let createdRaw = row.double(6) else { return nil }
            let body = row.string(3) ?? ""
            let conf = row.double(4) ?? 0.0
            let citationsJSON = row.string(5) ?? "[]"
            let citationIDs: [KnowledgeObject.ID] = {
                guard let data = citationsJSON.data(using: .utf8) else { return [] }
                return (try? decoder.decode([KnowledgeObject.ID].self, from: data)) ?? []
            }()
            let answer: VerifiedAnswer? = body.isEmpty ? nil : VerifiedAnswer(
                body: body,
                answerText: body,
                citations: citationIDs.map { id in
                    VerifiedAnswer.Citation(objectID: id, snippet: "")
                },
                confidence: Confidence(conf)
            )
            return InvestigationStep(
                id: stepID,
                question: qText,
                answer: answer,
                createdAt: Date(timeIntervalSince1970: createdRaw)
            )
        }
        return Investigation(
            id: id,
            question: question,
            steps: steps,
            synthesis: synthesis,
            createdAt: Date(timeIntervalSince1970: createdAtRaw)
        )
    }

    public func count() async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM investigations;",
            []
        )
        return Int(rows.first?.int(0) ?? 0)
    }
}

/// Lightweight list row used by the Notebook tab — avoids hydrating
/// the per-step VerifiedAnswer when only the header is rendered.
public struct InvestigationHeader: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let question: String
    public let synthesis: String?
    public let createdAt: Date
    public let finishedAt: Date?
}
