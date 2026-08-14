# OWNER_ACCEPTANCE_CHECKLIST — v1 release acceptance (owner-run)

_Every command, fixture and harness below already exists; your part is running them and
recording results. Fill the `[ ]` boxes and the result fields, then copy the outcomes into
`release/RELEASE_EVIDENCE_v1.md` (owner fields) and `RELEASE_EVIDENCE_INDEX.md` (§E persona
rows, SC1/SC2). Estimated total: one focused day plus ingest wait time._

## 0. Preconditions (record once)

| Field | Value |
|---|---|
| Build under test | `[Release archive / SHA]` |
| Mac model / chip / RAM | `[…]` |
| macOS version | `[…]` |
| Date | `[…]` |

---

## 1. Private-archive ingest + 20 representative questions (OWNER-ONLY A)

1. [ ] Launch the release build. Add your real archive folder(s) via **Sources → Add Folder**.
2. [ ] Wait for Tier-0/1 ingest to complete (Live tab shows progress); note ingest duration: `[…]`.
3. [ ] Let background enrichment run (leave the app open ~30 min for Tier-2 on a large archive).
4. [ ] Ask the 20 questions below in **Ask**. Write REAL questions about YOUR archive — the
   template rows show the required shape coverage. For each: does the answer match what you
   know to be true, and does clicking each citation open the exact source?

| # | Shape | Your question | Answer correct? | Citations open? |
|---|---|---|---|---|
| 1 | lookup (who/what) | | [ ] | [ ] |
| 2 | lookup (amount) | | [ ] | [ ] |
| 3 | lookup (date) | | [ ] | [ ] |
| 4 | identity (person across docs) | | [ ] | [ ] |
| 5 | aggregation (how many / list all) | | [ ] | [ ] |
| 6 | aggregation (sum / total) | | [ ] | [ ] |
| 7 | temporal (what happened in <period>) | | [ ] | [ ] |
| 8 | temporal (before/after) | | [ ] | [ ] |
| 9 | multihop (X of the Y that Z) | | [ ] | [ ] |
| 10 | multihop (via relationship) | | [ ] | [ ] |
| 11 | table (from a spreadsheet) | | [ ] | [ ] |
| 12 | authority (contract/official doc wins) | | [ ] | [ ] |
| 13 | contradiction (conflicting sources — shown as conflict?) | | [ ] | [ ] |
| 14 | missing evidence (honest refusal, states searched scope) | | [ ] | [ ] |
| 15 | email thread (who said what) | | [ ] | [ ] |
| 16 | attachment content | | [ ] | [ ] |
| 17 | OCR (scanned/image source) | | [ ] | [ ] |
| 18 | reconstruction ("tell the story of …") | | [ ] | [ ] |
| 19 | your hardest real question | | [ ] | [ ] |
| 20 | a question you KNOW has no answer in the archive | | [ ] | [ ] |

5. [ ] **Fast vs Full Evidence:** repeat two of the above (one lookup, one reconstruction) in
   each mode. Fast answers quickly from current evidence; Full Evidence digs deeper and may
   surface contradictions/gaps; neither invents missing facts. Result: `[…]`

## 2. Five persona journeys (§38 / RELEASE_EVIDENCE_INDEX §E)

Run the SAME journey once per persona; record the date per row when it completes cleanly.

Journey: create/select the persona's workspace → add real sources → open/create a matter
(intake job) → complete ONE representative job end-to-end → inspect cited evidence →
use one Method (e.g. 5 Whys or Timeline Analysis) and one DataLab preset (e.g. total by
category) → produce the work product → human review/approve → export (pick PDF or DOCX) →
**quit the app → relaunch** → confirm the matter, job state, method run, dataset and sealed
work product all reopen exactly.

| Persona | Representative job used | Export format | Reopen OK | Date |
|---|---|---|---|---|
| Investigator | | | [ ] | |
| Researcher/Historian | | | [ ] | |
| Journalist | | | [ ] | |
| Individual | | | [ ] | |
| Lawyer | | | [ ] | |

## 3. Answer-level eval (one action, §20)

1. [ ] In the DEBUG build (Xcode: Product → Run), open the diagnostics screen and run the
   in-app **SmokeTest** against your archive workspace (or the ProjectDelta fixture) — it
   executes the eval harness (T12) and writes `eval-report.md` with per-class keyword-hit /
   citation-precision / recall metrics.
2. [ ] Record the report path + headline numbers here and copy the table into
   `release/RELEASE_EVIDENCE_v1.md` → "Answer-citation metrics": `[…]`

## 4. Sanitized-archive migration (OWNER-ONLY A, one command)

```bash
bash ci/migrations/verify-real-archive.sh <path-to-sanitized-archive.sqlite> <manifest.json>
```
The manifest schema is `ci/migrations/real-archive-manifest.schema.json`. The script checks:
migration to v-latest, count preservation, stable-ID samples, foreign_key/integrity, reopen.
- [ ] PASS — output recorded at: `[…]`

## 5. Scale benchmark on THIS hardware (SC1/SC2, one command)

```bash
# NOTE: xcodebuild only forwards env vars PREFIXED with TEST_RUNNER_ to the
# XCTest process, and it does NOT capture the test's stdout — so pass the sizes
# with that prefix and write the table to a file via ..._BENCH_OUT.
# _DIM=384 measures at the real BGE embedding width (default is 64 for fast CI).
TEST_RUNNER_KALSMRITIKOSH_ANN_BENCH_SIZES="100000,500000,1000000" \
TEST_RUNNER_KALSMRITIKOSH_ANN_BENCH_DIM="384" \
TEST_RUNNER_KALSMRITIKOSH_ANN_BENCH_OUT="$HOME/ann-bench.md" \
xcodebuild -project Kalsmritikosh.xcodeproj -scheme Kalsmritikosh \
  -destination 'platform=macOS' \
  -only-testing:KalsmritikoshTests/ANNBenchmarkTests test
cat "$HOME/ann-bench.md"
```
The run writes a markdown table to `~/ann-bench.md` (build s, insert p50, query p50/p95, brute
baseline, recall@10, disk bytes) and the test passes only when recall@10 ≥ 0.90 at every size —
paste the table into `release/RELEASE_EVIDENCE_v1.md` → "Large-corpus metrics". Additionally
record, from a REAL archive of the size you intend to market: ingest duration, first-search
latency, Fast latency, Full Evidence latency, peak memory (Activity Monitor), DB+index size on disk.
- [ ] Recorded. **The marketed "tested to N GB" figure is THIS run's figure and nothing else.**

## 6. Release-binary network egress (§32, prepared procedure)

1. [ ] Quit everything. In Terminal: `nettop -p Kalsmritikosh -L 0` (leave running).
2. [ ] Launch the RELEASE build. Ingest a folder, ask questions, run a persona job, export.
3. [ ] Expected: **zero bytes in/out for the app's process** for the entire session.
   (The sandbox denies outgoing connections in Release; this witnesses it physically.)
4. [ ] Optional second witness: turn Wi-Fi off entirely and repeat the whole journey —
   everything must behave identically.
- [ ] PASS — note any observed connection here (any at all = FAIL, file it): `[…]`

## 7. Record and sign

- [ ] Copy results into `release/RELEASE_EVIDENCE_v1.md` (owner fields + sign-off block).
- [ ] Update `RELEASE_EVIDENCE_INDEX.md`: §E persona rows → PASS with dates; SC1/SC2 → PASS
  with the measured figure.
- [ ] Proceed to `CLEAN_MACHINE_ACCEPTANCE.md`, then `OWNER_RELEASE_RUNBOOK.md`.
