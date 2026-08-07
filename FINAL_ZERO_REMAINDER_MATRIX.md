# FINAL_ZERO_REMAINDER_MATRIX — release-closure directive §53

_Assembled 2026-08-07 from a FRESH audit of the repository (not prior claims): the release-
closure macros B–F + P9.3 (PRs #70–#76), the §46 zero-stub audit, the §47 dead-code audit,
the §48 live-wiring audit, and the hosted CI evidence in `RELEASE_EVIDENCE_INDEX.md` /
`ci/test-baseline.json`. Status vocabulary: **COMPLETE** (agent-verifiable, done) ·
**OWNER** (genuinely owner-dependent: private data / hardware / Apple account / legal /
physical machine)._

Baseline at assembly: schema **v103**, whole-suite floor **3400** (rises with PR #76),
migration floor **385**, parser-fixtures floor **126**, **8** architecture guards,
**7** named CI checks (incl. `release-build`).

| Requirement | Code | Live wiring | UI | Persistence | Automated test | Release proof | Owner action | Status |
|---|---|---|---|---|---|---|---|---|
| Release config: GOV-004 15.6 adaptive floor, offline Release, Ollama DEBUG-only | ✓ | ✓ AppState gating | n/a | pbxproj | release-configuration guard | release-build CI check, PR #70 | — | **COMPLETE** |
| Release configuration compiles | ✓ (OPS-003C port) | ✓ | n/a | n/a | — | release-build check every push | — | **COMPLETE** |
| Citation integrity F3 (authority union) | ✓ CitationResolver | ✓ EvidenceVerifier+AppState | citations open sources | ledger | 15 tests (PR #71) | INTEGRATION, run 31168181813 | — | **COMPLETE** |
| Redaction S3 (generated exports, output-representation level) | ✓ | ✓ export service | export UI | — | ReleaseSecurityGateTests (PR #72) | INTEGRATION | — | **COMPLETE** (visual source redaction honestly out of v1, RED-002) |
| Temp-export hygiene S4 | ✓ | ✓ | — | — | 2 tests (PR #72) | INTEGRATION | — | **COMPLETE** |
| Archive/malformed hardening S6 | ✓ USF-M2 | ✓ ingest | manifests visible | ledger | ContainerSafety+Integration (+ parser gate) | INTEGRATION | — | **COMPLETE** |
| SensitiveScope S2 | ✓ | ✓ | ✓ | ✓ | 122-test named check | PASS (pre-existing) | — | **COMPLETE** |
| Advertised-format matrix F1 | ✓ | ✓ registry | Library | ledger | parser-fixtures floor 126 (PR #73) | INTEGRATION | — | **COMPLETE** |
| Five-persona coverage F2 (71 jobs, live routing) | ✓ | ✓ all 15 services non-nil (§48 audit) | PersonaJobsView | ✓ | PersonaJobMatrixCoverageTests (PR #73) | INTEGRATION | §E journeys | **COMPLETE** (code half) / **OWNER** (§E acceptance) |
| Truth gate T1 (persona-neutral truth) | ✓ by construction | ✓ | same destinations | — | 4 tests + persona-neutral-truth guard (PR #74) | INTEGRATION | — | **COMPLETE** |
| Truth gate T3 (duplicate independence) | ✓ shared builder | ✓ HybridRetriever keys | — | — | 6 tests (PR #74) | INTEGRATION | — | **COMPLETE** |
| §19 deterministic 60Q retrieval eval | ✓ harness | ✓ | — | — | RetrievalGoldEvalTests, measured floors | hosted (PR #74) | — | **COMPLETE** |
| §20 answer/citation eval harness | ✓ EvalKitRunner+GoldEvalGate | DEBUG diagnostics | SettingsView (DEBUG) | reports | SmokeTest T12 | — | run on target hardware | **COMPLETE** (harness) / **OWNER** (run) |
| Methods MET-01..16 | ✓ 16/16 + validators | ✓ engine + services | persona jobs | MethodRunRepository | lifecycle/reopen suites | — | — | **COMPLETE** |
| Workbench/DataLab LAB-001..006 | ✓ | ✓ | TableWorkbenchView | ✓ | LAB suites | — | — | **COMPLETE** |
| Fast/Full Evidence naming + budgets | ✓ | ✓ | shipped strings | — | LLMBudgetTests 8/8 | — | — | **COMPLETE** |
| Autosave/resume | ✓ | ✓ | ✓ | ✓ | reopen suites (nav/workflow/method/lab/product/approval/closure/receipt) | — | — | **COMPLETE** |
| P9.3 disk ANN + selector + benchmarks (GOV-005) | ✓ 9/9 steps | ✓ boot+scheduler | transparent | v103 ledger | 36 tests (PR #76) | release-build + hosted run | SC1 run on new selector | **COMPLETE** (engineering) / **OWNER** (SC1 figure) |
| Migration/recovery | ✓ v103 head | ✓ | — | ✓ | migration-matrix floor 385 | named check | sanitized-archive one-command | **COMPLETE** / **OWNER** (archive run) |
| Zero-stub §46 | ✓ | — | — | — | audit 2026-08-07 | — | — | **COMPLETE** (0 blocking; 3 gated provider stubs verified Release-unreachable + labelled; 1 non-blocking defaults-backed settings TODO) |
| Dead code §47 / live wiring §48 | ✓ | ✓ | ✓ | — | audit 2026-08-07 | — | — | **COMPLETE** (zero dead code; all components created→consumed→reachable) |
| Accessibility §33 | ✓ (2026-08-06 hardening audit; custody-icon label fixed) | — | ✓ | — | — | — | VoiceOver manual pass (in acceptance checklist) | **COMPLETE** (static) / **OWNER** (VoiceOver witness) |
| Release docs current §44/§45 | ✓ | — | — | — | — | PR #75 (v102→v103 era facts, provider matrix, honest metrics) | — | **COMPLETE** |
| App Store copy / legal drafts §41/§42 | ✓ release/ + docs/legal + docs/website; overclaim audit clean (no 1 TB/unlimited/Ollama) | — | — | — | — | — | insert contacts, host pages, review | **COMPLETE** (drafts) / **OWNER** (host + sign) |
| Owner harnesses §32/§36/§37/§38/§39 | ✓ OWNER_ACCEPTANCE_CHECKLIST + CLEAN_MACHINE_ACCEPTANCE + verify-real-archive.sh + ANNBenchmark + egress procedure | — | — | — | ANNBenchmarkTests (harness proven) | — | execute them | **COMPLETE** (prepared) / **OWNER** (execution) |
| Branch ruleset requires all checks | — | — | — | — | — | — | repo settings: add release-build to required checks | **OWNER** |
| Apple archive/sign/upload/submit AS1–AS11 | prerequisites ✓ (bundle id, entitlements, PrivacyInfo, no debug UI in Release, provider matrix) | — | — | — | — | release-build check | credentials + App Store Connect | **OWNER** |

## KNOWN AGENT-COMPLETABLE IMPLEMENTATION REMAINDER: **0**

Every software-controlled row above is COMPLETE. The remaining rows are the directive's
OWNER-ONLY classes A–G verbatim (private archive, owner hardware, clean physical Mac, Apple
credentials, screenshots, hosting, legal sign-off) — sequenced in `OWNER_RELEASE_RUNBOOK.md`.

_Repeat-audit note (§54): this matrix was assembled after a second-pass fresh audit (the
2026-08-06 hardening audit found and fixed 3 defects; the 2026-08-07 audits above found 0
new product-relevant defects). Statuses cite their evidence; nothing is PASS on assertion._
