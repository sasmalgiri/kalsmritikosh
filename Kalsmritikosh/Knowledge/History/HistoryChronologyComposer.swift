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

// MARK: - ResolvedClaim-native section composer (PA-002/004)

extension HistoryChronologyComposer: WorkProductSectionComposer {
    public var id: WorkProductComposerID { WorkProductComposerID("history.chronology") }
    public var sectionKind: BlueprintSection.Kind { .chronology }

    /// The first GENUINE section composer on the shared protocol. It renders a chronology
    /// SECTION from the already-selected, review-resolved claims in `context` — ONLY those
    /// claims, in the order supplied (temporal ordering is applied upstream by the selector
    /// that holds the dates). Each claim is turned into a cited row via the canonical
    /// AssertabilityPolicy on its EFFECTIVE assessment (latest review applied); a claim the
    /// policy refuses is dropped (fail-closed). It does NOT query repositories and does NOT
    /// reuse the legacy `compose(outline:)` path or the legacy composer's inputs.
    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        let claims: [WorkProductClaim] = context.selectedClaims.compactMap { selected in
            // Full render (not the compat wrapper) so hasReproducibleDerivation is honoured —
            // a verified derivation stays a derivation instead of being downgraded.
            guard var claim = ResolvedClaimRenderer.render(selected)?.workProductClaim else { return nil }
            // Prefix the row with its LINEAGE-resolved date phrase, or an explicit "Undated"
            // label — never an invented date. Conflicting lineage dates are called out.
            claim.text = "\(Self.datePhrase(for: selected)) — \(claim.text)"
            return claim
        }
        let section = WorkProductSection(
            title: "Chronology",
            preamble: ["Chronology for \(context.subjectLabel). Rows are ordered by their lineage-resolved dates (undated rows last); each material row cites a reopenable source."],
            claims: claims)
        return [section]
    }

    /// The precision-honest date phrase for a selected claim, or an explicit undated label.
    /// A claim with conflicting lineage dates is labelled as such, never given a guessed date.
    private static func datePhrase(for selected: SelectedClaim) -> String {
        if let anchor = selected.temporalAnchor {
            let tv = TemporalValue(start: anchor.start, end: anchor.end,
                                   precision: anchor.precision, confidence: 1.0)
            return HistoryNarrativeRenderer.datePhrase(tv) ?? "Undated"
        }
        return selected.isTemporallyAmbiguous ? "Undated (conflicting source dates)" : "Undated"
    }
}
