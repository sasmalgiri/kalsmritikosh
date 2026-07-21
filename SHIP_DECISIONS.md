# kalsmritikosh — Ship Decisions (LOCKED)

**Status: CURRENT.** Authority chain: the *Production Readiness Instruction Pack*
(`01_MASTER_PRODUCTION_DIRECTIVE`, `03_LOCKED_PRODUCT_CONTRACT_AND_MOAT`) → this file →
committed code → tests. When this file conflicts with an older tracker, this file wins.
Any change to a product claim, model, minimum OS, supported format, scale, privacy
behaviour, release provider, evidence vocabulary or persona list **requires a dated entry
in the change-control log at the bottom**.

Every technical number here must name its verification evidence, or be marked *unverified*.

---

## 1. Locked product contract (v1)

| Area | Decision | Implication |
|---|---|---|
| **Reasoning model** | **Apple Foundation Models where available; deterministic evidence engine always works with zero model.** No bundled Llama, no Ollama, no cloud in the release build. | Release ships no third-party LLM weights. On a Mac where Foundation Models is unavailable, the app is honestly deterministic-only (search, timelines, matrices, contradictions, gaps, deterministic reports) and must not claim "AI answers" it cannot produce. Optional downloaded local GGUF is a **v1.x** possibility, gated on the §6 checks — **not** in v1. |
| **Embedding model** | **Bundled BGE-small-en-v1.5 (MIT), 384-dim Core ML (~130 MB).** | Fixed dimension corpus-wide; reuses the existing BGE tokenizer/reranker infra. NLEmbedding remains only as a clearly-labelled degraded fallback. A re-embedding migration re-vectorizes on model change. |
| **Minimum OS** | **macOS 26.** | Apple Intelligence / Foundation Models baseline. Requires `MACOSX_DEPLOYMENT_TARGET = 26.0` in pbxproj (owner-run, Xcode-closed step). |
| **Network / privacy** | **No network provider in the release build.** | `PrivacyGate` filters all cloud providers out of capability resolution; the only network code path (Routing/Providers) is compiled out or unreachable in release. Fully offline. Ollama/MLX/Cloud stay compiled but dev/internal-only (`#if DEBUG`). |
| **Advertised scale** | **"Tested to <N> GB" only — where N is a recorded owner-hardware run.** | No 100 GB / 1 TB marketing claim until a real run is recorded (§ship gates). The disk-backed/sharded ANN (task P9.3) remains the scale engineering item; until it and a measured run exist, copy states only the tested figure. |
| **Distribution** | **Mac App Store only.** | Apple payment + review; App Sandbox mandatory (already configured). No DMG/notarization path at launch, no license server. |
| **Pricing** | **$29–49 one-time, Personal tier.** | Pro tier deferred to v1.x. |
| **Launch claim** | **Early access — "works with mixed document collections."** | Never "understands every document"; never list a format that has not passed the declared matrix; never claim universal AI answers where no reasoning provider can resolve. |
| **Personas** | **Five lenses over one engine:** Lawyer, Investigator, Journalist, Researcher/Historian, Individual. | Persona changes terminology/work-cards/defaults only — never evidence, truth state, confidence, contradiction logic or source independence. No sixth persona before release. |
| **Evidence vocabulary** | One vocabulary across storage/UI/exports: `DIRECTLY_OBSERVED`, `SOURCE_ASSERTED`, `DETERMINISTICALLY_DERIVED`, `INFERRED`, `CONTRADICTED`, `UNSUPPORTED`, `MISSING_EVIDENCE`, `HUMAN_CONFIRMED`, `HUMAN_CORRECTED`, `HUMAN_REJECTED`. | Model text is never primary evidence; human-confirmed is not automatically proven; contradictions show both sides; missing evidence states searched scope. |

## 2. Answer modes (both share one evidence ledger and truth rules)

| Mode | Contract |
|---|---|
| **Fast** | Currently-queryable evidence; deterministic exact paths first; zero model calls when possible; **max 1 generative call** for an ordinary supported question; shows readiness/coverage limits; never fabricates missing fields. |
| **Deep Analysis** | Completes required deferred work for the scope; broader structured/lexical/dense/temporal/graph evidence; may decompose within a hard request budget; selects only necessary experts; builds contradictions/gaps/alternatives; shows expected resource use and permits cancellation. |

Hard generative-call budgets (enforced, shared across classifier/experts/planner/synthesis/retry/fallback; a failed call still consumes budget): deterministic 0, ordinary 1, moderate 2, complex 3, reconstruction 3, deep-reconstruction 5, investigation 5, unsupported 0.

## 3. Ship gates (ALL must be true before App Store submission)

- [ ] Reasoning path: Apple Foundation Models resolves on macOS 26 target hardware **or** the app clearly presents deterministic-only mode. No Ollama/cloud/terminal dependency.
- [ ] Bundled BGE embedder loads with the correct WordPiece tokenizer, fixed ID/dimension; re-embedding migration proven; mixed-model rejection enforced. *(P6.2)*
- [ ] Retrieval: query-conditioned document-fitness authority (RET-001/RET-003) replaces the density heuristic; real-corpus questions cite the authoritative source; eval gate no regression. *(unverified until RET-003 lands + measured)*
- [ ] Executable macOS test target exists and CI runs unit + integration + migration + retrieval-eval + security tests as a mandatory merge gate. *(TST-001/CI-001 — owner-run, Xcode-closed)*
- [ ] Every material answer claim opens its exact source locator; unsupported claims excluded from final output.
- [ ] Redaction: exported work products verified for text **and** visual/binary redaction. *(F7 — safety-critical, deferred)*
- [ ] Privacy: network audit confirms no egress in release; `PrivacyInfo.xcprivacy` present; sensitive-logging audited.
- [ ] Scale: index-strategy selector (in-memory HNSW ↔ disk-backed ANN) + a **recorded** owner-hardware run at the marketed figure. *(P9.3 + P9.2)*
- [ ] Owner self-test: personal archive ingested; ~20 representative real questions answered correctly with openable citations.
- [ ] Clean-machine install on a Mac that never had Xcode/the app; offline replay of a historical answer against its corpus snapshot.
- [ ] Privacy Policy + Terms/EULA hosted and linked; App Store metadata complete (no PII in screenshots); release notes state "early access."

## 4. Out of scope for v1.0 (defer to v1.x)

- Optional downloaded local GGUF reasoning runtime (llama.cpp binding, licence, App Store checks) — **P1.2/P3.1 DEFERRED**.
- Pro tier definition/pricing; DMG distribution; cloud-routed model; multi-language UI; iOS/iPad companion.
- Legacy binary Office edge cases beyond the tested matrix; PST/OST/NSF email formats.
- 1 TB advertised scale (until a recorded run exists).

## 5. Change-control log

- **2026-07-22 (GOV-001, this rewrite):** Model/OS contract **resolved and flipped**. v1 reasoning = **Apple Foundation Models + deterministic engine**, **no bundled Llama, no Ollama/cloud in release**; **minimum OS macOS 26**; embedding = bundled BGE-small (unchanged); advertised scale = **tested-figure-only, no 100 GB/1 TB claim without a recorded run**. Consequences: llama.cpp packaging (P1.2) and GGUF bundling (P3.1) **DEFERRED to v1.x**; Llama licence work (P3.2) retained only for that optional path. Superseded the 2026-07-13 "bundled Llama-3.2-3B / macOS 15.6 / 8 GB floor" decision (preserved below). Removed obsolete "currently N" eval numbers — live status now lives in `PRODUCTION_STATUS.md` (GOV-003).
- **2026-07-13:** Locked BGE-small embedder; adopted dual-mode dynamic scale; confirmed (now-superseded) Llama-3.2-3B bundled default + 8B optional.
- **2026-06-18:** Gate 1 baseline lock (`4bcf4e5`); G2-0 partial rollback (`7b23986`); G2-PROGRESSIVE spec (`e9486e9`); Mac App Store + one-time pricing + macOS 15.6 (now raised to 26).

---

## Appendix — SUPERSEDED decisions (historical, do not act on)

> Retained per document-governance rule ("never delete history"). These reflect the
> 2026-07-13 contract and are **no longer in force** after the 2026-07-22 flip above.

- **Reasoning (superseded):** bundled Llama-3.2-3B Q4 default + optional 8B download, tiered by detected RAM; `LlamaCppProvider` unstubbed; no Ollama for end users.
- **Minimum OS (superseded):** macOS 15.6; **Minimum RAM:** 8 GB floor paired with the 3B default.
- **Scale (superseded wording):** "tested to 100 GB" until a 1 TB run passed; the dual-mode selector itself remains the plan, only the marketing figure rule tightened.
- The 2026-07-13 "currently 0.33 / 0.50 / 0.54" eval numbers and the 10-tester→owner-self-test ("Set C-prime") gate history are retained in `docs/history/` and superseded by the current ship gates + `PRODUCTION_STATUS.md`.
