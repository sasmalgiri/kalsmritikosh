# AI-Modes plan — two toggleable AI regimes for A/B testing, + the topic leap

Date 2026-09-20. Purpose: give the owner **two switchable AI regimes** so we can run the
SAME archive both ways, compare answer + topic quality, and keep whichever wins — plus the
one build that the live-DB evidence says will actually raise quality (AI subject resolution).

Everything here is a **module** (Settings → Modules), on/off, old behaviour preserved as the
default where a change touches the ledger.

---

## 0. What the live DB already proves (2026-09-20 snapshot, 209 docs)
- **Facts: 142 total / 142 distinct → 0% duplicates.** The dedup rule is working; the ledger
  is clean. Fact values are plausible (`role=Senior Manager`, `employer=Chinese Chemical`).
- **Topics: 70** (33 person · 16 org · 21 topic), built **deterministically (no AI)** — narratives
  are bulleted field-dumps, not prose.
- **Two real weaknesses (this is what to fix):**
  1. **Document-scoped subjects** — one real subject is split across several topics (five separate
     topics for one résumé: `RESUME_2…`, `RESUME_ for Riyaz`, `Resume…`). Deterministic
     minimization folds *thin* topics into a substantive one but never **merges two substantive
     document-copies of the same subject**. ~20 of 70 topics are document-keyed.
  2. **Terse narratives** — field lists, no connective prose (FM polish didn't run).
- **Conclusion:** the deterministic pipeline meets the *clean-ledger* goal but NOT the
  *few-real-world-subject-topics* goal. AI can close that gap — see §3.

---

## 1. The two AI regimes (mutually-exclusive preset modules)

A single **AI Mode** selector in Settings → Modules with two positions; each flips a coherent
set of sub-flags. Exactly one is active.

### Module `aiModeUnconstrained` — "AI everywhere, free"
- The model composes/builds **everywhere with no throttle**: minimum-LLM budget OFF, synthesis
  ALWAYS on (every answer + every topic), evidence-gate relaxed to **advisory** (the sentence-
  citation validator and FactLockGate WARN instead of reject), topic build runs AI subject-
  clustering + prose freely, HyDE always on.
- Goal: see the CEILING of fluency/coverage. **Risk (disclosed in-UI):** may state ungrounded or
  wrong facts; answers carry a bright "unconstrained AI — verify everything" banner and are NOT
  written to the durable evidence ledger as verified.

### Module `aiModeGuided` — "AI as per our suggestions" (DEFAULT)
- The model runs under the guardrails we built: **evidence-gated** (every factual sentence must
  cite; ungrounded prose rejected → deterministic body), **fact-preserving** (FactLockGate blocks
  invented numbers/dates), **topic-first** (answers drawn from distilled topics), **minimum-LLM**
  budget respected, AI subject-clustering/prose under the fact-preserving guard.
- Goal: maximum fluency that stays provably grounded — the product's contract.

### Module `aiModeOff` (implicit) — no model
- Deterministic only (today's behaviour when Apple Intelligence is off). Always the safe floor.

> The selector writes the sub-flags below; power users can still override any single sub-flag.

---

## 2. The sub-flag modules each regime sets (already exist unless marked NEW)
| Sub-capability | Unconstrained | Guided | Module |
|---|---|---|---|
| Compose every answer | on | on | `aiComposeEveryAnswer` ✅ |
| Topic-first answering | on | on | `topicSeededComposers` ✅ |
| Evidence-gate (reject uncited) | **advisory** | enforce | `answerEvidenceGate` **NEW** |
| Fact-lock (block invented numbers) | **advisory** | enforce | `answerFactLock` **NEW** |
| Minimum-LLM budget | off (unlimited) | on | `queryLLMBudget` **NEW** |
| HyDE expansion | always | on-weak-pass | `hydeExpansion` ✅ (add always-mode) |
| Topic prose polish | on | on | `topicProsePolish` **NEW flag over existing polisher** |
| AI subject clustering (see §3) | on | on | `aiSubjectResolution` **NEW** |

---

## 3. The quality leap the DB evidence demands — `aiSubjectResolution` (NEW, gated)
- **Problem (proven):** 5 topics for 1 résumé; ~20 document-keyed topics.
- **Build:** in `AppState.buildTopics`, before spines, run an AI pass (fact-preserving, evidence-
  gated) that **clusters same-subject documents/labels into one canonical subject** (résumé copies →
  one person). Model proposes clusters; a deterministic guard requires shared entities/values before
  a merge is accepted (no blind merges). Then build + polish per canonical subject.
- **Effect:** 70 document-shaped topics → a smaller set of real-world subject topics — the
  "upside-down tree" goal. Default OFF (ledger-scoping change; opt-in), on in both AI regimes.
- **Files:** `AppState+LedgerMaintenance.buildTopics`, new `Knowledge/Topics/AISubjectClusterer.swift`,
  reuse `TopicConsolidator`. Test: 5 résumé fixtures → 1 topic; a distinct patent stays separate.

---

## 4. Measurement so "test what is best" is objective
- **Side-by-side compare (NEW `AnswerModeCompare`):** ask one question, run it through BOTH regimes,
  show the two answers + their grounding stats (cited-fraction, sources, model-consulted, latency).
- **RetrievalEval (B1, exists):** run the gold set under each regime → recall@k / precision@k / hallucination-rate.
- **Topic scoreboard:** #topics, #document-keyed vs subject-keyed, %AI-polished — before/after `aiSubjectResolution`.
- Surfaced on the Live dashboard next to the Apple-Intelligence status chip.

---

## 5. Build order (each its own gated, tested, green commit)
1. **M1 — AI Mode selector** (`aiModeUnconstrained` / `aiModeGuided`) + the 3 NEW sub-flags
   (`answerEvidenceGate`, `answerFactLock`, `queryLLMBudget`) wired as advisory-vs-enforce switches
   in EvidenceVerifier/AnswerSynthesizer/MasterBrain budget. Settings shows a 3-way picker.
2. **M2 — `aiSubjectResolution`** in buildTopics (the topic leap). Fixture test.
3. **M3 — `topicProsePolish` flag** over the existing TopicProsePolisher (explicit on/off + a
   "N of M topics AI-polished" indicator).
4. **M4 — `AnswerModeCompare`** side-by-side + RetrievalEval-per-regime + topic scoreboard on Live.
5. Owner runs the same archive both ways, reads the scoreboard, picks the regime → we lock the
   default and retire the loser (kept as a module, off).

Invariants kept throughout: on-device only; sources never mutated; in Guided mode every claim
cites or abstains; Unconstrained answers are clearly banner-marked and never enter the verified
ledger/exports. Each step: implement → unit test → build → GoldWall+AskTheLedger green → commit.
