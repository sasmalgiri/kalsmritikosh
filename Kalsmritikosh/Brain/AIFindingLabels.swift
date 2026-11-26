//
//  AIFindingLabels.swift
//  Kalsmritikosh
//
//  AI split AI-49 (owner 2026-11-23/24) — the screens say who made what they show. Inside a case, the AI case picture's
//  records (case_ai_records) are shown labelled "Found by AI · quote checked". Anything the app's rules made (outside a
//  case, or where the AI has recorded nothing yet) is labelled "Hint (rule-made, not checked)" and never presented as a
//  fact. The Quality strip counts only conflicts the AI found and the app checked (both quotes verbatim in their documents).
//
//  No model names here; nothing here calls a model. Pure labelling and filtering.
//

import Foundation

public nonisolated enum AIFindingLabels {
    /// On an item the AI recorded and the app quote-checked.
    public static let ai = "Found by AI · quote checked"
    /// On an item the app's rules made (a hint, never a fact).
    public static let hint = "Hint (rule-made, not checked)"
    /// The one-line explanation under a list of hints (plain words).
    public static let hintExplanation = "Made by the app's rules from words in your documents. A hint is not checked and is not a finding: open the source to check it, or ask the AI inside a case."
    /// The one-line explanation above a list of AI findings.
    public static let aiExplanation = "Found by the AI while reading this case. The app checked every quote word for word in its document."

    /// What a screen shows: the AI's records when a case has them, otherwise the rule items as hints.
    public enum Source: String, Sendable, Equatable {
        case aiRecords
        case ruleHints
        public var label: String { self == .aiRecords ? AIFindingLabels.ai : AIFindingLabels.hint }
    }

    /// Which source a screen shows: the AI's records when there are any (inside a case) and the rules no longer decide;
    /// otherwise hints. With the retired rule path switched back on, the rule items are shown as before — still labelled.
    public static func source(aiRecordCount: Int) -> Source {
        aiRecordCount > 0 && !CaseAIUnderstanding.rulesDecide ? .aiRecords : .ruleHints
    }

    /// A rule-made line, labelled as a hint (idempotent).
    public static func hinted(_ text: String) -> String {
        text.hasPrefix(hint) ? text : hint + ": " + text
    }

    // MARK: - Conflicts (the Quality strip)

    /// The marker an AI-verified conflict carries in its description.
    public static let conflictMarker = "(" + CaseAIRecord.checkedLabel + ")"

    /// An AI conflict record as an answer's contradiction (both quotes checked by the app when it was recorded).
    public static func contradiction(_ r: CaseAIRecord) -> VerifiedAnswer.Contradiction {
        VerifiedAnswer.Contradiction(description: r.text + " " + conflictMarker, claimA: r.quote ?? "", claimB: r.quoteB ?? "")
    }

    /// The answer with the AI's conflict records added to its contradictions (not already there).
    public static func withAIConflicts(_ a: VerifiedAnswer, _ records: [CaseAIRecord]) -> VerifiedAnswer {
        let add = records.filter { $0.kind == .conflict }.map(contradiction).filter { !a.contradictions.contains($0) }
        guard !add.isEmpty else { return a }
        var out = VerifiedAnswer(body: a.body, answerText: a.answerText, intentKind: a.intentKind, citations: a.citations,
                                 confidence: a.confidence, contradictions: a.contradictions + add, refused: a.refused,
                                 refusalReason: a.refusalReason, report: a.report, walkSteps: a.walkSteps, source: a.source,
                                 reasoningTrace: a.reasoningTrace, answerState: a.answerState, ledgerAnswerID: a.ledgerAnswerID)
        out.resolvedQuestion = a.resolvedQuestion
        out.ledgerState = a.ledgerState
        return out
    }
}

// MARK: - What each screen shows from the AI case picture

extension AIFindingLabels {
    /// Which part of the AI case picture a screen shows.
    public enum Lens: String, Sendable, CaseIterable {
        /// Timeline, History: the AI's dated events, earliest first.
        case events
        /// Relationship graph: the AI's relationships.
        case relationships
        /// People pages: the people the AI recorded, with their roles.
        case people
        /// Organisation pages: the organisations the AI recorded.
        case organisations
        /// Fact status: the AI's facts with their status (found / in conflict / hypothesis).
        case facts
        /// Insights, Quality strip: the AI's conflicts (both quotes checked).
        case conflicts
        /// Case story, Dossier: the AI's dated events as the story, with quotes.
        case story
    }

    /// One line a screen shows from the AI case picture (always labelled `AIFindingLabels.ai`).
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let title: String
        public let detail: String
        public let label: String
    }

    static func matches(_ r: CaseAIRecord, _ subject: String?) -> Bool {
        guard let subject, !subject.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let k = VerifiedRecordExtractor.normalized(subject)
        let hay = [r.text, r.from ?? "", r.to ?? "", r.quote ?? "", r.quoteB ?? ""] + r.supporting
        return hay.contains { VerifiedRecordExtractor.normalized($0).contains(k) }
    }

    static func quoted(_ q: String?) -> String {
        guard let q, !q.isEmpty else { return "" }
        return "\u{201C}" + String(q.prefix(200)) + "\u{201D}"
    }

    /// The rows a screen shows for `lens`, from the AI's records, optionally only those about `subject`.
    public static func rows(_ lens: Lens, records: [CaseAIRecord], subject: String? = nil) -> [Row] {
        let mine = records.filter { matches($0, subject) }
        switch lens {
        case .events, .story:
            return CaseAIUnderstanding.timeline(mine).map {
                Row(id: $0.id, title: ($0.dateText ?? "Undated") + " — " + $0.text, detail: quoted($0.quote), label: ai)
            }
        case .relationships:
            return CaseAIUnderstanding.relationships(mine).map { r in
                let who = [r.from, r.relation, r.to].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " → ")
                return Row(id: r.id, title: who.isEmpty ? r.text : who, detail: quoted(r.quote), label: ai)
            }
        case .people, .organisations:
            let parties = lens == .people ? CaseAIUnderstanding.people(mine) : CaseAIUnderstanding.organisations(mine)
            return parties.compactMap { p in
                guard let id = p.records.first else { return nil }
                var detail = p.roles.isEmpty ? "No role recorded yet" : p.roles.joined(separator: "; ")
                if !p.alsoWrittenAs.isEmpty { detail += " · also written as " + p.alsoWrittenAs.joined(separator: ", ") }
                return Row(id: id, title: p.name, detail: detail, label: ai)
            }
        case .facts:
            return mine.filter { $0.kind == .fact || $0.kind == .hypothesis }.map { r in
                let status = CaseAIUnderstanding.status(of: r, in: records)
                return Row(id: r.id, title: r.text, detail: status.rawValue.prefix(1).uppercased() + status.rawValue.dropFirst()
                           + (r.quote.map { " · " + quoted($0) } ?? ""), label: status == .hypothesis ? "AI hypothesis — not a finding" : ai)
            }
        case .conflicts:
            return CaseAIUnderstanding.conflicts(mine).map {
                Row(id: $0.id, title: $0.text, detail: quoted($0.quote) + " vs " + quoted($0.quoteB), label: ai)
            }
        }
    }
}

extension VerifiedAnswer.Contradiction {
    /// AI-49 — found by the AI and checked by the app (both quotes verbatim). Everything else is a rule-made hint.
    public nonisolated var isAIVerified: Bool { description.contains(AIFindingLabels.conflictMarker) }
}

extension VerifiedAnswer {
    /// AI-49 — the conflicts the Quality strip counts: the AI's, quote checked.
    public nonisolated var aiVerifiedConflicts: [Contradiction] { contradictions.filter(\.isAIVerified) }
    /// AI-49 — rule-made conflict hints (shown only as hints, never counted).
    public nonisolated var conflictHints: [Contradiction] { contradictions.filter { !$0.isAIVerified } }
}
