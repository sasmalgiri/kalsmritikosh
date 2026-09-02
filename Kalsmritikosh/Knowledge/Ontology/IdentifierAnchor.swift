//
//  IdentifierAnchor.swift
//  Kalsmritikosh
//
//  V3 (C-8) — the anchor identity layer. An anchor is the real-world subject a
//  canonical identifier names (Patent No. 555489, Application No. 202211045678,
//  invoice/case numbers…). Twelve emails that each MENTION 555489 resolve to ONE
//  anchor; the ledger stops mentioning the patent and starts KNOWING it.
//
//  RULING (owner 2026-09-02):
//   D1 — one Entity.Kind (`.identifierAnchor`); the field id rides as DATA
//        (attributes["anchorField"]); display + behavior specialize by field.
//   D2 — identity = (anchorField, canonicalValue), EXACTLY. Same value under two
//        fields = two anchors (the resolver cage's coincidence rule). Anchors
//        resolve by EXACT normalized equality only — no fuzzy R-4 machinery ever
//        touches an anchor; an OCR-corrupt identifier becomes a SEPARATE anchor
//        (I-5 detects it and proposes a reversible merge, never auto-folds).
//   Display name = displayLabel(field) + " " + canonicalValue — reusing the
//   landed constants, so anchor names inherit the answer surface's by-constant
//   safety (immune to source OCR/spacing noise).
//
//  This file is IDENTITY ONLY (V3 scope fence): the writer binding, the
//  bridge-at-read, and the producer bumps land in 3c; I-5 in 3d. Pure +
//  deterministic + offline — the resolve-or-create core is a pure function over
//  a candidate set; the DB adapter is a thin wiring added when bound.
//

import Foundation

public enum IdentifierAnchor {

    /// The attribute key the field id rides in on an anchor Entity.
    public static let fieldAttributeKey = "anchorField"

    /// The canonical value of an identifier (bare atom: label words stripped,
    /// spacing/punctuation removed) — the SAME normalization the comparator and
    /// the C-10 merge key use, so an anchor's identity agrees with fact dedup.
    public nonisolated static func canonicalValue(_ raw: String) -> String {
        CanonicalFactComparator().canonical(raw, .identifier)
    }

    /// Identity key = (normalized field, canonical value). Exact equality only.
    /// Two different fields carrying the same value produce two DISTINCT keys —
    /// patent 555489 and application 555489 are never one anchor.
    public nonisolated static func identityKey(field: String, value: String) -> String {
        "\(FactSchemaRegistry.normalizeField(field))|\(canonicalValue(value))"
    }

    /// Display name by CONSTANT: "Patent No. 555489". Reuses the landed
    /// displayLabel constants; falls back to the bare value when a field has no
    /// label (never fuses a source spelling in).
    public nonisolated static func displayName(field: String, canonicalValue: String) -> String {
        if let label = SlotAnswerComposer.displayLabel(forFieldID: field) {
            return "\(label) \(canonicalValue)"
        }
        return canonicalValue
    }

    /// The field id an anchor entity carries (nil if not an anchor / unset).
    public nonisolated static func anchorField(of entity: Entity) -> String? {
        guard entity.kind == .identifierAnchor else { return nil }
        if case let .string(f)? = entity.attributes[fieldAttributeKey]?.value { return f }
        return nil
    }

    /// Build a fresh anchor entity for (field, value). `value` is stored as the
    /// canonical atom in both value and normalizedValue; the field rides in
    /// attributes; T1 (a trusted structured identity, not body NER noise).
    public nonisolated static func makeAnchor(
        field: String,
        value: String,
        sourceObjectID: KnowledgeObject.ID,
        confidence: Confidence = .high
    ) -> Entity {
        let canon = canonicalValue(value)
        let normField = FactSchemaRegistry.normalizeField(field)
        return Entity(
            kind: .identifierAnchor,
            value: displayName(field: normField, canonicalValue: canon),
            normalizedValue: canon,
            sourceObjectID: sourceObjectID,
            confidence: confidence,
            attributes: [fieldAttributeKey: AnyCodable(.string(normField))],
            qualityTier: .t1
        )
    }

    /// Resolve-or-create over a candidate set (pure). Returns the id of an
    /// existing anchor whose (field, canonicalValue) matches EXACTLY, or a
    /// decision to create a new one. The DB adapter (3c) passes the candidate
    /// anchors for the value; here the identity law is enforced with no fuzz.
    public enum Resolution: Equatable, Sendable {
        case existing(Entity.ID)
        case create
    }

    public nonisolated static func resolve(
        field: String,
        value: String,
        among candidates: [Entity]
    ) -> Resolution {
        let key = identityKey(field: field, value: value)
        for c in candidates where c.kind == .identifierAnchor {
            guard let cf = anchorField(of: c), let cv = c.normalizedValue else { continue }
            if "\(cf)|\(cv)" == key { return .existing(c.id) }
        }
        return .create
    }
}
