# AI-50 — fair run 4 ("fair4"): scored results (2026-11-25)

**Fair agent-simulated AI reader — blind reader, clean run incl. 12 unseen real public cases; not a live AI run.**

Code: setup commit d55a418e (current code after FAIR3's strictness fixes and F1–F5: F1 same-document support + quote
arithmetic, F2 "Money by party", F3 second-look checklist, F4 cross-document discrepancies, F5 identifiers as whole
tokens). One fresh exchange folder for both suites (build/agent-eval-fair4/, git-ignored): **451 requests, all replied by
a blind reader** that opened only the requests (READER_INSTRUCTIONS.md: no keys, fixtures, sources, earlier runs or web).
Every request of every case was new for this reader, including the 21 cases of FAIR3 (F2–F4 changed their text). Scored
run: Xcode RunSomeTests 2026-11-25 07:47, `AgentReaderEvalTests/run()` + `AgentReaderHardEvalTests/run()` in one call,
both passed; console log test-console-log-2026-11-25T07-47-11+05-30.txt; 0 pending; filing checks 0 MISFILED / 0 LEAK in
all 27 cases. **No reply was written, edited or re-filed by the scorer and no product code was changed.** Keys stayed in
/tmp (hard-, real-, real3-, real4-keys.json; never committed). The scorer judged the FINAL SHOWN answer
(run/<case>/qN/final.txt: conclusion, checked statements, the app's arithmetic, "Also worth checking", NOTES).

Cases (27, 166 questions):
- **hard** (5 fictional multi-document cases, 13–15 documents, 40 questions): harbor, meridian, solace, vantage, kiln.
- **earlier real** (10 cases, 34 questions): forensic, individual, compliance, investigator, journalist, researcher, siu,
  lawyer, genealogist + inv104.
- **real3** (6 public cases first used in FAIR3, 46 questions): jha, archcoal, carpenter, k2, valenti, jfk.
- **NEW real4** (6 public cases never seen by the reader or the harness, 46 questions; KalsmritikoshTests/Fixtures/
  AgentEvalReal4, sources in REAL4_SOURCES.md): real4-newark (DOJ NJ, NWCDC kickbacks, 7 releases), real4-leondi (DOJ NJ,
  Picatinny bribes, 4 releases), real4-mayfield (SEC, MayfieldGentry, 3 litigation releases), real4-4x (CFTC, forex
  Ponzi, 2 releases), real4-stoddard (9th Cir. 1998 opinion), real4-autoland (NTSB Cirrus SF50 autoland, 4 parts).

Scoring is FAIR3's, unchanged, for every set: **correct** = the must facts that answer what the question asks are in the
shown text and nothing on the wrong list; **partly** = a part unanswered, a trap element missing or the conclusion
mis-framed; **confident-wrong** = a confident claim on the wrong list; **honest not-stated** (key: not established, app
says so) counts as correct; **refused-when-answer-existed**. (W) = the AI's conclusion withheld by the app. Strict side
score: every element of every key "must" (incl. context the question did not ask for), applied to ALL sets this time.

## 1. Totals

| | all (166) | hard (40) | earlier real (34) | real3 (46) | **NEW real4 (46)** |
|---|---|---|---|---|---|
| correct | **160 = 96.4 %** | **37 = 92.5 %** | **34 = 100 %** | **46 = 100 %** | **43 = 93.5 %** |
| partly | 6 | 3 | 0 | 0 | 3 |
| confident-wrong | **0** (see sensitivity) | 0 | 0 | 0 | 0 |
| honest not-stated (key: not established) | 20 / 21 | 7 / 7 | 2 / 2 | 6 / 6 | 5 / 6 |
| refused when an answer existed | 0 | 0 | 0 | 0 | 0 |
| **strict, every key element** | **156 = 94.0 %** | 35 = 87.5 % | 34 = 100 % | 46 = 100 % | 41 = 89.1 % |

- Same 120 questions as FAIR3: **117 / 120 = 97.5 %** (FAIR3 scored run 112 / 120; FAIR3 replies after F1–F5 115 / 120).
- Sensitivity (confident-wrong): two partly answers call a rounding difference a disagreement — autoland q6 ("the speed
  does not quite [agree]: 167 knots vs about 170 knots") and 4x q3 ("No, not exactly … close but not identical", while
  naming the rounded allegation vs the exact court finding). Both show both figures and assert no contradiction, so they
  are scored partly (mis-framed). Counting autoland q6 as confident-wrong gives 0.6 per 100; counting both gives 1.2 per
  100 (above the bar).
- Strict-only misses (correct by the FAIR3 standard): meridian q1 ("£20,000 remained" not stated — closing 22,000 and
  opening 2,000 are), kiln q1 (the 30 July $900,000 interim payment not placed in the sequence), stoddard q2 (the
  17 Oct / 2 Oct 1989 closings not dated), autoland q5 (ACRA poll and no remote-ID data, given in q8 but not in q5).

### Per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C | C | **P** | C | C | C | C | C (NS) |
| meridian | C (s) | C | C | C | C | C | C (NS) | C (NS) |
| solace | **P (W)** | C | C | C | C | C | C (NS) | C |
| vantage | **P** | C | C | C | C | C | C | C (NS) |
| kiln | C (s) | C | C | C | C | C | C (NS) | C (NS) |
| 10 earlier real | all 34 C (inv104 q4, q5 NS) | | | | | | | |
| real3-jha / archcoal / carpenter / k2 / valenti / jfk | all 46 C (6 NS) | | | | | | | |
| **real4-newark** | C | C | C | C | C | C | C | C (NS) |
| **real4-leondi** | C | C | C | C | C | C | C | C (NS) |
| **real4-mayfield** | C | C | C | C | C | C | C | C (NS) |
| **real4-4x** | C | C | **P** | C | C | **P (W)** (key NS) | | |
| **real4-stoddard** | C | C (s) | C | C | C | C | C | C (NS) |
| **real4-autoland** | C | C | C | C | C (s) | **P** | C | C (NS) |

(s) = correct, missed on the strict reading. Changes against FAIR3's scored run on the 120 repeated questions: now right —
kiln q1 (Pemberton kept 70,000), solace q5 (Iyer = Ayyar at Flat 7B, and Menon's brother-in-law "Rajesh Ayyar" with the
"No" tick), carpenter q2 and q4, k2 q5, valenti q3; newly missed — solace q1 (app defect, §5 item 1). Unchanged misses:
harbor q3, vantage q1.

## 2. Per trap type

Hard set (FAIR3 classes):

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | **7** | harbor q1 q2, meridian q1 q2, solace q8, vantage q2, kiln q1 right; **solace q1 P (W)** (app defect), **vantage q1 P** (kept amounts not stated) |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh, Chen |
| date / claim-vs-record inconsistency | 6 | 5 | harbor q3 partly |
| two name spellings | 5 | **5** | solace q5 now right |
| "2.4 million" vs "2,400,000" | 5 | 5 | |
| not established | 7 | 7 | |
| other (instalment, overcharge, title) | 3 | 3 | |

Real sets (real3 + NEW real4, 92 questions):

| trap | real3 | **real4** | notes |
|---|---|---|---|
| not established | 6 / 6 | **5 / 6** | 4x q6: honest answer written by the reader, lost to an app defect (§5 item 2) |
| release vs release with a real difference | 2 / 2 (carpenter q2, q4) | **4 / 4** | newark q1 ($730,000 alleged vs $956,948 admitted), q6 (Newark vs West Orange), leondi q2 ($125k / $150k), q3 ($46k / $48k / ~$50k) |
| rounding, not a conflict | 2 / 2 (archcoal q6, k2 q2) | **0 / 2** | 4x q3, autoland q6 mis-framed as disagreement |
| scheduled vs actual sentencing | 3 / 3 | 2 / 2 | newark q5, leondi q5 |
| money trace / flow | — | 4 / 4 | newark q2 q3, 4x q2 (incl. the $69,020 the court figures leave), stoddard q2 |
| arithmetic / reconcile | 4 / 4 | 5 / 5 | newark q7 (12 payers = $999,000), mayfield q3 ($175,000), stoddard q3 ($127,196 ≠ $116,223), q4 ($31,000 vs $32,180.91), 4x q4 (3 × $2,745,226) |
| one name / place, two spellings | 1 / 1 | 4 / 4 | Picattiny / Picatinny, Stroudsburg / Stroudsberg, Matthew / Matthews, Murier / Mourier |
| inconsistency inside one document | 1 / 1 | 2 / 2 | autoland q3 (Lufkin vs Cincinnati), stoddard q6 (discovery date vs the recited facts) |
| witness / account vs record | 3 / 3 | 1 / 1 | autoland q4 (EA button press recorded at the 2nd activation) |
| unnamed identity (inference only) | — | 1 / 1 | leondi q4 — Grassie / Conway named as matching, flagged as not stated |
| other facts | 24 / 24 | 15 / 15 | |

## 3. Did F2, F3, F4 fix what they targeted?

| item | FAIR3 | fair4 | fixed? | why |
|---|---|---|---|---|
| vantage q1 (each party's kept €50,000) | P | **P** | **no** | the task carried F2's per-party lines and "state what each party kept", but F2's figures for vantage are wrong (Ardmore "kept 700,000", Tidewell "kept −400,000": every transfer is counted once per document that records it). The reader gave the round trip, Ardmore's 51,000 balance and Tidewell's € 52.500,00 closing balance, but no kept amount. |
| kiln q1 (Pemberton kept $70,000) | P | **C** | **yes, by the reader's own sum** | F2's table said Pemberton "kept −210,000" (also double-counted); the reader followed F2's instruction, ignored its numbers and used the sum tool (350,000 + 350,000 − 350,000 − 280,000 = 70,000). |
| solace q5 (Iyer = Ayyar; false "no relative" tick) | P | **C** | **yes, not via F3** | the question reply itself named the shared Flat 7B address and Menon's brother-in-law with the "No" tick; F3's checklist for q5 listed eight other records (price, approval, dates) — not the declaration. The briefing's Relationships line ("Dr. Anil Menon — brother-in-law (declared) — Rajesh Ayyar") was there. |
| k2 q5 (consent judgment, officer/director bar) | P | **C** | **yes, by F3** | the checklist listed "February 13, 2015: Final judgment by consent …"; the second look added the consent judgment and the officer-and-director bar. |
| harbor q3 (ledger 4 Mar vs paid 13 Mar, before the 10 Mar instalment) | P | **P** | **no** | F4 put the BMC-0311 dates (13 Mar in both banks, 4 Mar in the ledger, "6 days before the 10 Mar receipt") in the briefing; the reader saw it and judged the 4 Mar date a ledger posting date "which may not be the payment date" (the ledger's column is "Posting date"). Defensible reading; the key wants it called a conflict (§5, key issue). |

Second look overall: **133 / 166 answers carry "Also worth checking"** lines (FAIR3: 0 / 109, all "nothing to add").

F4 itself: 6 discrepancies in 4 cases, **1 genuine** (harbor BMC-0311). 4 come from reading day/month dates in US order
(kiln "KSL-0907: 2026-09-07 vs 2026-07-09" — both 9 July; "KSL-CN-0907: 2026-03-08 vs 2026-08-03"; vantage "600,000 with
ardmore: 2026-03-09 vs 2026-09-03" — both 3 Sept; vantage 500,000: 02/10 and 01-10 read as Feb / Jan); 1 groups three
different transfers on one account (inv104 "account …8804 with 50,000: different dates"). No reader was misled by them.

F2 itself: wrong in every hard case. Each transfer is counted once per document that records it (sender's statement,
receiver's statement, ledger): harbor Bluewater "kept 85,000" (true 25,000), Deepline "money in 60,000 + 60,000 +
1,400,000 + 60,000"; meridian Larkfield "kept 440,000" (true 20,000); solace Medline "kept 100,000" (true 50,000); kiln
Pemberton "kept −210,000" (true 70,000). Currencies mix in one sum ("1,800,000 − EUR 1,100,000"). Three shown conclusions
say so to the user: harbor q1 / q2 ("The app's per-party totals count the same transfers twice and should not be relied
on") and solace q1's withheld conclusion.

## 4. Conclusions, drops, stops, calls, tokens

- **Conclusions: 155 replies carried one (11 "documents don't say"); 153 shown = 98.7 %, 2 withheld** (solace q1, 4x q6
  — both caused by an app defect, §5 items 1–2). FAIR3 scored run 102 / 109.
- **Verifier drops: 12 question-reply claims, 21 second-look claims** (of 816 + 713 kept). Must facts lost: solace q1
  (Lata Menon ₹3,00,000) and 4x q6 (the "no restitution, disgorgement + penalty instead" statement) — both app defects.
  The rest lost no must fact: `about` "Deepline Dredging Inc." not in Deepline's own ledger (harbor ×4); a control
  character inside "ASDE\x1eX" in the jfk source the reader typed as "ASDEX" ("quote not in passage", jfk ×6); a value
  from another sentence (harbor q5 "41", solace q2 "4", stoddard q2 "901945", newark q7 "2012", stoddard q6 ×2, vantage
  q3–q6, valenti q2 q7, meridian q3, leondi q4 "No. 1", jfk q6 "7110"); identifiers in a look claim held only by the
  question's quotes (inv104 ×4).
- **Relevance:** 0 warnings on question replies; one second look said `addresses_question: "no"` (4x q6, shown as "The
  AI says this may not answer your question"). **0 "Stopped early".**
- **AI calls per question: 338 sends / 166 = 2.04** (question + second look; a sum-tool round in 17 questions; 1 send
  for the 11 "documents don't say"). Plus 86 picture steps and 27 background suggestion reads: 86 + 183 + 155 + 27 = 451.
- **1 distinct question prefix per case in all 27 cases.** Picture: 27–77 records per case, all from the picture, 0 from
  questions, 0 without a run id (hard 65–71, FAIR3 36–44).
- Estimated input tokens (CaseReader.estimatedTokens, before prompt caching): **3.93 M for the run, 146 k per case on
  average** — hard 174–192 k (avg 182 k; FAIR3 124–144 k: the per-party and discrepancy sections and longer pictures),
  earlier real 28–166 k (avg 68 k), real3 100–249 k (avg 175 k), **real4 80–371 k (avg 216 k)**: newark 371 k (7
  releases, ~18.8 k per send), stoddard 287 k, autoland 217 k, leondi 196 k, mayfield 142 k, 4x 80 k.

## 5. Misses diagnosed

App defects (code; none changed in this run):
1. **Masked account in the quote not matched** — `VerifiedAnswerComposer.identifiers(in:)` (pattern 2, l. 414) takes only
   the digits of "XXXX7316" as the token, and `containsIdentifier` (l. 444) requires no letter before them, so the quote's
   own "SBI XXXX7316/professional fees" fails. Cost: **solace q1** — the ₹3,00,000 to Lata Menon dropped in the question
   AND the second look, conclusion withheld. A regression from F5 (FAIR3: C).
2. **A digit in a name read as a number** — "4X" (4X Solutions) read as "the number 4 not in the quote". Cost: **4x q6** —
   the reader's honest "no restitution stated; disgorgement $2,745,226 and a penalty instead" claim dropped; the
   conclusion ("Not established …") withheld because its amounts were only in that claim, although the second look
   re-quoted the same amounts and they were kept (the conclusion check does not use verified second-look quotes), and the
   look's "Not stated" answer is not shown. Shown: only "the CFTC said it sought restitution" and a caution. Same family:
   "No. 1", "Rule 404(b)", "clause 2.1" (no must lost).
3. **F2 per-party money counts each transfer once per document** and mixes currencies (§3). Contributed to vantage q1;
   visible to the user in three conclusions.
4. **F4 / money-record dates read DD/MM as MM/DD** in non-US documents, and distinct transfers grouped as one (§3): 5 of 6
   discrepancies false. No score cost this run; a hint that is wrong 5 times in 6 trains the reader to ignore the one
   that matters (harbor q3).
5. Minor, no cost: quote matching does not drop control characters (jfk "ASDE\x1eX"); `about` must be in the passage
   even for a party's own ledger (harbor ×4); identifiers in a second-look claim are not looked up in the question's
   verified quotes (inv104 ×4).

Reader errors: vantage q1 kept amounts not stated (with item 3 behind it); 4x q3 and autoland q6 framed rounding
("approximately $2 million" vs $1,985,754; 167 vs "about 170" knots) as disagreement; under-quoting in the drops above.

Key issue (partial): harbor q3 — the reader's "posting date, may not be the payment date" is a defensible accounting
reading of a GL column headed "Posting date"; the key requires the date to be called a conflict and the 10 March
instalment named. Fourth run in a row answered this way (now with F4's hint in front of the reader).

Design gaps: the conclusion check ignores claims verified in the second look (item 2); the second look's own answer text
is never shown, so an honest "not stated" there is lost when the question reply fails.

## 6. Verdict

| bar | result |
|---|---|
| owner's goal 99 % | **not met** — 96.4 % (160 / 166); 97.6 % if app defects 1–2 were fixed (solace q1, 4x q6 were answered right by the reader) |
| ≥ 90 % correct | **met** — 96.4 % overall; hard 92.5 %, earlier real 100 %, real3 100 %, **NEW real4 93.5 %**; strict every-element 94.0 % (hard 87.5 %, real4 89.1 %) |
| ≤ 1 confident-wrong per 100 | **met** — 0 / 166 (0.6 / 100 if autoland q6 is counted; 1.2 / 100 if 4x q3 is too) |
| key multi-document question right | **mostly** — round-trip traces 7 / 9 (solace q1 app defect, vantage q1), corrected witnesses 5 / 5, spellings 5 / 5, "2.4 million" 5 / 5, date conflicts 5 / 6, not-established 20 / 21 |

**Bar met on the headline numbers (agent-simulated reader, not a live AI run), including the six new unseen real cases
(93.5 %), with 0 confident-wrong. The owner's 99 % is not reached:** 2 of the 6 misses are app defects that dropped true,
exactly quoted claims (one a regression from F5), 1 is a reader omission behind a wrong F2 table, 1 a defensible reading
the key scores partly, 2 are reader framing of rounding. F2 and F4 as built give wrong numbers / false discrepancies in
most cases where they fire; F3 works (k2 q5; 133 / 166 answers gained checked second-look lines).

## 7. Next

Fix items 1–2 (match a masked number against masked forms in the quote; read a digit glued to letters as part of a name;
let the conclusion check use second-look-verified quotes and show the look's "not stated"); de-duplicate F2 transfers
(one transfer seen in the sender's statement, the receiver's statement and a ledger counts once; never sum across
currencies); infer each document's day/month order (any day > 12, its other dates, its locale) before F2/F4 use a date,
and never call distinct transfers one discrepancy; then a fresh blind round, k = 3 readers per case, and a live AI run
when the bench key has credit. Evidence (local, git-ignored): build/agent-eval-fair4/run/ (final.txt per question,
picture-records.txt, picture-steps.txt, summaries), build/agent-eval-fair4/requests/ (451 requests + replies), console
log above.
