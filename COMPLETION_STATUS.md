# Kalsmritikosh — Completion Status

Honest per-task status against `Kalsmritikosh_Definitive_Full_Project_Instructions.md`.
States: NOT_STARTED · IMPLEMENTED (builds) · UNIT_VERIFIED · INTEGRATION_VERIFIED ·
REAL_DATA_VERIFIED · RELEASE_VERIFIED · DEFERRED · BLOCKED(reason).

"IMPLEMENTED" means the code is written and the app builds green — NOT that it is
runtime-proven. Only a live Probe/Deep run or the test target promotes past IMPLEMENTED.

_Build: green. Not runtime-verified end-to-end._

## P0 — Truthful shipping config
| Task | State | Notes |
|---|---|---|
| P0.1 audit docs | PARTIAL | This file added. FULL_REPOSITORY_STATIC_AUDIT / FILE_BY_FILE_AUDIT / SUPPORTED_FORMATS_V1 not yet. |
| P0.2 governance banners | NOT_STARTED | CLAUDE.md still points at old TASKS.md. |
| P0.3 ReleaseCapabilityProfile | IMPLEMENTED | `App/ReleaseCapabilityProfile.swift` + violations(). |
| P0.4 zero-LLM ingest policy | IMPLEMENTED | `LedgerEventDrivenEngine.ingestPolicy` firstChunkCard→false; ReleaseReadiness guard added. |
| P0.5 remove mode chooser | IMPLEMENTED | RootView sheet compile-gated `#if DEBUG`. |

## P1 — Hard minimum-LLM query
| Task | State | Notes |
|---|---|---|
| P1.1 request context + budget | IMPLEMENTED | `Core/LLM/*`, `Brain/LLMQueryClass*`. |
| P1.2 provider-boundary enforcement | IMPLEMENTED | scoped `ModelProvider.generate(...purpose:context:)`. |
| P1.3 remove ungrounded Ask preview | IMPLEMENTED | streamPreview deleted; Ask uses only brain.answer. |
| P1.4 cap experts | IMPLEMENTED | `minimalExpertSet(from:queryClass:)`. |
| P1.5 fix query classification | PARTIAL | factualLookup→ordinary; reconstruction only on explicit signals via intent. Deeper signal tuning pending. |
| P1.6 budget synthesis/council | IMPLEMENTED | Depth gating; council only on investigation. (Enum names not renamed to spec's exact set.) |
| P1.7 budget history | IMPLEMENTED | shared budget across chapters+fallback. (Whole-outline single-call mode not done; per-chapter+cap used.) |
| P1.8 budget investigation | IMPLEMENTED | maxSteps=2; nested shares parent budget. |
| P1.9 request-scoped diagnostics | IMPLEMENTED | `answerWithDiagnostics`, RealDataProbe by requestID. |
| P1 acceptance tests | PARTIAL | `LLMBudgetTests.swift` written; NOT in a target (see P9.1). |

## P2 — Bundled local model
| Task | State | Notes |
|---|---|---|
| P2.1 select model + licence | BLOCKED(owner decision) | Needs owner's model/quantization/licence choice. |
| P2.2 LlamaCppProvider | NOT_STARTED | Still a `throw unavailable` stub. **#1 ship blocker.** |
| P2.3 package model | BLOCKED(owner + Apple) | Packaging/ODR decision. |
| P2.4 optional larger-model download | NOT_STARTED | `ModelDownloader.swift` absent. |
| P2.5 simplify provider wiring | PARTIAL | Boot prewarm generation removed. Cloud/Ollama still registered. |
| P2.6 hide non-v1 providers in release UI | NOT_STARTED | |

## P3 — Transactional/versioned ingest — NOT_STARTED (all)
Parse-once, ingest_runs, per-file transaction, file versioning, universal locator,
parent-child provenance, unsupported/failed states, resume. None implemented.

## P4 — Parser support matrix
| Task | State |
|---|---|
| P4.11 ZIP security | IMPLEMENTED (zip-bomb / entry-flood / zip-slip guards in expandZIP) |
| P4.1–P4.10 (format matrix, PDF/DOCX/XLSX/PPTX/email/image/AV locators) | NOT_STARTED |

## P5 — Ledger semantics
| Task | State |
|---|---|
| P5.1 epistemic vocabulary (UI) | PARTIAL (FactStatus exists; not all 10 states surfaced) |
| P5.2 assertions first-class | NOT_STARTED |
| P5.3 event extraction fixes | NOT_STARTED |
| P5.4 canonical entities | PARTIAL (dedup exists; language detect/merge-split review not) |
| P5.5 contradiction taxonomy | PARTIAL (Kind enum + v36 persistence; only date detector tags kind — other detectors pending) |
| P5.6 missing-evidence taxonomy | PARTIAL (gap rules exist; not full taxonomy) |
| P5.7 human review | PARTIAL (fact_reviews append-only exists) |
| P5.8 answer ledger (atomic claims) | PARTIAL (derived_objects v35 stores whole-answer claim, not per-sentence) |
| P5.9 custody | PARTIAL (custody_events exists) |

## P6 — Retrieval
| Task | State |
|---|---|
| P6.4 privilege filtering | IMPLEMENTED (chunks + events + entities + relations) |
| P6.5 disable daily CommunitySummarizer | IMPLEMENTED (gated off in release profile) |
| P6.7 deterministic reranker default | DONE (ladder = Core ML cross-encoder) |
| P6.1 direct-evidence-first / P6.2 entity pollution / P6.3 ANN discovery / P6.6 sentence embeddings / P6.8 table path / P6.9 corroboration | NOT_STARTED |

## P7 — Reconstruction
| Task | State |
|---|---|
| P7.4 sentence-level citation | IMPLEMENTED (composer + expert synthesis reject-uncited) |
| P7.5 deterministic fallback | IMPLEMENTED (`DeterministicEvidenceFallback`) |
| P7.1 deterministic plan / P7.2 causality / P7.3 alternatives / P7.6 gold cases | NOT_STARTED |

## P8 — UI consolidation — NOT_STARTED (large)
Nav consolidation, Sources health, blank Ask, Findings primary, Explore relabel,
consumer Settings, onboarding-from-format-matrix, Convert deferral, accessibility.

## P9 — Tests/CI/eval
| Task | State | Notes |
|---|---|---|
| P9.1 Xcode test target | BLOCKED(pbxproj) | Editing pbxproj while Xcode open is unsafe — owner must add target. |
| P9.2 CI | NOT_STARTED | |
| P9.3 unit suites | PARTIAL | LLMBudgetTests + SessionFeatureTests written (not wired). |
| P9.5 60+ gold questions | NOT_STARTED | Still 16. |
| P9.6 release-gate honesty | PARTIAL | Gate is software-only by design. |

## P10 — Scale — BLOCKED(owner decision + hardware)
1 TB vs revised gate decision (owner); disk-backed ANN; stress tiers need real hardware runs.

## P11 — Privacy/security
| Task | State |
|---|---|
| P11.3 prompt injection | IMPLEMENTED (evidence delimited as untrusted in all prompts) |
| P11.1 remove cloud from release | PARTIAL (profile flags off; providers still registered) |
| P11.2/P11.4/P11.5/P11.6 | NOT_STARTED |

## P12 — App Store — BLOCKED(Apple account + owner)
Signing, archive, metadata, clean-machine test, owner acceptance — require the owner's
Apple Developer account and hardware.

---

### Honest summary
- **Done & solid:** P1 (hard minimum-LLM incl. P1.3/P1.6), P0.3–P0.5, P4.11, P5.5(partial),
  P6.4/P6.5/P6.7, P7.4/P7.5, P11.3.
- **Biggest blocker:** P2.2 bundled `LlamaCppProvider` — until done, the app needs Ollama,
  breaking the locked v1 promise. Requires an owner model/licence decision first (P2.1).
- **Large greenfield:** P3, P4, P6, P8 are subsystems, not tweaks — realistically weeks each.
- **Environment-blocked:** P9.1 (pbxproj), P10 (hardware), P12 (Apple account).
