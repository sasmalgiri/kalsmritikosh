//
//  AppState+TimeTravel.swift
//  Kalsmritikosh
//
//  I-5 — "what did we know on date X?" Answers using only evidence whose file
//  date is on or before the chosen day, through the same fail-closed source
//  scope a case uses (nothing later can enter the evidence or the citations),
//  and names the later documents that changed the answer.
//

import Foundation
import os

public struct AsOfResult: Sendable {
    public let date: Date
    public let answer: VerifiedAnswer
    /// Source versions available on that day.
    public let sourcesAvailable: Int
    /// Documents the current answer cites that are dated after the day.
    public let laterDocuments: [String]
}

extension AppState {

    public func answerAsOf(_ date: Date, question: String, current: VerifiedAnswer) async -> AsOfResult? {
        guard ProductModuleFlags.isEnabled(.timeTravel), let database, let investigationAnswers else { return nil }
        // End of the chosen day, in the user's calendar.
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date
        do {
            let rows = try await database.query("""
                SELECT sv.id FROM source_versions sv JOIN files f ON f.id = sv.logical_source_id
                WHERE f.modified_at < ?;
                """, [.real(end.timeIntervalSince1970)])
            let ids = Set(rows.compactMap { $0.uuid(0) })
            let answer = await investigationAnswers.answer(
                scopedTo: ids, question: question, access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
            // Which of today's cited documents did not exist yet?
            let cited = Set(current.citations.map(\.objectID))
            var later: [String] = []
            if !cited.isEmpty {
                let marks = cited.map { _ in "?" }.joined(separator: ",")
                let laterRows = try await database.query("""
                    SELECT DISTINCT f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                    WHERE ko.id IN (\(marks)) AND f.modified_at >= ?;
                    """, cited.map { .uuid($0) } + [.real(end.timeIntervalSince1970)])
                later = laterRows.compactMap { $0.string(0) }.map { URL(string: $0)?.lastPathComponent ?? $0 }
            }
            return AsOfResult(date: date, answer: answer, sourcesAvailable: ids.count, laterDocuments: later)
        } catch {
            KalsmritikoshLog.app.error("As-of answer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
