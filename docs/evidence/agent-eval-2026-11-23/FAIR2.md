# AI-50 — clean fair re-run ("fair2"): scored results (2026-11-24)

**Fair agent-simulated AI reader — blind reader, clean run; not a live AI run.**

Setup commit 8e198f81. One fresh exchange folder for both suites (build/agent-eval-fair2/, git-ignored): 213 requests,
all answered by a blind reader that saw only the requests (no keys, no fixtures, no source files, no question list in
advance); filing checks 0 MISFILED, 0 LEAK, 0 UNPARSEABLE. Flow per case: the AI case picture first (3–4 steps), then
each question through the app's own case path — agent loop, sum tool, merge, second look, claim verifier, relevance check
(`answers_question` + second-look `addresses_question`), conclusion check. Scored run: Xcode RunSomeTests 2026-11-24
08:14, `AgentReaderEvalTests/run()` + `AgentReaderHardEvalTests/run()` in one call, both passed, 0 pending requests;
console log test-console-log-2026-11-24T08-14-31+05-30.txt. **No reply was edited or re-filed and no product code was
changed.** Keys stayed outside the repo (/tmp, not committed). The scorer judged the FINAL SHOWN answer (run/<case>/qN/final.txt).

Cases: 5 hard multi-document cases (harbor, meridian, solace, vantage, kiln; 13–15 documents, 8 questions each = 40) and
the 10 real solved cases AGENT-10 names (9 public: forensic, individual, compliance, investigator, journalist,
researcher, siu, lawyer, genealogist; plus inv104) = 34 questions. 74 questions in all. For the 9 public cases the key is
per case (publisher-derived title/parties/amounts/facts, or court/date/docket/author); each question was judged against
that key and the published record (every shown quote is checked against the source by the app). forensic and individual
also have per-question keys (used). inv104 uses its hand-written acceptance key.

Scoring (same as HARD.md): **correct** = every "must" fact in the shown text, nothing on the "wrong" list; **partly** =
must facts missing or the conclusion missing/mis-framed; **confident-wrong** = a confident claim on the wrong list;
**honest not-stated** = key says not established and the app says so (counted correct); **refused-when-answer-existed**.
"(W)" = correct on the shown checked statements, but the AI's own conclusion was withheld by the app.

## 1. Totals

| | all (74) | hard (40) | real (34) |
|---|---|---|---|
| correct | **70 = 94.6 %** | **38 = 95.0 %** | **32 = 94.1 %** |
| correct with the AI's conclusion shown (or an honest "documents don't say") | 66 = 89.2 % | 37 = 92.5 % | 29 = 85.3 % |
| partly | 4 | 2 | 2 |
| confident-wrong | **0** | 0 | 0 |
| honest not-stated (key: not established) | 9 / 9 | 7 / 7 | 2 / 2 (inv104 q4, q5) |
| refused when an answer existed | 0 | 0 | 0 |

Previous fair run (HARD.md, 47 questions): 13/47 as filed; 43/47 = 91.5 % only after the scorer re-filed misfiled replies.

### Per question

| case | q1 | q2 | q3 | q4 | q5 | q6 | q7 | q8 |
|---|---|---|---|---|---|---|---|---|
| harbor | C | C | **P** | C | C | C | C | C (NS) |
| meridian | C | C | C | C | C | C | C (NS) | C (NS) |
| solace | C | C | C | C | **P** | C | C (NS) | C |
| vantage | C | C | C | C | C | C | C | C (NS) |
| kiln | C (W) | C | C | C | C | C | C (NS) | C (NS) |
| forensic | C | C | C | | | | | |
| individual | C | C | C | **P** | | | | |
| compliance | C | C | C | C | | | | |
| investigator | C | C | C | | | | | |
| journalist | C | C | C | | | | | |
| researcher | C | C | C | | | | | |
| siu | C | C | C | | | | | |
| lawyer | **P (W)** | C | C | | | | | |
| genealogist | C | C | C (W) | | | | | |
| inv104 | C (W) | C (W) | C | C (NS) | C (NS) | | | |

The four partly answers:
- harbor q3 (payment date): the shown conclusion gives 13 March from both statements and Marsh's email and the ledger's
  4 March posting, but frames the three as "agree" and the ledger as "posted earlier" — it never calls the 4 March entry a
  conflict, and the 10 March instalment point is missing. Reader framing (same miss as the previous run, softer).
- solace q5 (Iyer = Ayyar): all spellings, the flat and the brother-in-law "Rajesh Ayyar" shown; the false "no relative
  deals with the hospital" tick is not. Reader omission (same as before).
- individual q4 (runway): conclusion "They do not contradict each other: both describe runway 07" although the key counts
  the Glastar pilot's "waiting for an airplane to land on runway 25" as a difference; the facts are shown and the warning
  half is right. Reader judgment (same as before). The key's wrong list is empty, so it is scored partly, not
  confident-wrong; counted as confident-wrong it would be 1 / 74 = 1.35 per 100.
- lawyer q1 (date, court, docket): date and court shown; the true claim "The docket number is No. 8649" was dropped
  ("quote too short": the quote `No. 8649.` is 9 characters) and the conclusion withheld for 8649. App defect (§6).

## 2. Per trap type (hard set)

| trap | questions | correct | notes |
|---|---|---|---|
| round-trip money (trace / net / kept) | 9 | 9 | harbor q1 q2, meridian q1 q2, solace q1 q8, vantage q1 q2, kiln q1 (kiln q1 conclusion withheld wrongly, facts complete) |
| corrected witness | 5 | 5 | Hale, Nair/Rowe, Pillai, Walsh, Chen — every conclusion used the correction and was shown |
| date / claim-vs-record inconsistency | 6 | 5 | meridian q3, solace q3, vantage q3 q4, kiln q3 right; harbor q3 partly |
| two name spellings | 5 | 4 | harbor q5, meridian q5, vantage q6, kiln q5 right; solace q5 partly |
| "2.4 million" vs "2,400,000" | 5 | 5 | no answer invented a conflict (vantage q7 now right with its conclusion) |
| not established | 7 | 7 | none named the obvious suspect as fact (harbor q8, meridian q8, solace q7 as "documents don't say"; the rest as "Not established — …") |
| other (instalment, overcharge, title) | 3 | 3 | harbor q7, solace q2, kiln q2 |

Real cases: single-document press releases 19/19; court opinions 5/6 (lawyer q1 partly); inv104 5/5 (paid twice → no,
amended finding withdrawn; gross 100,000 / returned 50,000 / net 50,000 by the app's arithmetic; finding 2 withdrawn;
approver and namesake identity not established — all as the acceptance key).

## 3. Conclusions shown vs withheld

71 replies carried a conclusion; 66 shown, 5 withheld (the 3 "documents don't say" replies carry none). Withholding was
right in 1 of 5, wrong in 4 (all 5 conclusions were correct).

| question | reason given | right? | cause |
|---|---|---|---|
| kiln q1 | "the number 3" | **No** | conclusion "refunded by Kiln (03 Aug 26)"; `values(in:role:)` reads "Aug 26" as 26 August (month-day pattern runs first), leaving "03" a bare number, and the quote's `03/08/2026` is read month-first as 8 March. |
| lawyer q1 | "the number 8649" | **No** | the only claim with 8649 was dropped as "quote too short" (`whyNot`, fragments < 12 characters) though `No. 8649.` is the exact docket line. |
| genealogist q3 | "the number 100" | **No** | claim "one hundred percent" is read as 100 (number word + unit), but the quote's own "one hundred percent" is read in `.any` role as 1 — units are applied only on the claim side; claim dropped, conclusion withheld. |
| inv104 q2 | "the number 2" | **No** | "(two INR 50,000 debits)": "inr" is in `numberWordUnits`, so "two INR" becomes a required 2. The app's arithmetic (100,000; net 50,000) shown below the statements still answers fully. |
| inv104 q1 | "the number 50000" | Yes, by the contract | INR 50,000 was in two claims the verifier dropped because their text named "FR-12" / "INV-104" and their quotes did not; the shown text ("The amendment withdraws that finding: the second debit KS-77985 settles PO-561, invoiced as INV-109, a distinct payment" + second-look lines) still answers "no". Reader under-quoting; the drop of a document's own identifier is over-strict. |

## 4. Verifier drops, relevance, second look

- Verifier drops of correct claims: 7 question-reply claims (+6 repeats in second looks), **all true**. App defects: 2
  (lawyer q1 short exact quote; genealogist q3 "one hundred percent" in the quote not read). Contract-consistent (the
  claim carried a value its quote did not): 5 — kiln q5 ("12 Ferrier Lane" with the email quote; the address survived via
  the second look), kiln q6 ("lots 1 to 60" with "Amount claimed: AUD 2,400,000"), inv104 q1 ×2 (FR-12, INV-104 named in
  text, not in quote), inv104 q5 (account 8804 with "Authorised signatory: Arjun Mehta, director"). Only lawyer q1 lost a
  must fact.
- Relevance: 74/74 replies restated their question verbatim (`answers_question`), 0 off-question; second look
  `addresses_question` = yes in 71/71 (not-stated replies get no second look). **0 relevance warnings** — correct for a
  clean run with no misfiled reply.
- Second look added checked lines in 5/74 questions (meridian q1, kiln q1 q5 q6, inv104 q1); "nothing to add" elsewhere.

## 5. Case picture, calls, prefixes, tokens

- Picture: 61–73 records per hard case, 22–44 per real case, all origin "picture"; 0 records added by questions.
  Usefulness (strict heuristic: every proper name and ≥3-digit number of the key's "must" text present in
  picture-records.txt): 33/40 hard questions. Misses are detail the question send then read from the documents: closing
  and opening balances (harbor q1, vantage q1, kiln q1), addresses (solace q5, vantage q6), "Twenty-Four Lakh" / 800,000
  (solace q6, q2). (HARD.md's 46/47 used a looser token heuristic; not comparable.)
- AI calls per question: 151 sends / 74 = **2.04** (question + second look; +1 round for the sum tool in 6 questions —
  harbor q2, meridian q2, solace q2 q8, vantage q2, inv104 q2; 1 send for the 3 "documents don't say" replies). Picture: 4
  steps for harbor and lawyer, 3 elsewhere.
- Distinct question prefixes: **1 per case in all 15 cases.**
- Estimated input tokens (CaseReader.estimatedTokens, before prompt caching):

| case | picture | questions | total |
|---|---|---|---|
| harbor | 28,769 | 134,844 | 163,613 |
| meridian | 18,787 | 116,993 | 135,780 |
| solace | 20,193 | 134,374 | 154,567 |
| vantage | 20,097 | 134,212 | 154,309 |
| kiln | 21,233 | 127,298 | 148,531 |
| forensic | 9,705 | 21,408 | 31,113 |
| individual | 13,962 | 37,793 | 51,755 |
| compliance | 11,469 | 34,230 | 45,699 |
| investigator | 9,298 | 20,729 | 30,027 |
| journalist | 8,677 | 19,060 | 27,737 |
| researcher | 11,057 | 23,824 | 34,881 |
| siu | 13,475 | 27,848 | 41,323 |
| lawyer | 71,261 | 108,056 | 179,317 |
| genealogist | 49,437 | 99,345 | 148,782 |
| inv104 | 13,803 | 55,232 | 69,035 |

  About 7–9 k tokens per send on the hard cases (16–18 k on the two court opinions), most of it the one shared prefix.
- Whole run about 3 minutes (08:14–08:17); no stall, no "database not open" line.

## 6. Verdict against the owner's bar (clean run, no re-filing)

| bar | result |
|---|---|
| ≥ 90 % correct | **met** — 94.6 % overall (hard 95.0 %, real 94.1 %); 89.2 % if the AI's own conclusion line must also be shown |
| ≤ 1 confident-wrong per 100 | **met** — 0 / 74 |
| key multi-document questions right | **met** — 9/9 round-trip traces/nets, 5/5 corrected witnesses, 7/7 not-established; date conflicts 5/6 and name spellings 4/5 (one partly each, no wrong) |

**Bar met on the clean fair run** (agent-simulated reader, not a live AI run). Caveat: 4 correct conclusions were
withheld by over-strict mechanical checks, so the line an investigator reads first is right in 89.2 % of questions; the
checked statements underneath carried the answer in each case.

## 7. Misses diagnosed

App defects (code; none changed in this run):
1. `VerifiedAnswerComposer.values(in:role:)` (Kalsmritikosh/Brain/VerifiedAnswerComposer.swift, date patterns): "03 Aug
   26" (day, month, 2-digit year) is read as 26 August + a bare 3, and `dd/mm/yyyy` is always read month-first
   (`03/08/2026` = 8 March). Cost: kiln q1 conclusion withheld.
2. Same function, number words: units are applied only in `.claim` role, so a quote's "one hundred percent" never backs a
   claim's "one hundred percent" (100 vs 1). Cost: genealogist q3 claim dropped + conclusion withheld.
3. Same function, `numberWordUnits` contains currency codes ("inr", "usd", "eur", "gbp"): a count before a currency amount
   ("two INR 50,000 debits") becomes a required number. Cost: inv104 q2 conclusion withheld.
4. `VerifiedAnswerComposer.whyNot(_:passages:person:)` (~l. 254): quotes under 12 characters are dropped even when exact
   ("No. 8649."). Cost: lawyer q1 docket lost (the only partly answer caused by the app).
5. Over-strict, contract-consistent: a claim naming its own document's identifier ("FR-12", "INV-104") is dropped when
   the quote line does not repeat it (inv104 q1, q2 second look).

Reader errors: harbor q3 conflict not named; solace q5 false-declaration tick omitted; individual q4 runway judgment;
under-quoting in kiln q5/q6, inv104 q1/q5.

## 8. Next

Fix 1–4 (mechanical number/date reading and the short-exact-quote rule), then a live AI run when the bench key has
credit. Evidence (local, git-ignored): build/agent-eval-fair2/run/ (final.txt per question, summaries),
build/agent-eval-fair2/requests/ (213 requests + replies), console log above.

## Re-score after ALCOA (2026-11-24)

**Replay of the same blind replies on the current code (HEAD 3dc80863, after ALC-01…ALC-22); no new reader, no reply
written or edited, no product code changed.** Xcode RunSomeTests 2026-11-24 22:02, `AgentReaderEvalTests/run()` +
`AgentReaderHardEvalTests/run()` in one call, both passed; console log test-console-log-2026-11-24T22-02-48+05-30.txt.
Same 213 request names, 0 pending, filing checks 0 MISFILED / 0 LEAK / 0 UNPARSEABLE. Scored against the same keys
(/tmp/agent-eval-keys-staging/) exactly as §1–§4.

### Did the requests change? Yes — this is a replay, not a clean blind run

The harness reads a reply by file name only, so a reply is reused even when its request text changed. Of 213 requests:

| change | requests | kind |
|---|---|---|
| identical | 65 | — |
| record ids only (`R-xxxxxxxx` in tool results) | 19 | mechanical |
| same lines, different order (briefing people/date lists) | 54 | mechanical (kiln, meridian, solace, vantage) |
| **sum-tool / briefing money lines changed (ALC-03)** | 56 (+2 with the next row) | **real** — harbor, vantage, compliance, forensic, researcher: every question and second-look request (26 questions) |
| **picture-loop rejection reasons changed (ALC-22 checker)** | 9 (+2 siu) | **real** — genealogist, kiln, inv104, lawyer, siu picture rounds r1–r3 |
| second look's "Answer given" changed (the app now shows a different answer) | 5 (+2) | real, downstream of the fixes — genealogist q3, kiln q1, meridian q1, inv104 q2, lawyer q1, harbor q1, vantage q2 |
| siu briefing name "Ferrer" → "Mr. Ferrer" | 1 (+2) | real |

**75 requests carry real content changes**, e.g. harbor q1: `Paid: USD 180,000 + USD 95,000 + USD 180,000 = USD 455,000`
→ `Paid: 180,000 + 95,000 + $180,000 (currency unclear) = 275,000; $180,000 (currency unclear)` ($ no longer assumed USD);
vantage: `EUR 500` / `EUR 550` (comma-decimal misread) → `EUR 500,000` / `EUR 550,000`. The replies were written against the
old texts, so this re-score shows what the current checker and composer do with the same replies; **a fresh blind reader is
needed for a clean score on the current code.**

### Totals, before vs after (same replies)

| | before (§1) | after |
|---|---|---|
| correct (all 74) | 70 = 94.6 % | **71 = 95.9 %** |
| hard (40) / real (34) | 38 / 32 | 38 / **33** |
| correct with the AI's conclusion shown (or an honest "documents don't say") | 66 = 89.2 % | **68 = 91.9 %** (hard 36 = 90.0 %, real 32 = 94.1 %) |
| partly | 4 | **3** (harbor q3, solace q5, individual q4 — reader errors, unchanged) |
| confident-wrong | 0 | **0** |
| honest not-stated | 9 / 9 | 9 / 9 |
| refused when an answer existed | 0 | 0 |

64 of 74 shown answers are byte-identical to before; 3 differ only in run timing. The 7 that changed:

| question | before | after | why |
|---|---|---|---|
| lawyer q1 | P (W) | **C** | ALC-22: the exact short quote `No. 8649.` is kept; docket and conclusion now shown |
| kiln q1 | C (W) | **C** | ALC-22: "03 Aug 26" read as one date; conclusion shown |
| genealogist q3 | C (W) | **C** | ALC-22: quote-side "one hundred percent" = 100; claim kept, conclusion shown |
| inv104 q2 | C (W) | **C** | ALC-22: "two INR 50,000" is a count word; conclusion shown |
| harbor q1 | C | **C (W)** — regression | new: conclusion withheld "the date in it is not in any checked quote" |
| meridian q1 | C | **C (W)** — regression | same new cause |
| vantage q2 | C | C | one true claim newly dropped (below); conclusion and must fact (€100,000) still shown |

### Conclusions shown vs withheld

71 replies carried a conclusion; **68 shown, 3 withheld** (before 66 / 5). Withholding right in 1 (inv104 q1, unchanged:
INR 50,000 only in claims dropped for naming FR-12 / INV-104), wrong in 2 — both new:

- harbor q1 "…reached Bluewater on **13 Mar, 95**,000.00 was wired…" and meridian q1 "…S McGillan on **30 Apr, 40**,000.00
  to Garside…": the ALC-22 day–month–year pattern in `VerifiedAnswerComposer.values(in:role:)`
  (`…monthAlternation + ",?\s+(\d{4}|\d{2})(?![\d:])"`) takes the first two digits of the following amount as a 2-digit
  year (13 Mar 2095, 30 Apr 2040), a date no quote carries. The lookahead should also refuse a following `,`/`.` digit
  group. All must facts are still in the checked statements, so both stay correct. App defect, introduced by ALC-22.

### Verifier drops, second look

- Drops of correct claims: 6 question-reply claims (+4 repeats in second looks), before 7 (+6). Gone: lawyer q1 and
  genealogist q3 (the two app defects of §4). New: vantage q2 "The balance at 30/09/2026 was 1,800,000.00 after the
  600,000.00 release" with the 03/09/2026 statement row — true (no transaction until 02/10), but the quote does not carry
  30/09, so contract-consistent. Still dropped, contract-consistent: kiln q5, kiln q6, inv104 q1 ×2, inv104 q5. **App-defect
  drops: 0; no must fact lost.**
- Second look added checked lines in 7/74 questions (before 5): + genealogist q3, lawyer q1.
- Relevance: 74/74 restated their question; 0 relevance warnings.

### Provenance (ALC-02, ALC-13)

RunSomeTests 22:11, all executed (not cached): `ALCOAGroup2Tests/attributedRunsAndRecords()` — a question through the
real answer service opens a `picture` and a `question` row in case_ai_runs (provider, model requested and served, fallback
labelled, requester, input versions, coverage, call and token usage, prompt version); every AI record carries run_id
(linked to its run), model requested/served, requester, prompt version and a 64-hex request SHA-256.
`runIsFixed()` — a finished run cannot be edited. `ALCOAGroup4Tests/integrityReport()` — the Data integrity report
builds for one case: twelve principles, chain intact, custody and intake SHA-256 per document, vault re-hash, AI runs with
model and prompt version, access events, revisions, what the picture did not read; never says "compliant". All 3 passed.
(The eval harness itself does not print run ids; the eval cases run the same path these tests drive.)

### Verdict

Same replies on the current code: 95.9 % correct, 0 confident-wrong, AI conclusion shown in 91.9 % (bar of §6 still met).
The four FAIR2 checker defects are fixed; one new one (2-digit year taken from a following amount) withholds two correct
conclusions. Because 75 requests changed in content (money lines, rejection reasons), this is not a clean blind score —
re-run with a fresh blind reader after fixing the new date defect.
