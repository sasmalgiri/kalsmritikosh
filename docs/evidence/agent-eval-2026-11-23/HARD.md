# AI-50 — hard multi-document cases: scored results (2026-11-24)

**Fair agent-simulated AI reader — the reader never saw the questions in advance or the keys; not a live AI run.**

Setup: commit 4980b853. Five written multi-document cases (KalsmritikoshTests/Fixtures/AgentEvalHard/: harbor, meridian,
solace, vantage, kiln; 13–15 documents each, 8 questions each) plus two of the 2026-11-23 real cases unchanged as
controls (forensic = DOJ press release, 3 questions; individual = NTSB SEA08LA057, 4 questions). 47 questions in all.
Harness: `AgentReaderHardEvalTests/run()` (KalsmritikoshTests/AgentReaderEvalTests.swift). The case picture is built
before any question; each question goes through the app's own case path (agent loop, sum tool, merge, second look,
claim verifier, conclusion check) with the reader's reply files as the AI transport. Answer keys stayed outside the
repo (not committed). The scorer (this document) did not change any reply or any product code.

## 1. What happened: the reader filed most replies under the wrong question

Run 1 (2026-11-24 05:24, test passed, all 130 requests had replies, no placeholder) is the run exactly as the reader left
it. Scoring it showed that the shown answer to most questions answers a *different* question of the same case — e.g.
harbor q4 "Was Daniel Okafor at the bid scoring meeting?" was shown "AI's conclusion: No — the board minutes ($2.4
million) and the contract (USD 2,400,000) give the same value…".

Cause, checked against the 04:27 run's console dump (the run whose requests the reader answered): every
`requests/<case>/qN-q-p1-r0.txt` carried the right question `qN`; the harness labelled nothing wrongly. The reader
wrote its answer to question Y into the reply file of question X (33 of 40 hard questions; all 7 control replies were
filed correctly). Reader error, not an app or harness defect. Mapping found (file → question it answers):

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | 2 | 4 | 1 | 6 | 8 | 3 | 5 | 7 |
| meridian | 1 | 2 | 4 | 5 | 6 | 8 | 3 | 7 |
| solace | 1 | 3 | 4 | 5 | 2 | 7 | 8 | 6 |
| vantage | 2 | 1 | 3 | 5 | 6 | 7 | 4 | 8 |
| kiln | 1 | 2 | 4 | 5 | 6 | 8 | 3 | 7 |

Run 2 (06:12, test passed) re-filed every reply file (content byte-for-byte unchanged, multi-round tool replies and
second-look replies moved together) under the question it answers, and ran the same harness again, so each reply flowed
through the app's merge, second look, verifier and conclusion check against its own question. The original files were
restored afterwards (build/agent-eval-hard/requests/ is as the reader left it; run 1 output in
build/agent-eval-hard/run/, run 2 output in build/agent-eval-hard/run-refiled/, both git-ignored).

Run 2 measures the reader + app answer quality. Run 1 is the literal result of this fair run.

## 2. Scores

Scoring: **correct** = every "must" fact of the key in the shown text and nothing on the key's "wrong" list;
**partly** = some must facts missing or the conclusion is missing or mis-framed; **wrong** = a confident claim on the
key's wrong list, or a shown answer to a different question; **honest not-stated** = the key says not established and
the app says so (counted correct); **refused-when-answer-existed** = "the documents don't say" for a question with an
answer.

| | run 2 (replies under their own question) | run 1 (as filed by the reader) |
|---|---|---|
| correct | **43 / 47 = 91.5 %** (5 of these only as checked facts: the AI's conclusion was withheld) | 13 / 47 = 27.7 % |
| correct with the AI's conclusion shown | 38 / 47 = 80.9 % | — |
| partly | 4 | 1 |
| confident-wrong | **0** | 31 shown answers to another question (several read as a confident "Yes —"/"No —") |
| honest not-stated (key: not established) | 7 / 7 | 1 / 7 (vantage q8) |
| refused when an answer existed | 0 | 2 (harbor q5, meridian q6 got the not-stated reply of another question) |
| hard set only | 37 / 40 = 92.5 % (33 / 40 with conclusion) | 7 / 40 (the 7 replies the reader filed correctly) |
| controls only | 6 / 7 | 6 / 7 (all control replies were filed correctly) |

### Run 2 per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C | C | **P** | C | C | C | C | C (NS) |
| meridian | C | C | C | C (W) | C | C | C (NS) | C (NS) |
| solace | C (W) | C | C | C | **P** | C | C (NS) | C |
| vantage | C (W) | C | C | C | C | C (W) | **P** (W) | C (NS) |
| kiln | C | C | C | C | C | C | C (NS) | C (NS) |
| forensic | C | C | C | | | | | |
| individual | C (W) | C | C | **P** | | | | |

C correct · P partly · NS honest not-stated · W the AI's conclusion was withheld by the app (facts shown).

individual q1 counts as correct only because the second look saved it: the reader's correct claim "about 1430 Pacific
standard time … at the Sonoma County Airport (OQ3)" was dropped for saying "the two airplanes" (the quote has no "2"),
the conclusion was then withheld because 1430 was in no kept quote, and the main body shows only "2230 UTC" and
"Sonoma, CA"; the 1430 / OQ3 sentence appears only under "Also worth checking (a second AI look)". App defect (§4, §7).

The four partly answers:
- harbor q3 (date): both dates shown (paid 13 March; ledger 4 March) but the reader explained the ledger date away as
  "an accounting entry date, not the payment date" instead of flagging the conflict the key requires. Reader judgment.
- solace q5 (two spellings): Iyer = Ayyar, same flat, and the brother-in-law "Rajesh Ayyar" are shown; the false
  "no relative deals with the hospital" tick on Dr. Menon's declaration is not. Reader omission.
- vantage q7 ("€2.4 million" vs 2,400,000): all figures shown, but the "Yes — they agree" conclusion was withheld
  ("three receipts" — a count the reader derived), so the shown text never says they agree. App strictness (see §4).
- individual q4 (control): the reader concluded "No conflict on the runway" although the key counts the Piper landing
  on 07 vs the Glastar pilot waiting for traffic landing on 25 as a difference; the warning half is right. Reader
  judgment.

## 3. Per trap type (run 2, hard set)

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | 9 | harbor q1 q2, meridian q1 q2, solace q1 q8, vantage q1 q2, kiln q1; solace q1 and vantage q1 lost their conclusion (facts complete) |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh, Chen — every answer used the correction; meridian q4 conclusion withheld |
| date inconsistency | 6 | 5 | harbor q3 partly (conflict explained away) |
| two name spellings | 5 | 4 | solace q5 partly; vantage q6 conclusion withheld (facts complete) |
| "2.4 million" vs "2,400,000" | 5 | 4 | no answer invented a conflict; vantage q7 partly (conclusion withheld) |
| not established | 7 | 7 | harbor q8, meridian q7 q8, solace q7, vantage q8, kiln q7 q8 — none named the obvious suspect as fact |
| other (overcharge, title, instalment) | 3 | 3 | |

## 4. Conclusions the app withheld, and whether that was right

Same six in both runs (run-1 file names in brackets: meridian q3, solace q1, vantage q2/q5/q6, individual q1).

| question (run 2) | reason given | right? |
|---|---|---|
| meridian q4 [file q3] | "the number 1" — from "**One** delivery, on 2026-05-09" | No. Number word in plain prose; the conclusion was correct. |
| solace q1 [q1] | "the number 4" — "the **four** BW-V900"; the quote says "BW-V900 **x4**" | No. "x4" is not read as 4 (digits after a letter are skipped), and "four" counts as a required number. |
| vantage q1 [q2] | "the number 2218" — account ****2218 | Yes, by the contract: no kept quote carries ****2218 (the reader did not quote it). The conclusion itself was correct. |
| vantage q6 [q5] | "the number 3" — "all **three** give the same … address" | No. A count of the documents just listed. |
| vantage q7 [q6] | "the number 3" — "three receipts of 800000.00" | Defensible (a derived count not in any quote) but over-strict: three listed receipts are three claims. |
| individual q1 | "the number 1430" | No. 1430 was in the reader's quote; that claim was dropped for "the two airplanes" (below). |

Verifier drops (run 2): 3 claims, all true. individual q1 — dropped for the number word "two" (app defect; the key fact
survived only through the second look). meridian q2 ("…came after it received the 310,000.00", quote carries only 310,000) and solace q8
("closing 62,000.00 from an opening 12,000.00", quote carries only 62,000) — the reader put two amounts in one claim
with one quoted; the drop follows the contract and lost nothing (the facts are in other kept claims).

## 5. AI case picture, calls, prefixes, tokens

- Picture usefulness (heuristic: every key "must" token of the question present in picture-records.txt): 46 / 47. Only
  kiln q8 ("could not see the plate") was not in the picture. 88–102 picture records per hard case, all origin
  "picture"; 0 records added by questions.
- AI calls per question: 2.0–2.25 (the question + the second look; +1 round when the sum tool is used — 7 questions;
  1 when the answer is not stated). Picture: 4 steps per hard case, 3 per control. The second look added checked lines
  in 4 of 47 questions (kiln q4: forklift keys and the patrol-book entry; forensic q1, q2; individual q1, where it
  carried the only copy of the 1430 / OQ3 fact); in the other 43 it replied "nothing to add".
- Distinct prefixes: 1 per case in every case (the stable case prefix is shared by every picture step and question).
- Estimated input tokens per case (CaseReader.estimatedTokens, before any prompt caching):

| case | picture | questions | total |
|---|---|---|---|
| harbor | 29,396 | 150,781 | 180,177 |
| meridian | 26,726 | 129,446 | 156,172 |
| solace | 28,280 | 157,248 | 185,528 |
| vantage | 28,255 | 151,153 | 179,408 |
| kiln | 29,810 | 142,861 | 172,671 |
| forensic | 9,603 | 23,157 | 32,760 |
| individual | 13,956 | 39,394 | 53,350 |

  About 7.5–9.9 k tokens per send, most of it the one shared prefix (cache-readable).
- Run 1 had two complete 15-minute silences with no log lines (05:25:29 → 05:40:29 in meridian q8's rules reading;
  05:40:52 → 05:55:53 in vantage q1's AI answer); each resumed with "database not open" errors from background workers
  of an already-closed case ledger (CooccurrenceGraphBuilder, AgglomerativeCommunityDetector, upgrade drain). Not
  reproduced in run 2 (whole run about 2 minutes). Not attributed; worth a look (background tasks outliving
  `state.shutdown()`).

## 6. Verdict against the owner's bar

| bar | run 2 | run 1 (literal) |
|---|---|---|
| ≥ 90 % correct | met on facts — 91.5 % overall, 92.5 % on the hard set; **not met** if the AI's conclusion must be shown (80.9 %) | not met — 27.7 % |
| ≤ 1 confident-wrong per 100 | **met** — 0 | not met |
| key multi-document questions right | **met in content** — 9/9 round-trip traces/nets, 5/5 corrected witnesses; 2 traces shown without the AI's conclusion | not met |

**Not met as a fair run.** The run as the reader left it (run 1) fails the bar outright because the reader misfiled
replies — a failure the app could not see. With every reply under its own question (run 2, a scorer re-filing, no
content changed) the reader + app clear the 90 % and confident-wrong bars on the shown facts, with every round trip,
witness correction and not-established question right; but 5 of those correct answers lost the AI's own conclusion to
the app's number check (4 of them wrongly), so the answer an investigator reads first is right in only 80.9 %.
AI-50 stays IMPLEMENTED until the number-word defect is fixed and a clean fair run (no re-filing) meets the bar.

## 7. Misses diagnosed

App defects (code):
1. `VerifiedAnswerComposer.values(in:)` (Kalsmritikosh/Brain/VerifiedAnswerComposer.swift, number-word pass using
   `numberWords`, ~l. 366 and ~l. 436–443) treats plain-prose number words ("one delivery", "the two airplanes", "all
   three", "the four units") as numbers that a quote must contain. Used by `valueMissing(claim:quote:passage:)`
   (claim drop) and `conclusionWithheld(_:claims:arithmetic:)` (conclusion withheld). Cost: a true claim dropped (individual q1),
   4 conclusions withheld wrongly (meridian q4, solace q1, vantage q6, individual q1) and vantage q7 partly.
2. Same function, remaining-numbers pattern `(?<![\p{L}\d.])…`: digits glued to a letter ("x4", "4x") are never read,
   so "four" in the conclusion cannot be matched to "BW-V900 x4" (solace q1).
3. No check that an answer addresses its question. In run 1, 31 replies answering a different question passed the
   verifier (quotes were real) and the second look, and were shown as "AI's conclusion" under the wrong question. A
   live model is unlikely to misfile, but the gate has no relevance test at all.

Reader errors: misfiling of 33 replies (run 1); harbor q3 conflict explained away; solace q5 omission; individual q4
runway judgment; vantage q1 account number not quoted.

## 8. Top fixes

1. Number words: only require a number word to be backed when it is a quantity of money/date or the claim's subject
   count, or accept it when the quote lists that many items; simplest safe step — ignore "one"…"ten" in conclusions and
   claims unless followed by a unit the quote also has, and read "x4"/"4x" as 4.
2. Relevance guard: have the second-look request (or a mechanical check against the question's named entities and
   wh-type) reject a conclusion that does not answer the asked question, and show "not answered" instead.
3. Re-run this set with the corrected reader (or a live model when the bench key has credit) and the 10 real solved
   cases AGENT-10 also names (not part of this run).

Evidence files (git-ignored, local): build/agent-eval-hard/run/ (run 1), build/agent-eval-hard/run-refiled/ (run 2),
console logs /tmp/hard-run-log.txt and /tmp/hard-run2-log.txt.

## 9. Fixes after this run (2026-11-24; the hard set not yet re-run)

1. Number words (c3c5ec9e): `VerifiedAnswerComposer.values(in:role:)` reads a claim or conclusion as `.claim` — plain number
   words ("one", "two", "all three", "twice", "both") are not required in a quote; digits, money, percentages, dates and a
   number word with a unit ("two million", "fifty percent") still are; "x4" / "4x" / "×4" read as 4. AI-46's rule stands:
   a conclusion's amounts come from a checked quote or the app's sum.
2. Relevance (c3c5ec9e): the reply restates the question it answers (`answers_question`, verbatim); another question (or
   none, when a conclusion is given) → the conclusion is withheld and the checked claims are shown as related evidence.
   The second look answers `addresses_question` yes/no + `why`; "no" leads the answer with "The AI says this may not
   answer your question". Mechanical (normalised string compare), no rules understanding.
3. The two 15-minute silences of run 1 (f8855538) were the Mac's idle Maintenance Sleep (`pmset -g log`: "Entering Sleep
   state due to 'Maintenance Sleep' … 901 secs" at 05:25:29 and "… 900 secs" at 05:40:53; DarkWake at 05:40:30 and
   05:55:53) freezing the test process — not an app hang or a lost continuation. The "database not open" lines were the
   background loops of earlier, closed case ledgers (community detector, co-occurrence builder, ANN maintenance, upgrade
   and embedding drains, idle maintenance, team swarm) firing their overdue timers on wake: `AppState.shutdown()` only
   closed the database and left them running. Now shutdown stops every loop boot started before closing the ledger, the
   case's after-answer AI work (suggestions, picture) is cancelled on shutdown and on case erase, and the eval run holds an
   idle-sleep assertion. Tests: KalsmritikoshTests/AgentEvalFixesTests.swift.
