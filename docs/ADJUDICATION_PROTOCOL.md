# Accuracy adjudication protocol (F5)

The release gate is **≤ 1 % wrong answers** on a fresh held-out set, judged by people, not only by the
automatic scorer. This protocol is how that number is produced. Agent-side preparation is done; the
adjudication itself is done by people.

## 1. Inputs

- **Regression set ho9.** 60 public prosecutions (US DOJ press releases), 2 paraphrases per question,
  generated after the fixes it measures. It is used for regression only; nothing is tuned on it.
- **Fresh held-out set ho10.** Generated only after the code and scorer are frozen (§4). Run once.
- Both answer paths, each with its own bench results: **rules** (AI off, the default) and **claude**
  (cloud composition, a public-data bench key).

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

## 4. The fresh held-out run (ho10) — once

1. Freeze the code and scorer: record the commit and the scorer's SHA-256 in the release packet. No
   change to the code, scorer or prompts after this point counts toward the gate.
2. Generate ho10 with a new seed, skipping every prosecution used in ho1–ho9 (see
   `~/CaseBench/chain-ho9.sh` for the generator; add ho9's keys to `--skip-keys`).
3. Run both paths once, build the pack, adjudicate per §3.
4. If the gate fails, fix, refreeze and generate **ho11**; ho10 becomes a regression set. A held-out
   set is never re-used to claim the gate.

## 5. Other answer families

The bench covers dated chronology questions over press releases. Before claiming ≤ 1 % for the app,
repeat §2–§4 for the other advertised answer families: amounts, names and roles, counts, and absence
("the documents don't say"). Use the existing generators (`scripts/casebench/enron.py`, `ntsb.py`,
`osha.py`).
