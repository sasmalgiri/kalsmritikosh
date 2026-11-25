# AI-50 — fair run 5 ("fair5"): scored results (2026-11-25)

**Fair agent-simulated AI reader — blind reader, clean run incl. 18 unseen real public cases (6 international); not a live AI run.**

Code: setup commit 7085ad31 (current code after G1–G5 + universality: G1 d02ff25b de-duplicated per-currency "Money by
party", G2 05ecfc26 per-document day/month order in discrepancies, G3 21177dbd masked accounts, G4 a7ba3583 digit in a
name, G5 ae055c39 rounding at the stated precision, universality c6cd2f13 + adda9c3e). One fresh exchange folder for both
suites (build/agent-eval-fair5/, git-ignored): **598 requests, all replied by a blind reader** that opened only the
requests (READER_INSTRUCTIONS.md). Every request of every case was new for this reader. Scored run: Xcode RunSomeTests
2026-11-25 17:52, `AgentReaderEvalTests/run()` + `AgentReaderHardEvalTests/run()` in one call, both passed; console log
test-console-log-2026-11-25T17-52-08+05-30.txt (754,445 lines); 0 pending; 0 MISFILED / 0 LEAK / 0 UNPARSEABLE in all 33
cases. **No reply was written, edited or re-filed by the scorer and no product code was changed.** Keys stayed in /tmp
(hard-, real-, real3-, real4-, intl5-keys.json; never committed). The scorer judged the FINAL SHOWN answer
(run/<case>/qN/final.txt: conclusion, checked statements, the app's arithmetic, "Also worth checking", NOTES).

Cases (33, 213 questions): hard (5 fictional, 40 q), earlier real (10, 34 q), real3 (6, 46 q), real4 (6, 46 q) as in
FAIR4, plus **NEW intl5** (6 international public cases never seen by the reader or the harness, 47 questions;
KalsmritikoshTests/Fixtures/AgentEvalIntl5, sources in INTL5_SOURCES.md): intl5-barclays (UK Insolvency Service, 3
releases, £), intl5-cook (UK SFO, 2 releases, £), intl5-ethical (UK SFO, 2 releases + case page, £), intl5-eurocartel (EC,
2 decisions, €), intl5-berndale (ASIC, 5 media releases, A$), intl5-siddiqui (ASIC, 3 media releases, A$).

Scoring is FAIR4's, unchanged: **correct** = the must facts that answer what the question asks are in the shown text
(incl. the app's arithmetic lines) and nothing on the wrong list; **partly**; **confident-wrong**; **honest not-stated**
counts as correct; **refused-when-answer-existed**. (W) = the AI's conclusion withheld by the app. Strict side score: every
element of every key "must".

## 1. Totals

| | all (213) | hard (40) | earlier real (34) | real3 (46) | real4 (46) | **NEW intl5 (47)** |
|---|---|---|---|---|---|---|
| correct | **202 = 94.8 %** | 37 = 92.5 % | 34 = 100 % | 46 = 100 % | 44 = 95.7 % | **41 = 87.2 %** |
| partly | 6 | 3 | 0 | 0 | 1 | 2 |
| confident-wrong | **0** (see sensitivity) | 0 | 0 | 0 | 0 | 0 |
| honest not-stated (key: not established) | 27 / 27 | 7 / 7 | 2 / 2 | 6 / 6 | 6 / 6 | 6 / 6 |
| refused when an answer existed | **5** | 0 | 0 | 0 | 1 | 4 |
| **strict, every key element** | **193 = 90.6 %** | 32 = 80.0 % | 34 = 100 % | 46 = 100 % | 41 = 89.1 % | 40 = 85.1 % |

- **All 11 misses but 4 are one app defect (D1, §5):** the reader's true, exactly quoted claims were dropped because a
  claim said "Document 1" / "Document 3" or named an ASIC release ("26-088MR") — read as the numbers 1, 3, 26. All 6
  intl5 misses and mayfield q4 are this. With D1 fixed: **209 / 213 = 98.1 %** (intl5 47 / 47).
- Same 166 questions as FAIR4: **161 / 166 = 97.0 %** (FAIR4 scored 160; FAIR4 same replies after G1–G5 162).
- Sensitivity: real4-4x q3 says the misappropriated amounts ("approximately $2.8 million" vs $2,745,226) differ "by more
  than rounding" — the app's compare tool told it so (§3). Counted partly; as confident-wrong it is 0.5 per 100.
- Strict-only misses (correct by the standard reading): kiln q1 (30 July $900,000 not in the sequence), harbor q5,
  meridian q5, vantage q6 (all three name both spellings and the shared address but say "no document states they are the
  same person"), meridian q3 (W; the two dates are shown, "conflict" only in the withheld conclusion), autoland q5 (ACRA
  poll), stoddard q2 (closing dates), leondi q6 (22 Oct 2018 plea date), berndale q7 (W; Abraham / Abrahams shown, "same
  judge" only in the withheld conclusion).

### Per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C | C | **P (W)** | C | C (s) | C | C | C (NS) |
| meridian | C | C | C (W, s) | C | C (s) | C (W) | C (NS) | C (NS) |
| solace | C | C | C | C | **P** | C | C (NS) | C (W) |
| vantage | **P** | C | C | C | C | C (s) | C | C (NS) |
| kiln | C (s) | C | C | C | C | C | C (NS) | C (NS) |
| 10 earlier real | all 34 C (inv104 q2 W; inv104 q4, q5 NS) | | | | | | | |
| real3 (6 cases) | all 46 C (k2 q6 W; 6 NS) | | | | | | | |
| real4-newark / leondi / stoddard / autoland | all C (leondi q6, stoddard q2, autoland q5 s; 4 NS); **autoland q6 now C** | | | | | | | |
| real4-mayfield | C (W) | C | C | **R** | C | C | C | C (NS) |
| real4-4x | C | C | **P** | C | C | C (NS) | | |
| **intl5-barclays** | C | C | C | **R** | **R** | C | C | C (NS) |
| **intl5-berndale** | **R** | **R** | C | C | C | C | C (W, s) | C (NS) |
| **intl5-cook** | **P (W)** | C | C | C | C | C | C (NS) | |
| **intl5-ethical** | C | C | C | C | C (W) | C | C | C (NS) |
| **intl5-eurocartel** | C | C | C | C | C | C | C | C (NS) |
| **intl5-siddiqui** | C | C | C | C | C | C | **P (W)** | C (NS) |

(s) = strict miss; R = refused when the answer existed; NS = not established, answered honestly. Against FAIR4 on the
166 repeated questions: now right — solace q1 (G3), 4x q6 (G4), autoland q6 (G5); newly missed — solace q5 (reader),
mayfield q4 (D1); unchanged — vantage q1, harbor q3, 4x q3.

## 2. Per trap type

Hard set:

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | 8 | solace q1 now right (G3); solace q8 right via the app's arithmetic (W); **vantage q1 P** |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh, Chen |
| date / claim-vs-record | 6 | 5 | **harbor q3 P** (posting-date reading, 5th run) |
| two name spellings | 5 | 4 | **solace q5 P** (false "No" tick omitted); 3 others hedge on identity (strict) |
| "2.4 million" vs "2,400,000" | 5 | 5 | meridian q6 via the compare line (W) |
| not established | 7 | 7 | |
| other | 3 | 3 | |

Real sets:

| trap | real3 | real4 | **intl5** | notes |
|---|---|---|---|---|
| not established | 6 / 6 | 6 / 6 | **6 / 6** | 4x q6 now right (G4) |
| release vs release, real difference | 2 / 2 | 4 / 4 | **1 / 4** | barclays q4, berndale q2 refused, siddiqui q7 P — all D1; berndale q3 (16 Sep 2024 vs 15 May 2025) right |
| wording / rounding, not a conflict | 2 / 2 | 1 / 2 | **2 / 4** | autoland q6 now right; 4x q3 P (§3); ethical q7, eurocartel q3 (€485,456,000 vs "€485 million") right; cook q1 P (W), berndale q1 refused — D1 |
| scheduled vs actual date | 3 / 3 | 2 / 2 | **4 / 4** | ethical (May → 3 Sep 2026), berndale (2 → 23 July 2026), cook, siddiqui |
| money trace / flow | — | 4 / 4 | **4 / 4** | barclays £13.9m in / £11.7m out (sum tool: £10,620,000 itemised), cook, ethical, siddiqui |
| arithmetic / reconcile | 4 / 4 | 5 / 5 | **5 / 5** | barclays 13 + 10 + 7.5 + 7.5 = 38 years; ethical 15 y 9 m; eurocartel €1,310,039,000 and €1,494,302,000 (space-grouped "465 861 000"); cook £123,000 ≠ £70,000+ |
| one name, two spellings / former names | 1 / 1 | 3 / 4 | **2 / 3** | mayfield Matthew/Matthews refused (D1); barclays former names refused (D1); Abraham/Abrahams, JPMorgan/JPMorgan Chase right |
| inconsistency inside one document | 1 / 1 | 2 / 2 | — | |
| witness / account vs record | 3 / 3 | 1 / 1 | — | |
| unnamed identity (inference only) | — | 1 / 1 | — | leondi q4 |
| other facts | 24 / 24 | 15 / 15 | **17 / 17** | |

## 3. Did G1, G2, G5 fix their targets? (fresh blind replies — this is the measurement FAIR4 §8 could not make)

| item | FAIR4 | fair5 | fixed? | why |
|---|---|---|---|---|
| **G1** vantage q1 (each party kept €50,000) | P | **P** | **no** | G1's table now has Ardmore "kept 600,000 − 550,000 = 50,000" (right) but Tidewell "kept 550,000 − 1,000,000 = −450,000": the client-account statement credit and the ledger receipt of the same €500,000 have two payee names ("Hanley & Moore client account" / "VQ-ESCROW client account") and are not merged. The reader wrote "Ardmore … kept a 51000.00 balance" and Tidewell "held € 52.500,00" — balances, not kept amounts. |
| G1 elsewhere | wrong in every hard case | **right in kiln and for Ardmore; still double in harbor, meridian, solace** | partly | the fresh picture records one statement line twice (payer's and payee's view) citing the SAME document; G1 merges only across documents (D3). Readers saw it: harbor q1/q2 and solace q1 say "the app's party totals count each wire twice"; solace q8's conclusion quoted the app's 100,000 and was withheld (the sum line 1,500,000 − 1,450,000 = 50,000 is shown). |
| **G2** harbor q3 (ledger 4 Mar vs paid 13 Mar, before the 10 Mar instalment) | P | **P (W)** | **no** | G2 removed the false flags (2 discrepancies in 33 cases, both genuine: harbor BMC-0311, berndale Kirby 10 vs 15 July 2025; FAIR4: 6 with 5 false). But the harbor line's decisive part is cut by the briefing's line cap ("2026-03-04 is 6 days befo…"), the reader again read the GL date as a posting date, and its conclusion ("9 days before the wire", from compare_dates) was withheld because compare_dates results are not in the app's arithmetic (D2). |
| **G5** autoland q6 (167 vs "about 170" knots) | P | **C** | **yes** | "the speeds differing only by rounding". |
| **G5** 4x q3 ("approx. $2 million / $2.8 million" vs $1,985,754 / $2,745,226) | P | **P** | **no — by design** | the compare tool says "approximately $2.8 million" is stated to the nearest 100,000 (2,750,000–2,850,000), so $2,745,226 is outside; the reader followed it: losses agree within rounding, misappropriation "does not". True at the stated precision; the key wants "consistent (allegation vs court finding)". A key / G5-rule decision, not a reader error. |

## 4. Universality evidence from intl5 (GBP, EUR, AUD, day-first dates, name variants)

- **GBP:** £ figures with scale words summed and compared exactly (barclays £1.675m + £7.4m + £1.545m = £10,620,000
  itemised of "more than £11.7 million"; cook £123,000 confiscation ≠ "more than £70,000"); durations added (38 years,
  15 years 9 months). "over £44,000" vs "£44,000" understood by the reader — lost to D1, not to the amount reader.
- **EUR:** space-grouped thousands ("465 861 000") and "€ 1 494 302 000" summed exactly; "€485 million" vs 485,456,000
  called rounding; yen fines kept out of the euro total; SG's later amendment flagged as unstated.
- **AUD:** "$1000" and "$1,000" recognisance treated as the same term; $681,496.98 matched exactly.
- **Day-first dates:** "16 January 2026", "28 Mar 2025", "2-3 September 2026", "10 July 2025" vs "15 July 2025" all
  verified against quotes; 0 date misreads in intl5. (The hard set's money table still shows "2026-08-06 or
  2026-06-08" where a document's order is unknown.)
- **Name variants:** Abraham / Abrahams surfaced, JPMorgan / JPMorgan Chase joined, Oldcoft = FT (OPS) Limited found by
  the reader. **Where universality broke:** non-US document labels — ASIC media-release numbers ("26-088MR",
  "25-135MR") and the reader's "Document N" references — read as figures (D1). 4 of 6 intl5 misses are ASIC/Insolvency
  releases with several numbered documents.

## 5. Conclusions, drops, calls, tokens

- **Conclusions: 193 replies carried one (20 "documents don't say"); 177 shown = 91.7 %, 11 withheld, 5 answers lost
  entirely** (all their claims dropped — D1). FAIR4: 153 / 155. Withheld because of: "Document N" / release numbers /
  another document's year (cook q1, siddiqui q7, mayfield q1, k2 q6, berndale q7), compare_dates day counts (harbor q3,
  meridian q3, meridian q6), the app's own wrong money-table figure (solace q8), a case-wide figure not in that answer's
  quotes (ethical q5 "£70 million"), a case number read as a date (inv104 q2 "2025-17").
- **Verifier drops: 42 question-reply claims, 83 second-look claims** (of 1,015 + 812 kept). **33 of the 42 question
  drops are D1** (the number 1, 2, 3, 24, 25, 26 or 2023 "not in the quote"). The rest: a date or value from another
  sentence, `about` not in the passage (harbor q7 "Deepline Dredging Inc.", ethical ×2), quote not verbatim. Look drops
  are mostly "the date / amount not in the quote" for inferences across two records (no must lost).
- **Relevance warnings: 3** (solace q8, siddiqui q7, inv104 q2 — all where the conclusion was withheld). **0 "Stopped
  early".** 1 distinct question prefix per case.
- **AI calls per question: 443 question sends / 213 = 2.08** (255 question + 188 second look). Plus 122 picture steps
  and 33 background suggestion reads: 122 + 255 + 188 + 33 = 598.
- **Estimated input tokens (sum of the sends' estimates, before prompt caching): 5.21 M for the run, 158 k per case** —
  hard 183–212 k (avg 199 k), earlier real 28–167 k (avg 70 k), real3 113–296 k (avg 194 k), real4 93–386 k (avg 226 k;
  newark 386 k), **intl5 77–227 k (avg 167 k)**: eurocartel 227 k, berndale 207 k, barclays 198 k, ethical 159 k,
  siddiqui 134 k, cook 77 k.

## 6. Misses diagnosed

App defects (code; none changed in this run; the per-miss list is in /tmp/fair5-misses.md):
1. **D1 — document labels and release numbers read as figures.** `VerifiedAnswerComposer.check` (l.298–345:
   `strippingIdentifiers` → `valueSupport`/`valueMissing`) and `conclusionWithheld` (l.1119). Cost: barclays q4, q5,
   berndale q1, q2, mayfield q4 refused; cook q1, siddiqui q7 partly; 3 more conclusions withheld. **Fix:** strip the
   request's own labels ("Document N", "[DN]", "passage N", N ≤ documents sent) before the value check; read a release /
   docket token (`\d{2}-\d{3}[A-Z]{1,3}`, "LR-22720", "IP/13/1208") as one identifier allowed when any sent document's
   file name or header holds it; let a claim name the own year of any sent document ("the 2023 release"). Keep the
   negatives: a wrong amount or date in a claim that also says "Document 2" is still rejected.
2. **D2 — compare_dates results are not in the app's arithmetic.** `CaseAgent` tool dispatch (CaseAgent.swift l.892):
   unlike `compare` (l.896) and `sum` (l.1051) its text is not appended to `arithmeticLines`, so "9 days", "35 days",
   "18 days" withhold conclusions (harbor q3, meridian q3, q6, siddiqui q7). **Fix:** append it the same way.
3. **D3 — G1 merges duplicates only across documents.** `CaseAIUnderstanding.partyFlows` l.318–321
   (`$0.record.document != e.record.document`): one statement line recorded from both sides in one document is counted
   twice (harbor, meridian, solace); a ledger's matter name is not joined to the account it books (vantage Tidewell).
   **Fix:** within a document merge records with the same amount, day, payer and payee that cite the same quoted line;
   join a ledger account name to its account by tail / also-written-as / reference; if still unjoined, say so rather than
   compute "kept".
4. **D5 — a case number "2025-17" read as a date** (`VerifiedAnswerComposer.values(in:)`): YYYY-NN with NN > 12 is an
   identifier. No score cost.
5. **D6 — the discrepancy line is cut before its decisive comparison** (`CaseLedgerBriefing`, harbor "6 days befo…"):
   never truncate the nearest-money comparison.

Reader errors: solace q5 (false "No" tick omitted though the briefing's Conflicts lists it); vantage q1 (balances named
as kept, with D3 behind Tidewell); harbor q3 (posting-date reading — also a key issue).

Key / design: 4x q3 (G5's precision rule vs the key's "approximately" tolerance); harbor q3 (the key requires a GL
"Posting date" to be called a conflict; fifth run answered this way).

Design gaps carried: the conclusion check does not accept case-wide figures outside the answer's own quotes (ethical
q5, by contract); a hedge on identity ("no document says they are the same person") is honest but misses the strict key
in 3 hard spelling questions.

## 7. Verdict

| bar | result |
|---|---|
| owner's goal 99 % | **not met** — 94.8 % (202 / 213); **98.1 % with D1 fixed** (the reader answered all 7 D1 questions right) |
| ≥ 90 % correct | **met overall** — 94.8 %; hard 92.5 %, earlier real 100 %, real3 100 %, real4 95.7 %; **NEW intl5 87.2 % — below 90 %** (all 6 misses D1); strict 90.6 % |
| ≤ 1 confident-wrong per 100 | **met** — 0 / 213 (0.5 / 100 if 4x q3 is counted) |
| key multi-document question right | **mostly** — round trips 8 / 9, corrected witnesses 5 / 5, spellings 4 / 5, "2.4 million" 5 / 5, date conflicts 5 / 6, not-established 27 / 27 |

**Bar met overall on the headline numbers (agent-simulated reader, not a live AI run), 0 confident-wrong, every
not-established question answered honestly — but the six unseen international cases score 87.2 %, below the 90 % bar,
and the owner's 99 % is not reached.** The cause is one app defect (D1) that dropped the reader's true, exactly quoted
claims whenever a claim named "Document N" or an ASIC release number; 7 of 11 misses. G3, G4 and G5 (autoland) are
confirmed fixed by fresh blind replies; G2 removed the false discrepancies but not harbor q3; G1 is right across
documents but still double-counts within one document (D3).

## 8. Next

Fix D1 (labels / release numbers / other documents' years), D2 (compare_dates into the arithmetic), D3 (same-document
duplicates and ledger account names in G1), D5, D6; re-run with the same fair5 replies to confirm the 7 D1 answers are
shown, then a fresh blind round (k = 3 readers per case) and a live AI run when the bench key has credit. Evidence
(local, git-ignored): build/agent-eval-fair5/run/ (final.txt per question, picture-records.txt, picture-steps.txt,
summaries), build/agent-eval-fair5/requests/ (598 requests + replies), console log above.
