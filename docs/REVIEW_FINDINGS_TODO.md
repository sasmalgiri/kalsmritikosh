# Review findings — verified TODO

_Source: external read-only review `Kalsmritikosh-Review-Matrix.xlsx` (28 Sep 2026, pinned `main` 49e914b7,
32 findings, no Mac execution, 68/1,920 files read in full). Every finding below was re-checked against
the source on 2026-09-28 by the agent. Branch: `review-fixes` off `main` b9cdb5f2._

**Verdict keys:** ✔ confirmed in source (file:line read) · ◐ confirmed as design limit / scale-only ·
⚖ owner decision already on record (claim wording, not a code defect).
**Priority:** **R0** fix before release (wrong output, leak, crash, lost data on ordinary files) ·
**R1** fix before release if time allows / no ordinary-use harm · **R2** scale or post-release.
**Status:** ☐ open · ◐ in progress · ☑ done.

Every fix: one commit, a small fixture test that FAILS on the old code first, full suite + CI green.

---

## Wave 1 — protect what leaves the app (R0)

| ID | Verdict | Finding (verified) | Fix | Acceptance test | Status |
|---|---|---|---|---|---|
| F22 | ✔ | `DisclosureSelectionService.conflicts` copies side B text + evidence without scope check (gaps DO require both ends in scope — conflicts don't) | Resolve both sides' evidence under the export's effective scope; out-of-scope side → a generic "withheld opposing source" line with no text | Permitted claim linked to an out-of-case / privileged opposing source: report + receipt carry none of its text | ☑ — each side authorized (workspace ∩ sensitivity; case = claims' own evidence); unauthorized side → withheld line, no text/evidence |
| F23 | ✔ | `WorkProductExportService.redactedDocument` passes `citations` and `manifest` through unredacted | Redact every user-text field (citation snippets/labels, manifest titles/notes); keep IDs; verify the FINAL bytes of every format | PII only in a citation snippet / manifest title / author → absent in md, html, docx, pdf outputs | ☑ — citations (label/title/author/locator/exhibit/bibliographic) + manifest text redacted; second category pass over user text fails closed; tested in all 8 formats |
| F24 | ✔ | `PDFRedactionService`: failed `flatten` draws a BLANK page; unreadable output makes `residualTerms` return [] → `verified: true`; missing page silently skipped | Throw on nil flatten / missing page / reparse failure; check output page count == input | Injected render failure and corrupt output never return `verified` | ☑ — nil flatten / missing page → `renderFailed`; unparseable output or page-count mismatch → `verificationUnreadable` |
| F29 | ✔ | `WorkflowEvidenceReferenceGate`: issue/gap/contradiction skip sensitivity lineage | Resolve referenced evidence under workspace/case/sensitivity scope; deny unknown lineage in restricted workflows | Mixed-workspace claim, global contradiction, unknown owner → denied in restricted workflow | ☑ — issue links / gap anchors / contradiction evidence each pass workspace + sensitivity; malformed or unknown link kind denies; explicit scope denies unknown lineage (unscoped global behaviour kept); 5 tests fail on old code |
| N1 | ✔ (found while fixing F23) | `PIIRedactor.phonePattern` `\+?\d[\d \-]{8,}\d` also matches ISO dates ("2026-09-01") → redacting phones blanks every ISO date in exported prose | Require a phone shape (country code / grouping / not a YYYY-MM-DD date) — reuse `EntityQualityGate.isPhoneShaped` rules | "Hearing on 2024-08-06, call +91 98765 43210" → date kept, phone redacted | ☑ — candidates made only of YYYY-MM-DD / DD-MM-YYYY dates or a year range are skipped; every other match still redacted |

## Wave 2 — correct answers on ordinary files (R0)

| ID | Verdict | Finding (verified) | Fix | Acceptance test | Status |
|---|---|---|---|---|---|
| F30 | ✔ (Swift run) | CSV: `"\r\n"` is ONE Swift Character → neither `"\r"` nor `"\n"` branch → every Windows CSV collapses to one row (structural + discussion parsers) | One shared CSV reader over unicode scalars / bytes: CRLF, LF, CR, quoted newlines | Same two-row data in CRLF/LF/CR (+ quoted newline) → 2 rows everywhere, row citations reopen | ☑ — `CSVRowReader` (unicode scalars, CRLF/LF/CR, BOM) behind structural, discussion, Workbench + loader rowCount; CSV parser → v2; row locators tested |
| F26 | ✔ | `parseNumber` keeps only digits/./+/- → `1e3`→13, `abc12`→12, `1,23`→123; ROUND `Int(places)` TRAPS on NaN/huge | Declared number grammar (sign, grouping, decimal, exponent, %, currency); reject junk; ROUND precision bounded & finite | 1e3=1000, abc12=null, 1e-11 kept, ROUND(x, NaN/1e20) → error not crash | ☐ |
| F27 | ✔ | Aggregate group key = labels joined with " · ", null = "∅" → distinct tuples merge (dedup path already length-prefixes) | Typed tuple key (length-prefixed, distinct null); lineage includes grouping cells | [A · B, C] vs [A, B · C] stay 2 groups; null ≠ literal "∅" | ☐ |
| F31 | ✔ | XLSX: cells packed in encounter order (ignores `r=`), sheet names by `sheetN` order not relationships, `<f>`+`<v>` stripped together (`SUM(A1:A2)3`) | Honour `row@r`/`c@r`, resolve workbook rels, store formula and cached value separately | A1/C1 sparse row, row 5 gap, reordered sheets, formula cell → exact locators and value | ☐ |
| F32 | ✔ | XML scanner skips every `<!…>` incl. CDATA text; status stays complete | Keep CDATA text; report any skipped construct as partial | Plain + CDATA text both retained; lost content → partial status | ☐ |
| F06 | ✔ | `LedgerTools.lookupField` puts BLOCK ids in `objectIDs`; AppState turns them into `Citation.objectID` → citation can't open | Map blocks → owning object (`EvidenceStore.owningObject`) before citing | Tool-grounded field answer: citation opens its document | ☐ |
| F07 | ✔ | ToolGroundedComposer rejects ADDED negation only; a sentence that DROPS the evidence's negation passes | Polarity must match both ways (+ keep currency/unit/date checks) | "was granted" against "was not granted" evidence → sentence dies | ☐ |
| F10 | ✔ | Embedding drain: first 256 missing chunks all known-unembeddable → treated as "drained" → older valid chunks starve | Exclude known failures IN the SQL (before LIMIT) / keyset past them | 256 failing chunks ahead of 1 valid → valid gets its vector | ☐ |
| F04 | ✔ | SQLite loader: `WHERE rowid > ?` starting at 0 skips rowid ≤ 0; 500,000-row cap | First page without lower bound, keyset after; count + report deferred rows | rowids −2, 0, 1 all imported; WITHOUT ROWID table handled | ☐ |
| F03 | ✔ | Intake snapshot copies only the main SQLite file; `ExternalSQLiteSource` looks for `-wal` next to the SNAPSHOT → committed WAL rows lost | Capture db + `-wal`/`-shm` as one acquisition set (hash each), or online-backup derivative labelled as such | Live WAL db with uncheckpointed committed rows → all rows imported | ☐ |
| F05 | ✔ | Multi-object block ownership only understands mailbox indices | Parser-native record key + exact block ids for every multi-object parser | Multi-table SQLite: each chunk resolves to its row block | ☐ |

## Wave 3 — backup, recovery, background work (R1)

| ID | Verdict | Finding (verified) | Fix | Acceptance test | Status |
|---|---|---|---|---|---|
| F17 | ✔ | Backup `inspect` checks only file presence; basename flattening; UI backup omits evidence vault | Verify size + SHA-256 per entry; unique relative paths; label ledger-only vs full | One flipped byte (same size) / same-name originals / missing vault blob → rejected | ☐ |
| F18 | ✔ | Checkpoint then sequential file copies — no write exclusion | SQLite online backup API through the Database actor; integrity-check the copy | Backup during small concurrent writes opens clean (`integrity_check`) | ☐ |
| F19 | ✔ | Restore trusts manifest paths, deletes destination then copies, no staging/rollback (UI inspect-only today) | Validate paths (no `..`/symlink), stage into a fresh dir, open-check, atomic swap | Traversal/symlink/mid-copy failure → old data intact | ☐ |
| F20 | ✔ | `drainUpgrades` has no app caller; legacy recovery requeues running jobs incl. valid leases | Wire a supervised drainer at boot/idle; recovery only reclaims EXPIRED leases | Boot with pending + valid + expired leases → only eligible claimed, work completes | ☐ |
| F21 | ✔ | Terminal job writes `WHERE id = ?` only — no lease token/state | Condition terminal writes on `state='running' AND lease_token=?` | Reclaimed job: old worker's completion rejected | ☐ |
| F28 | ✔ | Raw `SAVEPOINT` spanning `await`s on the shared actor (Workbench + others) can interleave | Move validation + writes into `Database.withSavepoint` (synchronous, isolated); audit other await-spanning savepoints | Two interleaved transforms + one failing → no cross-rollback, stale revision fails | ☐ |
| F16 | ✔ | Reprocessor restamps readiness with the new parser version from the OLD proof — no re-parse | Run the new parser version, stage, validate, activate atomically | Parser-v2 fixture yields changed blocks; interruption never stamps v2 falsely | ☐ |
| F25 | ✔ | `.indexing` upgrade dispatches to `upgradeStructure`, which writes no chunks/FTS | Real index rebuild from committed blocks | Delete a source's chunks, request search readiness → known text found again | ☐ |
| F15 | ◐ | Completion/freshness is count-based | Per-stage expected-vs-produced coverage; evidence revision counter | Removing one derivation (same counts elsewhere) is detected + repaired | ☐ |
| F02 | ✔ | `mediaTranscription` module exists, but ingest defers ALL audio/video before plugin resolution | Route by resolved plugin capability; when module on, transcribe on ingest → blocks/chunks | Short audio with module on → searchable, timed citation opens; module off → deferred as today | ☐ |

## Wave 4 — retrieval completeness (R1)

| ID | Verdict | Finding (verified) | Fix | Acceptance test | Status |
|---|---|---|---|---|---|
| F08 | ✔ | SourceScopedRetriever filters AFTER global limits → case evidence crowded out (fails closed, recall loss) | Push scope predicates into candidate queries before LIMIT | Authorized rows behind higher-ranked unauthorized duplicates still retrieved | ☐ |
| F09 | ✔ | History collector caps 5,000 events / 5,000 assertions / 500 relationships | Keyset paging + processed/total/deferred counts in the story | Tiny page size → complete traversal, honest deferred count | ☐ |

## Wave 5 — scale & resource control (R2 — no large-data claim made)

| ID | Verdict | Finding | Plan | Status |
|---|---|---|---|---|
| F01 | ✔ | Plugin adapter reads the whole file into memory and returns all objects | Streaming producer/sink contract with per-batch commit | ☐ |
| F11 | ◐ | IVF probe loads whole cells before the 4,000 pool check | Page postings within cells; separate memory bound from recall budget | ☐ |
| F12 | ◐ | Corpus-wide caches; worker caps from boot-time RAM | Byte-accounted caches, bounded queues, pressure-adaptive workers | ☐ |

## Claim wording — not code defects (owner-decided scope)

| ID | Verdict | Note | Action | Status |
|---|---|---|---|---|
| F13 | ⚖ | Coverage "FULL" follows parser availability; RAR/7z unsupported; ZIP limits | Generate the capability matrix from measured fixture fidelity; reword "any format" claims | ☐ |
| F14 | ⚖ | English OCR/ASR defaults; name-based identity merges | v1 is English-only by owner decision (multilingual = v2, bge-m3); identity merges are reviewable/reversible — state both in product copy | ☐ |

---

**Suggested order:** Wave 1 → Wave 2 → Wave 3 → Wave 4; Wave 5 and the wording items after release.
Counts: 32 findings — 27 ✔ confirmed defects, 3 ◐ design/scale, 2 ⚖ wording. R0: 15 · R1: 12 · R2: 3 · wording: 2.
