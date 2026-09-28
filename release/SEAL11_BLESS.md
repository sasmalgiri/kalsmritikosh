# Seal #11 — bless note

_Captured 2026-09-28 00:30 IST by `BaselineCaptureHarness` (`BASELINE_QUIESCE=1`, single clone) at
`v11-implement-all` @ **d2581f9a**, on a VACUUM copy of the owner's live ledger (426 documents).
Artifact: `kalsmritikosh-baseline-seal11-d2581f9a.json` in the app container's `tmp` (10,359 bytes,
7 questions, drain receipt included). It supersedes seal #10f (faebecf) as the parity anchor._

## The sealed answers

| # | Question | Sealed answer | Confidence | Time |
|---|---|---|---|---|
| 1 | what is the granted patent number | Patent No. 555489. | 0.80 | 8.0 s |
| 2 | what is the application number | Application No. 202331019665. | 0.80 | 8.1 s |
| 3 | on which date was the patent granted | Patent granted on 29 November 2024. (+ the 3 grant records) | 0.90 | 0.0 s |
| 4 | who is Shirshendu Sasmal | Shirshendu Sasmal <sasmalgiri@gmail.com> — 119 e-mails sent, 23 Jul 2007 – 14 Aug 2020 (+ subjects) | 0.85 | 0.0 s |
| 5 | how many hearings were there | 2 hearings: 14 August 2024, 6 August 2024. | 0.90 | 6.5 s |
| 6 | is there any invoice from Khurana and Khurana | Yes — 5 invoices from Khurana and Khurana on record (listed, cited) | 0.85 | 0.0 s |
| 7 | what is the capital of France | refused (out of scope) | 0.00 | 0.0 s |

## Why this is blessed

- **Every answer checked against the documents.** Patent 555489 / application 202331019665 are the
  certificate's numbers; the grant is recorded "in the Register of Patents on the 29/11/2024"; the two
  hearings are dated 06/08/2024 and 14/08/2024 in their notices; the five invoices are the firm's tax
  invoices in the archive.
- **Stable before sealing.** Parity against seal #10f was run 5× quiesced on the same code line (q2–q6):
  5/5 identical on all 7 questions, text and confidence (docs/PROJECT_COMPLETION_TODO.md P4.4).
- **Every difference from #10f is accounted for** — predicted classes (subject-first answers, happenings
  not notices, era re-derivation) or defects parity itself found and that were fixed before this capture
  (milestone dates one day early; application-number mislabel never re-fielded; "on which date" phrasing;
  invoice existence answering with a signature quote).
- **The ledger it was taken from holds the fixed point** (P4.2: FixedPointCheck HOLDS, 184 tables).
- Full suite: every suite reports, 0 genuine failures (P4.1); gold wall green across the four persona
  archives, status table byte-identical (P4.3); all CI guards clean; scoreboard + kalverify regenerate
  byte-identical (P4.6).

## Known limits carried into the seal (not hidden)

- Q4 lists the owner's own e-mail subjects under "What was discussed" (the owner is the correspondent);
  correct but not yet phrased as "you".
- Three of the five invoices carry only a year in their extracted date facts, so Q6 shows the year.
- The live ledger was refreshed to facts era 11 / events era 4 by the development test host (each test
  run launches the app, which boots the live ledger); only derived rows were rewritten.

Blessed by the agent under the "complete the list" instruction (2026-09-27); the owner's live check
(HOLD 2 / P5) remains the owner's.
