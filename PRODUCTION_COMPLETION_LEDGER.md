# PRODUCTION_COMPLETION_LEDGER

**Generated:** 2026-07-22 (updated). **Head:** `8a7b7d0`.
**Purpose:** the definitive, honest status of all 104 pack tasks + the exact unblock for
anything not done. Statuses use the pack vocabulary.

**UPDATE — TST-001/002 are now DONE (no longer the gate).** The `KalsmritikoshTests`
target exists (created in the Xcode UI); the ~30 written suites now run under it and
**all 383 tests pass** via `RunAllTests`. Everything previously marked "UNIT_VERIFIED*"
(build + snippet only) is now **CI-verified**, and the Section-B live-schema/wiring work
is safe to finish under the test net. Since this flipped, two deep-wiring items landed
CI-verified: **SEM persistence** (migration v57 + `GenericFactRepository`, `f3c7800`) and
**domain-pack fact extraction at ingest** (`8a7b7d0`).

## A. Complete (code written, build-green, verified as noted)

**Whole workstreams complete:**
- Governance GOV-001/002/003/004 · Audit AUD-001/002/003 · Claims CLM-001/002/003/004
- Semantics SEM-001…009 (9/9) · Reconstruction REC-001/002/003/004 (4/4)
- Security SEC-001/002/003 · CI CI-001/002

**Substantially complete:**
- Retrieval: RET-001/003/006/007/008/009 (QueryPlan → DocumentFitness → wired, dedup,
  sufficiency, corrective) — real-data verified. RET-002/004/005 partial/pending.
- Evidence: EV-001 (authority), EV-002 (lossless locator), EV-003 (projection invariant,
  live-measured 99.7%). EV-004 snapshots pre-exist.
- Ingestion durability: ING-001/004 (durable run-state + resume, migration v56, verified).
- Workbench: LAB-001 (kernel), LAB-002 (durable repo, migration v55, verified),
  LAB-003 (transform graph), LAB-004 (lineage processors).
- Personas: PER-001 (policies), PER-002 (blueprints), PER-003…007 (one composer), EXP-002 (validator).
- Parsers: PAR-001 (capability manifest), PAR-002 (coverage report), PAR-003 (magic routing, earlier).
- Redaction RED-001 (text) · UX-002 (readiness model) · MOD-001 (locked contract);
  MOD-002 satisfied by the provider-budget architecture.

**Live wiring done (engines now active in the app):** SEC-003 defang in expert prompts;
RET-006 sufficiency + CLM-001 grounding + CLM-002 causal guard in the answer footer.

## B. Codeable but NOT done — needs care, not a gate

| Task(s) | Why deferred | Path to finish |
|---|---|---|
| EV-005 vault, EV-006 consolidate versions | EV-006 is a **data** migration (moves rows) — highest brick risk | additive copy-migration + throwaway-DB verify |
| ING-002/003/005/006/007 | touch the **live IngestCoordinator** (behavior) | wire the ING-001 repo into the coordinator, verify on re-ingest |
| PAR-004–010 | parser-internal fidelity (token boxes, formula model, thread fidelity) | per-parser work + fixtures |
| LAB-005–009, UX-001/003/004, EXP-001 | **SwiftUI views** — compile-checkable but not snippet-verifiable | build views on the models already landed; verify by running the app |
| RET-002/004/005 | fielded FTS / hierarchy / reranker-ladder tuning | schema + ranking work, eval-gated |
| Deep wiring | domain-pack extraction at ingest; fitness→answer; corrective loop in MasterBrain | integrate + eval no-regression |

## C. Physically gated — CANNOT be done in this environment

| Task(s) | Blocker | Exact unblock |
|---|---|---|
| SCL-001–004 (scale) | recorded runs on **your hardware** at 1/10/100 GB | run the scale harness on your Mac |
| REL-001–006 (release) | Apple **signing, clean-machine, App Store, your acceptance** | your Developer account + a clean Mac |
| EVAL-001/002 | in-app eval runs against the live stack | tap the eval/SmokeTest in-app |
| MOD-003/004/005, P1.2, P3.1 | **DEFERRED by GOV-001** (no bundled GGUF in v1) | only if v1.x adds optional GGUF |

## D. What's now unblocked (test target is live)
With TST-001 done and 383 tests green, the remaining **codeable** work is Section B,
now finishable safely because a regression would be caught by the suite:
- **Deep wiring** (in progress): SEM persistence + ingest fact extraction landed. Next:
  fitness→answer feed into MasterBrain; corrective-retrieval loop; make persisted
  GenericFacts readable at the answer layer (currently write-only).
- **Live-schema** EV-005/006, ING-002/003/005/006/007 — additive migrations + coordinator
  wiring, each verified on a throwaway DB then under the suite.
- **SwiftUI views** LAB-005–009, UX-001/003/004, EXP-001 — compile-checkable; final proof
  is running the app.

_The genuinely gated remainder (Section C) is scale runs, Apple release/signing, in-app
eval runs, and deferred GGUF — actions only you or a non-IDE environment can perform._
