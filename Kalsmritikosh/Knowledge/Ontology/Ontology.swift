//
//  Ontology.swift
//  Kalsmritikosh
//
//  G3.2 — static registry of the v1 ontology: 10 FactType schemas +
//  ~17 BondRules. Hand-curated, deterministic, no LLM in this file.
//
//  Adding a new FactType:
//    1. Append a case to FactType in FactSchema.swift
//    2. Register a `FactTypeSchema` in `types` below
//    3. Add `BondRule`s in `rules` for every typed edge the new type
//       can be on either end of
//    4. Bump the version constant and document the change in
//       ONTOLOGY_V1.md (or a future v2 doc)
//
//  Removing a slot or rule from a SHIPPED ontology is a breaking
//  change — backfills + slot data must be migrated. Don't do it
//  casually.
//

import Foundation

public enum Ontology {

    /// Schema-version stamp. Each fact row in v2+ carries the version
    /// it was classified under so that re-classification (G3.8) can
    /// upgrade rows on the fly.
    public static let version = 1

    // MARK: - FactType schemas

    public static let types: [FactTypeSchema] = [

        // ── Person ─────────────────────────────────────────────────
        FactTypeSchema(
            type: .person,
            description: "A real-world individual mentioned in the archive.",
            slots: [
                FactSlot(name: "name", type: .string, cardinality: .one,
                         extractorHint: "Full display name as it appears in source."),
                FactSlot(name: "email", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "Primary email address if known."),
                FactSlot(name: "role", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "Job title or role within an organisation."),
            ]
        ),

        // ── Organization ───────────────────────────────────────────
        FactTypeSchema(
            type: .organization,
            description: "A company, supplier, client, or other business entity.",
            slots: [
                FactSlot(name: "name", type: .string, cardinality: .one,
                         extractorHint: "Canonical org name (resolves through aliases)."),
                FactSlot(name: "kind", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "supplier | client | partner | other"),
                FactSlot(name: "domain", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "Primary email domain (e.g. supplier-abc.com)."),
            ]
        ),

        // ── Project ────────────────────────────────────────────────
        FactTypeSchema(
            type: .project,
            description: "A named initiative spanning multiple documents.",
            slots: [
                FactSlot(name: "name", type: .string, cardinality: .one),
                FactSlot(name: "status", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "active | paused | completed | cancelled"),
                FactSlot(name: "owner_person", type: .reference(.person), cardinality: .zeroOrOne),
                FactSlot(name: "start_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "end_date", type: .date, cardinality: .zeroOrOne),
            ]
        ),

        // ── Contract ───────────────────────────────────────────────
        FactTypeSchema(
            type: .contract,
            description: "A signed agreement between two organisations.",
            slots: [
                FactSlot(name: "title", type: .string, cardinality: .one),
                FactSlot(name: "party_a_org", type: .reference(.organization), cardinality: .zeroOrOne),
                FactSlot(name: "party_b_org", type: .reference(.organization), cardinality: .zeroOrOne),
                FactSlot(name: "effective_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "expiry_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "for_project", type: .reference(.project), cardinality: .zeroOrOne),
            ]
        ),

        // ── Amendment ──────────────────────────────────────────────
        FactTypeSchema(
            type: .amendment,
            description: "A modification to a Contract.",
            slots: [
                FactSlot(name: "amends_contract", type: .reference(.contract), cardinality: .one),
                FactSlot(name: "effective_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "summary", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "One-line description of what changed."),
            ]
        ),

        // ── Invoice ────────────────────────────────────────────────
        FactTypeSchema(
            type: .invoice,
            description: "A billing document with an amount and a due date.",
            slots: [
                FactSlot(name: "number", type: .string, cardinality: .one,
                         extractorHint: "Invoice number as printed (e.g. INV-401)."),
                FactSlot(name: "amount", type: .decimal, cardinality: .zeroOrOne),
                FactSlot(name: "due_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "from_org", type: .reference(.organization), cardinality: .zeroOrOne),
                FactSlot(name: "to_org", type: .reference(.organization), cardinality: .zeroOrOne),
                FactSlot(name: "for_project", type: .reference(.project), cardinality: .zeroOrOne),
                FactSlot(name: "status", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "issued | paid | overdue | disputed"),
            ]
        ),

        // ── Delivery ───────────────────────────────────────────────
        FactTypeSchema(
            type: .delivery,
            description: "A scheduled or completed delivery against a project.",
            slots: [
                FactSlot(name: "for_project", type: .reference(.project), cardinality: .zeroOrOne),
                FactSlot(name: "scheduled_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "actual_date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "status", type: .string, cardinality: .zeroOrOne,
                         extractorHint: "scheduled | completed | delayed | cancelled"),
            ]
        ),

        // ── Email ──────────────────────────────────────────────────
        FactTypeSchema(
            type: .email,
            description: "A single email message; threads are stitched via X-GM-THRID at ingest.",
            slots: [
                FactSlot(name: "sender_person", type: .reference(.person), cardinality: .zeroOrOne),
                FactSlot(name: "subject", type: .string, cardinality: .zeroOrOne),
                FactSlot(name: "sent_at", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "discusses_project", type: .reference(.project), cardinality: .zeroOrOne),
            ]
        ),

        // ── Meeting ────────────────────────────────────────────────
        FactTypeSchema(
            type: .meeting,
            description: "A scheduled or completed meeting.",
            slots: [
                FactSlot(name: "topic", type: .string, cardinality: .zeroOrOne),
                FactSlot(name: "date", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "about_project", type: .reference(.project), cardinality: .zeroOrOne),
            ]
        ),

        // ── Decision ───────────────────────────────────────────────
        FactTypeSchema(
            type: .decision,
            description: "An explicit decision recorded somewhere in the archive.",
            slots: [
                FactSlot(name: "summary", type: .string, cardinality: .one),
                FactSlot(name: "decided_at", type: .date, cardinality: .zeroOrOne),
                FactSlot(name: "decided_by_person", type: .reference(.person), cardinality: .zeroOrOne),
                FactSlot(name: "concerns_project", type: .reference(.project), cardinality: .zeroOrOne),
                FactSlot(name: "concerns_contract", type: .reference(.contract), cardinality: .zeroOrOne),
            ]
        ),
    ]

    // MARK: - BondRules

    /// Directed bond rules. Each rule is "from FactType, named bond,
    /// to FactType, with cardinality on the from side". The G3.10
    /// BondConstructor walks these at ingest time to write
    /// Relationship rows tagged with the bond name + provenance.
    public static let rules: [BondRule] = [
        BondRule(name: "affiliated_with", from: .person, to: .organization,
                 cardinality: .zeroOrMore,
                 description: "A Person works for or is associated with an Organization."),
        BondRule(name: "signed_by", from: .contract, to: .person,
                 cardinality: .zeroOrMore,
                 description: "A Contract was signed by one or more People."),
        BondRule(name: "party_a", from: .contract, to: .organization,
                 cardinality: .zeroOrOne,
                 description: "The first counterparty to a Contract."),
        BondRule(name: "party_b", from: .contract, to: .organization,
                 cardinality: .zeroOrOne,
                 description: "The second counterparty to a Contract."),
        BondRule(name: "amends", from: .amendment, to: .contract,
                 cardinality: .one,
                 description: "An Amendment modifies one Contract."),
        BondRule(name: "owns", from: .person, to: .project,
                 cardinality: .zeroOrMore,
                 description: "A Person is the named owner of a Project."),
        BondRule(name: "delivered_by", from: .project, to: .organization,
                 cardinality: .zeroOrMore,
                 description: "A Project is delivered by one or more Organizations."),
        BondRule(name: "issued_by", from: .invoice, to: .organization,
                 cardinality: .zeroOrOne,
                 description: "An Invoice was issued by an Organization."),
        BondRule(name: "issued_to", from: .invoice, to: .organization,
                 cardinality: .zeroOrOne,
                 description: "An Invoice was issued to an Organization."),
        BondRule(name: "invoice_for", from: .invoice, to: .project,
                 cardinality: .zeroOrOne,
                 description: "An Invoice covers work on a Project."),
        BondRule(name: "delivers_for", from: .delivery, to: .project,
                 cardinality: .zeroOrOne,
                 description: "A Delivery is part of a Project."),
        BondRule(name: "sent_by", from: .email, to: .person,
                 cardinality: .zeroOrOne,
                 description: "An Email was sent by a Person."),
        BondRule(name: "received_by", from: .email, to: .person,
                 cardinality: .zeroOrMore,
                 description: "An Email was received by one or more People."),
        BondRule(name: "discusses", from: .email, to: .project,
                 cardinality: .zeroOrMore,
                 description: "An Email discusses one or more Projects."),
        BondRule(name: "about", from: .meeting, to: .project,
                 cardinality: .zeroOrMore,
                 description: "A Meeting is about one or more Projects."),
        BondRule(name: "attended_by", from: .meeting, to: .person,
                 cardinality: .zeroOrMore,
                 description: "A Meeting was attended by one or more People."),
        BondRule(name: "made_by", from: .decision, to: .person,
                 cardinality: .zeroOrOne,
                 description: "A Decision was made by a Person."),
    ]

    // MARK: - Lookup helpers (no actor state — pure)

    public static func schema(for type: FactType) -> FactTypeSchema? {
        types.first { $0.type == type }
    }

    public static func bondRules(from type: FactType) -> [BondRule] {
        rules.filter { $0.from == type }
    }

    public static func bondRules(to type: FactType) -> [BondRule] {
        rules.filter { $0.to == type }
    }

    public static func bondRule(named name: String) -> BondRule? {
        rules.first { $0.name == name }
    }
}
