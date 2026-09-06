//
//  LedgerTools.swift
//  Kalsmritikosh
//
//  A3 (closing spec) — ASK-THE-LEDGER: the deterministic tools a model may
//  call but never bypass. Every tool is plain code over injected ledger
//  reads; every result is SMALL and ID-BEARING (each id resolves to a real
//  row/block), so a composition that cites a result id can be verified
//  mechanically by the sweep. Models understand, ask, and compose — the
//  tools KNOW.
//

import Foundation

/// One tool result: an id the composition may cite + the payload text the
/// sweep checks names/dates/amounts against.
public struct ToolResult: Sendable, Codable, Equatable, Identifiable {
    public let id: String            // "T1", "T2", … / span ids "S1", …
    public let text: String
    public let objectIDs: [UUID]     // the source documents behind it
}

/// The plan — A3.1. The deterministic router/resolver DERIVES it (primary);
/// an FM-generated plan may act as its twin later (router wins on
/// disagreement). The validating init enforces "cannot name a nonexistent
/// field": an unknown field becomes nil, never a fabricated lookup.
public struct QuestionPlan: Sendable, Codable, Equatable {
    public let shape: QuestionShape.RawValue
    public let subjectMention: String?
    public let field: String?          // validated against FieldRegistry
    public let needsGeneralKnowledge: Bool

    public init(shape: QuestionShape, subjectMention: String?, field: String?,
                needsGeneralKnowledge: Bool = false) {
        self.shape = shape.rawValue
        self.subjectMention = subjectMention
        self.field = field.flatMap { FieldRegistry.isKnown(FactSchemaRegistry.normalizeField($0)) ? FactSchemaRegistry.normalizeField($0) : nil }
        self.needsGeneralKnowledge = needsGeneralKnowledge
    }

    /// The deterministic derivation: router shape + slot field + charter
    /// subject. This IS the primary plan; nothing model-made outranks it.
    public static func derive(question: String, anchors: [Entity]) -> QuestionPlan {
        let shape = QuestionShapeRouter.route(question).shape
        let plan = QueryPlanCompiler().compile(
            intent: UserIntent(kind: .factualLookup, scope: .global, timeframe: nil,
                               entityHints: [], rawQuestion: question),
            category: .fact, queryClass: .ordinary)
        let charter = SubjectResolver.resolve(question: question, anchors: anchors)
        return QuestionPlan(shape: shape,
                            subjectMention: charter.anchors.first.map { SubjectResolver.canon($0) },
                            field: plan.slotFieldIDs.first,
                            needsGeneralKnowledge: shape == .outOfScope)
    }
}

/// The tools, over injected reads. Every closure is deterministic ledger
/// code; the struct itself holds no state and never writes.
public struct LedgerTools: Sendable {
    public let events: @Sendable ([String]) async -> [Event]           // by title tokens
    public let facts: @Sendable (String) async -> [GenericFact]        // by field
    public let chunksForQuestion: @Sendable (String) async -> [RetrievedChunk]

    public init(events: @escaping @Sendable ([String]) async -> [Event],
                facts: @escaping @Sendable (String) async -> [GenericFact],
                chunksForQuestion: @escaping @Sendable (String) async -> [RetrievedChunk]) {
        self.events = events
        self.facts = facts
        self.chunksForQuestion = chunksForQuestion
    }

    /// historyOf — the dated chain for a subject's vocabulary. Small: ≤12
    /// dated lines, each an id-bearing result.
    public func historyOf(question: String) async -> [ToolResult] {
        let terms = EventAnswerComposer.vocabularyTerms(in: question)
        let matched = await events(terms.isEmpty ? ["granted", "filed", "hearing"] : terms)
        let sorted = matched.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }.prefix(12)
        let df = DateFormatter(); df.dateFormat = "d MMMM yyyy"; df.timeZone = TimeZone(identifier: "UTC")
        return sorted.enumerated().map { n, e in
            ToolResult(id: "T\(n + 1)", text: "\(df.string(from: e.date)) — \(e.title)",
                       objectIDs: [e.sourceObjectID])
        }
    }

    /// lookupField — the value(s) on file for a registered field. An unknown
    /// field returns [] (the plan's validating init makes this unreachable
    /// from a plan, but the tool holds the law independently).
    public func lookupField(_ field: String) async -> [ToolResult] {
        let canon = FactSchemaRegistry.normalizeField(field)
        guard FieldRegistry.isKnown(canon) else { return [] }
        let rows = await facts(canon)
        var seen = Set<String>()
        return rows.filter { seen.insert($0.value.lowercased()).inserted }.prefix(6).enumerated().map { n, f in
            ToolResult(id: "F\(n + 1)", text: "\(canon): \(f.value)",
                       objectIDs: f.subjectID.map { [$0] } ?? [])
        }
    }

    /// countEvents — the count, with the rows it counts (ids resolvable).
    public func countEvents(question: String) async -> [ToolResult] {
        let terms = EventAnswerComposer.vocabularyTerms(in: question)
        guard !terms.isEmpty else { return [] }
        let matched = await events(terms)
        var seen = Set<String>()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        let distinct = matched.filter { seen.insert("\($0.title.lowercased())|\(df.string(from: $0.date))").inserted }
        return [ToolResult(id: "C1", text: "count: \(distinct.count)",
                           objectIDs: Array(Set(distinct.map(\.sourceObjectID))).sorted { $0.uuidString < $1.uuidString })]
    }

    /// fetchSpans — the A2.4 span cutter over retrieval, ≤6 spans, ids "S‹n›".
    public func fetchSpans(question: String, shape: QuestionShape) async -> [ToolResult] {
        let chunks = await chunksForQuestion(question)
        return SpanCutter.cut(question: question, shape: shape, chunks: chunks).map {
            ToolResult(id: $0.id, text: $0.text, objectIDs: [$0.objectID])
        }
    }
}
