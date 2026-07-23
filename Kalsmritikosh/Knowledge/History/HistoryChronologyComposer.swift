//
//  HistoryChronologyComposer.swift
//  Kalsmritikosh
//
//  Persona-v2 §7.4 (Phase 12 foundation). A REAL section composer — the master spec
//  requires that professional work-product sections stop routing through the generic
//  "GenericFact → field:value" mapping. This composes an evidence-cited CHRONOLOGY
//  section from a reconstructed HistoryOutline: one row per history item, date-phrased
//  by precision, carrying its status and exact evidence object ids. Shared by all
//  five personas (lawyer matter chronology, journalist story chronology, …) — the
//  persona layer only changes labels, never the rows. Deterministic, LLM-free.
//

import Foundation

public struct ChronologyRow: Sendable, Hashable, Identifiable {
    public let id: UUID                    // the history item id
    public let datePhrase: String          // precision-honest ("In 2005", "On 2004-01-01", "Undated")
    public let sortKey: Date               // for stable ordering (undated sort last)
    public let title: String
    public let kind: HistoryItemKind
    public let status: EvidenceStatus
    public let evidenceObjectIDs: [KnowledgeObject.ID]
    public var isUndated: Bool { datePhrase == "Undated" }
}

public struct ChronologySection: Sendable, Hashable {
    public let subjectName: String
    public let rows: [ChronologyRow]
    /// Every row cites at least one source — the material-claim citation gate.
    public var everyRowCited: Bool { rows.allSatisfy { !$0.evidenceObjectIDs.isEmpty } }
}

public struct HistoryChronologyComposer: Sendable {
    public init() {}

    public func compose(outline: HistoryOutline) -> ChronologySection {
        let distantFuture = Date(timeIntervalSince1970: 4_102_444_800)   // undated → sort last
        let rows = outline.items.map { item -> ChronologyRow in
            let phrase = HistoryNarrativeRenderer.datePhrase(item.start) ?? "Undated"
            return ChronologyRow(
                id: item.id, datePhrase: phrase,
                sortKey: item.start?.start ?? distantFuture,
                title: item.title, kind: item.kind, status: item.evidenceStatus,
                evidenceObjectIDs: item.evidence.map(\.objectID))
        }
        .sorted { a, b in
            a.sortKey != b.sortKey ? a.sortKey < b.sortKey : a.title < b.title
        }
        return ChronologySection(subjectName: outline.subject.displayName, rows: rows)
    }
}
