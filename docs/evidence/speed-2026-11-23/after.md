# Speed benchmark (PERF-33) — after the speed fixes (PERF-21 … PERF-32), small

The same harness and the same generated corpus as `baseline.md` (456 files, 11.7 MB; deterministic generator), in a
throwaway ledger. Run 2026-11-23 10:05 IST through `RunSomeTests` (trigger file `build/perf/RUN_SPEED_BENCH` = `small`),
cut from the console between the `===SPEED_BENCH_BEGIN/END===` markers. The run removed its corpus and ledger
("SPEED_BENCH removed …: true"); the trigger file was deleted afterwards.

Two after-runs were made:
- **Run A** (09:45, load 14.4/65.9/105 at start — heavier than the baseline's 9.0/8.8/7.9): AIMD start 2. It showed the
  6-part read never above 3 requests at once (cap 8), and IVF indexed **0** of 1,268 vectors in 3 ms (see Limits).
- **Run B** (10:00, load 5.8/11.4/41.4 at start, 2.3 at end — LIGHTER than the baseline): AIMD start tuned 2 → 4
  (`AdaptiveConcurrency.defaultStart`), bench diagnostics added for the vector sizes and ANN meta. **Run B is the
  after-run below.** Because its load was lighter than the baseline's, part of every gain is the quieter machine; Run A
  (heavier load than the baseline) is shown beside it as the conservative figure.

Build: Debug test host at 4f311f12 plus the test-phase fixes (statement-cache retry, keyset stored id, Data Lab keyed
base lookup, AIMD start 4). Data Lab phase: the harness now times what DataLabView does after PERF-31 (DataLabMemo; every
one of the 99,900 visible cells timed), where the baseline timed the old per-cell projection rebuild on 300 cells and
extrapolated.

## Baseline vs after

| Phase | Baseline | After (Run B) | Run A | Change (B vs baseline) | Peak MB baseline → B |
|---|---|---|---|---|---|
| import: folder through ingestAllRoots | 295.74 s (92.5 files/min, 2.37 MB/min) | 109.17 s (250.6 files/min, 6.42 MB/min) | 223.53 s (122 files/min) | 2.7× faster | 312 → 351 |
| embeddings: drain what the import left | 16.55 s (61.0 vectors/s) | 13.76 s (73.4 vectors/s) | 7.96 s (126.9 vectors/s) | 1.2× | 270 → 318 |
| ledger: drain + backfills | 31.43 s | 24.06 s | 26.26 s | 1.3× | 275 → 288 |
| indexes: HNSW build + IVF rebuild | 75.95 s (HNSW 74,545 ms for 752; IVF 1,401 ms for 752) | 1.51 s (HNSW 1,137 ms for 1,268; IVF 369 ms for 1,268) | 1.47 s (IVF 0 vectors — see Limits) | 50× (HNSW 66× on 1.7× the vectors) | 232 → 259 |
| backup: snapshot + complete backup + verify | 2.58 s | 0.92 s | 1.21 s | 2.8× | 496 → 293 |
| contradictions: 400-document case | 27.59 s (rules 26,644 ms, 400 documents) | 6.74 s (rules 6,284 ms, 418 documents — no 400 cap) | 8.38 s | 4.1× | 822 → 396 |
| retrieval: 20 questions | 231.41 s (retrieve p50/p95 3,342/4,907 ms; answer p50/p95 5,637/40,290 ms) | 130.64 s (2,215/2,622; 3,219/22,740 ms) | 152.50 s | 1.8× | 822 → 600 |
| data lab: full 20,000-row grid redraw (headless) | 674,363 ms extrapolated (6.75 ms per cell, projection rebuilt per cell) | 1,747 ms measured (0.017 ms per cell, 1 projection build) | 2,720 ms phase | ~386× | 742 → 503 |
| AI: 6-part case read, scripted helper 300 ms | 3,870 ms; 12 helper launches, 12 XPC connections; 6 in flight | 2,755 ms; **1 launch, 1 connection**; 4 in flight (AIMD start 4) | 3,618 ms; 1 launch, 1 connection; 3 in flight (start 2) | 1.4× | 450 → 504 |

Peak footprint is the whole test process (sampled every 250 ms), so a phase's peak includes what earlier phases left;
the drop in the later phases (822 → 396/600 MB) follows the contradiction finder no longer holding every sentence twice.

AIMD tuning (one re-run, as the instructions allowed): with start 2 the limiter reached 3 requests in flight on a
6-part read; with start 4 it reached 4 and the read took 2.76 s instead of 3.62 s. The unit tests keep the AIMD rules
(+1 per window while throughput rises, ×0.5 on 429/503/529/timeout, Retry-After honoured, WorkerBudget cap).

## Limits

- One run per configuration, Debug test host, shared machine. Run B's load was lighter than the baseline's; Run A's
  heavier. Neither is a signed Release measurement.
- **IVF 0 vectors in Run A (unexplained, not reproduced).** In Run A the IVF rebuild returned in 3 ms with 0 postings
  while 1,268 vectors of the right size were stored; in Run B (same code apart from the AIMD start and the added
  diagnostics) it indexed all 1,268 in 369 ms, and `SpeedVectorTests/ivfRebuildIndexesEverything` (1,300 384-d vectors)
  passes. The silent path is the empty-training-sample return (it logs nothing). The bench now records the stored
  vector sizes, column types and ANN meta state after every rebuild so a recurrence names its cause. Tracked on PERF-28.
- The AI phase uses the scripted helper stand-in; its single launch/connection is counted by the stand-in's own link
  (one per stand-in session), so it shows the client sends every request over one link — the real
  `NetworkHelperLink` (AppExtensionProcess + XPC) is not exercised headlessly.
- The Data Lab figure is the headless per-cell work, not SwiftUI layout or rendering.

---

## Generated report (Run B)


Generated by `KalsmritikoshTests/SpeedBenchmarkTests.swift` over the generated corpus of `KalsmritikoshTests/Support/SpeedBenchCorpus.swift` in a throwaway ledger (never the owner's).

## Machine

| Item | Value |
|---|---|
| RAM GB | 16 |
| build | Debug test host (XCTest process) |
| build_sha | 4f311f12596cb31daae6b1ed9b979b37ecaeb1ae |
| chip | Apple M4 |
| cores | 10 |
| efficiency cores | 6 |
| ledger MB | 95.7 |
| load average at end (1/5/15) | 2.3/6.3/30.2 |
| load average at start (1/5/15) | 5.8/11.4/41.4 |
| machine | Mac16,12 |
| measured_utc | 2026-11-23T04:35:57Z |
| os | Version 27.0.1 (Build 26A434) |
| performance cores | 4 |
| schema | 204 |
| size | small |

## Corpus

456 files, 11.7 MB: csv 10 (0.3 MB), mbox 3 (9.6 MB), md 200 (0.3 MB), pdf 40 (1.0 MB), pdf-image 2 (0.1 MB), txt 200 (0.3 MB), zip 1 (0.0 MB); 60 emails, 136 PDF pages, 4000 CSV rows, 50 ZIP members.

## Phases

| Phase | Wall time | Peak footprint | Start footprint |
|---|---|---|---|
| generate corpus (not app work) | 0.85 s | 128 MB | 91 MB |
| import: folder through ingestAllRoots | 109.17 s | 351 MB | 218 MB |
| embeddings: drain what the import left | 13.76 s | 318 MB | 255 MB |
| ledger: drain + backfills | 24.06 s | 288 MB | 288 MB |
| indexes: HNSW build + IVF rebuild | 1.51 s | 259 MB | 256 MB |
| backup: snapshot + complete backup + verify | 0.92 s | 293 MB | 259 MB |
| contradictions: 400-document case | 6.74 s | 396 MB | 293 MB |
| retrieval: 20 questions | 130.64 s | 600 MB | 396 MB |
| data lab: 20,000-row dataset, grid redraw | 1.82 s | 503 MB | 428 MB |
| AI: 6-part case read, scripted helper (300 ms) | 2.76 s | 504 MB | 459 MB |

### generate corpus (not app work)

| Metric | Value |
|---|---|
| MB | 11.69 |
| files | 456 |

### import: folder through ingestAllRoots

| Metric | Value |
|---|---|
| MB/min | 6.42 |
| failures | 0 |
| files in corpus | 456 |
| files reported read | 456 |
| files/min | 250.62 |
| rows: chunk_embeddings | 0 |
| rows: chunks | 1010 |
| rows: entities | 9265 |
| rows: events | 60 |
| rows: files | 546 |
| rows: generic_facts | 15245 |
| rows: knowledge_objects | 561 |
| shard workers used | 0 |

- Includes what ingestAllRoots runs after the files (topic build, post-ingest checks). The background embedding drain was held (pressure pause) so vectors are measured in the next phase.

### embeddings: drain what the import left

| Metric | Value |
|---|---|
| chunks still missing a vector | 0 |
| vectors after | 1010 |
| vectors before | 0 |
| vectors/s | 73.43 |

- Embedder: bge-small.v1 (index dimension 384).

### ledger: drain + backfills

| Metric | Value |
|---|---|
| ChunkReindexCoordinator ms | 927.18 |
| ClaimProjectionBackfill ms | 9016.87 |
| EmailParticipantBackfill ms | 1.67 |
| LedgerDrainCoordinator.drain ms | 13864.71 |
| SubjectSpine ms | 0.04 |
| TermSalienceComputer ms | 247.26 |
| TopicTreeBuilder ms | 0.07 |
| reindex: embeddings dropped (packed + split) | 258 |
| reindex: template prefixes stamped | 0 |

- The drain runs without the schema inducer (no model call). On a fresh import most rows are current, so these are the per-pass costs of an up-to-date ledger.

### indexes: HNSW build + IVF rebuild

| Metric | Value |
|---|---|
| HNSW build ms | 1137.23 |
| HNSW vectors | 1268 |
| IVF input: embeddingCount | 1268 |
| IVF input: first page rows | 1268 |
| IVF rebuild ms | 369.02 |
| IVF vectors | 1268 |
| re-embed of reindexed chunks ms | 6880.72 |
| stored vectors of 384 bytes | 1268 |
| vectors after the ledger phase (before re-embed) | 752 |
| vectors stored at index time | 1268 |

- Stored vector column types: scale real / q blob × 1268
- ANN meta after the rebuild: bge-small.v1=ready/142 cells

### backup: snapshot + complete backup + verify

| Metric | Value |
|---|---|
| backup MB | 130.49 |
| complete backup write ms | 270.45 |
| entries | 1044 |
| ledger snapshot ms | 577.85 |
| originals copied | 496 |
| verified ok | 1 |
| verify (inspect) ms | 55.65 |

### contradictions: 400-document case

| Metric | Value |
|---|---|
| document load ms | 453.94 |
| documents compared | 418 |
| findings | 80 |
| rules ms | 6284.49 |
| source versions | 400 |

### retrieval: 20 questions

| Metric | Value |
|---|---|
| answer p50 ms | 3219.25 |
| answer p95 ms | 22740.44 |
| answers refused | 1 |
| retrieve p50 ms | 2215.18 |
| retrieve p95 ms | 2621.76 |

- retrieve = HybridRetriever over every layer; answer = MasterBrain.answer (the whole ask, AI not configured in the bench).

### data lab: 20,000-row dataset, grid redraw

| Metric | Value |
|---|---|
| cellByKey ms | 50.49 |
| cells | 100000 |
| dataset build ms (generator, not app work) | 56.65 |
| full grid redraw ms (measured: every one of 99900 cells) | 1747.09 |
| orderedVisibleRows ms | 14.34 |
| per-cell gridCell work ms (sampled 99900) | 0.02 |
| projection build ms (once) | 1.02 |
| projection builds during the redraw | 1 |
| rows | 20000 |

- Headless: the computations DataLabView.grid/gridCell/orderedVisibleRows make, not SwiftUI layout or rendering.
- After PERF-31: the projection and cell map come from DataLabMemo (built once per change) and a base value is a keyed lookup; every visible cell was timed (no extrapolation). The baseline rebuilt the projection per cell and scanned every base cell per read (300 cells timed, extrapolated).

### AI: 6-part case read, scripted helper (300 ms)

| Metric | Value |
|---|---|
| XPC connections | 1 |
| case tokens (estimated) | 178926 |
| helper process launches | 1 |
| max requests in flight | 4 |
| ms per request (wall / requests) | 229.61 |
| parts | 6 |
| path concurrency (WorkerBudget) | 9 |
| requests at the helper door | 12 |
| requests the scripted helper answered | 12 |
| second look ran | 1 |
| total read ms | 2755.36 |

- Scripted helper: 300 ms per request, nothing leaves the Mac. The stand-in takes the helper's place inside NetworkHelperClient.sendViaHelper, after the door's own checks; launches and connections are counted where that function makes them (one of each per request in this code).

## Limits

- Debug (unoptimised) test host in the XCTest process, not a signed Release app; one run, no repeats.
- The boot ran with suppressAutoReingest (the eval isolation), so no boot-time maintenance overlaps the phases; the import's own after-work does run.
- Peak footprint is the whole test process (phys_footprint sampled every 250 ms), not the phase alone.
- The AI phase uses a scripted helper stand-in (300 ms per request); no network was used.
