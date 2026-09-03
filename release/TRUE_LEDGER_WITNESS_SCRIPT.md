# TRUE-LEDGER CHECKPOINT — Owner Witness Script (HOLD 1)

**Date prepared:** 2026-09-03 · **World:** post-drain live archive, schema v123, seal #4
**Your time:** ~half a day. Nothing here needs a terminal unless marked OPTIONAL.
**Gate phrase when satisfied:** `Witness complete — Go 2 activated.`

---

## 0. What you are witnessing

Go 1 ended with the one sanctioned rewrite of the derived layers (the drain). Everything
below shows you, live on YOUR archive, that the machine now stands on a true ledger:
junk retired, facts and events rewritten by the current extractors, every answer
reproducible to the byte. The banked Go 2 opens only on your phrase.

**Rollback exists first:** `~/Downloads/kalsmritikosh-pre-drain-snapshot-v123.sqlite`
(118 MB, integrity-checked). A second copy sits beside the live database. Nothing you do
below writes to the ledger.

## 1. Launch (5 min)

Build/launch Kalsmritikosh from `main` (≥ commit `a870ab5`) against your live archive.
Wait for the boot caches to warm (the status line settles; first minutes are the slow
window — this is the known I-6 boot item, honest and on record).

## 2. Rung 1 — the anchor fact (5 min)

Ask: **`what is the granted patent number`**

- Expect exactly: **“Patent No. 555489.”**
- Citations present; the quality strip shows confidence + evidence counts.
- This answer is sealed: five consecutive harness runs reproduced it — and its body,
  citations, and confidence — byte-identically (seal #4 ×5 record in your Downloads).

## 3. Rung 1n — the honest not-found (10 min)

Ask: **`what is the trademark number`**

- Expect a NAMED abstention: the answer names the trademark-number field, states it is
  not among the fields this archive's documents contain, and offers the nearest field
  on file.
- Expect the receipt line: *“(Receipt: N document(s) exhausted across the keyword,
  entity, timeline and semantic layers; no model was consulted.)”*
- Expect NO “Reported: …” fact-spam anywhere in the answer.
- This was Go 1's last flip (F8): the machine that knows 555489 also knows what it
  does NOT know, and proves it searched before saying so.

## 4. Conflicts surfaced, never averaged (5 min)

Ask: **`what is the application number`**

- Expect a conflict list (four variants of 202331019665, canonically labelled).
- The junk variants are real OCR artifacts from your documents, kept by the no-delete
  law and shown honestly; their cleanup path is the ingestion train (post-1.1).

## 5. The timeline data — what the drain built (10 min)

Open the **Timeline** view and locate the patent-lifecycle milestones:

> FER issued 2022-11-29 → application filed 2023-03-21 → objections → FER 2023-08-22 →
> hearing notice 2024-07-11 → hearings 2024-08-05/13 → **granted 2024-11-28** →
> intimation of grant 2024-11-28

- 36 milestones, all dated, ordered, and event-classed (v4 class gating: no
  “invoice issued” noise inside legal documents).
- HONEST EXPECTATION: asking *“timeline of the patent”* in Ask does NOT yet compose
  these into one narrative chain — that composer is Go 2 (P3-U2), diagnosed and on
  record (R-1). The DATA is what you are witnessing today; the STORY is next.

## 6. The drain receipt (10 min)

Read (Downloads): `kalsmritikosh-seal4-x5-stability__pinned-1788220800.txt` and the
bless note `kalsmritikosh-baseline-seal4-fa5b975.blesses.txt`. The receipt of record:

```
entities retired:        30 (+0 memory rows)
facts: sources rewritten 132 (deleted 564 stale → wrote 1969 v2); anchors now 6
events: KOs rewritten    573 (deleted 902 stale → wrote 864 v1)
milestones rebuilt:      36
document_class stamped:  716 (of 716)
entities stamped v1:     4313
untouched: chunks 10455→10455 · fts 10455→10455 · embeddings 9632→9632 [PROVEN]
```

The untouched line is the law: sources and evidence were never touched — the proof is
counted before and after, and the run fails if they differ.

## 7. The ledgers (15 min)

- **Self-Rulings Ledger** (2 entries, both under your standing grant):
  - SR-01 — drain snapshot lands beside the live ledger (sandbox denies ~/Downloads);
    mirrored to your Downloads after the run. Adding a Downloads entitlement was
    rejected to keep the ship posture minimal (RC-1).
  - SR-02 — XLSX table exports were dropping citations; they now append the citation
    block. Found BY the new export-citations guard; the page promise (“Excel with
    citations baked in”) now holds in the bytes.
- **The remaining reds (4), each owned:** OCR digit recovery + page-break assembly
  (Go 3 Train 3) · rung-2 timeline composer (Go 2 P3-U2) · causal bounding (Go 3
  Train 4). The xfail set can only shrink.
- **OWNER CALL at this HOLD:** the Convert card says “back and forth” — pairs do
  convert both directions; byte-round-trip is not a thing any converter does. Keep the
  wording or soften it (page wording is yours alone). See
  `release/PROMISE_CARD_INVENTORY.md`.

## 8. OPTIONAL — reproduce the seal yourself (terminal, ~15 min)

```bash
TEST_RUNNER_BASELINE_ARTIFACT="$HOME/Downloads/kalsmritikosh-baseline-seal4-fa5b975__v123__pinned-1788220800__true-ledger.json" \
TEST_RUNNER_BASELINE_QUIESCE=1 TEST_RUNNER_KALSMRITIKOSH_REFERENCE_NOW=1788220800 \
xcodebuild test -project Kalsmritikosh.xcodeproj -scheme Kalsmritikosh \
  -destination 'platform=macOS' -only-testing:KalsmritikoshTests/BaselineParityHarness \
  -parallel-testing-enabled NO
```
Expect: `PARITY: 7/7 answers byte-identical to seal4-fa5b975`.

## 9. The gate

If the above held, reply with exactly:

> **Witness complete — Go 2 activated.**

Go 2 then runs S2-U1 → P5-U2 (representation → answer contract → story → ship gate,
plus RC-1…RC-7), reseals #5/#6/#7, to HOLD 2 — your ship day.
