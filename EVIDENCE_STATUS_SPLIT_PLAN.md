# EvidenceStatus Dimension Split (S0.5 item 2) — authoritative plan

The single `EvidenceStatus` enum mixes **evidence basis**, **human review**, **origin**,
**availability** and **conflict** into one field, and duplicates other systems
(`ReviewState`, `HistoryReviewStatus`). This plan replaces it with **five orthogonal
dimensions** carried by one aggregate, migrated additively, adopted in four focused commits.
No aliases are added to the legacy enum; legacy raw values are preserved and decodable.

## The five dimensions (CONTRADICTED is relational — its own dimension)

```swift
enum EvidenceBasis: String, Codable {          // how the info was established
    case directlyObserved, sourceAsserted, deterministicallyDerived, inferred, unknownLegacy
}
enum ReviewDisposition: String, Codable {      // human review, never an evidence basis
    case unreviewed, confirmed, corrected, disputed, rejected, needsReview
}
enum ProposalOrigin: String, Codable {         // who/what proposed it
    case sourceExtraction, deterministicRule, modelProposed, userCreated, importedLegacy
}
enum AvailabilityStatus: String, Codable {     // is the backing evidence present
    case present, partiallyAvailable, missingEvidence, unsupported, preservedOnly
}
enum ConflictStatus: String, Codable {         // relational conflict state
    case none, contradicted, unresolved, resolved
}
```

`ConflictStatus` is **derived from contradiction links** wherever possible; persisted only in
snapshots/caches where derivation isn't available at read time.

## Aggregate + compatibility

```swift
struct EvidenceAssessment: Codable, Sendable, Hashable {
    let basis: EvidenceBasis
    let review: ReviewDisposition
    let origin: ProposalOrigin
    let availability: AvailabilityStatus
    let conflict: ConflictStatus
    let legacyStatus: EvidenceStatus?          // preserved original raw value
}
```

`LegacyEvidenceStatusAdapter` maps ALL ten legacy `EvidenceStatus` cases → an
`EvidenceAssessment`, and encodes an assessment back to a best-effort legacy `EvidenceStatus`
for old readers (deprecated compatibility only). Mapping rules — **human review never changes
the evidence basis**:

| Legacy status | basis | review | origin | availability | conflict |
|---|---|---|---|---|---|
| directlyObserved | directlyObserved | unreviewed | **importedLegacy** | present | none |
| sourceAsserted | sourceAsserted | unreviewed | **importedLegacy** | present | none |
| deterministicallyDerived | deterministicallyDerived | unreviewed | deterministicRule | present | none |
| inferred | inferred | unreviewed | **importedLegacy** | present | none |
| contradicted | unknownLegacy | unreviewed | importedLegacy | present | **contradicted** |
| unsupported | unknownLegacy | unreviewed | importedLegacy | **unsupported** | none |
| missingEvidence | unknownLegacy | unreviewed | importedLegacy | **missingEvidence** | none |
| humanConfirmed | **unknownLegacy** (basis NOT recoverable) | **confirmed** | importedLegacy | present | none |
| humanCorrected | unknownLegacy | **corrected** | **importedLegacy** | present | none |
| humanRejected | unknownLegacy | **rejected** | importedLegacy | present | none |

Origin rule: the legacy enum does NOT record who/what created the item, so origin is
`importedLegacy` for everything EXCEPT `deterministicallyDerived` (rule origin is implied by
the basis). An old `.inferred` could be model, heuristic, or another path — do NOT infer
`modelProposed`. Explicitly **do NOT** map `humanConfirmed → sourceAsserted`.

Legacy-encode (assessment → status) — **review disposition is NOT consulted**; it must not
override a known basis or synthesise a new human status. Priority: actual conflict
(`contradicted`/`unresolved`)→`contradicted`; then availability `.missingEvidence`/
`.unsupported`→those; then `basis`; `unknownLegacy`→`legacyStatus ?? .unsupported`. So
`.disputed` never invents a contradiction, and new writes NEVER create `humanConfirmed/
Corrected/Rejected` — those survive only via `legacyStatus`. (This makes Commit D nearly
free.) Round-trip is NOT lossless (five dims → one); `legacyStatus` preserves the original.

## Assertability is a POLICY, not a Bool

`EvidenceStatus.isAssertable` is used in work-product validation, ReasoningExpert promotion,
retrieval and MasterBrain — a Bool is insufficient. Replace with:

```swift
enum AssertabilityDecision { case assertAsFact, assertWithAttribution, presentAsInference, presentAsConflict, refuse }

struct AssertabilityPolicy {
    static func evaluate(assessment: EvidenceAssessment, supportingEvidenceCount: Int,
                         hasExactLocator: Bool, personaPolicy: PersonaPolicy?) -> AssertabilityDecision
}
```
Rules: observed+evidence→assertAsFact; sourceAsserted+evidence→assertWithAttribution (unless
independently corroborated); deterministicallyDerived+reproducible→assertAsFact(derivation);
inferred→presentAsInference; conflict contradicted/unresolved→presentAsConflict;
availability missing/unsupported→refuse; review confirmed→doesn't change basis; review
rejected→exclude from ordinary output (keep in audit); origin modelProposed→never canonical
until reviewed+grounded.

## Per-table schema (v62, additive; NOT four identical columns)

- **generic_facts**: add `evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status`. Keep `status`.
- **temporal_claims**: add the same six, but claims normally **inherit** review/basis from source assertions/facts. Keep `status`.
- **history_items**: already has `status` AND `review_status` (raw vocab `unreviewed/accepted/rejected/corrected` = `HistoryReviewStatus`). Add `evidence_basis, review_disposition, proposal_origin, availability_status, legacy_status`. Do NOT reuse `review_status` (its vocabulary differs from `ReviewDisposition`, which adds `confirmed/disputed/needsReview`). Keep `review_status` unchanged; add a NEW `review_disposition` column and backfill deterministically: `unreviewed→unreviewed`, `accepted→confirmed`, `corrected→corrected`, `rejected→rejected`, unknown→`needsReview`. Do NOT rewrite the old column in place. Conflict stays DERIVED from `contradiction_group_id` + contradiction records — no `conflict_status` column on history_items.
- **DO NOT touch in v62**: `events`, `assertions`, existing contradiction tables, existing `review_decisions`, and work-product tables (which don't exist yet). Provide read-time compatibility adapters for Events/Assertions instead. Change the projector's `EventStatus.reviewed → humanConfirmed` / `.rejected → humanRejected` mapping to emit separate basis + review dimensions.
- New columns are **nullable** at the SQLite level during compatibility; repository writes for NEW records still supply all dimensions.

Migration is nullable/default-safe, SAVEPOINT-wrapped, sentinel → newest touched table,
verified on a throwaway DB with v61→v62, fresh-v62, interrupted-recovery and no-row-loss tests.

## Four-commit sequence (each independently green)

- **Commit A — vocabulary + compatibility (no schema, no call-site changes).** The five enums,
  `EvidenceAssessment`, `LegacyEvidenceStatusAdapter`, exhaustive mapping tests for all ten
  legacy statuses + unknown-future-value safety + determinism. Existing behaviour unchanged.
- **Commit B — v62 schema + repository dual read/write.** Additive columns, compat read, dual
  write, sentinel bump, migration tests. Keep old `status` columns.
- **Commit C — domain + live-path adoption.** Move `GenericFact`, `TemporalClaim`,
  `HistoryItem`, `TemporalEventProjector`, `GenericFactRepository`, `TemporalClaimRepository`,
  `HistoryArtifactRepository`, `HistoryDiffEngine`, `HistoryChronologyComposer`,
  `ReasoningExpert`, `HybridRetriever`, `MasterBrain`, `WorkProductValidator` onto
  `EvidenceAssessment` + `AssertabilityPolicy` together (they share `isAssertable`, so they
  must move together or retrieval and export would disagree).
- **Commit D — stop legacy writes.** Prohibit new `humanConfirmed/humanCorrected/humanRejected`
  as basis; derive legacy status only for compatibility; add a diagnostic if any new
  legacy-human write is attempted.

Gate for the whole item: legacy raw values still decode; new records never write human-review
states as evidence basis; v61→v62 tests pass; full suite stays green.
