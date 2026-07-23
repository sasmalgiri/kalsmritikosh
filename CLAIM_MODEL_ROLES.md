# Claim-Model Roles (locked) — S0.5 item 3

**Purpose.** The repository already has several types with "Claim" or fact-like meaning.
Before S1 adds a persona-level claim layer, this file LOCKS the canonical role of each so
we never create a second truth table or duplicate evidence. Prohibited shortcut (§17 of
the master spec): *"create five copies of facts."*

## The existing types and their ONE role each

| Type | File | Role | Persists? | Establishes truth? |
|---|---|---|---|---|
| **Assertion** | `Core/Models/Assertion.swift` | Canonical persistent atomic proposition — subject·predicate·object with evidence blocks, direct quote, provenance, extractor, retraction. The authoritative "who asserted what, with which evidence." | Yes (ledger) | It records an assertion; provenance grades it. This is the closest thing to canonical truth. |
| **GenericFact** | `Core/Models/GenericFact.swift` | Derived subject·field·value projection carried by evidence blocks. Domain-neutral "any subject" layer. Never authoritative on its own. | Yes (ledger) | No — a projection over evidence. |
| **TemporalClaim** | `Knowledge/History/TemporalClaim.swift` | Temporal projection: subject·predicate·object true over an interval, for history. Built deterministically from Assertions + GenericFacts. | Yes (`temporal_claims`, v60) | No — a projection for the history layer. |
| **ExpertFindings.Claim** | `Core/Services/Expert.swift` | Transient answer candidate produced by an expert at question time. Never stored. | No | No — a candidate awaiting the evidence gate. |
| **WorkProductClaim / ComposedClaim** | `Core/Models/WorkProduct.swift`, `Export/*` | Output DTOs — a claim as it appears in a composed/exported work product, carrying its citations. | Only inside a persisted work-product run | No — a presentation of already-established facts. |

## The NEW type S1 will add — and its strict limits

**`WorkspaceClaim`** (persona workflow layer). It represents a legal fact / investigative
finding / journalistic claim / historical proposition / personal record statement **as one
canonical object all five personas point at** (persona invariance, §4.2). It is a *wrapper*,
never a new truth store:

```swift
struct WorkspaceClaim {
    let id: UUID
    let workspaceID: Workspace.ID
    let statement: String
    // References to canonical truth — NEVER copies of it:
    let assertionIDs: [Assertion.ID]
    let historyItemIDs: [HistoryItem.ID]
    let evidenceReferences: [EvidenceReference]
    // Workflow state only:
    let reviewDisposition: ReviewDisposition          // (S0.5 item 2 dimension)
    let createdBy: ClaimActor
    let createdAt: Date
    let supersededBy: UUID?
}
```

Rules:
1. A `WorkspaceClaim` MUST reference at least one Assertion / HistoryItem / EvidenceReference.
   It never stores an independent value that isn't grounded in one of those.
2. It never duplicates or rewrites the underlying Assertion/GenericFact/TemporalClaim.
3. Deleting a `WorkspaceClaim` (or any persona object) never deletes source truth.
4. Persona-specific extensions (legal_fact, investigation_finding, journalism_claim, …)
   attach to the SAME `WorkspaceClaim.ID` via `persona_object_extensions`; they add status,
   not truth.
5. Epistemic state uses the S0.5 item-2 dimensions (`EvidenceBasis` / `ReviewDisposition` /
   `ProposalOrigin` / `AvailabilityStatus`), not new mixed cases on `EvidenceStatus`.

## Consequence
S1 must implement `WorkspaceClaim` + its evidence/contradiction/review/usage links as a
LAYER over `Assertion`/`HistoryItem`, reusing `EvidenceReference` (now block-resolved per
S0.5 item 1). No migration may introduce a second canonical atomic-fact table.
