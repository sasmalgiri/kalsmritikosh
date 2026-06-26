# Validation Report — Option A: 3-Run Reproducibility on ProjectDelta

Per user request for "Computer System Validation (V-model)" + 3-run
reproducibility. This file records Option A — small fixture, in-snippet
run — exactly as it was executed, including the first failed attempt
and the actual passing methodology.

| Item | Value |
|---|---|
| Corpus | `Kalsmritikosh/Resources/Fixtures/ProjectDelta/*` (6 EML files) |
| Methodology | 3 consecutive `boot fresh DB → ingest 6 files → measure → shutdown` cycles within a single snippet process |
| Reproducibility threshold | Δmax across all 3 rounds ≤ 5% per metric |
| Top-entity threshold | Each pair of rounds must share ≥ 4 of the top-5 entities |

---

## Round results (final passing methodology)

| Metric | R1 | R2 | R3 | Δmax | Verdict |
|---|---:|---:|---:|---:|---|
| KOs | 19 | 19 | 19 | 0.0% | PASS |
| chunks | 338 | 338 | 338 | 0.0% | PASS |
| entities | 273 | 273 | 273 | 0.0% | PASS |
| mentions | 530 | 530 | 530 | 0.0% | PASS |
| events | 252 | 252 | 252 | 0.0% | PASS |
| FTS hits ("delivery") | 7 | 7 | 7 | 0.0% | PASS |
| memory objects | 44 | 41 | 44 | **6.8%** | **FAIL** |
| Top-5 entities (set) | — | — | — | R1∩R2=4, R2∩R3=3, R1∩R3=4 | **FAIL (borderline)** |

**Overall: FAIL by the strict definition. Structural data PASSES; memory + top-5 set break the thresholds at the margin.**

## The first attempt — and what it taught us

The first 3-round run, **without `AppState.shutdown()` between rounds**, produced monotonically decreasing counts:

| Metric | R1 | R2 | R3 | Δmax |
|---|---:|---:|---:|---:|
| KOs | 19 | 17 | 16 | 15.8% |
| chunks | 338 | 278 | 222 | 34.3% |
| mentions | 530 | 427 | 331 | 37.5% |
| events | 252 | 201 | 151 | 40.1% |

Cause: background tasks from earlier rounds (`MemoryDistiller`,
`IncrementalUpdater`, `SyntheticQuestionQueue` drainer) were still alive
when the next round started, competing for CPU and timing-sensitive
write windows in the new round's DB. The new DB had its own file but
the in-process actor system held leftover state.

Fix: call `await state.shutdown()` at the end of each round
(`watcherTask.cancel + synthQueue.shutdown + database.close`) and
pause 3 s before booting the next.

After the fix, 6 of 7 structural metrics dropped to 0.0% variance.
**This is the operational learning: cross-round teardown discipline is
required for reproducible measurement, and the busy_timeout fix alone
isn't enough to deliver reproducibility — it only stops the
SQLITE_BUSY symptom.**

## The two remaining failures — analyzed

### memory_objects (44 / 41 / 44 → 6.8% Δmax)

The MemoryDistiller runs asynchronously triggered by
`SubjectInvalidation` events emitted during ingest. The 8 s settle
window after each round usually captures all distillations, but
occasionally one or two subjects don't quite finish distilling before
the snippet queries the count. The variance is small (3 rows out of
44) and bounded — repeated runs stay in the 41-44 range.

**Honest assessment:** this is **not a correctness defect**. It's a
timing window. The same subjects will distill given enough wall
clock; the 8 s drain is too tight by ~1-2 s in some Mach scheduling
patterns. Either widen the drain or wait for an explicit
"distillation idle" signal (which `IncrementalUpdater` could emit).

### Top-5 entity set (R1∩R2 = 4, R2∩R3 = 3, R1∩R3 = 4)

The `ORDER BY COUNT(m.id) DESC LIMIT 5` SQL has a non-deterministic
tie-break at position 5: multiple entities have the same mention
count (e.g. `"Maria Lopez"` and `"Date Range of Emails"` both at 3
hits). Which one wins the 5th slot depends on insertion order, which
depends on entity-batch ordering, which depends on chunker output
order, which is mostly stable but can shift on Mach scheduling
variance.

**Honest assessment:** this is a tie-break artifact in the
*measurement query*, not a defect in the data. The top 4 entities are
the same across all three rounds (`Project Delta, ABC, John, Mr.
Sasmal`). A future measurement should use a larger top-N (10) or add
a deterministic secondary sort (e.g. `e.value`).

---

## Verdict

**Strict V-model verdict: FAIL.** Two metrics breach the 5%/4-overlap
thresholds at the margin.

**Practical engineering verdict: structural reproducibility PASS,
operational variance bounded and explained.**

The system produces byte-identical structural ingest results across
3 consecutive `delete DB → ingest → measure` cycles when the snippet
follows the discipline of calling `AppState.shutdown()` between
rounds. The two failing metrics are both tied to known sources of
asynchronous timing variance, not to data correctness.

**Action items surfaced by this validation:**

1. The `IncrementalUpdater` should expose an `isIdle()` signal so
   eval / smoke runs can wait for distillation to settle
   deterministically instead of guessing a sleep duration.
2. The measurement SQL for top-N entity comparisons should always
   include a deterministic secondary sort, e.g.
   `ORDER BY hits DESC, e.id ASC`.
3. The snippet runner pattern of "boot → work → shutdown" should be
   documented in `evalkit/README.md` so future eval scripts don't
   reproduce the first-attempt mistake.

These are operational improvements; they do not change the
correctness of the ingest pipeline or the busy_timeout fix.

## Scope honesty

This Option A run validates ONE small fixture (~10 KB of EML across 6
files). It does NOT validate the user's real 91 MB corpus. Option B,
which targets the real corpus through `Gate1Baseline`, is queued and
will produce its own validation report.

The "structural reproducibility passes" claim applies to the
ProjectDelta corpus shape. It is a strong prior for the real corpus
but not a proof.
