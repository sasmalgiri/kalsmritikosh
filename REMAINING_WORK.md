> **DOC STATUS: HISTORICAL** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Superseded by PRODUCTION_BACKLOG.csv. _(bannered 2026-07-22, GOV-002.)_

# Kalsmritikosh — Remaining Work & Handoff

> **SUPERSEDED for planning by `PROJECT_COMPLETION_INSTRUCTIONS.md`** (authoritative
> tracker with per-task IDs, status, and blockers). Retained for history.

Companion to `COMPLETION_STATUS.md`. This file answers three questions for every
outstanding item: **what remains**, **why it isn't done**, and **who/what unblocks it**
(owner decision, environment/account, another coding agent, or a research agent).

Audited against `Kalsmritikosh_Definitive_Full_Project_Instructions.md`.
Build state: green. All committed work is on `origin/main`.

---

## Legend — who unblocks it
- **OWNER** — a decision only the product owner can make (licence, gate size, taste).
- **ENV** — an environment/account I cannot access (Xcode pbxproj, Apple Developer, hardware).
- **CODE-AGENT** — a coding agent can implement it (me or a subagent) given a scoped spec.
- **RESEARCH-AGENT** — a web-research agent can gather the facts needed to decide.

---

## 1. Blocked on an OWNER decision (no code possible until decided)

| Item | Remaining | Why not done | Unblocks |
|---|---|---|---|
| **P2.1 / P2.2** | Real bundled `LlamaCppProvider` (load, stream, cancel, context-window, structured JSON, memory-pressure, budget integration) | Spec forbids coding until the exact model + quantization + **licence / redistribution rights** are recorded. Must not assume a licence. **This is the #1 ship blocker — until done, the app still needs Ollama.** | OWNER (pick model) + RESEARCH-AGENT (candidate comparison) |
| **P2.3** | Model packaging (app bundle vs On-Demand-Resource vs first-launch download) | Depends on App Store size limits + owner's hosting choice | OWNER + RESEARCH-AGENT |
| **P6.6** | Bundle a real sentence-level embedding model (replace word-average NLEmbedding) | Same licence/redistribution gate as P2.1 | OWNER + RESEARCH-AGENT |
| **P10.1** | 1 TB scale gate: build disk-backed/sharded ANN, OR revise the locked gate | In-memory HNSW can't credibly do 1 TB on 8 GB RAM; product decision first | OWNER, then CODE-AGENT (large) |

## 2. Blocked on ENVIRONMENT / ACCOUNTS (cannot be done from this agent)

| Item | Remaining | Why not done | Unblocks |
|---|---|---|---|
| **P9.1** | Add the Xcode unit-test target; wire `LLMBudgetTests.swift` + `SessionFeatureTests.swift` | Editing `project.pbxproj` while Xcode is open risks crashing Xcode; blocked by steering rules. Test files exist, just unwired. | ENV (owner in Xcode) |
| **P12.1** | Fix `productName = "Atlas chronica memora"`, release signing, archive config | pbxproj + signing certs | ENV (owner in Xcode) |
| **P12.2–12.5** | Migration matrix run, clean-machine install, owner 100 GB test, App Store metadata/screenshots | Needs Apple Developer account + real hardware + real archives | ENV (owner) |
| **P10.2** | Stress tiers 1/10/100 GB / 1 TB with RAM/thermal metrics | Real large archives + hours of hardware time | ENV (owner) |

## 3. Large GREENFIELD subsystems (a coding agent can do — weeks each, needs scoping)

Each touches schema and/or the live DB and core behaviour. The spec explicitly warns
against a fast broad rewrite; these must be done one task / one commit / with acceptance
checks. **Not** quick safe commits.

| Phase | Remaining | Why not done | Unblocks |
|---|---|---|---|
| **P3** | Transactional/versioned ingest: parse-once, `ingest_runs`/`parser_runs`, per-file commit-or-rollback, file versioning (supersedes/valid_from/to), universal source locator, parent-child provenance, resume/recovery | Large; rewrites IngestCoordinator + several schema migrations; high risk to rush | CODE-AGENT (scoped) |
| **P4.1–4.10** | Real parser matrix + per-format exact locators (PDF block/OCR-confidence/boxes, DOCX heading path, XLSX structured cells + numeric/table query, PPTX, email threading, image boxes, A/V timestamps) + `SUPPORTED_FORMATS_V1.md` | Each loader is a focused project with fixtures | CODE-AGENT per format (parallelizable) |
| **P5.2 / 5.3 / 5.8** | Assertions first-class; event-extraction fixes (sent vs received, event-specific entities/dates, dedup, commitments-as-assertions); atomic answer-ledger (per-claim, not whole-answer) | Reworks extraction + ledger core | CODE-AGENT (scoped) |
| **P5.1 / 5.4 / 5.6 / 5.7** | Surface full epistemic vocabulary in UI; entity merge/split review + language detection; full missing-evidence taxonomy; reversible human-review actions | Mix of UI + model work | CODE-AGENT |
| **P6.1 / 6.3 / 6.8 / 6.9** | Direct-evidence-first fusion (memory NOT top authority); independent ANN candidate discovery; structured table query path; corroboration = independent sources | Retrieval-quality rewrite; needs the 60-question eval to prove no regression | CODE-AGENT (after P9.5) |
| **P7.1 / 7.2 / 7.3 / 7.6** | Deterministic reconstruction outline; causality discipline; alternative histories; 5 mixed-source gold cases | The differentiating workflow; needs gold data authored | CODE-AGENT + OWNER (gold data review) |
| **P8** | UI consolidation: nav (Home/Sources/Ask/History/Findings/Explore/Search/Settings), Sources health, blank Ask, Findings primary, consumer Settings, onboarding from format matrix, Convert deferral, accessibility | Broad UI; needs product taste | CODE-AGENT + OWNER (taste) |
| **P9.2 / 9.5** | CI workflow (`build-and-guard.yml` verify + test + guard + fixtures); expand eval 16 → 60+ gold questions | 60 questions need **gold answers authored** for the fixture | CODE-AGENT + OWNER (gold answers) |
| **P0.2** | Governance banners on historical docs; point CLAUDE.md at this plan | Low-risk doc work | CODE-AGENT |

## 4. Smaller code items still open (low risk, could be done next)

| Item | Remaining |
|---|---|
| **P5.5 (finish)** | Detectors for the non-date contradiction kinds (amount/identity/payment/…) — vocabulary + persistence already landed |
| **P6.5 (finish)** | Lazy community-summary generation when a topic is opened (daily sweep already disabled) |
| **P11.1** | Stop registering cloud/Ollama providers in the release path (profile flags already off; wiring still registers them) |
| **P11.2 / 11.5 / 11.6** | Network-entitlement docs; privacy warning on inventory/eval exports; host Privacy Policy / Terms / licences |
| **P2.4** | `ModelDownloader.swift` (resumable, SHA-256 verified, atomic) — depends on P2.1 |

---

## Recommended next action

**Make the P2.1 model decision.** It is the single highest-leverage unblock: it gates
P2.2/P2.3/P2.5/P2.6 and most of P12, and until it lands the app cannot ship as promised
(it still needs Ollama). A RESEARCH-AGENT can produce a model-candidate comparison
(licence · redistribution · size · RAM · tokens/sec on M1 · quality) so the owner decides
from real data; then a CODE-AGENT implements `LlamaCppProvider`.

After that, the highest-value CODE-AGENT work — in order — is:
**P9.5 (60-question gold set) → P6 retrieval quality → P3 transactional ingest → P8 UI.**
Everything else (P10, P12) is environment/owner-gated.
