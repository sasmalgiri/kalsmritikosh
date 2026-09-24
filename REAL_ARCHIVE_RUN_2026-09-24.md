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

## Still not verified

- **Whether the extracted values are CORRECT** beyond the ground-truth items
  checked above. Nothing here reads all 71 facts against their sources.
- **Induction** — defaults off, has never called a model.
- **The mbox through the answer path.** Only the 19-file archive was asked
  questions.
