# Real-archive run — 2026-09-24

The first end-to-end run over the owner's own files rather than fixtures. Input:
`~/Downloads/Mail` — 8 PDFs (one scanned), 10 `.eml`, 1 `.docx`, and a 95 MB
mbox. Ground truth was read out of the files by hand BEFORE running anything, so
extraction is judged against what the documents say, not against a fixture
written to pass.

Build `development` · schema v132 · `RealArchivePipelineTests`.

## Ground truth used

| Source | Established by hand |
|---|---|
| `GDPR_Report_patent.pdf` | Data Subject "patent"; generated 21 May 2026; "Emails Involving Subject: 60 of 526 total" |
| `1_.eml` | sasmalgiri@gmail.com → vishu_rani2821@yahoo.com, 8 Jul 2008, body quoted-printable |
| `Sent.mbox` | 526 strict separators; 526 `X-GM-THRID` headers; **366 unique** thread ids |
| `Final POA.pdf` | no extractable text layer — scanned, OCR-only |

The `.eml` files carry a `sourceFile: Sent.mbox` header: they are single messages
carved out of the mbox, so the two inputs overlap and dedup is exercised.

## Ingest — 19 files, 82.4 s

| Format | Files | Documents |
|---|---:|---:|
| docx | 1 | 1 |
| eml | 10 | 10 |
| pdf | 8 | 8 |

217 blocks · 261 chunks · 291 entities · 274 events · 71 facts ·
**0 tolerated failures** · 0 files without a document.

## Ground truth verified

- **Scanned POA → 5,836 characters.** The OCR lane works on a real scan.
- **"Data Subject" findable** — 50 chunks via FTS, a phrase printed on four PDFs.
- **39 email-address entities, none split or still encoded.** The recent
  transfer-decode fix holds on real quoted-printable mail; the split-address
  defect did not reappear.
- **274 dated events** across an archive spanning 2008–2026.

## Golden Thread — twelve stages, real document

`GDPR_Report_patent.pdf`, complete file → citation:

```
✓ file · ✓ version · ✓ blocks (11, paragraph) · ✓ derived · ✓ chunks (18)
· vectors: none yet — embedding drain had not reached it (keyword still finds it)
✓ keyword: found by its own phrase “transmitted externally CONFIDENTIAL”
✓ entities (94) · ✓ events (50) · ✓ facts (6)
✓ retrieval: surfaced via the metadata layer at score 1.000
✓ citation: 8 blocks resolve to a citable place in the source
```

This closed the gap no synthetic test could: retrieval and citation on content
nobody wrote to make a test pass.

## Answers — live model

| Question | Result |
|---|---|
| "What do we know about sasmalgiri@gmail.com?" | answered, cited, conf 0.80 |
| "What do we know about vishu_rani2821@yahoo.com?" | answered, cited, conf 0.80 |
| "What is the date of Case SMOKE_TEST_001 …?" | answered, cited, conf 0.80 — matches ground truth 2023 |
| **control: "What was decided in Case No. …-ZQX?"** | **correctly refused**, conf 0.00, 0 LLM calls |

The control question FAILED on the first run — it was answered in 1,159
characters with three citations at confidence 0.40, composed from a
shape-similar case. See commit `700700a`; fixed and re-verified.

## Defects this run found

1. **Answered a question about a case that does not exist, with citations.**
   Three causes in the RAG fallback: refusal detected by substring-matching two
   English phrases; `refused: refusedShape && citations.isEmpty` letting any
   citation override a refusal; and nothing checking that the identifier the
   question named exists at all. Fixed — `AbsentSubjectGate`, commit `700700a`.

2. **The language report's premise was false.** Its header claimed the app "has
   ALWAYS known what language each document is in". `IngestCoordinator` computes
   `cleaner.clean(...)`, uses it for classification, then persists the
   **uncleaned** originals — the detected language is computed on every ingest
   and discarded. On 19 English documents the report said "19 documents had no
   detectable language": true of the ledger, false about the documents. Now
   detects from stored content at report time; reports 18 English / 1 not.

3. **A warning about zero documents** — "⚠️ 0 document(s) are not in English",
   because the issue line used the unsupported count when the finding was the
   undetected count.

## RESOLVED — the mbox "gap" was my own measurement error

**Nothing was lost.** The 408-of-526 alarm came from comparing *documents* to
*messages*, which are not the same quantity: an email's **attachments are
expanded into documents of their own**.

Measured with the coalescing flag pinned, in one run:

```
mbox:  526        ← exactly one document per message, zero lost
jpg 59 · pdf 31 · doc 31 · docx 17 · unknown 13 · png 12
xlsx 3 · xls 2 · pptx 2 · zip 1 · eml 1        = 172 attachments
tolerated failures: 0 · derivation incomplete: 0
```

The arithmetic closes exactly, and the same 172 appears under both settings —
which is what makes it an explanation rather than a coincidence:

| Thread coalescing | Loader documents | + attachments | = stored |
|---|---:|---:|---:|
| ON | 236 threads | +172 | **408** — the original measurement |
| OFF | 526 messages | +172 | **698** — this run |

The splitter is exact: with coalescing off it recovers all 526 separators.

### The real finding underneath it

`EmailLoader.threadCoalescingEnabled` is **ON** in this environment, read from
`UserDefaults` key `kalsmritikosh.moveA.threadCoalescing`. The code defaults it
to `false` and its own comment says to hold it there:

> Held at `false` until the per-message extraction fanout lands in
> `IngestCoordinator.processKnowledgeObject` so events, mentions, and memory
> subjects don't degrade on thread KOs.

So the archive is currently being ingested as 236 thread documents rather than
526 message documents, with the degradation the code warns about. That is an
owner decision, not a defect — but it is on against the code's own guidance, and
it changes what per-message questions can be answered.

### How I got it wrong

I raised a defect alarm by comparing two incommensurable counts, then proposed
three causes for a gap that did not exist. The tightening that mattered was not
more hypotheses but one measurement that broke the counts down by type. Two
wrong hypotheses were eliminated first — the splitter (exact) and coalescing
(236, which cannot produce 408) — and the contradiction "408 > 236" is what
forced the right question.

## Value audit — and the defect it found (2026-09-25)

Dumped all facts and read them against the documents. **Structure sound, values
not** — then fixed the largest cause.

### The defect: line breaks were being thrown away

`GDPR_Report_patent.pdf` prints ~60 clean `Label: value` pairs. **None became a
fact.** Cause, proven by reading both stored columns:

```
evidence_blocks.raw_text        → 11 / 16 / 34 newlines   (parser preserves)
evidence_blocks.normalized_text → 0                       (normalizer strips)
```

Both callers fed the extractor the normalized text, so every label after the
first sat mid-run behind a plain space, and the label-position gate refused them
all. The gate was correct; it just needed structure the normalizer had removed.

Fixed by passing `layoutTextByBlock` — a separate map read only by the
open-field pass, so the eleven domain packs keep the normalized text they were
tuned against.

**Result: 71 → 352 facts**, and all five hand-verified labels correct:

| Fact | Value | Ground truth |
|---|---|---|
| `datasubject` | patent | ✓ |
| `datasubject` | sasmalgiri@gmail.com | ✓ |
| `emailsinvolvingsubject` | 60 of 526 total | ✓ exact |
| `analysisscope` | PII detection, phishing assessment, data flow mapping | ✓ |
| `earliestrecord` | 23 Jul 2007 | ✓ |

No regressions: ValueRepairTests 21/21, V0AdversarialFixtureTests 10/10.

**The honest other half** — the same change admits noise, since a line opening
"1. Fwd: …" looks like a labelled field: `1fwd`, `categorypersonal`,
`casesmoketest001`, `bodyofre`. Four classes measured and recorded as task #93
with a rule each. The noise is additive, sits at 0.55 below pack facts, and
never displaces a reserved field.

### Value defects still open

- `date = 1970` — the Unix epoch, a MISSING date rendered as a real one
- `date = 2066`; six contradictory dates on one PDF, because bare years in prose
  are stored as the document's date
- `applicationnumber` = `2023310` vs `202331019665` — a truncated identifier
- `signature = 28`; `table = 2 rows × 3 columns` stored as document facts
- `patient = GIRIDHAR SASMAL` — medical pack firing on an investigation report
- `status = filed` and `status = amendment` on one file, no conflict raised
- entity `date: 06:00:22 +0530` — a time stored as a date

### What worked

`applicant = shirshendu sasmal` recovered from the **scanned** POA — the
lowercase-grantor module doing its job on real OCR output.

## Is the database building properly? — structure audited (2026-09-25)

A different question from "do the engines fire". That asks whether rows exist;
this asks whether the rows that exist hold together. Counts look healthy over a
ledger full of orphans — a fact citing a deleted block still counts as a fact,
and an answer built on it still counts as cited.

`LedgerIntegrityTests` builds the ledger from these 19 files, drives every
derived pass, then audits six properties. **All clean:**

| Property | Result |
|---|---|
| SQLite `foreign_key_check` (with `foreign_keys=1`) | 0 violations |
| Orphans — chunks, embeddings, blocks, block→object links, mentions, events, event_entities, KOs | 0 each |
| Facts citing no block at all | 0 |
| **Dangling citations** — walked individually with `json_each` | **0 of 397** across 352 facts |
| Facts citing no block · citation list not valid JSON | 0 each |
| Duplicate fact density | **0%** (352 distinct of 352) |
| `merged_into` dangling · merge **chains** · orphan aliases | 0 each |
| Identifier anchors duplicated on one identity | 0 |

Two results worth naming. The **claim–evidence contract holds on real data** —
all 397 individual citations across the 352 facts resolve to a block that
exists, which is the promise the product is built on and had never been checked
end-to-end. And **duplicate density is 0%**, measured rather than assumed: the
ledger was once 96% duplicate facts, so the test keeps a 40% threshold to trip a
regression.

### Second pass — the audit did not deserve the verdict it produced

The first version returned all zeros and I reported the ledger sound. On a
re-read that claim outran its evidence in three ways, all the same error — **a
check that cannot fail is not evidence** — and all three are now closed:

1. **Vacuous passes.** "embeddings whose chunk is gone: 0" is equally true of a
   correct ledger and of an *empty* table, and this archive's embedding drain
   had not finished. Every check now prints the size of the table it audits and
   reports NOT VERIFIED, never ✓, when that table is empty.
2. **The citation check was loose.** It asked whether a fact LIKE-matched *any*
   surviving block id, so a fact citing five blocks of which four were gone
   passed. I reported it as "every fact cites a block that resolves" — wording
   the SQL could not support. It now walks every citation individually.
3. **No negative control.** Nothing proved the queries could report a problem at
   all; a mistyped column yields a clean zero. The audit now **breaks the ledger
   on purpose** — inside a SAVEPOINT, FKs off, rolled back after — and requires
   each check to fire:

```
✓ delete a knowledge object → orphan chunks detected           0 → 4
✓ delete a CITED block      → dangling citation detected       0 → 5
✓ delete a block            → orphan block→object link         0 → 1
✓ delete an entity          → orphan mentions detected         0 → 1
✓ break merged_into         → dangling merge detected          0 → 1
✓ delete a knowledge object → foreign_key_check reports it     0 → 33
```

**The control immediately caught a hole in my own check** — the citation control
failed at first, because it deleted an arbitrary block and only 102 of 217
blocks are cited by any fact. The check was live; the control was testing the
wrong row. "A block" and "a CITED block" are different populations.

### The one thing NOT verified, and why it is not a gap

**0 entities have ever been merged**, so the two `merged_into` checks have no
population (their queries are proven live by the control above). That is
expected, not missing: `merge()` has three callers and all are user-initiated or
repair. **Unification happens at write time** — every entity insert is
`ON CONFLICT(kind, normalized) DO UPDATE`, so one person named in nineteen
documents becomes one row without any merge.

Reading 0 merges as a broken capability would have been a fourth false alarm, so
the audit now measures the thing itself:

```
entities unified across ≥2 documents: 175 of 277 mentioned
```

### My own bug, caught before it became a reported defect

The first version checked `evidence_blocks.document_id` against
`knowledge_objects` and reported **all 217 blocks orphaned**. That column
references `source_documents` — the parsed structural document — and blocks
reach a KO through `evidence_block_objects` (217 rows, exactly matching). The
Golden Thread above had already disproved the claim by resolving 8 of those
blocks to citations, which is what made the number suspicious rather than
alarming.

Assuming a column's referent is the same error as assuming a call site. That is
the fourth time in this program a confident "something is broken" came from a
measurement that could not support it; the correction each time was to read the
thing rather than pattern-match its name.

## Still not verified

- **Whether the extracted values are CORRECT** beyond the ground-truth items
  checked above. Nothing here reads all 71 facts against their sources.
- **Induction** — defaults off, has never called a model.
- **The mbox through the answer path.** Only the 19-file archive was asked
  questions.
