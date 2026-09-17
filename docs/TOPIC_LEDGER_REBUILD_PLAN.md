# Topic-Ledger Rebuild — two owner rules (2026-09-17)

Owner diagnosis confirmed against the live DB (`/tmp/kalsmri-audit.sqlite`, 716 docs):
- **Facts are ~96% duplicates** — 9,266 rows / **387 distinct** field|value. Cause:
  `GenericFactRepository.upsert` is `INSERT OR REPLACE` keyed by `fact.id` (a fresh
  UUID per extraction), so re-extracting the same (subject,field,value) mints a new
  row every time. `amount` is also junk (`"rs,"`, `"$0"`, `"$1"`).
- **The topic/narrative layer is empty** — `summaries=0, memory_objects=0,
  history_chapters=0, history_items=0`. A `MemoryDistiller`/`IncrementalUpdater`
  exists but distillation needs the AI, and the app runs pinned to minimum-LLM
  (`ledgerEventDriven`), so topics are never built.

## Owner rules (locked)
1. **One-time-consumable = per distinct fact.** A source's evidence is consumed once
   PER DISTINCT fact (dedup by subject+field+value+unit). The same document may still
   support many topics, but it can never emit the same fact 24×. Kills duplication,
   loses no evidence.
2. **AI reconstructs topics into the existing empty topic tables** (summaries /
   memory_objects / history_chapters). The AI adds ONLY connective grammar/helping
   words over deterministic facts — it must not change context, and helps minimally.
   Raw facts + citations remain the authority; AI prose is stored separately and is
   re-derivable.

## Invariants
On-device only; scope before retrieval; facts are derived projections (dedup/rebuild
allowed — the no-delete law protects sources/evidence, NOT derived facts); AI prose is
advisory over deterministic facts, never the authority; every topic line drills to a
cited source.

## Units (dependency order)
- **U1 — Fact merge core (Rule 1).** `GenericFact.naturalKey` + pure `merged(into:)`
  (union sourceBlockIDs, sourceCount = distinct blocks, max confidence, keep earliest
  id/assessment). `GenericFactRepository.mergeUpsert` writes ONE canonical row per key.
  Tests: 3 identical facts → 1 row, sourceCount=3, blocks unioned. *(THIS TURN)*
- **U2 — Route writers through mergeUpsert.** Point the extraction/producer write path
  at `mergeUpsert`; keep batch `upsert([])` as a thin wrapper. Guard: no new dup rows
  on re-ingest (double-boot zero-dup test).
- **U3 — Dedup the existing 9,266 rows.** A one-time maintenance/drain pass (facts are
  derived → safe) collapsing to canonical rows; run on next boot; report before/after
  counts. Owner verifies in-app.
- **U4 — Junk-value gate.** Reject non-values at extraction (`amount="rs,"`, `"$0"`,
  bare `$`+1 digit) — extend the existing plausibility gate; tests over the real junk.
- **U5 — Topic build (Rule 2), deterministic spine.** From deduped facts + events per
  subject, assemble a deterministic topic (ordered claims + citations) into
  memory_objects/summaries. No AI yet — pure, testable.
- **U6 — AI connective reconstruction (Rule 2).** `StoryProseRephraser` (exists) adds
  ONLY grammar/connectives over the U5 spine under a strict guard: output must contain
  every deterministic fact token, add no new digits/proper-nouns (reuse the sweep).
  Stored separately; re-derivable. Bounded 1 call/topic. Owner GUI-verifies.
- **U7 — Composers read topics first.** Answer path prefers the built topic over raw
  fact piles; the deterministic fallback becomes truly last-resort.

## Verification
U1/U4/U5 are unit-testable headlessly. U2/U3/U6/U7 need a re-ingest + owner GUI check
(the agent cannot press Ask/ingest). Success = facts distinct≈total, topic tables
populated with coherent per-subject topics, and "who drafted the claims?" answered from
a built topic, not a fact dump.
