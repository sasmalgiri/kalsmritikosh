//
//  MissingChapterEngine.swift
//  Kalsmritikosh
//
//  INN-201 (Universal History program, Phase 13). Turns typed gaps into ACTIONABLE,
//  persona-flavoured evidence requests instead of just reporting "information is
//  missing". Each action carries concrete evidence targets (from the gap) so it can
//  drive a focused retrieval / import, not a generic chat. Deterministic, LLM-free.
//

import Foundation

public enum HistoryPersona: String, Sendable, CaseIterable {
    case lawyer, investigator, journalist, historian, individual
}

public struct MissingChapterAction: Sendable, Hashable, Identifiable {
    public let id: UUID              // == the gap id
    public let personaLabel: String  // persona-specific framing of the action
    public let prompt: String        // what to look for
    public let searchTargets: [String]
    public let affectedPeriod: TemporalValue?
    public let gapKind: HistoryGapKind
}

public struct MissingChapterEngine: Sendable {
    public init() {}

    public func actions(for gaps: [HistoryGap], persona: HistoryPersona) -> [MissingChapterAction] {
        gaps.map { gap in
            MissingChapterAction(
                id: gap.id,
                personaLabel: Self.label(for: persona),
                prompt: gap.description,
                searchTargets: gap.expectedEvidenceTypes,
                affectedPeriod: gap.affectedPeriod,
                gapKind: gap.kind)
        }
        // Stable order for deterministic UI.
        .sorted { ($0.gapKind.rawValue, $0.prompt) < ($1.gapKind.rawValue, $1.prompt) }
    }

    /// The persona framing of a gap→action (§15.3). Presentation only — the
    /// underlying gap and its evidence targets are identical across personas.
    static func label(for persona: HistoryPersona) -> String {
        switch persona {
        case .lawyer:       return "Missing document request"
        case .investigator: return "Collection lead"
        case .journalist:   return "Interview / right-of-reply question"
        case .historian:    return "Archive / source search target"
        case .individual:   return "Missing-record checklist item"
        }
    }
}
