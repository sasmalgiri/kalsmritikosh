# AI-50 — fair run 3 ("fair3"): scored results (2026-11-25)

**Fair agent-simulated AI reader — blind reader, clean run incl. 6 unseen real public cases; not a live AI run.**

Code: HEAD 66fd4ef3 (setup commit; current code after the AI-agent split, the ALCOA++ program ALC-01…22 and the
2-digit-year fix 5c49739e). One fresh exchange folder for both suites (build/agent-eval-fair3/, git-ignored): **320
requests, all replied by a blind reader** that opened only the requests (no keys, fixtures, sources or web). Scored run:
Xcode RunSomeTests 2026-11-25 00:09, `AgentReaderEvalTests/run()` + `AgentReaderHardEvalTests/run()` in one call, both
passed; console log test-console-log-2026-11-25T00-09-02+05-30.txt; 0 pending, filing checks 0 MISFILED / 0 LEAK /
0 UNPARSEABLE in all 21 cases. **No reply was written, edited or re-filed and no product code was changed.** Keys stayed
in /tmp (hard-keys.json, real-keys.json, real3-keys.json; never committed). The scorer judged the FINAL SHOWN answer
(run/<case>/qN/final.txt, with its NOTES block: conclusion shown/withheld and why, relevance warning, stopped early,
verifier drops).

Request stability: the 320 requests of the scored run were compared with the texts the reader answered (last dump per
request in the 2026-11-24 reply-round logs). All 128 question and 109 second-look requests are identical (record ids
aside); 28 picture requests differ only cosmetically — 13 in line order, 15 in a rejection reason naming a different
missing value of the same rejected record or an honorific ("Shamos" / "Mr. Shamos"). So every reply met the request it
was written for (see §8 item 4).

Cases (21, 120 questions):
- **hard** (5 fictional multi-document cases, 13–15 documents, 8 questions each = 40): harbor, meridian, solace,
  vantage, kiln.
- **earlier real** (10 cases, 34 questions): forensic, individual, compliance, investigator, journalist, researcher, siu,
  lawyer, genealogist (public) + inv104 (acceptance fixture).
- **NEW real** (6 public cases the reader and this harness had never seen, 46 questions; KalsmritikoshTests/Fixtures/
  AgentEvalReal3, sources in REAL3_SOURCES.md): real3-jha (DOJ, NSF grant fraud, 2 releases), real3-archcoal (DOJ, Arch
  Coal kickbacks, 11 releases), real3-carpenter (DOJ, movie-studio fraud, 3 releases), real3-k2 (SEC, K2 / 211 Ventures,
  4 releases), real3-valenti (2d Cir. 1995 opinion), real3-jfk (NTSB runway incursion, 4 documents).

Scoring (as FAIR2 / HARD.md): **correct** = the must facts that answer what the question asks are in the shown text and
nothing on the wrong list; **partly** = a part of the question unanswered, a trap element missing, or the conclusion
mis-framed; **confident-wrong** = a confident claim on the wrong list; **honest not-stated** = key says not established
and the app says so (counted correct); **refused-when-answer-existed**. "(W)" = the AI's own conclusion was withheld by
the app. NS = honest not-stated.

## 1. Totals

| | all (120) | hard (40) | earlier real (34) | **NEW real (46)** |
|---|---|---|---|---|
| correct | **112 = 93.3 %** | **36 = 90.0 %** | **34 = 100 %** | **42 = 91.3 %** |
| correct with the AI's conclusion shown (or an honest "documents don't say") | 110 = 91.7 % | 34 = 85.0 % | 34 = 100 % | 42 = 91.3 % |
| partly | 8 | 4 | 0 | 4 |
| confident-wrong | **0** | 0 | 0 | 0 |
| honest not-stated (key: not established) | 15 / 15 | 7 / 7 | 2 / 2 | 6 / 6 |
| refused when an answer existed | 0 | 0 | 0 | 0 |

Sensitivity (NEW real only, literal reading of every "must" element): 6 more answers miss a sub-detail the question did
not ask for or that is context — jha q4 (the $100,000 of DoD stipends authorised), valenti q6 (the 13 June 1992 meeting
lie), jfk q1 (aircraft types), jfk q7 (LC2 wore corrective lenses), k2 q4 (consent judgment date), carpenter q1
(indictment date). Literal: NEW real 36/46 = 78.3 %, all 106/120 = 88.3 % (the literal reading was not applied to the
hard and earlier real sets, which were scored as in FAIR2).

### Per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C | C | **P** | C | C | C | C | C (NS) |
| meridian | C | C | C | C | C | C | C (NS) | C (NS) |
| solace | C | C | C | C | **P** | C | C (NS) | C |
| vantage | **P** | C (W) | C | C | C (W) | C | C | C (NS) |
| kiln | **P (W)** | C | C | C | C | C | C (NS) | C (NS) |
| forensic | C | C | C | | | | | |
| individual | C | C | C | C | | | | |
| compliance | C | C | C | C | | | | |
| investigator | C | C | C | | | | | |
| journalist | C | C | C | | | | | |
| researcher | C | C | C | | | | | |
| siu | C | C | C | | | | | |
| lawyer | C | C | C | | | | | |
| genealogist | C | C | C | | | | | |
| inv104 | C | C | C | C (NS) | C (NS) | | | |
| **real3-jha** | C | C | C | C | C | C | C (NS) | |
| **real3-archcoal** | C | C | C | C | C | C | C | C (NS) |
| **real3-carpenter** | C | **P (W)** | C | **P (W)** | C | C | C (NS) | |
| **real3-k2** | C | C | C | C | **P (W)** | C | C | C (NS) |
| **real3-valenti** | C | C | **P (W)** | C | C | C | C | C (NS) |
| **real3-jfk** | C | C | C | C | C | C | C | C (NS) |

Changes against FAIR2 on the 74 repeated questions (new reader, same keys): lawyer q1, kiln q1-conclusion, genealogist
q3, inv104 q1/q2 conclusions now shown and right; individual q4 now names the runway 25 difference (C). New misses:
vantage q1, kiln q1. Unchanged reader misses: harbor q3, solace q5.

The eight partly answers:
- **harbor q3** (payment date): 13 March from both bank statements; the ledger's 4 March posting shown but framed as
  "posts … earlier", not a conflict; the 10 March first-instalment point missing. Reader framing (third run in a row).
- **solace q5** (Iyer = Ayyar): all spellings and the brother-in-law "Rajesh Ayyar" shown; the false "no relative deals
  with the hospital" tick omitted, and the link hedged ("the documents do not confirm they are the same person").
  Reader omission (third run in a row).
- **vantage q1** (trace €600,000): the round trip is complete (Ardmore → Tidewell €550,000 → €500,000 back as a
  "purchaser's top-up"), but neither "Ardmore kept €50,000" nor "Tidewell kept €50,000" is stated (the 51,000.00 and
  € 52.500,00 balances appear only inside quoted lines). Reader omission.
- **kiln q1** (trace Kerr ↔ Pemberton ↔ Kiln): both legs on Kerr's own statement (8 Jul $350,000 loan out, 6 Aug
  $280,000 back) were dropped — the reader tagged them `about: "Bradley Kerr"` and the statement says `BRADLEY J KERR`;
  with them went the conclusion (its dates were in no kept quote) and the $70,000 Pemberton kept. Shown: the Kiln legs
  and the $900,000 interim payment. Contract-consistent drop; over-strict (§8 item 2).
- **carpenter q2** (loss, restitution): "The 2014 release says … lost over $5 million" and "The 2018 releases say they
  lost millions" dropped because "2014"/"2018" — the year of the cited release — is not in the quote; conclusion
  withheld; only $3,642,755 restitution shown. Contract-consistent; over-strict (§8 item 1).
- **carpenter q4** (FBI statements, do releases agree): the three false statements, incl. the Hollywood producers, shown;
  "The 2018 release lists only the personal-expenses and 50 to 75 percent statements" dropped for "2018"; conclusion
  withheld — the "do they describe it the same way" half is lost. Same cause.
- **k2 q5** (Glatfelter disgorgement): the claim "… deemed satisfied by the restitution order of December 18, 2014" put
  $340,369.77 (from another sentence) into a claim whose quote lacks it; dropped, conclusion withheld; "deemed satisfied"
  and the consent judgment are not shown. Reader under-quoting.
- **valenti q3** (why $122,466): the explanation claim ($59,000 of earlier wire transfers + $63,466) carried $122,466,
  which is in the previous sentence, not its quote; dropped, conclusion withheld; shown only "The loss totalled
  $122,-466." Reader under-quoting.

In all four (W) partly answers the second look was handed the reduced answer, said `addresses_question: "yes"` and
"nothing to add" — a second reader error in each (valenti q3's "Answer given" was just "The loss totalled $122,-466.").

## 2. Per trap type

Hard set (same classes as FAIR2):

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | **7** | harbor q1 q2, meridian q1 q2, solace q1 q8 right with what stayed; vantage q2 C (W) (net €100,000 shown by the app's arithmetic); **vantage q1, kiln q1 partly** |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh (conclusion withheld for "VQ-REL-01", every statement shown), Chen |
| date / claim-vs-record inconsistency | 6 | 5 | meridian q3, solace q3, vantage q3 q4, kiln q3 right; harbor q3 partly |
| two name spellings | 5 | 4 | harbor q5, meridian q5, vantage q6, kiln q5 right; solace q5 partly |
| "2.4 million" vs "2,400,000" | 5 | 5 | no invented conflict |
| not established | 7 | 7 | none named the obvious suspect |
| other (instalment, overcharge, title) | 3 | 3 | harbor q7, solace q2, kiln q2 |

NEW real cases:

| trap | questions | correct | notes |
|---|---|---|---|
| not established (unnamed professor / producers, no Runyon sentence, no investor count, no repayment, no discipline) | 6 | **6** | all "documents don't say"; none invented a name or number |
| scheduled vs actual sentencing date | 3 | 3 | jha q6 (11 Jul → 29 Aug 2014), archcoal q7 (15 Oct → 9 Oct 2014), carpenter q5 |
| release vs release ("do they agree", rounding vs conflict) | 4 | **2** | archcoal q6 ($35,170.60 vs "more than $35,000" = agree), k2 q2 ("at least" / "more than" $1.8 m) right; carpenter q2, q4 partly (year-of-release drops) |
| arithmetic / reconcile figures | 4 | 3 | k2 q4 (parts add to $525,896.51), k2 q3 (> $2.3 m), archcoal q3 right; valenti q3 partly |
| witness disagreement / claim vs record | 3 | 3 | valenti q4 ($24,000 not a loan), valenti q5 (three witnesses vs Shamos), jfk q4 (LC1 vs LC2) |
| one person, two name forms | 1 | 1 | k2 q6 (Robert C. Rice / Robert S. Anderson; one claim dropped for "2014", conclusion shown) |
| inconsistency inside one report | 1 | 1 | jfk q7 ("The LC2 controller was certified…" in the LC1 paragraph) |
| other facts (who / what / how much / how) | 24 | 23 | k2 q5 partly |

Earlier real: single-document press releases 19/19, the NTSB report (individual) 4/4, court opinions 6/6, inv104 5/5 (paid twice → no, amendment withdraws finding 2;
gross 100,000 / returned 50,000 / net 50,000; approver and namesake not established).

## 3. Conclusions shown vs withheld

109 replies carried a conclusion (11 were "documents don't say"); **102 shown = 93.6 %, 7 withheld** (FAIR2 re-score:
68 / 71). All 7 withheld conclusions were themselves correct, and every withholding follows the contract — the value
named was in no kept quote and not in the app's arithmetic; **0 withheld by a mechanical misreading** (FAIR2: 4).

| question | reason given | root cause |
|---|---|---|
| carpenter q2 | "the amount" ($5 million) | only in the two claims dropped for the release year (§8 item 1) |
| carpenter q4 | "the number 2018" | same |
| kiln q1 | "the date" | the dates were in the two claims dropped for `about: "Bradley Kerr"` (§8 item 2) |
| k2 q5 | "the date" (December 18, 2014) | only in the claim the reader packed with another sentence's amount |
| valenti q3 | "the amount" ($59,000) | same pattern |
| vantage q2 | "the date" (31/10/2026) | same pattern; the answer (€100,000) still shown by the app's arithmetic |
| vantage q5 | "the number 1" | the conclusion names instruction "VQ-REL-01", which no kept quote carries; every statement shown |

The 2-digit-year regression of the FAIR2 re-score (harbor q1 "13 Mar, 95,000", meridian q1 "30 Apr, 40,000") is gone:
both conclusions are shown.

## 4. Verifier drops, relevance, second look, stops

- **17 question-reply claims dropped, all 17 true; 0 app misreads** (FAIR2: 2 app defects). By class:
  - claim names the year of its own cited release ("The 2014 release says…", "in the 2014 judgment"): 4 — carpenter q2
    ×2, q4, k2 q6. Cost: carpenter q2, q4 must facts. Over-strict, contract-consistent (§8 item 1).
  - `about` names the person in a fuller form than the passage ("Bradley Kerr" vs "BRADLEY J KERR"): 2 — kiln q1. Cost:
    kiln q1. Over-strict, contract-consistent (§8 item 2).
  - claim carries a value its quote does not (reader under-quoting or packing two lines into one claim): 11 — harbor q3
    ×2 (email date from the header; BMC-0311 with the invoice-date line), harbor q5 (Apt 3 with the signatory line),
    meridian q2 (310,000), vantage q1 (VQ-REL-01 with the statement line), vantage q2 (600,000), inv104 q1 ×2 (FR-12,
    INV-104), inv104 q5 (8804), k2 q5, valenti q3. Cost: k2 q5, valenti q3; the rest lost no must fact.
- **Relevance:** 128/128 question replies restated their question verbatim (`answers_question`); second look
  `addresses_question` = yes in 109/109; **0 relevance warnings**; 0 "Stopped early".
- **Second look:** "nothing to add" in 109/109 (FAIR2 re-score: added lines in 7/74). It rescued none of the four (W)
  partly answers (§1).

## 5. Case picture, calls, prefixes, tokens

- Picture: 22–71 records per case (hard 36–44, FAIR2 61–73; real 22–39; NEW real 30–71, archcoal 71), all origin
  "picture", 0 records added by questions, **0 records without a run id**. Picture steps: 5 jfk, 4 vantage and valenti,
  2 for the 1-document press releases, 3 elsewhere.
- Picture usefulness (strict heuristic as FAIR2: every proper name and ≥ 3-digit number of the key's "must" text present
  in picture-records.txt): hard **18 / 33**, NEW real **26 / 40** (answerable questions). The heuristic is noisy (it also
  counts numbers the question must compute, e.g. 120,000 / 210,000 nets, and joined name tokens). Real misses: what each
  account kept / closing balances (harbor q1, meridian q1, vantage q1, kiln q1 — the questions then read the statements;
  vantage q1 and kiln q1 are the two round-trip misses), second spellings (solace q5 "Ayyar", vantage q6 "Niamh
  Sullivan"), addresses (Lakeview Residency, Dandenong), docket and judge lines (k2 11cv11649, valenti No. 1510), the
  $525,896.51 total (k2 q4). The pictures were smaller than in FAIR2 for the same hard cases (36–44 vs 61–73 records).
- **AI calls per question: 237 sends / 120 = 1.98** (question + second look; +1 sum-tool round in 8 questions — harbor
  q1 q2, meridian q2, solace q2 q8, vantage q2, k2 q4, inv104 q2; 1 send for the 11 "documents don't say"). Plus 62
  picture steps and 21 background suggestion reads (AI-37): 62 + 128 + 109 + 21 = 320 requests.
- **Distinct question prefixes: 1 per case in all 21 cases.**
- Estimated input tokens (CaseReader.estimatedTokens, before prompt caching):

| case | picture | questions | total |
|---|---|---|---|
| harbor | 19,907 | 123,721 | 143,628 |
| meridian | 18,353 | 107,182 | 125,535 |
| solace | 19,323 | 119,360 | 138,683 |
| vantage | 26,036 | 109,519 | 135,555 |
| kiln | 20,323 | 103,622 | 123,945 |
| forensic | 5,864 | 20,935 | 26,799 |
| individual | 13,723 | 36,681 | 50,404 |
| compliance | 11,248 | 33,976 | 45,224 |
| investigator | 5,732 | 20,257 | 25,989 |
| journalist | 5,567 | 18,886 | 24,453 |
| researcher | 6,939 | 23,379 | 30,318 |
| siu | 8,474 | 27,156 | 35,630 |
| lawyer | 52,499 | 107,649 | 160,148 |
| genealogist | 49,070 | 97,141 | 146,211 |
| inv104 | 13,150 | 54,337 | 67,487 |
| **real3-jha** | 21,964 | 101,395 | 123,359 |
| **real3-archcoal** | 36,241 | 199,345 | 235,586 |
| **real3-carpenter** | 16,211 | 74,602 | 90,813 |
| **real3-k2** | 24,666 | 129,295 | 153,961 |
| **real3-valenti** | 39,982 | 153,278 | 193,260 |
| **real3-jfk** | 39,837 | 120,205 | 160,042 |

  About 7–8 k tokens per send on the hard cases, 13–14 k on archcoal (11 releases), 10–11 k on valenti, 16–18 k on the
  two older court opinions; most of it the one shared prefix. Whole run about 4 minutes (00:09–00:13); no stall.

## 6. ALCOA evidence on a NEW case (real3-jha)

From the scored run, every case: `provenance|… AI run(s): picture=1 question=N; states done; 0 record(s) without a run
id` (real3-jha: 8 runs, picture=1 question=7; ai-runs.txt: provider anthropic, model requested claude-opus-5, requested
by "this Mac's owner", state done).

A scorer probe (a temporary test, run once 2026-11-25 00:27 and deleted, never committed) drove real3-jha through the
same path — import, case, picture, q1 with the same blind replies — then read the ledger:
- **AI records:** 36 / 36 linked to a run that exists, 36 / 36 with model requested (claude-opus-5), 36 / 36 with a
  64-hex request SHA-256, 36 / 36 with the prompt version (case-agent/2afeed6b7d8f). Model *served* is empty (shown
  "not recorded") — the scripted reader reports no served model.
- **AI runs rows** (case_ai_runs): picture + question, coverage `{"caseDocuments":2,"excluded":0,"parts":1,"sent":2}`,
  64-character cache key, prompt version; `model_calls` = 0 and `input_tokens` = 0 — the eval's scripted reader returns
  no usage, so calls/tokens are not recorded on this path (ALCOAGroup2Tests drives a reader that reports usage and sees
  ≥ 2 calls).
- **Audit chain:** sealed 51 events, first broken none, missing none, unsealed 0, keyless 0 — intact.
- **Data integrity report:** builds — 12 principles, chain intact ("No change detected in 51 sealed events.
  Tamper-evident, not tamper-proof…"), 2 documents with 64-hex intake SHA-256, 0 vault mismatches, 2 AI runs, 36 AI
  findings, 0 not read; never says "compliant". Export: integrity-report.pdf + .json + evidence-manifest.csv, 3
  certification sidecars, PDF archival check passed.

## 7. Verdict against the owner's bar

| bar | result |
|---|---|
| ≥ 90 % correct | **met** — 93.3 % overall; hard 90.0 %, earlier real 100 %, **NEW real 91.3 %**; 91.7 % with the AI's own conclusion line shown. Not met on a literal every-must-element reading of the NEW real set (78.3 %; all 88.3 %). |
| ≤ 1 confident-wrong per 100 | **met** — 0 / 120 |
| key multi-document questions right | **mostly** — corrected witnesses 5/5, not-established 13/13 (hard 7, new 6), "2.4 million" 5/5, scheduled-vs-actual 3/3, witness disagreement 3/3; **round-trip traces 7/9** (vantage q1 kept amounts not stated; kiln q1 lost Kerr's legs to an over-strict check), date conflicts 5/6, spellings 4/5, release comparisons 2/4 — no answer wrong, the misses are omissions or withheld halves |

**Bar met on the headline numbers (agent-simulated reader, not a live AI run), including the unseen real cases
(91.3 %), with 0 confident-wrong.** It is not met if every element of every key must appear, and the two round-trip
misses mean the key multi-document question is not right in every hard case. The margin is thin: the hard set sits
exactly at 90.0 %.

## 8. Misses diagnosed

App-side (code; none changed in this run). No mechanical misreading of a number or date remained; the drops below are
rules working as written, and too strict for true, exactly quoted claims:
1. `VerifiedAnswerComposer.whyNot` → `valueMissing(claim:quote:passage:)` (Kalsmritikosh/Brain/VerifiedAnswerComposer.swift
   l. 268 / 568): a claim that names the year of its own cited document ("The 2014 release says …") is dropped because the
   year is in the document's date line, not in the quoted sentence. Cost: carpenter q2 and q4 (two partly answers on an
   unseen case), one k2 q6 statement. Same family as FAIR2's FR-12 / INV-104 (a document's own identifier), still present
   (inv104 q1 ×2, vantage q1 "VQ-REL-01").
2. `VerifiedAnswerComposer.whyNot` step 3 (l. 270): the AI's `about` must occur as a literal substring of the passage, so
   "Bradley Kerr" fails against "BRADLEY J KERR". Cost: kiln q1 (two true legs and the conclusion).
3. `CaseReader.secondLookSuffix` (Kalsmritikosh/Brain/CaseReader+Path.swift l. 138): the second look gets only the reduced
   answer, not which statements the checker dropped and why, so it cannot re-quote them; it rescued 0 of 4 (W) partly
   answers. Design gap, not a rule violation.
4. Request text not byte-stable between runs: a picture-step rejection reason names one missing value picked in an
   unstable order ("the number 39" / "the number 26" for the same record), and a briefing name line flips between
   "Shamos" and "Mr. Shamos" ("Lindqvist" / "Mr Lindqvist"). Picture requests only; question prefixes were stable
   (1 per case). Affects reproducibility of a re-run and prompt-cache hits on picture rounds.
5. Eval path only: case_ai_runs `model_calls` / `input_tokens` = 0 and model served "not recorded" when the scripted
   reader is used (§6) — a harness limitation, the real provider path records them (ALCOAGroup2Tests).

Reader errors: harbor q3 conflict not named; solace q5 false-declaration tick omitted; vantage q1 kept amounts not
stated; k2 q5 and valenti q3 a value packed from another sentence; the second look said "nothing to add" on four
incomplete answers; under-quoting in harbor q3 q5, meridian q2, vantage q2, inv104 q1 q5.

## 9. Next

Relax items 1–2 (a year or identifier that is the cited document's own date/label; a name in `about` matched by tokens
allowing a middle initial), tell the second look what was dropped and why (item 3), make the rejection reason and the
briefing name form deterministic (item 4), then a live AI run when the bench key has credit. Evidence (local,
git-ignored): build/agent-eval-fair3/run/ (final.txt per question with NOTES, picture-records.txt, ai-runs.txt,
summaries), build/agent-eval-fair3/requests/ (320 requests + replies), console log above.
