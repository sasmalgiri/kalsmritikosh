# Answer-quality uplift plan — "as fluent as ChatGPT, but grounded"

Owner-approved investigation (2026-09-17). Goal: raise the **universal (`.unresolved`)
answer path** to modern advanced-RAG quality **without** weakening the evidence
gate. Grounded, on-device (Apple FM + bundled BGE), no network. Every phase is
independently shippable, tested, and owner-verified by re-running the three
diagnostic questions.

## Diagnostic baseline (proven against the live archive, 2026-09-17)
Archive: 716 docs / 10,632 chunks / 9,266 facts (`/tmp/kalsmri-audit.sqlite`).
Query **"who has drafted the claims?"** routes to `.unresolved` and returns a
**subject-field dump** (`applicant`, `applicationnumber`) + a **boilerplate
heading** (*"IN THE MATTER OF PATENT ACT…"*), with a *"not found verbatim"*
caution — instead of the real answer that FTS ranks at ~#5:
*"…finalize and file the FER response. @Khurana & Khurana…"* /
*"we have prepared a draft… amendment in claims."*

Root cause: on the universal path, **field-facts + semantically-generic
boilerplate outrank the passage that actually answers**, the **cross-encoder
reranker is not decisively applied**, there is **no vocabulary-mismatch bridge**
(question says "drafted", evidence says "prepared a draft"), and the composer
**pads instead of abstaining**.

## What already exists (reuse, don't rebuild)
- Hybrid BM25 + vector + RRF + reranker ladder: `RerankerLadder` (tiered:
  `HeuristicKeywordTier` cost 0 → `CoreMLCrossEncoderTier`), `EmbeddingReranker`.
- Adaptive/corrective retrieval: `CorrectiveRetrievalPlanner.decide()`
  (1 corrective pass budget), AEE `MissionEvidenceAssessor` / `QueryMissionCompiler`.
- Sentence-precision: `SpanCutter`, `SentenceQuoteComposer`.
- Evidence gate + abstention: `EvidenceVerifier`, `ToolGroundedComposer`, GoldWall.
- Boilerplate detection substrate: `boilerplate_templates` table.

## Invariants (never violated by any phase)
- On-device only; no network; capability discipline (no model names in Brain/…).
- Scope enforced before retrieval (SensitiveAccessContext) — unchanged.
- Every surfaced claim cites evidence or the answer abstains. No phase may let an
  unsupported sentence acquire an accepted state.
- Determinism preserved where it exists (total order on ties); any LLM step is a
  *twin/advisory* over deterministic code, never the sole authority.

---

## Phase W1 — Cross-encoder rerank decisively on the universal path  *(highest ROI, isolated)*
**Problem:** the rank-5 real passage lost to field-facts/boilerplate; the
reranker isn't the deciding step for `.unresolved`.
**Change:** in the `.unresolved` retrieval assembly (MasterBrain answer path),
after hybrid candidate gathering (top ~100), run `RerankerLadder.score` with the
`CoreMLCrossEncoderTier` as the deciding tier and keep top ~8–10 by reranked
score for the composer. Ensure **field-facts do not bypass reranking** — they
enter the same candidate pool and must earn their rank against passages.
**Files:** `Brain/MasterBrain.swift` (retrieval→compose seam), `Brain/RerankerLadder.swift`
(confirm cross-encoder tier is reachable, cost-gated), `Brain/EvidenceRanker.swift`.
**Tests:** deterministic reranker test — given a boilerplate heading, a
field-fact string, and the "prepared a draft… amendment in claims" passage for
query "who drafted the claims", the passage ranks #1. (Pure, uses a stub/real
cross-encoder tier.)
**Owner verify:** re-run the 3 questions; the drafter passage should surface.
**Risk:** latency (cross-encoder over 100). Mitigate with the ladder's
fast-path floor + cap; measure. **On-device:** CoreML, already bundled.

## Phase W2 — Corrective re-retrieve before composing a weak answer  *(depends on W1)*
**Problem:** when top evidence is boilerplate/field-only, the app composes a dump
instead of trying again.
**Change:** wire `CorrectiveRetrievalPlanner.decide()` into the `.unresolved`
path: after rerank, if the top reranked groundedness is below a floor (evidence
is generic/boilerplate or doesn't contain question content-terms), spend the
1-pass budget to re-retrieve with expanded terms, then re-rank. If still weak →
abstain (W4), never pad.
**Files:** `Brain/MasterBrain.swift`, `Brain/CorrectiveRetrievalPlanner.swift`,
`Brain/AEE/MissionEvidenceAssessor.swift`.
**Tests:** a corrective-trigger unit test (weak top evidence → `shouldRetry`);
a "still weak → abstain" path test.
**Owner verify:** a question whose evidence is thin returns "not found", not a dump.
**Risk:** one extra retrieval pass (bounded to 1). **Grounding:** unchanged.

## Phase W3 — HyDE / query rewrite to bridge vocabulary mismatch  *(depends on W1)*
**Problem:** "drafted" vs "prepared a draft… amendment" — a short question and a
long passage land far apart in embedding space.
**Change:** add an on-device **HyDE** step (Apple FM via `capabilities.resolve`):
generate a short hypothetical answer sentence, embed it (bundled BGE), and use it
as an *additional* query vector fused (RRF) with the original — never replacing
the literal query (which guards recall). Gate it: only when first-pass
groundedness is low (so common questions stay 1-call/fast, per the query-time
LLM budget). The hypothetical text is **never shown and never cited** — it only
steers retrieval.
**Files:** new `Brain/HypotheticalQueryExpander.swift` (pure, injected FM +
embedder closures), wired in `MasterBrain` retrieval; reuse `EmbeddingReranker`/
vector search.
**Tests:** pure test with a stubbed FM returning a known hypothetical → asserts
the fused query includes both vectors; intent-preservation guard (rewrite that
drops all content terms is rejected).
**Owner verify:** vocabulary-mismatch questions (drafted/prepared, paid/remitted)
now retrieve the right passage.
**Risk:** +1 FM call + drift; gated + intent-guarded. **On-device:** Apple FM only.

## Phase W4 — Abstention & anti-dump discipline on the universal path
**Problem:** the composer pads with boilerplate + field-facts instead of saying
"not found."
**Change:** before `ReasoningExpert`/composer emits, apply a **relevance gate**:
(a) drop candidates flagged boilerplate (`boilerplate_templates`) unless they
literally contain the question's content terms; (b) forbid answering a non-field
question purely from `generic_facts` subject fields; (c) if no surviving passage
addresses the question, return the honest not-found + offer the closest related
passages (never invented). Reuse `EvidenceVerifier` groundedness + GoldWall
abstention semantics.
**Files:** `Brain/EvidenceVerifier.swift`, `Brain/ToolGroundedComposer.swift`,
`Experts/ReasoningExpert.swift` (stop framing bare field dumps as "The source says").
**Tests:** "who drafted the claims" with only boilerplate+fields available →
abstains; adversarial: boilerplate heading cannot become the answer.
**Owner verify:** unanswerable-from-archive questions abstain cleanly.
**Risk:** could over-abstain; tune the content-term floor with the metric (W6).

## Phase W5 — `.actor` fast-path shape  *(precision bonus, after W1–W4)*
**Change:** add `QuestionShape.actor` ("who *drafted/prepared/filed/signed/wrote/
sent* …") distinct from `role`; route to an actor-selector that requires a
passage containing the action verb + object and names the acting party; falls to
the (now-improved) universal path if none. Twin detector updated; safest-order
placement.
**Files:** `Brain/QuestionShapeRouter.swift` (+ twin), a small actor selector,
composer hook.
**Tests:** router classification for a dozen actor phrasings + twin agreement;
"who drafted the claims" → actor → attorney passage.
**Risk:** low (additive shape; universal path is the fallback).

## Phase W6 — Evidence metrics harness (measure, don't guess)  *(parallel; gates the rest)*
**Change:** a deterministic eval over a small gold set (10–20 real questions incl.
the 3 diagnostics) measuring **separately** (directive §6.3): retrieval recall@k,
source-identity correctness, claim support/groundedness, unanswerable handling,
conflict detection, scope violations. Emit one report; wire a CI floor so a phase
can't regress groundedness to gain recall.
**Files:** new `KalsmritikoshTests/AnswerQualityEvalTests.swift` + a gold fixture
(synthetic + de-identified real-shaped), reuse existing eval scaffolding.
**Verify:** before/after each phase, the report shows the intended lift with no
groundedness regression.

---

## Dependency order & sequencing
1. **W6 metrics harness** (baseline numbers first — so every later phase is proven).
2. **W1 rerank-on-universal-path** (biggest single lift; likely fixes the example).
3. **W4 abstention/anti-dump** (bounds the failure mode to honest not-found).
4. **W2 corrective re-retrieve** (recovers thin-evidence cases).
5. **W3 HyDE** (bridges remaining vocabulary-mismatch misses).
6. **W5 `.actor` shape** (precision polish).

Each phase: implement → unit tests green → build green → **owner re-runs the 3
diagnostic questions + spot-checks 5 of their own** → commit → next.

## Owner-verification checkpoints (cannot be done headlessly)
Rendering/latency/answer-feel must be judged in the running app. After W1 and
again after W4, the owner runs the diagnostic set and confirms: (a) the drafter
passage surfaces, (b) genuinely-absent facts abstain, (c) latency acceptable.

## Explicit non-goals (protect the moat)
- No answering from the model's own world knowledge (that is ChatGPT's
  hallucination mode; ours abstains).
- No network retrieval / web tools in the release path.
- No replacing deterministic routing/verification with an LLM as sole authority —
  LLM steps stay advisory/twin over deterministic code.
