# Speed benchmark after the torrent rows (PERF-34 … PERF-40), small corpus

Two runs on 2026-11-23 through `RunSomeTests` with the trigger file `build/perf/RUN_SPEED_BENCH` set to `small`. The trigger
file was deleted afterwards. Each run printed "SPEED_BENCH removed …: true", so its corpus and ledger are gone. The raw
reports are in `after-torrent.json` (`fresh_run`, `reimport_run`).

- **Fresh run.** This is `SpeedBenchmarkTests/fullBenchmark()`, run at 17:42 IST. It uses the same generator and corpus as
  `baseline.md` and `after.md`: 456 files, 11.7 MB. The build is be7a3731 (Debug test host), schema 207. The load
  average was 12.1/6.2/9.6 at the start and 8.8/8.8/9.7 at the end.
- **Re-import run.** This is `SpeedBenchmarkTests/reimportBenchmark()`, which is new. It ran at 17:52 IST with a load of
  11.3/8.9/9.5. The corpus is the same, except that its large mailbox is 14 MB instead of 10 MB, because a piece map needs
  at least 12 MiB. The run has three imports:
  1. a fresh import;
  2. the same corpus read again, unchanged;
  3. edited copies of all 400 text and markdown documents (one line added at the end, so the bytes are new but the
     paragraphs are the same), plus the large mailbox with 25 messages appended.

Both runs used the content cache the way the app does, through the ledger's own store. A DEBUG-only seam,
`ContentResults.TestOverride.ledgerStoreInTestHost`, makes this possible. It is off by default, and only the benchmark
turns it on. Without the seam, the test host would use no content cache at all.

## Baseline vs after vs after-torrent (fresh run)

| Phase | Baseline | After (Run B) | After-torrent | Peak MB (baseline → B → torrent) |
|---|---|---|---|---|
| import: folder through ingestAllRoots | 295.74 s | 109.17 s | 231.71 s (118 files/min) | 312 → 351 → 511 |
| embeddings: drain what the import left | 16.55 s | 13.76 s | 7.24 s * | 270 → 318 → 205 |
| ledger: drain + backfills | 31.43 s | 24.06 s | 23.52 s | 275 → 288 → 215 |
| indexes: HNSW build + IVF rebuild | 75.95 s | 1.51 s | 1.31 s (IVF 0 vectors *) | 232 → 259 → 216 |
| backup: snapshot + complete backup + verify | 2.58 s | 0.92 s | 1.45 s | 496 → 293 → 245 |
| contradictions: 400-document case | 27.59 s | 6.74 s | 9.70 s | 822 → 396 → 339 |
| retrieval: 20 questions | 231.41 s | 130.64 s | 150.72 s | 822 → 600 → 588 |
| data lab: 20,000-row grid redraw | 2.39 s phase (674 s extrapolated per-cell) | 1.82 s | 2.82 s | 742 → 503 → 483 |
| AI: 6-part case read, scripted helper | 3.88 s | 2.76 s, 1 launch, 1 connection | 2.93 s, 1 launch, 1 connection | 450 → 504 → 484 |

Load at the start: baseline 9.0, Run B 5.8, after-torrent 12.1. For the import, Run A in `after.md` is the comparable
heavy-load figure: 223.5 s at a starting load of 14.4. The after-torrent import, 231.7 s at 12.1, is in line with Run A.
This run does not show a torrent speed-up for a fresh import, and none was expected, because a fresh corpus has nothing to
reuse. It does not prove a slowdown either.

The import's peak memory rose from 351 MB to 511 MB. One run cannot tell whether the cause is load (more files in flight at
once) or the content cache. This is recorded as open.

The folder-import read lane on the internal disk ended at width 10, its cap, so PERF-38 did not narrow the import.

\* **Embedder fallback.** At 17:42:40, under load, routing logged "Embedding provider provider.local.coreml.embedder
slow/failed — using local embedder for the rest of the session". After that, every vector stored was 300-dimensional (the
local NL embedder), but each one was still labelled `bge-small.v1`, whose index dimension is 384. Two things follow:

- the embedding phase is not comparable with earlier runs;
- the IVF rebuild found no 384-dimensional training sample and indexed 0 vectors.

This is the cause of the unexplained IVF-0 result in `after.md` Run A (PERF-28). It is a silent fallback that mixes two
embedders under one label. It predates the torrent rows and was not fixed here; it is reported on PERF-28.

## Re-import run (PERF-34 reuse, PERF-35 piece map)

| Step | Wall time | Files read | Reuse measured |
|---|---|---|---|
| Fresh import, 456 files / 15.5 MB | 258.65 s | 456 | 7,661 typed-field entries and 4 OCR entries kept; 1 piece map (the 14 MB mailbox) |
| Fresh embeddings | 7.03 s | — | 1,006 vectors, all computed (no cache yet) |
| Re-import 1: the same corpus, unchanged | 8.18 s | 456 | Nothing derived again: 0 new versions, 0 cache entries, 0 vectors |
| Re-import 2: 400 edited copies plus the mailbox grown by 25 messages | 88.31 s | 856 | 401 new versions. Typed fields: 3,788 lookups by a document, but only 77 new entries, so about 3,711 blocks (98 %) were answered from the cache. Mailbox piece map: 14,128,120 of 14,134,976 bytes proven unchanged, append-only (3 of 4 pieces of the previous version unchanged) |
| Re-import 2 embeddings | 6.03 s | — | 705 vectors added. 280 (40 %) came from the embedding cache and 425 were computed. The edited last chunk of each copy is new text |

### Limits found by the re-import run

- **PERF-35: the mailbox message index is never used in the default configuration.** The piece map is computed and
  compared correctly (above). However, the previous version kept **0** message starts (`record_offsets`), so no message
  range was taken from the index. Two things cause this:
  - mailboxes under 64 MiB (`streamAboveBytes`) are parsed whole, not through `EmailLoader.streamMbox`;
  - thread coalescing is on by default (IN-22), so the stream takes the thread-plan path, which does not read the proven
    ranges.

  The index-reuse code works when it is reached: `TorrentPieceMapTests/grownMailbox` streams per message, and the result
  equals a full scan. But for a 12–64 MiB mailbox, the default path pays one extra hashing read and saves no scan. This is
  recorded on PERF-35.
- The re-import time cannot be split by mechanism. Re-import 2 also re-reads 456 unchanged files, finds them unchanged
  and skips them (about 8 s by re-import 1). Every new version is still parsed, and its entities and events are
  recomputed, as the row states.
- Typed-field reuse is estimated as "origins added − entries added": each new entry and each reuse adds one origin row.
  OCR reuse did not occur in this corpus, because the copies are text documents. It is covered by
  `TorrentContentCacheTests/ocrCacheHit`.
- PERF-36, 37, 38 and 39 have no separate benchmark phase. A fresh corpus imported with no open case exercises none of
  their benefits. Their evidence is the TorrentSpeedTests suites, plus the read-lane widths recorded above. PERF-40 is
  simulated in one process (two ledgers, one folder) and was never run on two Macs.
- One run per configuration, in a Debug test host on a shared Mac under load. These are not Release measurements.

## Re-import run again, after Fix PERF-28 and PERF-35 default path (2026-11-23, 20:00 IST)

`SpeedBenchmarkTests/reimportBenchmark()` once more, trigger file `build/perf/RUN_SPEED_BENCH` = `small` (deleted after;
the run printed "SPEED_BENCH removed …: true"). Build: the working tree on top of 2b68acd8 that became the commits
"Fix: embedder label …" and "Speed PERF-35: …" (Debug test host), schema 208. Load 9.4/11.2/11.2 at the start,
7.1/9.1/10.2 at the end. Same corpus as above (456 files, 15.5 MB, the large mailbox 13.5 MB).

| Step | Wall time (before → now) | Measured now |
|---|---|---|
| Fresh import | 258.65 s → 144.14 s | 456 files, 0 failures; peak 604 MB (was 511 MB in the fresh run) |
| Fresh embeddings | 7.03 s → 14.57 s | 1,006 vectors, all computed. **Embedder health at the end: healthy; 0 vectors of another size under `bge-small.v1`; 0 under the fallback label.** The earlier 7.03 s was partly the 300-d fallback; 14.57 s is the bundled embedder doing all the work |
| Re-import 1 (unchanged) | 8.18 s → 8.73 s | nothing derived again |
| Re-import 2 (400 edited copies + mailbox grown by 25) | 88.31 s → 90.30 s | 401 new versions; typed fields 77 new entries (≈ 98 % from the cache, as before); mailbox: 40 previous message starts now kept (was 0), 39 ranges proven by the piece map, 3 of 4 pieces unchanged |
| Re-import 2 embeddings | 6.03 s → 6.42 s | 705 added, 280 (40 %) from the embedding cache |

What the two fixes changed, measured:

- **PERF-28:** under this run's load the embedder never fell back, and no vector of another size was written under the
  active label (both counted every phase). The fresh-embedding time is now the real bundled embedder's.
- **PERF-35:** the whole-file mailbox path (below 64 MiB) now keeps the message index (40 starts, was 0) and fingerprints
  and decodes of its messages. **In this corpus no decode was reused (0 of 39 proven messages):** every message of the
  large mailbox carries a binary attachment (that is how the generator makes it 13.5 MB), and a message with attachments
  is never kept — its attachments are staged files of that read and must be staged again. The 25 appended plain messages
  were kept (25 `mailMessage` entries), so the next growth of this mailbox reuses them. Reuse of plain messages is shown by
  `TorrentPieceMapTests/grownMailboxWholeParse` (2,800-message, ≈ 20 MB mailbox, threads on and off: 2,799 decodes reused,
  91 parsed, documents identical to a plain parse).
- One run, Debug test host, shared Mac under load; the fresh-import difference (258 s → 144 s) is mostly load, not these
  fixes.
