# Accuracy adjudication protocol (F5; corrected 2026-10-31 for App Store completion §7)

The release gate is **≤ 1 % wrong answers per answer path (rules; claude) and per question family** on a
fresh held-out set run once on frozen code, judged by people, not only by the automatic scorer. This
protocol is how that number is produced. Agent-side preparation (sets, runs, blinded packs) is done by
the agent; the adjudication itself is done by people who are not the agent and not the owner alone.

**Corrections to the earlier text.** (1) ho10 is no longer the fresh set: ho10, ho11, ho12 and ho13 were
each run once and then informed fixes, so all of ho9–ho13 are **regression sets**; the next fresh draw is
**ho14**, generated only after the freeze (§4). (2) The gate is per path **and per family**, not one
pooled figure. (3) A run that errors (launch failure, a shard that did not finish, a document that
ingested as zero chunks without an error) is reported as an error and excluded from the denominator
with its count stated — never scored as correct, a refusal or 0 %. (4) The claude path has not been
measured since ho8; it must be measured on the frozen candidate from Terminal (the sandboxed test host
has no key) before any claude-mode figure is stated.

## 1. Inputs

- **Regression sets ho9–ho13.** 60 public prosecutions each (US DOJ press releases), 2 paraphrases per
  question. Used for regression only (`ProceedingAnswererTests.heldOut9`–`heldOut13` pin every miss);
  nothing measured on them counts toward the gate.
- **Fresh held-out set ho14.** Generated only after the code and scorer are frozen (§4), skipping every
  prosecution in `$CASEBENCH_HOME/skip-chron` (x1–x15). Run once per path.
- Both answer paths, each with its own bench results: **rules** (AI off, the default) and **claude**
  (cloud composition, a public-data bench key, Terminal run only).
- **Route validation.** Before scoring, the run record must show which route answered each question
  (rules vs model) — a model answer on a rules run, or the reverse, voids the run.

## 2. The pack

Build it with `scripts/casebench/adjudication_pack.py CASES RESULTS OUTDIR --label NAME`. It
writes two files:

| File | Who sees it | Contents |
|---|---|---|
| `NAME-sheet.csv` | Adjudicators | Item, question, the system's answer, its cited sources and quoted passages, empty verdict and notes columns |
| `NAME-key.csv` | The coordinator only | Item → case, question id, the scorer's automatic class and note, the expected answer |

The sheet holds every answer the scorer did not count correct or as an honest refusal, plus a seeded
random sample of 100 of the rest. They are shuffled together, so the sheet does not show which items
the scorer doubted.

Packs already built from the previous ho9 runs (`~/CaseBench/adjudication/`):

| Label | Items | Scorer-flagged | Sampled from the rest |
|---|---|---|---|
| ho9-claude-prev | 126 | 26 | 100 of 906 |
| ho9-rules-prev | 132 | 32 | 100 of 900 |

## 3. Adjudication

- Two adjudicators judge each item independently against the case's documents (the cited sources
  open from the paths given). Neither sees the key.
- Verdicts:
  - **correct** — the answer is right and supported by its cited passage;
  - **wrong** — it states something false, or something its sources do not support;
  - **partly correct** — right in part, with a material omission or error;
  - **should have refused** — the documents do not answer it, but the system answered;
  - **refusal was wrong** — the documents answer it, but the system refused.
- Disagreements go to a third adjudicator, whose verdict stands. Record agreement (Cohen's κ) before
  that resolution.
- An adjudicator's verdict replaces the scorer's on that item. A sampled item judged wrong means the
  scorer under-counts errors. Then estimate the error rate for the unsampled "correct" answers by
  their sampled rate, and report it with its confidence interval.

**Wrong rate** = (wrong + should have refused + partly correct with a material error) / answered
questions, per path, with a 95 % interval. Refusals are reported separately: refusing when unsure is
allowed; a wrong refusal is a recall loss, not a "wrong".

## 4. The fresh held-out run (ho14) — once

1. Freeze the code and scorer: record the commit and the scorer's SHA-256 in the release packet
   (`docs/RELEASE_CANDIDATE.md`). No change to the code, scorer or prompts after this point counts toward
   the gate.
2. Re-run ho9–ho13 as regression on the frozen commit first (bundled pack, rules path) and record them;
   a regression below the last recorded figure is a defect to explain, not a gate result.
3. Generate and run ho14 once with a new seed, skipping every prosecution used in ho1–ho13 (x1–x15 in
   `$CASEBENCH_HOME/skip-chron`): `scripts/casebench/heldout.sh ho14-chron --generate <seed>` from
   Terminal (both paths), or the bundled-pack path for rules only (FINAL_BRIEF_EXECUTION §E3). The
   driver records the commit, the scorer digest, the host and the command beside the results.
4. Build the blinded pack (the driver does), adjudicate per §3, **per path and per family**.
5. If the gate fails, fix, refreeze and generate **ho15**; ho14 becomes a regression set. A held-out
   set is never re-used to claim the gate.

## 5. Other answer families

The bench covers dated chronology questions over press releases. Before claiming ≤ 1 % for the app,
repeat §2–§4 for the other advertised answer families: amounts, names and roles, counts, and absence
("the documents don't say"). Use the existing generators (`scripts/casebench/enron.py`, `ntsb.py`,
`osha.py`).
