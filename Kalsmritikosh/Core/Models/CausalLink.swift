//
//  CausalLink.swift
//  Kalsmritikosh
//
//  HISTORY Phase G.3 — typed cause-and-effect edge between two
//  Events. The Historical Intelligence Platform reference standard
//  (Vol 08 Causal Intelligence Engine) lists seven relation types;
//  design research pruned to five that real systems converge on:
//
//      CAUSED            — strongest causal claim. Only auto-assigned
//                          when an explicit lexical trigger appears
//                          ("because of", "due to", "as a result of")
//                          near the entity in question.
//      CONTRIBUTED_TO    — weaker, "this likely played a role".
//                          Default heuristic emission level. The
//                          ledger's Hume guard: never auto-promote
//                          to CAUSED on co-occurrence alone.
//      ENABLED           — preconditional. "Patent application
//                          ENABLED grant certificate."
//      PREVENTED         — counterfactual edge. "Maintenance budget
//                          PREVENTED early bearing failure."
//      FOLLOWED          — temporal-only, no causal claim. Used by
//                          the chapter planner to surface ordering
//                          without claiming causation.
//
//  Allen interval relations live on the link too (denormalized hint)
//  so the composer can render "X happened DURING Y" without
//  re-computing on every read.
//
//  Anti-patterns documented in the research and guarded here:
//    1. Never auto-promote a heuristic link to CAUSED. Discoverer
//       emits CONTRIBUTED_TO by default; a lexical-trigger pass
//       (or user assertion) is the only path to CAUSED.
//    2. Counterfactuals live in a parallel table (Phase G.4 will
//       add `event_links_hypothetical`) — never UNION them into the
//       main timeline.
//    3. Confidence ships with every link; no link is treated as a
//       hard fact downstream.
//

import Foundation

/// Typed causal / temporal relation between two events.
public nonisolated enum CausalRelation: String, Codable, Sendable, Hashable, CaseIterable {
    case caused          = "CAUSED"
    case contributedTo   = "CONTRIBUTED_TO"
    case enabled         = "ENABLED"
    case prevented       = "PREVENTED"
    case followed        = "FOLLOWED"

    /// Display verb used by the narrative composer when rendering
    /// the link inline ("X led to Y", "X enabled Y", "X followed Y").
    public var renderVerb: String {
        switch self {
        case .caused:        return "caused"
        case .contributedTo: return "contributed to"
        case .enabled:       return "enabled"
        case .prevented:     return "prevented"
        case .followed:      return "was followed by"
        }
    }

    /// Whether the relation expresses a true causal claim (UI shows
    /// these in stronger language; the evidence gate raises the
    /// citation requirement for them).
    public var isCausal: Bool {
        switch self {
        case .followed:      return false
        case .caused, .contributedTo, .enabled, .prevented:
            return true
        }
    }
}

/// Allen's interval algebra — the 13 base relations between two time
/// intervals. Research note: ship only the 5 most useful for a
/// non-PhD audience; the inverses are computed on the fly when
/// reversing the link's direction.
public nonisolated enum AllenRelation: String, Codable, Sendable, Hashable, CaseIterable {
    case before    = "before"
    case meets     = "meets"
    case overlaps  = "overlaps"
    case during    = "during"
    case equals    = "equals"
}

/// Source attribution for a causal link. Different sources carry
/// different trust weight — the evidence verifier treats `user`
/// assertions as ground-truth-level, `llm` as medium, `heuristic`
/// as needing corroboration.
public nonisolated enum CausalLinkSource: String, Codable, Sendable, Hashable {
    case heuristic        // CausalDiscoverer background heuristic
    case lexicalTrigger   // explicit "because", "due to" near event
    case llm              // future LLM-assisted causal extraction
    case user             // user assertion in the History tab
    case ontology         // BondConstructor-style domain rule
}

/// A typed edge between two events. Append-only; supersession is
/// handled via the `superseded_by` column (G.4 follow-on).
public nonisolated struct CausalLink: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sourceEventID: Event.ID
    public let targetEventID: Event.ID
    public let relation: CausalRelation
    /// 0..1 — composer's prose softens by confidence ("X likely
    /// contributed to Y" vs "X contributed to Y").
    public let confidence: Double
    /// Source KO IDs that justify this link. The composer cites
    /// these inline when it renders the relation.
    public let evidenceObjectIDs: [KnowledgeObject.ID]
    /// Optional Allen relation precomputed at discovery time so
    /// downstream consumers don't recompute.
    public let allen: AllenRelation?
    /// Who proposed this link.
    public let source: CausalLinkSource
    /// Free-text reason snippet (the lexical trigger phrase, or the
    /// heuristic that fired). Shown in the UI's "why this link?"
    /// surface. Optional; empty when the heuristic produces nothing
    /// readable.
    public let reason: String?
    public let createdAt: Date
    /// When set, this link has been replaced by another. Default nil.
    public let supersededBy: UUID?

    public nonisolated init(
        id: UUID = UUID(),
        sourceEventID: Event.ID,
        targetEventID: Event.ID,
        relation: CausalRelation,
        confidence: Double,
        evidenceObjectIDs: [KnowledgeObject.ID] = [],
        allen: AllenRelation? = nil,
        source: CausalLinkSource = .heuristic,
        reason: String? = nil,
        createdAt: Date = Date(),
        supersededBy: UUID? = nil
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.targetEventID = targetEventID
        self.relation = relation
        self.confidence = max(0.0, min(1.0, confidence))
        self.evidenceObjectIDs = evidenceObjectIDs
        self.allen = allen
        self.source = source
        self.reason = reason
        self.createdAt = createdAt
        self.supersededBy = supersededBy
    }
}
