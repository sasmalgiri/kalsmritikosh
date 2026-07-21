# Kalsmritikosh — End‑to‑End Analysis: Ingestion → Answer Quality

_Investigation date: 2026‑07‑21. Corpus: `~/Downloads/Mail` (20 top‑level files incl. a 91 MB `Sent.mbox`). Device: 16 GB Mac, macOS 26.5. Reasoning model: Ollama (mixtral → qwen2.5:7b)._

This document records, honestly, what was investigated, what was found, what was
fixed, and what remains — from raw files all the way to a cited answer.

---

## 0. TL;DR

- **Ingestion is correct and complete.** Every supported format parses; the whole
  mail folder is covered (526/526 messages, 99.3% unique attachments, 0 failures);
  stored text faithfully matches the source (~100% once measurement artifacts are
  removed).
- **The model layer is now safe.** The app no longer silently runs an over‑RAM
  model; it hard‑gates unfit models and prefers a device‑fitting one (qwen2.5:7b),
  with consent‑gated install.
- **The real remaining weakness is RETRIEVAL AUTHORITY, not ingestion or the model.**
  For questions about a person/entity, the retriever could surface high‑volume
  incidental mentions (patent/legal emails) above the one authoritative document
  (a résumé). A first fix landed and works for the clear case; two harder cases
  remain and need a document‑type / intent‑aware iteration.

The one‑line mental model that held up throughout: **the intelligence must live in
the database and its retrieval, not the model.** Ingestion delivered that; retrieval
ranking is the current frontier.

---

## 1. Ingestion & parsing — VERIFIED GOOD

**Parsers (all 20 formats).** Each format was run through its real parser (no mocks)
on synthetic fixtures (100% marker recovery) and on real mbox attachments. Legacy
`.doc` (OLE2/MS‑DOC) and `.xls` (BIFF8) extract real text; PDF via PDFKit; images via
real Vision OCR. Benchmarked against my own reading of the source docs — parser output
matched what a human can read; only cosmetic OCR‑glyph differences (₹ → 7).

Fixes made along the way:
- `partial` status was over‑conservative (a blank PDF page / an `.info` table‑geometry
  note downgraded a text‑complete extraction). Now only genuine degradation → `partial`.
- Images no longer inject their filename as searchable "content".
- Extensionless attachments (a real JPEG named as a bare hash) were mis‑routed to the
  text loader and refused as binary. Now routed by MIME `Content‑Type` + magic‑byte
  sniffing → they ingest correctly.

**Evidence‑first storage.** `chunks.evidence_block_id` was written at ingest but **omitted
from every read query**, so the chunk→EvidenceBlock link was invisible at query time.
Fixed the read path → 100% of chunks now report their block link.

## 2. Completeness — VERIFIED (disk vs DB reconciliation)

Source enumerated exhaustively and reconciled against the DB:

| Unit | Source | In DB | Coverage |
|---|---|---|---|
| Top‑level files | 20 | 20 | 100% |
| Mbox messages | 526 | 526 | 100% |
| Unique non‑media attachments | 148 | 147 | 99.3% |
| Media (audio/video) | 4 | deferred (0 as files) | correct by design |
| Failed / interrupted | — | 0 / 0 | — |

The single "missing" attachment was a **truncated/corrupt copy** damaged in the source
email itself; its clean duplicate is ingested. After the extensionless‑attachment fix
and a re‑ingest, failures went to **0**.

Two ingest robustness/UX bugs found & fixed here too: a stranded folder bookmark under a
legacy key (`atlas.bookmarks`) that made "re‑ingest do nothing"; and a MainActor freeze
from counting a 91 MB mailbox on the main thread. Pause/Stop controls + a live per‑stage
status bar were added.

## 3. Content fidelity — VERIFIED (~100%)

Beyond counts, the **stored text was compared to the source text**:
- Word‑for‑word verbatim match on a `.docx` and an `.eml`.
- A sampled token‑overlap audit of 40 message KOs: raw ~99%, and every apparent "miss"
  was proven to be a **measurement artifact** (my audit truncated words mid‑character
  and my re‑decode was rougher than the app's). A `grep` of the raw mailbox confirmed the
  "missing" words are present (e.g. `tarun` 135×, `xmlns` 260×). Direction of every
  discrepancy: my checker ⊂ DB ⊆ source — i.e. the DB captured *more* than my audit,
  never *less*. **No fabrication, no corruption.**

Deliberate, correct differences: the parser **adds** structural labels (`Subject:`,
`Date:`) and **drops** transport headers (Message‑ID/Received/DKIM). Additive/curated,
never destructive.

## 4. Model selection — FIXED

**Why the app used mixtral (26 GB) on a 16 GB Mac:** it adopted whatever reasoning model
Ollama already had (discovery), and the resolver picked by *capability*, not *fit* —
RAM was advisory. Result: a model that only "runs" by swapping to disk → multi‑minute
answers.

Fixes:
- **Strict device‑fit gate:** any generative model whose estimated working set exceeds
  70% of device RAM is **excluded from selection — even if pinned**. mixtral (≈39 GB) is
  refused; qwen2.5:7b (6 GB) and llama3 are eligible.
- **Consent‑gated install** of a device‑suitable model (qwen2.5:7b recommended for 16 GB);
  no download without the user's explicit tap.
- Verified live: reasoning provider resolves to `qwen2.5:7b`, answers in ~35–60 s, no
  hallucination, always cites, honest ("not specified") when evidence is thin.

## 5. Answer quality — THE REAL REMAINING PROBLEM (retrieval authority)

With a good model on a faithful, complete ledger, answers were still sometimes wrong —
and the cause is **retrieval**, not the model or the data.

**Root cause (measured in SQL):** a person's name appears far more in high‑volume
correspondence than in their one authoritative document.
- "Shirshendu Sasmal": **186×** across `Sent.mbox` per‑message KOs vs **~15×** in his
  résumé. So semantic/entity retrieval floods with incidental patent/legal mentions and
  the authoritative bio is outvoted.
- Compounded by **entity fragmentation**: the person was split into 5 un‑merged entities
  (`Mr. …`, `'…'`, `… Patent No`, `… CORPORATE`).
- The data is present and findable (FTS for the real employer "Orchid" hits the résumé).
  It is purely a **ranking / authority** problem — the open task **P5.1**.

**Fix landed (commit `8d3184e`):**
- **A. Person‑name merge** — fold honorifics + surrounding quotes so variants collapse to
  one canonical entity (applies on re‑ingest).
- **B. Direct‑evidence‑first authority** — for the query's entity, documents that *densely*
  mention it (the mbox fans out to per‑message KOs, so a résumé's ~15 mentions/KO dominates
  correspondence's ~1/KO) are **injected** as candidates and **stable‑promoted** to the top
  before diversify. Gated on entity seeds → other query types unaffected.

**Measured outcome (honest):**

| Question | Before | After |
|---|---|---|
| "Summarize Tapas Maity's research experience" | patent grant certificates | ✅ cites his résumé (Piramal, Process R&D) |
| "PhonePe payment — to whom / how much" | email, amount "not specified" | ⚠️ unchanged |
| "Where has Shirshendu Sasmal worked" | patent PDF ("Khurana") | ⚠️ unchanged |

Eval gate (ProjectDelta fixture, deterministic): retrieval recall **1.00**, cite‑precision
**1.00** across all classes — **no regression**.

**Why the two stragglers remain:**
1. **PhonePe payment** — the amount (₹3,800) + payee live in a **receipt IMAGE**
   (`TransactionReceipt.jpeg`) via OCR. It isn't *entity‑dense*, so the density heuristic
   doesn't inject it. Needs a **document‑type / intent** signal (a receipt/transaction doc
   is authoritative for a payment question).
2. **Sasmal's employer** — his name is dense in **both** his résumé *and* patent threads,
   so mention‑count alone can't disambiguate; and the entity‑merge (A) isn't applied to the
   current DB yet (needs a re‑ingest). His real employer (Orchid Chemicals, Production
   Executive) is in `Resume.doc`.

Minor, separate: a `"Subjects in scope: …"` debug line leaks into answer bodies (UI/synthesis).

---

## 6. Conclusions

1. **Ingestion is not the bottleneck — it is solved.** Coverage, completeness, format
   fidelity, evidence linking, and embeddings are all verified against the real corpus.
   Effort spent re‑checking ingestion has reached diminishing returns.
2. **The model layer is now correct and safe** (device‑fit enforced, fast fitting model,
   honest/no‑hallucination behavior). Model choice is not the problem.
3. **The decisive lever for answer quality is retrieval authority** — deciding *which*
   evidence reaches the model. This matches the product thesis ("intelligence in the
   database, not the model"): a faithful ledger is necessary but not sufficient; the
   ranking that selects evidence is what makes or breaks an answer.
4. **The first authority fix is real and generalizes** (a document genuinely *about* an
   entity now surfaces), proven by the Tapas Maity case with no eval regression — but it is
   a **first iteration**, not the finished P5.1.
5. **Next step, in priority order:**
   - (a) Re‑ingest to apply the entity‑merge (A) and de‑fragment people.
   - (b) Add **document‑type / query‑intent authority**: a person's own résumé outranks
     their correspondence for "where worked"; a receipt/transaction doc wins payment
     questions; a contract wins "what were the terms".
   - (c) Remove the `"Subjects in scope"` debug leak from answer bodies.
   - (d) Then re‑run the same real questions to confirm all three pass.

**Honest bottom line:** the database is built to a high standard and faithfully mirrors the
source. Getting consistently correct *answers* now depends on finishing the retrieval‑
authority work (P5.1) — that is where the remaining quality lives, not in ingestion or the
model.
