# AI-50 — fair run 6 ("fair6"): scored results (2026-11-26)

**Fair agent-simulated AI reader — blind reader, clean run incl. 24 unseen real public cases from the US, UK, EU,
Australia, Canada and New Zealand; not a live AI run.**

Code: setup commit d0fad5c7 = current code after D1–D6 (D1 cbb5d843 + 1ba4cc5e references and labels are not figures,
D2 f6eefaa3 + 6444133c compare_dates day counts are the app's arithmetic, D3 e907ca65 one movement recorded twice in one
document counted once, D5 024f2503 date-shaped case numbers are identifiers, D6 3e670d2f discrepancy lines keep their key
part). One fresh exchange folder for both suites (build/agent-eval-fair6/, git-ignored): **677 requests, all replied by
a blind reader** that opened only the requests (READER_INSTRUCTIONS.md); every request was new for this reader. Scored
run: Xcode RunSomeTests 2026-11-26 17:53, `AgentReaderEvalTests/run()` + `AgentReaderHardEvalTests/run()` in one call,
both passed; console log test-console-log-2026-11-26T17-53-33+05-30.txt (784,717 lines), collected line by line
(extract.py); 0 pending; 0 MISFILED / 0 LEAK / 0 UNPARSEABLE in all 39 cases; 1 distinct question prefix per case.
**No reply was written, edited or re-filed by the scorer and no product code was changed.** Keys stayed outside the
repo (build/agent-eval-keys/, git-ignored; never committed). The scorer judged the FINAL SHOWN answer
(run/<case>/qN/final.txt: conclusion, checked statements, the app's arithmetic, "Also worth checking", NOTES).

Cases (39, 259 questions): hard (5 fictional, 40 q), earlier real (10, 34 q), real3 (6, 46 q), real4 (6, 46 q), intl5 (6,
47 q) as in FAIR5, plus **NEW mix6** (6 public cases never seen by the reader or the harness, 46 questions;
KalsmritikoshTests/Fixtures/AgentEvalMix6, sources in MIX6_SOURCES.md): mix6-midway (US DOJ, health-care / Medicare
fraud, 4 releases), mix6-bec (US SDNY, business-email-compromise, 3 releases, "$100 million" vs "$120 million"),
mix6-crash (UK CPS, insurance crash-for-cash, 2 releases, £), mix6-brandon (Canada Competition Bureau, bid-rigging, 2
releases, C$), mix6-sharma (New Zealand SFO, Indian names, 5 documents, NZ$), mix6-glencore (UK SFO, bribery, 4
documents, $ and £).

Scoring is FAIR5's, unchanged: **correct** = the must facts that answer what the question asks are in the shown text
(incl. the app's arithmetic lines) and nothing on the wrong list; **partly**; **confident-wrong**; **honest not-stated**
counts as correct; **refused-when-answer-existed**. (W) = the AI's conclusion withheld by the app. Strict side score: every
element of every key "must".

## 1. Totals

| | all (259) | hard (40) | earlier real (34) | real3 (46) | real4 (46) | intl5 (47) | **NEW mix6 (46)** |
|---|---|---|---|---|---|---|---|
| correct | **252 = 97.3 %** | 38 = 95.0 % | 34 = 100 % | 45 = 97.8 % | 45 = 97.8 % | 46 = 97.9 % | **44 = 95.7 %** |
| partly | 7 | 2 | 0 | 1 | 1 | 1 | 2 |
| confident-wrong | **0** (see sensitivity) | 0 | 0 | 0 | 0 | 0 | 0 |
| honest not-stated (key: not established) | 33 / 33 | 7 / 7 | 2 / 2 | 6 / 6 | 6 / 6 | 6 / 6 | 6 / 6 |
| refused when an answer existed | **0** | 0 | 0 | 0 | 0 | 0 | 0 |
| **strict, every key element** | **237 = 91.5 %** | 34 = 85.0 % | 34 = 100 % | 44 = 95.7 % | 42 = 91.3 % | 45 = 95.7 % | 38 = 82.6 % |

- Same 213 questions as FAIR5, fresh blind replies: **208 / 213 = 97.7 %** (FAIR5 first run 202 = 94.8 %; FAIR5 §9 same
  old replies after D1–D6 209 = 98.1 %). Now right: harbor q3 (first time in six runs). Still partly: solace q5,
  vantage q1, 4x q3. Newly partly: archcoal q6, cook q6 (both reader framing).
- 5 of 7 misses are reader errors (verdict word or framing), 1 is the key / G5 rounding rule (4x q3, third run), 1 is a
  reader framing plus an app withhold (archcoal q6, D7). **No miss is caused by the app dropping a true claim.**
- Sensitivity: midway q2 ("the releases differ on Dagnesses and del Cueto") and 4x q3 ("differs by more than rounding")
  call a non-conflict a difference; counted as confident-wrong they are 2 / 259 = 0.8 per 100.

### Per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C (s) | C | **C (s)** | C | C | C | C | C (NS) |
| meridian | C | C | C | C | C | C | C (NS) | C (NS) |
| solace | C | C | C | C | **P** | C | C (NS) | C |
| vantage | **P** | C | C (W, s) | C | C | C | C | C (NS) |
| kiln | C (s) | C | C | C | C | C | C (NS) | C (NS) |
| 10 earlier real | all 34 C (inv104 q2 W; inv104 q4, q5 NS) | | | | | | | |
| real3-archcoal | C | C (W) | C | C | C | **P (W)** | C | C (NS) |
| real3 carpenter / jfk / jha / k2 / valenti | all 38 C (jha q4 s; valenti q3 W; 5 NS) | | | | | | | |
| real4-4x | C | C | **P** | C | C | C (NS) | | |
| real4 autoland / leondi / mayfield / newark / stoddard | all 40 C (autoland q5 s; leondi q7 W, s; newark q6 W, s; 5 NS) | | | | | | | |
| intl5-cook | C | C | C | C | C | **P** | C (NS) | |
| intl5 barclays / berndale / ethical / eurocartel / siddiqui | all 40 C (ethical q3 W; ethical q7 s; siddiqui q3 W; 5 NS) | | | | | | | |
| **mix6-midway** | C | **P** | C (W) | C | C | C | C (s) | C (NS) |
| **mix6-bec** | C (s) | C | C | C | C | C | C (NS) | |
| **mix6-crash** | C | C | C (W, s) | C (s) | C | C | C | C (NS) |
| **mix6-brandon** | C | C (s) | C | C | C | C | C (NS) | |
| **mix6-sharma** | **P** | C | C | C | C | C | C | C (NS) |
| **mix6-glencore** | C | C | C | C | C | C | C (s) | C (NS) |

(s) = strict miss; NS = not established, answered honestly; W = conclusion withheld, answer judged on the rest.

## 2. Per trap type

Hard set:

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | 8 | **vantage q1 P** (no "kept" figure, though the app's table now has both right — §3) |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh, Chen |
| date / claim-vs-record | 6 | **6** | **harbor q3 now right**: bank 13 Mar vs ledger 4 Mar, "the records disagree" |
| two name spellings | 5 | 4 | **solace q5 P** (false "No" tick omitted again); harbor q5, meridian q5 now name one person |
| "2.4 million" vs "2,400,000" | 5 | 5 | |
| not established | 7 | 7 | |
| other | 3 | 3 | |

Real sets:

| trap | real3 | real4 | intl5 | **NEW mix6** | notes |
|---|---|---|---|---|---|
| not established | 6 / 6 | 6 / 6 | 6 / 6 | **6 / 6** | unnamed victims (bec), del Cueto's sentence, Emin's sentence, the five firms, restrained funds, Glencore verdicts |
| release vs release, real difference | 2 / 2 | 4 / 4 | 4 / 4 | **3 / 3** | **bec $100M vs $120M**, brandon 89 / $4.5M vs 54 / $3.5M, sharma case page omits money laundering |
| wording / rounding / scope, not a conflict | 1 / 2 | 1 / 2 | 4 / 4 | **3 / 5** | archcoal q6 P, 4x q3 P; **midway q2 P, sharma q1 P**; midway $20M vs $10M (scope), glencore 5 → 6 (added later), crash £18,415 vs £33,362 right |
| scheduled vs actual date | 3 / 3 | 2 / 2 | 4 / 4 | **3 / 3** | bec 24 Jul → 19 Dec 2019, midway Rodriguez as scheduled, sharma trial 8 Sep 2025 vs pleas |
| money trace / flow | — | 4 / 4 | 4 / 4 | **1 / 1** | bec Latvia / Cyprus → six countries |
| arithmetic / reconcile | 4 / 4 | 5 / 5 | 4 / 5 | **4 / 4** | midway USD 21,847,000; bec USD 76,217,638.65; brandon CAD 196,000; sharma NZD 1,420,000 ≈ $1.4M; **cook q6 P** ("Yes, it covers it") |
| one name, two spellings / other names | 1 / 1 | 4 / 4 | 3 / 3 | **2 / 2** | Ghanaseelan / Gnanaseelan; Neha Sharma née Chandrasekaran |
| inconsistency inside one document | 1 / 1 | 2 / 2 | — | **2 / 2** | glencore case page 21 June vs 3 Nov 2022 for the £280M order; midway strike-force counts |
| different currencies, no rate | — | — | — | **1 / 1** | glencore £280M vs "$25 million": not compared as one currency |
| relative date | — | — | — | **1 / 1** | brandon "Yesterday" in the 6 Feb 2025 release |
| witness / account vs record | 3 / 3 | 1 / 1 | — | — | |
| other facts | 24 / 24 | 16 / 16 | 17 / 17 | **18 / 18** | |

## 3. Did D3 (in-document dedupe) and D6 (discrepancy lines) help? (first fresh blind measurement)

| item | FAIR5 | fair6 | helped? | evidence |
|---|---|---|---|---|
| **D3** Money by party, one line recorded from both sides | double in harbor, meridian, solace; Tidewell kept −450,000 | harbor Bluewater kept 180,000 − 155,000 = 25,000; vantage **Ardmore 50,000 and Tidewell 50,000 (both right)**; kiln Pemberton 70,000; meridian Larkfield ****3307 20,000; solace Medline 50,000 | **yes** | no reader this run said "the app's party totals count each wire twice" (FAIR5: harbor q1/q2, solace q1). vantage q1 is still P — the reader omitted the (now correct) kept figures. |
| D3 residual (D3b) | — | meridian HOLLINS 2,400,000 + 2,400,000 = 4,800,000 and solace hospital INR 4,800,000 (one record dated, one undated, other document); Vitalair "kept 2,850,000"; meridian Larkfield split into a name entry (kept 210,000) and an account entry | partly | no score cost (readers ignored these lines); fix in §6 |
| **D6** discrepancy line keeps its key part | harbor line cut at "6 days befo…" | harbor line complete: "2026-03-04 is 6 days before the 2026-03-10 payment (NORTHGATE PORT…)"; berndale Kirby 10 vs 15 July complete; 2 discrepancy lines in 39 cases, both genuine | **yes (line); answer only partly** | harbor q3 is right for the first time (conflict named), but the reader did not use the "before the 10 Mar instalment" part (strict miss) |

## 4. Universality evidence from mix6 (health care, insurance, cyber/BEC, Canada, New Zealand, UK $ + £)

- **Health care (midway, US):** "$12.4 million" + "$5.1 million" + "$3.6 million" + "$747,000" summed exactly (USD
  21,847,000); the $20 million (all clinics) vs $10 million (Midway alone) scope difference explained; the four
  strike-force running totals (107/196 … 115/257) listed. Miss: the March 23 four-plea list vs the June six-plea list
  called a difference (midway q2, reader).
- **Insurance (crash, UK):** the Citroen occupants from both releases, £18,415 (one claimant) vs £33,362 (five claims)
  kept apart, two outcomes per defendant, the spelling Ghanaseelan / Gnanaseelan surfaced.
- **Cyber / BEC (bec, US SDNY):** "$100 million" (2017, March 2019) vs "$120 million / $120,000,000" (December 2019)
  flagged as a real difference between releases; 20-year vs 30-year wire-fraud maximum shown from the two releases;
  forfeiture $49,738,559.41 + restitution $26,479,079.24 = USD 76,217,638.65 to the cent; scheduled 24 July vs actual
  19 December 2019.
- **Canada (brandon):** a bare "$" in Canadian releases read as CAD (CAD 196,000 = the stated combined fines); "Yesterday"
  resolved against the release date; the plea (Competition Act s.45 only) vs the charge (also Criminal Code fraud).
- **New Zealand with Indian names (sharma):** Neha Sharma (née Chandrasekaran) and Amandeep Sharma kept apart per charge
  and sentence; the case page's missing money-laundering pleas found; NZD 2,100,000 − 680,000 = 1,420,000 ≈ "$1.4
  million"; $791,500 vs "almost $800,000" joined. Miss: "just over $2 million" vs "just over $2.1 million" called
  "slightly different" (sharma q1, reader).
- **UK with $ and £ (glencore):** "$25 million" bribes and "£280 million" order not compared as one currency; the case
  page's own inconsistency (order on 21 June vs 3 Nov 2022) found; five charged → six (Perez added) not called a
  conflict.
- Where universality still breaks (app side, no score cost this run): a year RANGE naming documents ("the 2018–2019
  releases") is not read as a label (D7); a yearless month in a quote is not completed by the document's year (D8).

## 5. Conclusions, drops, calls, tokens

- **Conclusions: 237 replies carried one (11 of them "not stated"); 226 shown = 95.4 %, 11 withheld, 0 answers lost**
  (FAIR5: 177 / 193 = 91.7 %, 5 lost). The 22 other answers are the app's "documents don't say" for not-established
  questions. Withheld because of: a year range naming documents (archcoal q6, leondi q7, newark q6 — D7), a yearless
  month completed with its year (ethical q3 — D8), a gross subtotal not in the arithmetic (inv104 q2 — D9), and — by
  contract — a fact the reader put in the conclusion but in none of its quotes (archcoal q2, valenti q3, crash q3,
  vantage q3, siddiqui q3, midway q3).
- **Verifier drops: 11 of 709 question-reply claims, 0 of 101 second-look claims** (FAIR5: 42 and 83). All are a value
  not in the claim's own quote (e.g. "97" months, a timeline date on the line above the quoted row, "page 1"); none lost a
  must fact. **0 D1-type drops** (FAIR5: 33).
- **Relevance warnings: 0. "Stopped early": 0.** 1 distinct question prefix per case.
- **AI calls per question: 517 question sends / 259 = 2.00** (280 question + 237 second look). Plus 121 picture steps and
  39 background suggestion reads: 121 + 280 + 237 + 39 = 677.
- **Estimated input tokens (sum of the question and picture sends' estimates, before prompt caching; the 39 suggestion
  reads not included): 5.41 M for the run, 139 k per case** — hard 151–177 k (avg 163 k), earlier real 26–162 k (avg 65 k),
  real3 98–262 k (avg 173 k), real4 75–322 k (avg 195 k; newark 322 k), intl5 75–208 k (avg 151 k), **mix6 92–200 k (avg
  138 k)**: sharma 200 k, midway 196 k, bec 130 k, crash 111 k, glencore 97 k, brandon 92 k.

## 6. Misses diagnosed (full list: build/agent-eval-fair6/misses.md, local)

Reader errors (5): solace q5 (false "No" tick omitted although the briefing's Conflicts lists it), vantage q1 (kept
figures omitted although D3's table now has both right), cook q6 ("Yes, it covers it" to "does it match"), midway q2
(the March release's four same-day pleas vs the June release's six called a difference), sharma q1 ("slightly different
figures" for "just over $2 million" / "just over $2.1 million").

Key / design (1): 4x q3 — G5 reads "approximately $2.8 million" at its stated precision (2.75–2.85 M), so $2,745,226 is
outside; the key wants "consistent (allegation vs court finding)". Third run with the same answer: a key or G5-rule
decision for the owner.

Reader + app (1): archcoal q6 — reader framing ("they do not agree on the total") plus D7.

App defects found (none changed in this run; each fix general, with negatives):
1. **D7 — a year range naming documents is not a label** ("the 2016–2017 Lusk releases", "the 2018–2019 releases"):
   `VerifiedAnswerComposer.referencePatterns` `dates` (l.811–818) joins dates only with `,` `&` `and` `or`.
   **Fix:** accept `–`, `—`, `-`, `to`, `through` between years; blank only when every year is a sent document's own year.
   Cost: 3 conclusions withheld (archcoal q6, leondi q7, newark q6).
2. **D8 — a yearless month in a quote vs "May 2026" in the conclusion**: `conclusionWithheld` → `valueMissing` (l.1432).
   **Fix:** a month + year is supported when a checked quote of a cited document has that month without a year and the
   year is that document's own year. Cost: ethical q3 withheld.
3. **D9 — a sum with `minus` shows no gross subtotal**: `CaseAgent.sum(_:)` (CaseAgent.swift l.1030–1056) appends only the
   final expression. **Fix:** also append the plus subtotal (and the minus subtotal with ≥ 2 minus terms). Cost: inv104 q2
   withheld ("INR 100,000 went out").
4. **D3b — Money by party: undated cross-document duplicate and name / account split**: `CaseAIUnderstanding.partyFlows`
   `duplicate` (l.317–324) and the party union (l.282–293). **Fix:** merge an undated record with the ONE dated record of
   the same amount, currency, payer and payee in another document when no reference contradicts it (two candidates:
   keep both, say "may be the same"); join "NAME" with "NAME ****NNNN" when no other tail is seen for that name. No score
   cost this run.
5. **D10 — G5's rounding note on a subtraction of two different quantities** (sharma q6 "$1.4 million is below it
   (outside …)" under 2,100,000 − 680,000): `CaseAgent.sum(_:)` l.1057–1059. **Fix:** add the note only when the two
   figures could be one amount written twice (within the coarser figure's precision band or 10 %). No score cost.

Design gaps carried: the conclusion check withholds a whole conclusion for one fact the reader did not quote (6 this run,
all still correct on the rest) — option: show it with the unsupported part struck out; the day/month order of a
one-date document is still shown as "2026-08-06 or 2026-06-08" in Money by party.

## 7. Verdict

| bar | result |
|---|---|
| owner's goal 99 % | **not met** — 97.3 % (252 / 259); the 7 misses are 5 reader errors, 1 key / G5-rule question, 1 reader + D7. App fixes D7–D9 would not change the score of this run (they unblock 5 conclusions; archcoal q6 would stay partly) |
| ≥ 90 % correct | **met by every set** — hard 95.0 %, earlier real 100 %, real3 97.8 %, real4 97.8 %, intl5 97.9 %, **NEW mix6 95.7 %**; strict 91.5 % (mix6 strict 82.6 %, hard 85.0 %) |
| ≤ 1 confident-wrong per 100 | **met** — 0 / 259 (0.8 / 100 if midway q2 and 4x q3 are counted) |
| key multi-document question right | **yes, mostly** — round trips 8 / 9, corrected witnesses 5 / 5, spellings 4 / 5, "2.4 million" 5 / 5, date conflicts 6 / 6, release-vs-release real differences 13 / 13, not-established 33 / 33; wording / rounding traps 9 / 13 (the weak spot) |

**Bar met on every set, including the six new cases from new domains and countries (95.7 %), with 0 confident-wrong,
0 refused, every not-established question answered honestly and 95.4 % of conclusions shown — but the owner's 99 % is
not reached (97.3 %).** This is the first fresh blind round after D1–D6: D1 removed every label drop (0 of 33), D3 made
the party table right in every case that FAIR5 found double-counted, and D6's complete discrepancy line came with the
first correct harbor q3. The remaining misses are mostly the reader calling a wording / rounding / scope difference a
difference (4 of 7): the app's evidence was in the shown text each time. Agent-simulated reader, not a live AI run.

## 8. Next

Fix D7, D8, D9 (conclusions), D3b and D10 (briefing tables) with property tests and negatives; decide the 4x q3 key vs
G5 rule; consider a briefing hint for scope / rounding differences ("a release may report only that day's events";
"just over $2 million" and "just over $2.1 million" can both be true) — a hint, not a decider. Then a fresh blind round
with k = 3 readers per case to separate reader variance from app effects, and a live AI run when the bench key has
credit. Evidence (local, git-ignored): build/agent-eval-fair6/run/ (final.txt per question, briefing-after-picture.txt,
picture-records.txt, picture-steps.txt, summaries), build/agent-eval-fair6/requests/ (677 requests + replies),
build/agent-eval-fair6/misses.md, console log above.
