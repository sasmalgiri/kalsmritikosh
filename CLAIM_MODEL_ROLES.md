# Claim-Model Roles (locked) — S0.5 item 3

**Purpose.** The repository already has several types with "Claim" or fact-like meaning.
Before S1 adds a persona-level claim layer, this file LOCKS the canonical role of each so
we never create a second truth table or duplicate evidence. Prohibited shortcut (§17 of
the master spec): *"create five copies of facts."*

## The existing types and their ONE role each

| Type | File | Role | Persists? | Establishes truth? |
|---|---|---|---|---|
| **Assertion** | `Core/Models/Assertion.swift` | **Canonical proposition record.** It records who or what asserted a proposition, with evidence (objects + blocks), direct quote, provenance, confidence, extractor, agent and retraction. It is the correct canonical atomic-proposition substrate — but it remains an *assertion*, and **does not itself establish that the proposition is true.** | Yes (ledger) | No — it records an assertion; provenance grades how it was established, human review never changes that basis. |
| **GenericFact** | `Core/Models/GenericFact.swift` | Derived subject·field·value projection carried by evidence blocks. Domain-neutral "any subject" layer. Never authoritative on its own. | Yes (ledger) | No — a projection over evidence. |
| **TemporalClaim** | `Knowledge/History/TemporalClaim.swift` | Temporal projection: subject·predicate·object true over an interval, for history. Built deterministically from Assertions + GenericFacts. | **Persistence infrastructure exists** (`temporal_claims`, v60 + `TemporalClaimRepository`), **but the live `HistoryReconstructionEngine` currently projects temporal claims in memory and passes them into the result — it does NOT insert them through the repository.** Whether to materialise/cache them is a separate decision. | No — a projection for the history layer. |
| **ExpertFindings.Claim** | `Core/Services/Expert.swift` | Transient answer candidate produced by an expert at question time. Never stored. | No | No — a candidate awaiting the evidence gate. |
| **WorkProductClaim / ComposedClaim** | `Core/Models/WorkProduct.swift`, `Export/*` | Output DTOs — a claim as it appears in a composed/exported work product, carrying its citations. | **No permanent run persistence today** (in-memory only); later persisted **only inside a versioned work-product run — that persistence belongs to S2**, not now. | No — a presentation of already-established facts. |

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
4. Persona-specific extensions attach to the SAME `WorkspaceClaim.ID` via **typed,
   indexed extension tables** — `legal_claim_extensions`, `investigation_claim_extensions`,
   `journalism_claim_extensions`, `research_claim_extensions`, `personal_claim_extensions`
   — each keyed on `workspace_claim_id`. Essential workflow properties (status, dates,
   assignments, dispositions) are typed columns, not JSON. A generic key/value extension
   may remain for OPTIONAL fields only. They add status, never truth.
5. Epistemic state uses the S0.5 item-2 dimensions (`EvidenceBasis` / `ReviewDisposition` /
   `ProposalOrigin` / `AvailabilityStatus`), not new mixed cases on `EvidenceStatus`.

## Consequence
S1 must implement `WorkspaceClaim` + its evidence/contradiction/review/usage links as a
LAYER over `Assertion`/`HistoryItem`, reusing `EvidenceReference` (now block-resolved per
S0.5 item 1). No migration may introduce a second canonical atomic-fact table.
