# P9.3 — Disk-Backed/Sharded ANN + Index-Strategy Selector (GOV-005 implementation plan)

_Authored 2026-08-07 from a code-verified design pass. Authority: SHIP_DECISIONS.md GOV-005
(owner chose to IMPLEMENT before release). This plan is the macro's spec; deviations get noted
here with reasons._

## 0. Verified current state

- `HNSWVectorIndex` — pure-Swift in-memory HNSW `actor`, int8-cosine, deterministic xorshift64*
  layer sampling, sidecar persist/load (`hnsw-index.bin`), rebuilt from SQL when stale, RAM gate
  `maxInMemoryVectors(physicalMemoryBytes:)` (~40% RAM, clamped 250k–20M). No incremental insert.
- `SQLiteVectorStore` — `actor VectorStore` over `chunk_embeddings(chunk_id, model_id, …, q BLOB
  int8, scale)` (v54); routes to HNSW only when built AND `annSize >= stored` AND no candidate
  filter; else memory-bounded rowid-paged vDSP brute force. Quantization duplicated in both files.
- Boot (AppState ~779–791, warm ~1752, wipe ~3242); scheduler wiring ~1515. Retriever consumes
  only the `VectorStore` protocol (top-20, candidate prefilter path).
- Migrations at v102; SAVEPOINT idiom + self-heal sentinel; `MigrationFixtureBuilder` for tests.

## 1. Architecture: IVF (k-means coarse quantizer) with SQLite-persisted, clustered posting lists

Chosen over (b) mmap flat shards (no useful pruning without clustering → full-corpus stream per
query; sidecar crash protocol) and (c) disk-persisted HNSW (random-hop page faults kill p95;
in-place graph mutation needs a custom pager; worst risk).

- Centroids in RAM: K ≈ 4·√N (1M → K≈4096 → ~6.3 MB, corpus-independent). Training is SPHERICAL
  k-means (centroids re-projected onto the unit sphere every update) so cells are ANGULAR — matching
  the cosine probe metric and structurally preventing the origin-collapse degeneracy.
- Query: one vDSP pass over centroids (sub-ms) → rank cells by cosine → walk nearest cells in
  batched round-trips, accumulating a bounded candidate POOL (≥4000 rows), scored with the existing
  int8/vDSP kernel → top-K. Target p50 < 25 ms / p95 < 60 ms warm at 1M.
- PERF-3 (measured, 384-D corpus): TWO real defects surfaced once the benchmark corpus was made
  representative (L2-normalized planted clusters instead of a synthetic unbounded axis).
  (1) *k-means origin-collapse*: Euclidean clustering on zero-mean spherical embeddings sank one
  centroid to the data mean, which then swallowed 93% of a 20k corpus into a single cell — recall
  looked fine only because the probe was scanning almost everything, at ~1.7 s/query. Fixed by
  spherical k-means (cell max size fell from 18650 to 200). (2) *count-based nProbe*: in high-D the
  "nearest" cells past #1 are near-equidistant noise, so a 2·√K cell probe pulled in ~99% of rows;
  bounding ROWS scanned (scan-budget) instead of cells restores O(pool) latency. Net at 100k:
  recall@10 = 1.000 and query p50 118 ms vs 438 ms brute (IVF 3.7× faster).
- Insert: assign-to-centroid + posting INSERT inside the SAME `SQLiteVectorStore.upsert` actor
  call → index can never be stale vs the ledger (structurally kills the recall-0.07 incident class).
- Crash-safety: all state is rows in the single ledger (WAL/SAVEPOINT/CASCADE); `state='building'`
  is the crash marker → not-ready → brute-force fallback → resume.
- Deterministic training: k-means++ on a reservoir sample + mini-batch Lloyd, xorshift64* seed
  persisted in meta. `candidateChunkIDs != nil` keeps today's bounded SQL path untouched.
- Postings denormalize `q`/`scale` for locality (~+0.4 GB per 1M vectors; documented; a JOIN lean
  mode is repository-internal later).

## 2. IndexStrategySelector + ANNIndexCoordinator

- `IndexStrategySelector` (pure static): `inMemoryHNSW → diskIVF` when `vectorCount > cap`
  (cap = `HNSWVectorIndex.maxInMemoryVectors`); back only when `< 0.8 × cap` (hysteresis).
  Persisted in `ann_index_meta.strategy`; boot serves the persisted strategy immediately.
- `actor ANNIndexCoordinator` owns hnsw + ivf + selector + meta repo: `activeIndex()`,
  `noteUpsert/noteRemove` (forwarded from `SQLiteVectorStore.upsert/remove`; HNSW no-op),
  `maintain()` (background: decide → rebuild in background while serving current strategy →
  flip strategy+state in one UPDATE; IVF retrain when corpus > 2× trained count or cell
  imbalance > 8× mean). Scheduler job `"ann.strategy.maintenance"`, interval 300.
- `VectorStore` protocol unchanged — retriever/ingest/backfill see zero API change.

## 3. Schema — migration v103 (DDL only; population is background work)

```sql
CREATE TABLE ann_index_meta (
    model_id TEXT PRIMARY KEY NOT NULL, strategy TEXT NOT NULL DEFAULT 'inMemoryHNSW',
    state TEXT NOT NULL DEFAULT 'empty', dimension INTEGER NOT NULL,
    cell_count INTEGER NOT NULL DEFAULT 0, trained_vector_count INTEGER NOT NULL DEFAULT 0,
    train_seed INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL,
    CHECK(strategy IN ('inMemoryHNSW','diskIVF')), CHECK(state IN ('empty','building','ready')),
    CHECK(dimension > 0), CHECK(cell_count >= 0), CHECK(trained_vector_count >= 0));
CREATE TABLE ann_cells (
    model_id TEXT NOT NULL, cell_id INTEGER NOT NULL, centroid BLOB NOT NULL,
    vector_count INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL,
    PRIMARY KEY (model_id, cell_id),
    FOREIGN KEY (model_id) REFERENCES ann_index_meta(model_id) ON DELETE CASCADE,
    CHECK(cell_id >= 0), CHECK(vector_count >= 0)) WITHOUT ROWID;
CREATE TABLE ann_postings (
    model_id TEXT NOT NULL, cell_id INTEGER NOT NULL, chunk_id TEXT NOT NULL,
    q BLOB NOT NULL, scale REAL NOT NULL,
    PRIMARY KEY (model_id, cell_id, chunk_id),
    FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE) WITHOUT ROWID;
CREATE UNIQUE INDEX idx_ann_postings_chunk_model ON ann_postings(chunk_id, model_id);
```

No FK postings→cells (retrain replaces cells + reassigns postings in one repository-managed
rebuild). Update `latestVersion=103`, `all += (103, v103)`, extend the self-heal sentinel.

## 4. File plan (sequencing order)

1. `SchemaMigrations` v103 + `Storage/Repositories/ANNIndexRepository.swift` (~280) +
   `KalsmritikoshTests/ANNIndexMigrationTests.swift` (~180).
2. `Storage/Vector/VectorQuantization.swift` (~120) — extract shared int8/vDSP kernel; adopt in
   SQLiteVectorStore + HNSWVectorIndex; byte-parity test BEFORE anything else changes.
3. `Storage/Vector/KMeansClusterer.swift` (~220) + `KMeansClustererTests` (~120).
4. `Storage/Vector/IVFDiskVectorIndex.swift` (~500, actor) + `IVFDiskVectorIndexTests` (~350).
5. `Storage/Vector/ANNIndexing.swift` (~60, protocol + ANNStrategy) +
   `Storage/Vector/ANNIndexCoordinator.swift` (~260); SQLiteVectorStore swaps
   `annIndex: HNSWVectorIndex?` → `ann: ANNIndexCoordinator?` (~60 delta); HNSW conforms (~30).
6. `Storage/Vector/IndexStrategySelector.swift` (~90) + `IndexStrategySelectorTests` (~180);
   AppState boot/warm/scheduler/wipe wiring (~70).
7. `DataHealthCheck` strategy + postings-parity line (~30).
8. `EvalKit/ANNBenchmark.swift` (~250): deterministic seeded 64-Gaussian corpora; 10k/100k/500k
   CI-safe, 1M+ behind env flag for the owner SC1 run; record train/build seconds, insert p50,
   query p50/p95/p99 cold+warm, recall@10 vs brute force, peak RSS, disk bytes.
9. MIGRATION_MATRIX.md row + docs.

## 5. Test gates

Migration (reach/preserve/self-heal/fault-rollback/CHECKs/cascades/uniqueness); recall parity
(5k synthetic, recall@10 ≥ 0.95 default, ≥ 0.99 escalated; self-query always hit #1);
incremental insert (immediately retrievable, postings == embeddings); deletion (explicit +
cascade); model-identity rejection (dim mismatch throws; two models coexist without cross-talk);
crash-recovery (state='building' reopen → fallback → maintain() completes); k-means determinism
+ imbalance flag; selector threshold/hysteresis/persistence; integration: switch-rebuild under
concurrent queries (never empty/throw), retriever parity (Jaccard ≥ 0.9 top-20 vs HNSW),
no new files outside the ledger + hnsw-index.bin.

## 6. Risks → mitigations

k-means quality (adaptive nProbe + retrain trigger + benchmark merge gate + brute-force floor);
real-BGE recall vs synthetic (RealDataProbe run before default flip); rebuild memory (streamed
mini-batches ≈ 9 MB peak); DB-actor contention (batched 500-row INSERTs, yields, WAL readers);
disk doubling (documented; lean mode later); quantization drift (single shared kernel + parity
test); flapping (hysteresis + persisted decision); stale-index class (same-call insert +
DataHealthCheck parity tripwire).
