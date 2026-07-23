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
| directlyObserved | directlyObserved | unreviewed | sourceExtraction | present | none |
| sourceAsserted | sourceAsserted | unreviewed | sourceExtraction | present | none |
| deterministicallyDerived | deterministicallyDerived | unreviewed | deterministicRule | present | none |
| inferred | inferred | unreviewed | modelProposed | present | none |
| contradicted | unknownLegacy | unreviewed | importedLegacy | present | **contradicted** |
| unsupported | unknownLegacy | unreviewed | importedLegacy | **unsupported** | none |
| missingEvidence | unknownLegacy | unreviewed | importedLegacy | **missingEvidence** | none |
| humanConfirmed | **unknownLegacy** (basis NOT recoverable) | **confirmed** | importedLegacy | present | none |
| humanCorrected | unknownLegacy | **corrected** | userCreated | present | none |
| humanRejected | unknownLegacy | **rejected** | importedLegacy | present | none |

Explicitly **do NOT** map `humanConfirmed → sourceAsserted`. Confirmation doesn't prove how
the underlying information was originally established → `basis = unknownLegacy`.

Legacy-encode (assessment → status): conflict `.contradicted`→`contradicted`; review
`.rejected`→`humanRejected`, `.corrected`→`humanCorrected`, `.confirmed`→`humanConfirmed`;
else availability `.missingEvidence`/`.unsupported`→ those; else map `basis`. Round-trip is
NOT lossless (five dims → one) — that's expected; `legacyStatus` preserves the true original.

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

- **generic_facts**: add `evidence_basis, review_disposition, proposal_origin, availability_status, legacy_status`. Keep `status`.
- **temporal_claims**: add the same five, but claims normally **inherit** review/basis from source assertions/facts. Keep `status`.
- **history_items**: already has `status` AND `review_status`. Add `evidence_basis, proposal_origin, availability_status, legacy_status` ONLY — **reuse `review_status`** for the review dimension (migrate its decoder to `ReviewDisposition`). No duplicate review column.
- **DO NOT touch in v62**: `events`, `assertions`, existing contradiction tables, existing `review_decisions`, and work-product tables (which don't exist yet). Provide read-time compatibility adapters for Events/Assertions instead. Change the projector's `EventStatus.reviewed → humanConfirmed` / `.rejected → humanRejected` mapping to emit separate basis + review dimensions.

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
