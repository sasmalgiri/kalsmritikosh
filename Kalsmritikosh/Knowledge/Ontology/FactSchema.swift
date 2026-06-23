//
//  FactSchema.swift
//  Kalsmritikosh
//
//  G3 Phase 1 — the Periodic Table of Facts, in code.
//
//  Every fact in the ledger gets a `FactType` (Contract, Invoice,
//  Person, Project, …). Every typed fact carries `FactSlot`s — named
//  fields with type, cardinality, and required/optional markers.
//  Every bond between two facts follows a `BondRule` — a rule that
//  says "Contract HAS-A SignedBy(Person), required, cardinality 1+".
//
//  G3.1 ships the data types only. G3.2 registers the v1 ontology.
//  G3.7 classifies existing entities/events into FactTypes; G3.10
//  walks the rules to construct typed bonds at ingest time.
//
//  Design rules (don't violate):
//  - Schema is hand-curated. Not an LLM ontology learner.
//  - Slots are typed; their values come from extractors, not free
//    LLM prose. An LLM fallback exists per slot (G3.14) but must
//    produce a typed value.
//  - Bond rules are deterministic. A walk from Project Delta →
//    delivers_for ← Delivery → caused_by ← Email is reproducible
//    bit-for-bit across runs.
//

import Foundation

/// The known kinds of structured facts. v1 is the 10 starter types;
/// new types append to this enum + register in Ontology.
public enum FactType: String, Codable, Sendable, Hashable, CaseIterable {
    case person
    case organization
    case project
    case contract
    case amendment
    case invoice
    case delivery
    case email
    case meeting
    case decision

    /// Display string used in UI surfaces ("Why this answer?" panel).
    public var displayName: String {
        switch self {
        case .person: return "Person"
        case .organization: return "Organization"
        case .project: return "Project"
        case .contract: return "Contract"
        case .amendment: return "Amendment"
        case .invoice: return "Invoice"
        case .delivery: return "Delivery"
        case .email: return "Email"
        case .meeting: return "Meeting"
        case .decision: return "Decision"
        }
    }
}

/// The data type a slot's value carries. v1 covers the primitive
/// scalars + reference-to-another-fact. v2 may add lists / enums /
/// money / location once the v1 ontology has stabilized.
public enum SlotType: Codable, Sendable, Hashable {
    case string
    case integer
    case decimal
    case date
    case bool
    /// A reference to another fact of the given type. The slot value
    /// is the target fact's ID; the ontology validator checks the
    /// referenced row exists and has the matching FactType.
    case reference(FactType)
}

/// How many values a slot can hold.
public enum Cardinality: String, Codable, Sendable, Hashable {
    case zeroOrOne   // optional, at most one
    case one         // required, exactly one
    case zeroOrMore  // optional, 0..n
    case oneOrMore   // required, at least one
}

/// One named field on a `FactType`. The Ontology lists all slots
/// for each type; the classifier and slot-extractor pipeline (G3.13/14)
/// fills them from the source content.
public struct FactSlot: Codable, Sendable, Hashable {
    public let name: String
    public let type: SlotType
    public let cardinality: Cardinality
    /// Free-text hint surfaced to the LLM-assisted slot extractor
    /// (G3.14) when the rule-based extractor can't fill the slot.
    public let extractorHint: String?

    public nonisolated init(
        name: String,
        type: SlotType,
        cardinality: Cardinality,
        extractorHint: String? = nil
    ) {
        self.name = name
        self.type = type
        self.cardinality = cardinality
        self.extractorHint = extractorHint
    }
}

/// The schema for one `FactType`: its slot list + a one-line
/// description that surfaces in the walk-path explanation UI.
public struct FactTypeSchema: Codable, Sendable {
    public let type: FactType
    public let description: String
    public let slots: [FactSlot]

    public nonisolated init(type: FactType, description: String, slots: [FactSlot]) {
        self.type = type
        self.description = description
        self.slots = slots
    }
}

/// A directed rule connecting two FactTypes — the "bonds" in the
/// periodic-table metaphor. E.g. "Contract SIGNED_BY Person" creates
/// a typed edge from a Contract fact to a Person fact whenever the
/// Contract's `signed_by` slot is filled.
public struct BondRule: Codable, Sendable, Hashable {
    public let name: String
    public let from: FactType
    public let to: FactType
    public let cardinality: Cardinality
    public let description: String

    public nonisolated init(
        name: String,
        from: FactType,
        to: FactType,
        cardinality: Cardinality,
        description: String
    ) {
        self.name = name
        self.from = from
        self.to = to
        self.cardinality = cardinality
        self.description = description
    }
}

/// G3.20 — the explainability trace. Every typed-graph answer comes
/// with a `[WalkStep]` showing how the bond engine got there. Phase 4
/// fills these out per question; the UI ("Why this answer?" panel)
/// renders the path.
public struct WalkStep: Codable, Sendable, Hashable {
    public let fromFact: FactType
    public let bond: String
    public let toFact: FactType
    /// The source object IDs whose chunks evidence the bond at this
    /// step. Click-through to the source viewer in the UI.
    public let evidenceObjectIDs: [UUID]

    public nonisolated init(
        fromFact: FactType,
        bond: String,
        toFact: FactType,
        evidenceObjectIDs: [UUID]
    ) {
        self.fromFact = fromFact
        self.bond = bond
        self.toFact = toFact
        self.evidenceObjectIDs = evidenceObjectIDs
    }
}
