# Case bench — real cases through the real app (2026-10-18)

Owner request: check the app against real cases and investigations, at least one million, and
find the gaps per persona.

## What "a case" is here

Public **full investigation files** (every piece of evidence of one case) exist only in the
dozens — NIST CFReDS, Enron, CSB. Public **case records with an official outcome** exist in the
millions. The bench uses the second kind at scale and keeps the first for start-to-end runs
(`docs/INVESTIGATION_FOCUS_TODO.md` §4).

Each case becomes a folder of the documents the professional would hold, plus an answer key
taken from the publisher's own coded fields — never from the app.

| Source | Persona(s) | Documents per case | Answer key | Licence | Available |
|---|---|---|---|---|---|
| NTSB aviation investigations (data.ntsb.gov/avdata) | Investigator | report page 1, factual narrative, analysis, probable cause | date, place, registration, fatalities, probable cause | US Government work | ~170k |
| Caselaw Access Project decisions (static.case.law) | Lawyer; SIU, Forensic, Compliance, Genealogist by subject | the decision (caption, head matter, opinions) | decision date, court, parties, docket, author, disposition | released without restriction, Mar 2024 (CC0) | ~6.7M |
| OSHA accident investigations (data.dol.gov) | Compliance / EHS | investigation summary, injury record | event date, what happened, injured count, fatal | US Government work | ~150k |

CFPB complaints were planned for the Individual persona but the current bulk file no longer
carries consumer narratives (coded fields only), so it cannot test reading documents; dropped.

Target mix for ≥ 1,000,000 cases: NTSB all (~170k) + OSHA all (~150k) + court decisions
(~770k, spread over federal and regional reporters). Measured: NTSB yields 62,846 cases with
full narratives and a probable cause, so court decisions make up the rest.

## How it runs

- `scripts/casebench/{ntsb,cap,osha}.py` write shards of 500 cases with `truth.jsonl`. Every
  question records `in_docs`: whether its expected value is in that case's documents (then
  refusing is the correct answer).
- `KalsmritikoshTests/CaseBenchRunner.swift` (owner-run, env-gated, never in CI): one fresh,
  temporary ledger per shard; the real ingest → extraction → Ask path; the owner's archive is
  never opened. Records answers, citations, extracted dates and names as JSON lines.
- `scripts/casebench/run.sh` spreads shards over parallel test hosts; finished shards are
  skipped, so a stopped run resumes.
- `scripts/casebench/score.py` compares results with the answer keys.
- `scripts/casebench/full-run.sh ~/CaseBench 3 1000000` drives the whole run (NTSB → OSHA →
  court-decision batches), deleting each batch's documents once scored. It lives in
  `~/CaseBench`, not `/tmp`, because macOS clears `/tmp` files untouched for three days.
  Questions are asked on every 50th case (`ASK_EVERY=50`, ≈ 20,000 cases / 100,000 answers).
  Progress: `tail ~/CaseBench/full-run.log`; score so far:
  `python3 scripts/casebench/score.py ~/CaseBench/cases ~/CaseBench/results --report out.md`.

Two tiers, because of measured cost (§ Throughput):

- **Tier A — every case:** ingest + extraction checks (event date, case/docket/complaint
  number, registration, parties) + answers on every 10th case, in the evidence-only answer mode
  ("Fully private (no AI)"), switched on in memory for the test process only.
- **Tier B — sample:** full on-device-AI answers on a few thousand cases.

## Answer classes

| Class | Meaning |
|---|---|
| correct | expected value in the answer and a citation points at this case's document |
| honest refusal | refused, and the value really is not in the case's documents |
| uncited | value present but no citation to this case |
| missed | refused although the value is in the case's documents |
| unsupported | answered although the value is not in the documents |
| wrong | value absent, or the answer cites only other cases |

A not-in-archive control question runs per shard; answering it is a fabrication.

## Throughput (measured)

| Mode | Per answer | Per case | Note |
|---|---|---|---|
| AI answers, 20-case ledger | ~17 s | 78 s | Apple on-device model is the bottleneck |
| Evidence-only, 20-case ledger | 1.25 s median | 5.7 s | |
| Evidence-only, 250-case ledgers, 4 hosts | 9 s median | — | Neural Engine contention (cross-encoder re-rank) and a per-question embedder availability check |
| Ingest + extraction | — | ~0.15 s | |

## First findings (pilot, before the full run)

1. Case-number blindness: questions naming a case number are often answered from another
   case's documents.
2. Identifiers are not extracted: NTSB numbers, tail numbers and docket numbers almost never
   become ledger entities (≤ 5%).
3. No incident chronology from prose: "On January 1, 2008, about 1430 … collided" yields a date
   entity but no dated event (event-date extraction ≤ 5%).
4. Entity typing: aircraft makes typed as people ("person:Piper"), airports as people,
   regulations as organisations, truncated names ("Pilatus PC-").
5. Answer text: titles repeated as "The source says: Ntsbden08la049: probable cause …".
6. Answer cost grows with ledger size (1.25 s → 9 s).

The full report goes to `docs/verification/CASE_BENCH_REPORT.md`.
