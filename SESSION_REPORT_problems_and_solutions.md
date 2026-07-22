# Session Report — Problems Found & Solutions Applied

**Date:** 2026-07-22
**Baseline at start:** `main` @ `8d3184e`
**Head at end:** `main` @ `f36b124` (all work committed **and pushed**)
**Method:** Production Readiness pack tasks, executed one bounded commit at a time; every
code change verified by `BuildProject` + `RunCodeSnippet`, and the retrieval fix verified
against the **real** `knowledge.sqlite` (667 knowledge objects from the Mail corpus).

This file records, honestly, every problem found this session and exactly what was done —
governance/documentation, then the decisive retrieval-authority engine work.

---

## Part A — Governance & audit (documentation truth)

### A1. Problem: contradictory, stale "authoritative" documents
The repo had multiple planning docs that disagreed on the core product contract — model
strategy (bundle Llama vs Apple Foundation Models), minimum OS, network/cloud, and
advertised scale (100 GB / 1 TB claims with no recorded test). Agents could follow any of
them and reach different conclusions.

**Solution (GOV-001/002/003/004, commits `d785e09` `75f7f62` `e5e17da`):**
- Rewrote `SHIP_DECISIONS.md` into ONE locked contract (owner-approved this session):
  **macOS 26 + Apple Foundation Models + bundled BGE; NO bundled Llama, NO Ollama/cloud in
  release; advertised scale = tested-figure-only.** Added per-class LLM budgets and a dated
  change-control log. (Consequence: llama.cpp packaging P1.2/P3.1 → DEFERRED.)
- Bannered 11 stale trackers (`CURRENT` / `PARTIALLY SUPERSEDED` / `HISTORICAL`) and
  converted `SHIPPING.md` into a Mac App Store runbook (old DMG/cloud/pricing preserved in an
  appendix — never delete history).
- Pointed `CLAUDE.md` at the pack instead of the stale `TASKS.md`.
- Generated `PRODUCTION_STATUS.md` — one evidence-cited status view across all 13 phases,
  separating "verified this session" from "proposed from manifest."

### A2. Problem: no code-grounded inventory of what actually exists
Old status docs marked implemented systems as missing and vice-versa.

**Solution (AUD-001/002/003, commits `778f8f4` `5747463` `d09a85a`):**
- `FULL_REPOSITORY_STATIC_AUDIT.md` — every subsystem with honest status (385 Swift files,
  ~88.7k LOC, schema v54).
- `FILE_BY_FILE_AUDIT.csv` — all 385 files classified (subsystem, authority level, runtime
  role, test coverage, release visibility, risk).
- `SCHEMA_AUTHORITY_MAP.md` — all 74 tables classified authority / projection / cache.
- `docs/architecture/EVIDENCE_AUTHORITY.md` (EV-001) — declares the single canonical chain
  `SourceDocument → SourceVersion → EvidenceBlock`; everything else is a projection.

### A3. Problem: the test suite cannot run
49 test files exist but **0** are wired into an executable target (`project.pbxproj` has no
test target; SDKROOT is even mis-set to `iphoneos`).

**Status:** documented as the **TST-001 blocker**. Not fixed this session because wiring the
test target edits `project.pbxproj`, which is unsafe while Xcode is open — and this AI
assistant runs *inside* Xcode, so closing Xcode would end the session. Deferred as the last,
reversible step. In the meantime, verification is done via `BuildProject` + `RunCodeSnippet`.

---

## Part B — The decisive problem: wrong-document retrieval (answer authority)

This is the heart of the session and your top-priority complaint: the app fetched the
**wrong document** to answer a question.

### B1. Root problem (restated and re-confirmed on real data)
For a question about a person/entity, the retriever ranked evidence by **how often the
subject was mentioned** ("density"). But mention count is the wrong signal:

- A person's **own résumé** names them only **~2 times** — it is short and focused.
- Their name appears **hundreds of times** across incidental correspondence (a Sent mailbox),
  patent emails, investigation PDFs, etc.

So the one authoritative document (the résumé that actually answers "where has he worked")
was **out-voted by high-volume incidental mentions**. The data was always present and
findable; the ranking was choosing the wrong evidence. The pack explicitly bans this density
hack (Directive §7).

### B2. Solution — a three-part, question-conditioned authority engine

Instead of "mentioned a lot = authoritative," a document is authoritative to the extent its
**role and the fields it carries match what the question asks for.**

**RET-001 — `QueryPlan` compiler** (`Kalsmritikosh/Retrieval/QueryPlan.swift`, commit `73f0bda`)
Turns a question into an explicit plan: target subjects, **requested fields** (amount, payee,
date, employment, terms, status…), time scope, **preferred source roles**, and an evidence
policy. Deterministic, zero model calls. Verified: "where worked" → employment field +
**biographical** role; payment → amount/payee + **transactional** role; "terms" →
**contractual**; "patent granted" → **official**.

**RET-003 — `DocumentFitness` scorer** (`Kalsmritikosh/Retrieval/DocumentFitness.swift`, commit `62510c3`)
Scores each candidate = **role-match + field-match**, with mention density **log-damped to a
whisker** (it can only break ties, never decide authority). A bridge role-inference maps
documents to roles from reusable signals (filename, source type, fields present) — pending
the canonical `DocumentRole` (SEM-001).

**RET-009 — wired into `HybridRetriever`** (commit `bc5b3f6`)
Replaced the density boost: the authoritative document now leads the evidence window, ordered
by fitness. Designed so **recall cannot regress** (no candidate is ever dropped) and it only
engages when the question names a specific role.

### B3. The bug the real-data check caught (why "check first" mattered)
After wiring, you asked me to verify against the real database first. That check found RET-009
did **not** actually fix the real case yet — two bugs my synthetic tests had hidden:

1. **Candidacy excluded the authoritative document.** I had gated candidates by mention
   *count* (≥ 3). But the résumé has only **2** subject mentions — so it was thrown out
   *before* fitness could score it. The candidates were all mailbox/investigation PDFs.
2. **The whole mailbox is one giant document.** `Sent.mbox` is a single knowledge object whose
   text quotes everyone's CVs, receipts and contracts — so it read as "employment" too and,
   with more mentions, would out-score the focused résumé.

**Solution (commit `f36b124`):**
1. Candidacy is now by mention **existence** (`objects.findMentioning(subject)`) **plus the
   retrieved set** — not count. The low-mention résumé is now considered.
2. A source's role is its **document type, not its quoted content**: email / mbox / chat
   families are always **correspondence**, so the giant mailbox can no longer masquerade as a
   résumé.

### B4. Verified result (on your real data signals)
Ranking for "Where has Shirshendu Sasmal worked?", built from the actual DB rows:

| Document | Subject mentions | Fitness score | Outcome |
|---|---:|---:|---|
| **Resume-*.doc** (his CV) | **2** | **1.855** | ✅ ranked #1 (biographical + employment) |
| whole `Sent.mbox` super-KO | 4 | 0.380 | demoted (correspondence + penalty) |
| Investigation PDFs | 5–7 | negative | demoted (wrong role, no employment field) |
| numeric/GDPR PDFs | 4–6 | ≤ 0.08 / negative | demoted |

**The authoritative document now wins despite having the *lowest* mention count** — which is
exactly the behavior the product thesis requires.

---

## Part C — Real-data facts surfaced during the check

- **Sasmal's CV/résumé does exist in your ledger** — ~15 copies (email attachments). Per the
  CV: current employer **Hospira India Pvt. Ltd.** (PPIC Executive); prior **Orchid Chemical
  & Pharmaceutical Ltd., Aurangabad**, 9+ years since Dec 2004 (production chemist/GMP → SAP →
  production planning for seven plants).
- **Entity fragmentation (open issue):** the person is split across **40+ un-merged entities**
  (`sasmalgiri@gmail.com` 571 mentions, `Shirshendu Sasmal` 230, `Sasmal` 130, `Mr. Sasmal`,
  `SHIRSHENDU SAMAL`, `…CORPORATE`, `…Patent No`, Fresenius emails…). The merge fix exists in
  code but only applies on **re-ingest**, which has not been run.

---

## Part D — What is done vs what remains

### Done & pushed this session (14 commits)
- Governance: GOV-001/002/003/004
- Audit: AUD-001/002/003
- Evidence authority declaration: EV-001
- Retrieval authority engine: RET-001, RET-003, RET-009 (+ the real-data fix)

### Remaining / known limitations (honest)
1. **In-app end-to-end confirmation of RET-009** — the fitness ranking is verified on real DB
   signals, but a full run through the live app (re-asking in the Ask screen) is the last
   mile. A code snippet cannot drive the whole app stack, and the running app would contend.
2. **Entity fragmentation** — needs a re-ingest to apply the person-merge (rebuilds the
   ledger; needs your go-ahead).
3. **RET-008 (duplicate independence)** — the ~15 identical résumé copies should count as
   **one** authority, not fifteen. Not yet implemented.
4. **Test target / CI (TST-001, CI-001)** — blocked on editing `project.pbxproj` with Xcode
   closed. Until then nothing is machine-verified in CI; statuses stay `IMPLEMENTED` /
   `UNIT_VERIFIED via snippet`, never `RELEASE_VERIFIED`.
5. **SEM-001 canonical `DocumentRole`** — the role inference is currently a reusable bridge;
   it should graduate to the real document-role model.
6. **Correction (not a bug):** the `"Subjects in scope: …"` line is an *intentional*
   retrieval footer (`EvidenceVerifier.swift:534–549`), rendered below a `---` separator "for
   the user's situational awareness" and explicitly excluded from scoring. Earlier notes
   called it a debug leak — that was wrong; it is by design. Whether to keep/restyle it is a
   product/UX decision (UX-003), not a defect to silently remove.

### Verification levels reached (per pack vocabulary)
- Governance/audit docs: **complete**.
- RET-001 / RET-003 / RET-009: **IMPLEMENTED + UNIT_VERIFIED (snippet, incl. real-data
  signals)** — not yet `REAL_DATA_VERIFIED` through the live app, not `RELEASE_VERIFIED`.

---

## Part E — Additional independent hardening (after the retrieval core)

These are self-contained improvements in *other* subsystems, each build- + snippet-verified,
tests written (run at TST-001):

- **RET-008 (duplicates ≠ corroboration)** — near-duplicate documents collapse to one
  authoritative representative (your ~15 résumé copies → 4 independent sources). `1f6f9ff`.
- **RET-006 (evidence sufficiency)** — the answer footer now honestly discloses which
  requested fields the evidence does NOT contain ("Not found: amount, payee") instead of a
  vague non-answer. Wired. `35569b6`,`e381cca`.
- **CLM-002 (causal-language guard)** — flags "X caused Y" when the evidence shows only
  sequence (adjacency ≠ causation). Wired into the footer. `c3247e2`.
- **CLM-001 (claim grounding)** — material specifics (amounts, dates, multi-word names) in a
  claim are checked against the cited evidence; a fabricated "₹5,000" or "Reliance
  Industries" not in evidence is flagged. High-precision. `50f061b`.
- **SEC-002 (logging privacy audit)** — user content/PII in logs (entity values, HTTP bodies,
  filenames/paths) moved `privacy:.public` → `.private`, so persisted/exported logs redact
  them (still visible live in Xcode for dev). `37e79e2`.
- **PAR-001 (parser capability manifest)** — the format-coverage matrix is now generated
  from the parser registry (can't drift); `SUPPORTED_SOURCES.md` written: 15 FULL, 6 PARTIAL
  (OCR), 10 DEFERRED (media), 12 PRESERVED-ONLY. `b78191c`.

Correction folded in: the `"Subjects in scope"` line is an intentional footer, not a debug
leak (see Part D item 6).

## One-line bottom line
The wrong-document problem was a **retrieval-authority** problem, not an ingestion or model
problem. It is now fixed in code by question-conditioned document fitness (role + field match)
that replaces mention density — and, crucially, the fix was corrected against your real data
so the low-mention-but-authoritative résumé wins. The remaining work is verification plumbing
(test target/CI), a re-ingest to de-fragment entities, and de-duplicating identical copies.
