//
//  AnswerPathExplainer.swift
//  Kalsmritikosh
//
//  I-11 — "How this answer was found", in plain language. Turns the captured
//  ReasoningTrace (layers consulted, where retrieval stopped, counts, AI calls,
//  assumptions, uncertainties) into short sentences a non-technical user can
//  follow. No identifiers, no internals; the raw trace stays under Technical
//  details. Pure.
//

import Foundation

public nonisolated struct AnswerPathStep: Sendable, Equatable, Identifiable {
    public var id: String { text }
    public let symbol: String
    public let text: String
}

public nonisolated enum AnswerPathExplainer {

    /// Plain names for the retrieval layers, in the ledger's priority order.
    static let layerNames: [String: String] = [
        "memory": "what the ledger already knows",
        "timeline": "the timeline of dated events",
        "entity": "people and organisations",
        "entities": "people and organisations",
        "fts": "a keyword search of the text",
        "metadata": "file details such as dates and senders",
        "summary": "document summaries",
        "summaries": "document summaries",
        "graph": "relationships between people and things",
        "vector": "a meaning-based search",
        "facts": "facts read from your documents",
        "genericFacts": "facts read from your documents",
    ]

    static func plainLayer(_ raw: String) -> String {
        let key = raw.lowercased()
        for (k, v) in layerNames where key.contains(k.lowercased()) { return v }
        return raw
    }

    public static func explain(trace: ReasoningTrace?, citations: Int, refused: Bool,
                               contradictions: Int) -> [AnswerPathStep] {
        guard let trace else {
            return [AnswerPathStep(symbol: "questionmark.circle",
                                   text: "This answer was made before the app recorded how answers are found.")]
        }
        var steps: [AnswerPathStep] = []
        var looked: [String] = []
        for l in trace.retrievalLayers {
            let p = plainLayer(l)
            if !looked.contains(p) { looked.append(p) }
        }
        if !looked.isEmpty {
            steps.append(.init(symbol: "magnifyingglass",
                               text: "Looked in \(ListFormatter.localizedString(byJoining: looked))."))
        }
        if let stop = trace.shortCircuitedAt {
            steps.append(.init(symbol: "checkmark.circle",
                               text: "Stopped early at \(plainLayer(stop)) because it already had a direct answer."))
        }
        let c = trace.retrievalCounts
        var found: [String] = []
        if c.events > 0 { found.append("\(c.events) dated event\(c.events == 1 ? "" : "s")") }
        if c.entities > 0 { found.append("\(c.entities) person or organisation record\(c.entities == 1 ? "" : "s")") }
        if c.genericFacts > 0 { found.append("\(c.genericFacts) fact\(c.genericFacts == 1 ? "" : "s")") }
        if c.chunks > 0 { found.append("\(c.chunks) passage\(c.chunks == 1 ? "" : "s")") }
        if c.relationships > 0 { found.append("\(c.relationships) relationship\(c.relationships == 1 ? "" : "s")") }
        steps.append(.init(symbol: "tray.full",
                           text: found.isEmpty ? "Found nothing that matched." : "Found \(ListFormatter.localizedString(byJoining: found))."))
        if refused {
            steps.append(.init(symbol: "hand.raised",
                               text: "Did not answer, because the evidence check found nothing in your documents that supports an answer."))
        } else {
            steps.append(.init(symbol: "checkmark.seal",
                               text: "Kept \(citations) source\(citations == 1 ? "" : "s") that passed the evidence check; anything the evidence did not support was left out."))
        }
        if contradictions > 0 {
            steps.append(.init(symbol: "exclamationmark.triangle",
                               text: "Found \(contradictions) disagreement\(contradictions == 1 ? "" : "s") between sources and shows both sides."))
        }
        let ai = trace.llmPurposes.count
        steps.append(.init(symbol: "cpu",
                           text: ai == 0 ? "Used no AI: the answer comes straight from the ledger."
                                         : "Used the AI \(ai) time\(ai == 1 ? "" : "s"), only to word the answer from the evidence."))
        for u in trace.uncertainties.prefix(3) {
            steps.append(.init(symbol: "questionmark.diamond", text: "Uncertain: \(u)"))
        }
        for a in trace.assumptions.prefix(2) {
            steps.append(.init(symbol: "lightbulb", text: "Assumed: \(a)"))
        }
        return steps
    }
}
