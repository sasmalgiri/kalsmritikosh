# Ontology v1 — the Periodic Table of Facts

> "Each meaningful sentence or paragraph or cluster should form bonds
> with rules — not chemistry rules but real facts that connect through
> their relevant information across documents."

This document is the human-readable companion to
`Ontology.swift`. It lists every `FactType` and every `BondRule` shipped
in v1 of the typed-fact graph, along with what each one means in a
real archive.

Version: **1**
Status: **active**
Locked: 2026-06-23

## What this is for

Every fact in Kalsmritikosh's ledger eventually gets a `FactType`. Every link
between facts follows a `BondRule`. With both in place, the brain stops
answering questions by similarity search and starts answering them by
**walking the typed graph** — with a citation trail per hop.

The chemistry metaphor:
- A `FactType` is an element. It has a fixed set of slots (Contract has
  `title`, `party_a_org`, `effective_date`, …).
- A `BondRule` is a chemical bond. It has a fixed shape (a Contract can
  be `signed_by` zero-or-more People).
- An ingest pass identifies elements + bonds them according to the
  rules. A query walks the resulting molecule.

## The 10 FactTypes

| Type | Description |
|---|---|
| **Person** | A real-world individual. |
| **Organization** | A company, supplier, client, or other business entity. |
| **Project** | A named initiative spanning multiple documents. |
| **Contract** | A signed agreement between two organisations. |
| **Amendment** | A modification to a Contract. |
| **Invoice** | A billing document with an amount and a due date. |
| **Delivery** | A scheduled or completed delivery against a project. |
| **Email** | A single email message. |
| **Meeting** | A scheduled or completed meeting. |
| **Decision** | An explicit decision recorded in the archive. |

### Slot summary (key ones)

| Type | Required slots | Optional reference slots |
|---|---|---|
| Person | `name` | — |
| Organization | `name` | — |
| Project | `name` | `owner_person` |
| Contract | `title` | `party_a_org`, `party_b_org`, `for_project` |
| Amendment | `amends_contract` | — |
| Invoice | `number` | `from_org`, `to_org`, `for_project` |
| Delivery | (none required) | `for_project` |
| Email | (none required) | `sender_person`, `discusses_project` |
| Meeting | (none required) | `about_project` |
| Decision | `summary` | `decided_by_person`, `concerns_project`, `concerns_contract` |

Full slot lists with types and extractor hints live in
`Ontology.swift::types`.

## The 17 BondRules

Each rule reads as "**From** `bond_name` **To** (cardinality)":

| Bond | From | To | Card | Meaning |
|---|---|---|---|---|
| `affiliated_with` | Person | Organization | 0..* | A Person works for / is associated with an Organization. |
| `signed_by` | Contract | Person | 0..* | A Contract was signed by one or more People. |
| `party_a` | Contract | Organization | 0..1 | First counterparty. |
| `party_b` | Contract | Organization | 0..1 | Second counterparty. |
| `amends` | Amendment | Contract | 1 | An Amendment modifies one Contract. |
| `owns` | Person | Project | 0..* | A Person is the named owner of a Project. |
| `delivered_by` | Project | Organization | 0..* | A Project is delivered by one or more Organizations. |
| `issued_by` | Invoice | Organization | 0..1 | An Invoice was issued by an Organization. |
| `issued_to` | Invoice | Organization | 0..1 | An Invoice was issued to an Organization. |
| `invoice_for` | Invoice | Project | 0..1 | An Invoice covers work on a Project. |
| `delivers_for` | Delivery | Project | 0..1 | A Delivery is part of a Project. |
| `sent_by` | Email | Person | 0..1 | An Email was sent by a Person. |
| `received_by` | Email | Person | 0..* | An Email was received by one or more People. |
| `discusses` | Email | Project | 0..* | An Email discusses one or more Projects. |
| `about` | Meeting | Project | 0..* | A Meeting is about one or more Projects. |
| `attended_by` | Meeting | Person | 0..* | A Meeting was attended by one or more People. |
| `made_by` | Decision | Person | 0..1 | A Decision was made by a Person. |

Cardinality decoder:
- `1` = required, exactly one
- `0..1` = optional, at most one
- `1..*` = required, at least one
- `0..*` = optional, any number

## How the rules feed a question

User asks: *"Why was Project Delta's delivery delayed in April 2024?"*

The walk planner (G3.17) turns this into:

```
Start:  fact_type=Project, slot.name="Project Delta"
Step 1: ← delivers_for      (Delivery facts that point at this Project)
Step 2: filter status="delayed", date in 2024-04
Step 3: ← discusses         (Emails that discuss this Project, dated 2024-04)
Step 4: ← sent_by           (Person who sent each such Email)
```

The walk executor (G3.18) returns each step's typed evidence + the
source object IDs that backed each bond. The answer renderer (G3.20)
attaches the full `[WalkStep]` trace to the `VerifiedAnswer`. The UI
shows it as a clickable path.

## Things that v1 deliberately does NOT model

- **Recurring patterns** ("every Monday standup")
- **Multi-currency** invoice amounts (assume USD; v2 adds currency)
- **Cross-thread email reply trees** (X-GM-THRID gets us close; precise
  reply trees defer to v2)
- **Document-class hierarchies** (PDFEnvironment tags
  `env.pdf.detected_doc_class` separately; we don't pull that into
  FactType taxonomy yet)
- **Geographic** facts (Location is a v2 FactType)
- **Legal-specific** types (Clause, Jurisdiction) — out of scope until
  enough non-fixture legal data is observed

## Adding a new type or rule

1. Append the case to `FactType` in `FactSchema.swift`.
2. Register the new `FactTypeSchema` in `Ontology.types`.
3. Add every `BondRule` the new type participates in.
4. Bump `Ontology.version` if the change is binary-breaking for
   already-classified rows.
5. Write a short rationale under "Things v1 does NOT model" → remove
   from that list if you've now modeled it.
6. Update ONTOLOGY_V1.md (this file) — or open ONTOLOGY_V2.md if the
   v1 numbering becomes confusing.

## Status of the v1 ship

| Phase | Item | Status |
|---|---|---|
| 1 | FactSchema.swift | ✅ shipped |
| 1 | Ontology.swift v1 registry | ✅ shipped |
| 1 | ONTOLOGY_V1.md (this doc) | ✅ shipped |
| 1 | Worked-example trace (ProjectDelta) | ❌ pending |
| 2 | DB migration: fact_type + slots columns | ❌ pending |
| 2 | FactTypeClassifier | ❌ pending |
| 2 | Backfill | ❌ pending |
| 2 | OntologyValidator | ❌ pending |
| 3 | BondConstructor | ❌ pending |
| 3 | Slot extractors per FactType | ❌ pending |
| 4 | Schema-aware retrieval | ❌ pending |
| 5 | Walk-path on VerifiedAnswer | ❌ pending |
| 5 | "Why this answer?" UI panel | ❌ pending |
| 6 | Eval expansion + walk-correctness metric | ❌ pending |

Phase 1 is now closed. Phase 2 (storage + labeling) is next.
