//
//  IntentDetector.swift
//  Kalsmritikosh
//
//  Rule-based intent detector. Looks at the question shape and known
//  trigger phrases. Returns a structured UserIntent; an LLM-backed
//  detector swaps in once a router model is available.
//

import Foundation

public struct RuleIntentDetector: IntentDetector {
    public nonisolated init() {}

    public func detect(question: String) async throws -> UserIntent {
        let q = question.lowercased()
        let kind = inferKind(q)
        let scope = inferScope(question)
        let hints = extractHints(question)
        // G2-TEMPORAL-GRAMMAR — surface a real Timeframe from natural-
        // language date expressions ("April 2024", "last week",
        // "between April and June 2024") so downstream retrieval can
        // filter events / chunks by date instead of treating every
        // question as timeframe=nil.
        let timeframe = DateGrammar.parse(question)?.timeframe
        return UserIntent(
            kind: kind,
            scope: scope,
            timeframe: timeframe,
            entityHints: hints,
            rawQuestion: question
        )
    }

    private func inferKind(_ q: String) -> UserIntent.Kind {
        // "What changed this week / month / since X" is a temporal-delta
        // question. We route it to executiveBriefing so the brain can
        // surface a WeeklyBriefing if one is wired in.
        if q.contains("what changed") || q.contains("changes this week") ||
           q.contains("changes this month") || q.contains("what's new") ||
           q.contains("whats new") {
            return .executiveBriefing
        }
        if q.contains("reconstruct") || q.contains("show history") || q.contains("what happened") {
            if q.contains("project") { return .reconstructProject }
            if q.contains("relationship") || q.contains("with ") { return .reconstructRelationship }
            return .reconstructTimeline
        }
        // Why / when / how questions about projects and people are
        // reconstruction-shaped — they need the timeline and the
        // multi-expert pipeline, not a one-shot factual lookup.
        let reconstructionVerbs = ["why", "how", "when", "explain", "delayed", "slipped", "blocked", "happened"]
        let isReconstructionShaped = reconstructionVerbs.contains { q.contains($0) }
        if isReconstructionShaped {
            if q.contains("project") { return .reconstructProject }
            if q.contains("supplier") || q.contains("vendor") || q.contains("client")
               || q.contains("company") || q.contains("relationship") { return .reconstructRelationship }
            return .reconstructTimeline
        }
        if q.contains("brief") || q.contains("summarize everything") {
            return .executiveBriefing
        }
        if q.contains("risk") {
            return .riskDetection
        }
        if q.contains("missing") || q.contains("don't know") || q.contains("gaps") {
            return .missingInformation
        }
        if q.contains("search") || q.contains("find") || q.contains("look up") {
            return .semanticSearch
        }
        return .factualLookup
    }

    private func inferScope(_ raw: String) -> UserIntent.Scope {
        if let match = match(raw, pattern: #"project\s+([A-Z][\w\-]+)"#) {
            return .project(match)
        }
        if let match = match(raw, pattern: #"with\s+([A-Z][\w\s&\-\.]+)"#) {
            return .organization(match.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .global
    }

    private func extractHints(_ raw: String) -> [String] {
        // Take capitalized multi-word noun phrases as soft entity hints.
        var hints: [String] = []
        let pattern = #"([A-Z][\w&\-\.]+(?:\s+[A-Z][\w&\-\.]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        for m in regex.matches(in: raw, range: range) {
            if let r = Range(m.range, in: raw) {
                let s = String(raw[r])
                if s.count > 2 { hints.append(s) }
            }
        }
        return Array(Set(hints))
    }

    private func match(_ raw: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        if let m = regex.firstMatch(in: raw, range: range),
           m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: raw) {
            return String(raw[r])
        }
        return nil
    }
}
