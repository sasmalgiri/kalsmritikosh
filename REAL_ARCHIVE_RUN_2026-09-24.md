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

## Open, not resolved — task #91

**The mbox produced 408 documents from 526 messages.** 9,355 chunks, 316 s.

The gap is not a counting artefact: 526 strict separators, 526 thread headers,
366 **unique** thread ids, and the app's own earlier GDPR PDF independently says
"of 526 total". 408 matches neither 526 (per message) nor 366 (per thread), so
neither "no dedup" nor "thread dedup" explains it. Candidate causes, untested:
content-hash dedup collapsing identical messages; the splitter dropping messages
on some header shape; or per-message derivation failing and being skipped.

Recorded precisely rather than resolved by speculation. The next step is to
re-ingest the mbox and read `files.alias_of`, `derivation_failures` and
`derivation_complete` to separate legitimate dedup from silent drops.

## Still not verified

- **Whether the extracted values are CORRECT** beyond the ground-truth items
  checked above. Nothing here reads all 71 facts against their sources.
- **Induction** — defaults off, has never called a model.
- **The mbox through the answer path.** Only the 19-file archive was asked
  questions.
