# Speed torrent test phase (PERF-34 … PERF-40), 2026-11-23

This phase covers the commits 786da60d..1378e991. There was no network and no live AI: providers were scripted, and every
ledger and team folder was throwaway. The owner's ledger was never opened.

All tests ran through the Xcode runner (`RunSomeTests`, plan `Kalsmritikosh`). No console log contained "hung before
connection".

## Existing suites

The suites were chosen like this:
- every test file that names a type changed since 2b15435d (types named in 12 or fewer test files);
- plus the requested suites: MigrationMatrix, the erasure suites (CaseErasure, SEC07, SmartMap S9/S16/S17/S18, case map
  recovery, case ask), the team-folder and team suites, backup/restore, shard merge/import (UnifiedPathIngest/Round2),
  IngestCoordinator/mbox, OCR, the embedding suites, case reading (CaseReadBudget, CaseWholeReading,
  CaseAnalysisWholeReading, UnifiedPathCase), RawSavepointRatchet, and the guard/boundary suites.

| Run | Suites | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|---|
| Batch 1: erasure, backup, migration, team, S9/S12/S16/S17, Speed*, shard/ingest, OCR, mbox, byte resolver | 39 | 295 | 288 | 5 | 2 (CASE_MAP_PERF only) |
| Batch 2: guards and boundaries, case reading, cloud scope, vault, embeddings, S18, SmartMap contracts, diagnostics, navigation | 95 | 692 | 689 | 3 | 0 |
| Reruns of the 8 failures after the fixes | — | 8 | 8 | 0 | 0 |

In total, about 134 suites and 987 tests ran.

### Failures and their outcomes

| Test | Outcome |
|---|---|
| `SmartMapS9Tests/everyEntryPointIsGuarded` | **Code defect (PERF-40), fixed in 87ecb885.** These swarm ledger entry points did not check the case access policy: `markSwarmOptInAnnounced`, `setSwarmState` and `setSwarmPiece` (mutators), and `swarmFootprint` (a read). They now call `CaseAccessPolicy.requireChange(.contribute)` or `requireRead`. |
| `SEC07ErasureReachTests/keychainHoldsNothingCaseScoped` | **Intentional change (PERF-40).** The X25519 key-agreement key is a new Keychain user. It is one key per Mac and is not case-scoped, and it was already listed as ST-27 in `docs/STORAGE_KEY_INVENTORY.md`. It was added to the test's inventory: "Updated for PERF-40 (owner 2026-11-23)". |
| `SourceVersionByteResolverTests/vaultBlobMissing` | **Intentional change (PERF-39).** A managed version whose vault blob is gone now reopens from its unchanged original, after the hash is checked. The error is still reported when neither copy exists, and the test now covers both cases: "Updated for PERF-39 (owner 2026-11-23)". |
| `PJE009WorkProductBoundaryGuardTests/workflowArtifactsHaveNoByteColumns` | **Intentional change (PERF-35).** The guard greps the whole migration file for `file_bytes`. In v206 that is `source_piece_maps.file_bytes`, a size in bytes (an INTEGER), not stored bytes. Exactly that column line is exempt, and the guard checks it appears at most once: "Updated for PERF-35 (owner 2026-11-23)". |
| `UnifiedPathIngestTests/shardMergeDirect` | Failed once with "database ingest_shard is already in use" after the launch-time log read failed ("SAVEPOINT shard_log_read" under load). It passed alone. ShardMerger was not changed by the torrent rows. This is noted, not fixed. |
| `SmartMapS17Tests/parseRunsOffTheMainThread` | A timing bound under a load average of 28. It passed alone. |
| `NavigationMergeTests/caseQuestionStaysInTheCase` | Hit its 5-minute allowance under load. It passed alone. |
| `DiagnosticEndToEndTests/fixedPointCheckRuns` | `summaries` went from 0 to 1 between runs, under load. It passed alone. |

No privacy, consent or erasure assertion was weakened.

## New suite: `KalsmritikoshTests/TorrentSpeedTests.swift`

The suite uses Swift Testing with no long `.timeLimit`. Vision is never called: an OCR cache hit is tested, and a miss is
shown by the key alone. All 18 tests pass.

| Suite | Row | What it proves |
|---|---|---|
| TorrentContentCacheTests (5) | 34 | **OCR:** lines come from the cache for the same page bytes under another name. A new reader version, language set or custom-words list is a new key. **Typed fields:** reused for the same normalised block text, re-anchored to the new block, and equal to a fresh extraction; extractor version 2 recomputes. **Vectors:** not embedded again (one batched lookup); another model is a miss. **AI replies:** reused only for the same case, cleared document set and permission grant; another case, a new grant or another version sends again, and a scope answered earlier is reused. **Erasure:** a case erase removes the case's replies, the entries derived from its exclusive document and that document's chunk vectors, while a shared document's entries and case B's stay. A person erase removes kept text that names the person. A full erase empties the content cache, its origins and the embedding cache. |
| TorrentPieceMapTests (2) | 35 | An appended file proves its old bytes, including the old partial piece. A middle change shortens the proof. The next-separator rule holds. A grown 13 MB mailbox: the previous index is used for the old messages (a doctored index changes the record count), the records equal a full scan, the old messages are the same documents, and both versions' maps are kept. |
| TorrentPriorityTests (3) | 36 | Open-case files and cited documents go first in a stable order, and nothing is dropped. Work-stealing segments start with priority work, and every index runs once. Enrichment claims take the priority subject first, then oldest first. |
| TorrentEndgameTests (2) | 37 | The stuck item is duplicated once. The duplicate wins, the loser is cancelled, the run ends in under 20 s against the stuck item's 30 s, and there is one row per item. Work that is not local is never duplicated. |
| TorrentVolumeLaneTests (3) | 38 | Files are grouped per disk (an unplugged path is its own offline lane) and dealt round-robin. Each kind starts at its own width and cap. One lane widens and then chokes without changing another lane. A full lane makes a read wait. Nested same-disk reads past the width do not deadlock. |
| TorrentFastestCopyTests (3) | 39 | The copy order follows the rules. A changed original is rejected and the vault copy is used. A missing original falls back to the vault. With both copies damaged, nothing is returned. A non-SHA-256 fingerprint is refused. The resolver reopens managed versions, and referenced versions that share vault bytes, from the vault when their original changed. Both copies wrong gives `hashMismatch`. |
| TorrentSwarmTests (1) | 40 | See below. |

The PERF-40 test simulates two Macs: two throwaway ledgers and cases, two signing keys plus two X25519 keys, and one
temporary team folder. It covers:
- opt-in announced and listed for both members;
- a signed manifest (a file outside the folder is refused, and a manifest edited after it was announced is not trusted);
- claims: the oldest valid claim wins, the loser leaves at once, an expired claim is retaken, a forged signature is ignored,
  and an endgame duplicate is offered;
- each Mac reads its piece into a partial ledger and publishes it encrypted (its header is not "SQLite format 3"), with the
  key wrapped for both members and a signed `swarm.shard` entry;
- a non-member, or a wrong agreement key, cannot open a piece;
- both Macs merge both pieces once, the ledgers hold the same 4 documents, and a second pass merges 0 pieces and adds no
  rows;
- progress shows 1 piece by this Mac and 1 by the other, with 2 joined;
- after Ada's erasure, her claims, pieces and manifest are gone from the folder and `swarm.erased` is announced, while
  Ben's files stay. CaseEraser then removes every swarm row for her case, and Ben's ledger is untouched.

## Defects found and fixed (87ecb885)

| Where | Failure | Cause | Fix |
|---|---|---|---|
| `LedgerCipher.rekeyedCopy` (PERF-40) | Every swarm piece failed with "piece N not fetched: … unable to open database …/Shards/<run>/N.sqlite", so no Mac could ever merge a published piece. | The source was opened `SQLITE_OPEN_READONLY`. ATTACH inherits the connection's flags, so the re-keyed target could not be created. | The source is now opened `READWRITE \| CREATE`, as in `plaintextCopy` and `encrypt`. It is this Mac's own fetched copy and is only read. Tested by `TorrentSwarmTests/twoMacSwarm`. |
| `CaseTeamSwarmLedger` (PERF-40) | Three mutators and the erasure footprint read had no case access check. | The checks were missed when v207 was built. | Access-policy checks were added (`SmartMapS9Tests/everyEntryPointIsGuarded`). |

One DEBUG-only seam was added, and the app is unchanged: `ContentResults.TestOverride.ledgerStoreInTestHost`. It is off by
default, and only the speed benchmark turns it on, so the benchmark uses the ledger's own content cache as the app does.

## Benchmark

`after-torrent.md` and `after-torrent.json` hold a fresh run and the new re-import run. Their findings:

- **Fresh run:** the import took 231.7 s at load 12.1, in line with Run A (223.5 s at load 14.4). Retrieval took 150.7 s,
  indexes 1.3 s and the AI read 2.9 s (1 launch, 1 connection).
- **Re-import of the unchanged corpus:** 8.2 s for 456 files, with nothing derived again.
- **Edited copies plus the grown mailbox:** 88.3 s. About 98 % of typed-field blocks and 40 % of vectors were reused. The
  piece map proved 14.13 of 14.13 MB of the mailbox unchanged.

Two problems were found and **not fixed**, and both are recorded:
- **PERF-35:** the mailbox message index is never used in the default path. Mailboxes under 64 MiB are parsed whole, and
  thread coalescing is on.
- **PERF-28:** the IVF-0 cause is named. Under load, the embedder silently falls back to the 300-dimension NL embedder,
  but the vectors are still labelled `bge-small.v1`.

## Tracker

These rows are AUTOMATED_VERIFIED, with their test names: PERF-34, 35, 36, 37, 38, 39 and 40.

- `performance_evidence` points to `after-torrent.md` for PERF-34, 35, 36, 37 and 38.
- PERF-39 has no slow disk measurement.
- PERF-40's limit stays: "simulated two Macs; real two-Mac run still needed". The AppState pass and loop, and the erasure
  step through the Keychain identity, were not run.
- PERF-35's next action is an owner decision.

`python3 scripts/smart-map-matrix.py` was regenerated, and `--check` is clean.
