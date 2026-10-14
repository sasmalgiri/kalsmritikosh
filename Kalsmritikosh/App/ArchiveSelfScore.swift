//
//  ArchiveSelfScore.swift
//  Kalsmritikosh
//
//  I-7 — measured accuracy on the user's OWN archive. Every AI tool says "may be
//  inaccurate"; this says how accurate it is here, on this ledger.
//
//  Builds checkable questions from facts the ledger already proves (a subject,
//  a field and its stored value — so the right answer is known in advance),
//  plus control questions about references that cannot exist (the right answer
//  is a refusal). Each is asked through the SAME answer path and access scope
//  the Ask screen uses. An answer counts as correct only if it is cited AND
//  contains the proven value.
//
//  The scorecard is kept, and answers are grouped by the confidence they showed,
//  so an answer can say "on your archive, answers this confident were right
//  8 of 10 times". Calibration needs enough samples per band; below that it
//  says nothing rather than quote a meaningless ratio.
//
//  Cost: real answers with real model calls, so it is a deliberate action
//  (Settings ▸ Diagnostics), bounded by `maxQuestions`.
//

import Foundation
import os

public struct ArchiveScorecard: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable {
            case correct, wrongValue, uncited, refusedWrongly, correctlyRefused, fabricated
        }
        public let question: String
        public let expected: String?
        public let outcome: Outcome
        public let confidence: Double
    }
    public struct Band: Codable, Sendable, Equatable {
        public let lower: Double
        public let upper: Double
        public let answered: Int
        public let correct: Int
    }

    public let ranAt: Date
    public let items: [Item]
    public let bands: [Band]

    public var answerable: [Item] { items.filter { $0.expected != nil } }
    public var controls: [Item] { items.filter { $0.expected == nil } }
    public var correctCount: Int { answerable.filter { $0.outcome == .correct }.count }
    public var correctRefusals: Int { controls.filter { $0.outcome == .correctlyRefused }.count }

    public var summary: String {
        var lines = ["Right on \(correctCount) of \(answerable.count) questions your ledger can prove."]
        lines.append("Refused \(correctRefusals) of \(controls.count) questions that have no answer in your archive.")
        let fab = controls.filter { $0.outcome == .fabricated }.count
        if fab > 0 { lines.append("⚠️ Answered \(fab) question\(fab == 1 ? "" : "s") that had no evidence — report this.") }
        return lines.joined(separator: "\n")
    }
}

public enum ArchiveSelfScore {

    /// Minimum answered questions in a confidence band before its ratio is shown.
    public static let minBandSamples = 5
    static let bandEdges: [Double] = [0, 0.5, 0.7, 0.85, 1.0001]
    private static let storeKey = "kalsmritikosh.selfscore.latest"

    // MARK: - Run

    @MainActor
    public static func run(_ state: AppState, maxQuestions: Int = 20, controls: Int = 3) async throws -> ArchiveScorecard {
        guard let database = state.database else {
            throw NSError(domain: "ArchiveSelfScore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The ledger is not open yet."])
        }
        // One fact per subject so a single document cannot dominate the score.
        let rows = (try? await database.query("""
            SELECT subject_label, field, value FROM generic_facts
            WHERE LENGTH(subject_label) >= 4 AND LENGTH(value) BETWEEN 2 AND 80
            GROUP BY subject_label
            ORDER BY COALESCE(MAX(source_count), 1) DESC, subject_label ASC
            LIMIT ?;
            """, [.integer(Int64(maxQuestions))])) ?? []

        var asks: [(q: String, expected: String?)] = []
        for r in rows {
            guard let subject = r.string(0), let field = r.string(1), let value = r.string(2) else { continue }
            asks.append(("What is the \(field.replacingOccurrences(of: "_", with: " ")) of \(subject)?", value))
        }
        for _ in 0..<controls {
            let ref = "Reference \(Int.random(in: 70_000_000...79_999_999))-QZX"
            asks.append(("What was decided in \(ref)?", nil))
        }

        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        var items: [ArchiveScorecard.Item] = []
        for a in asks {
            let d = await state.brain.answerWithDiagnostics(question: a.q, access: access)
            let ans = d.answer
            let text = ans.answerText ?? ans.body
            let outcome: ArchiveScorecard.Item.Outcome
            if let expected = a.expected {
                if ans.refused { outcome = .refusedWrongly }
                else if ans.citations.isEmpty { outcome = .uncited }
                else if contains(text, expected) { outcome = .correct }
                else { outcome = .wrongValue }
            } else {
                outcome = ans.refused ? .correctlyRefused : .fabricated
            }
            items.append(.init(question: a.q, expected: a.expected, outcome: outcome, confidence: ans.confidence.value))
        }

        let card = ArchiveScorecard(ranAt: Date(), items: items, bands: bands(for: items))
        save(card)
        KalsmritikoshLog.app.info("ArchiveSelfScore: \(card.correctCount, privacy: .public)/\(card.answerable.count, privacy: .public) correct, \(card.correctRefusals, privacy: .public)/\(card.controls.count, privacy: .public) refusals")
        return card
    }

    // MARK: - Calibration

    static func bands(for items: [ArchiveScorecard.Item]) -> [ArchiveScorecard.Band] {
        let answered = items.filter { $0.expected != nil && $0.outcome != .refusedWrongly }
        return zip(bandEdges, bandEdges.dropFirst()).map { lo, hi in
            let inBand = answered.filter { $0.confidence >= lo && $0.confidence < hi }
            return .init(lower: lo, upper: min(hi, 1), answered: inBand.count,
                         correct: inBand.filter { $0.outcome == .correct }.count)
        }
    }

    /// "On your archive, answers this confident were right 8 of 10 times", or nil
    /// when there is no scorecard or too few samples in that band.
    public static func calibratedNote(confidence: Double) -> String? {
        guard ProductModuleFlags.isEnabled(.archiveSelfScore), let card = latest() else { return nil }
        guard let band = card.bands.first(where: { confidence >= $0.lower && confidence < max($0.upper, 1.0001) }),
              band.answered >= minBandSamples else { return nil }
        return "On your archive, answers this confident were right \(band.correct) of \(band.answered) times."
    }

    // MARK: - Matching

    /// Case- and spacing-insensitive containment; numbers compare without separators.
    static func contains(_ answer: String, _ expected: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: ",", with: "")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        let e = norm(expected)
        return !e.isEmpty && norm(answer).contains(e)
    }

    // MARK: - Persistence

    public static func latest() -> ArchiveScorecard? {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(ArchiveScorecard.self, from: data)
    }

    static func save(_ card: ArchiveScorecard) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(card), forKey: storeKey)
        } catch {
            KalsmritikoshLog.app.error("ArchiveSelfScore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
