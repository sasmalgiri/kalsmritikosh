# Real-case evaluation, second arm — the pipeline WITH Opus 5 (Online), as wired today

**AGENT-run** (AI judge, no human review) · **Date:** 2026-11-03 · **App build:** `c3e8c5b0` (branch `investigations-next`), the same clean worktree and prebuilt test host as the first arm (`~/CaseBench/src-wt-c3e8c5b0`, `~/CaseBench/dd-final`).

**Arm:** the app's real pipeline (ingest → ledger → Ask; then the case opened as an investigation: custody, contradictions, gaps, findings) with the Online cloud steps on and `claude-opus-5` on the owner's key. `round-opus5.sh` sets `TEST_RUNNER_CASEBENCH_CLOUD_KEY_FILE` / `_CLOUD_MODEL=claude-opus-5` / `_CLOUD_EXTRACT_MODEL=claude-opus-5`.

How it is wired, verified in code (read-only):
- `KalsmritikoshTests/CaseBenchRunner.swift:256-270` installs three cloud parts on the archive-wide brain:
  - `CloudQuestionInterpreter`: chooses which fact field answers a question;
  - `CloudQuestionRewriter`: rewrites an unrecognised wording into a canonical form;
  - `VerifiedRecordExtractor`: reads a person's documents for charged/pleaded/sentenced/when questions.
- **Rewriter.** Wording only goes to the model. `QuestionCanonicalizer.canonicalize` runs only when the phrase rules do not recognise the question (`Brain/MasterBrain.swift:1698`).
- **Interpreter.** Wording plus the field names go to the model. `QuestionUnderstanding.interpret` runs only when the rules could not place the question, or placed it on a "weak" field (date, amount, status, …). Its choice is stored in a process-wide table that `SlotFieldResolver.resolve` reads (`Brain/QuestionUnderstanding.swift:94-138`, `Retrieval/SlotFieldResolver.swift:430`).
- **Extractor.** Document text goes to the model. Its answer is shown only if every check in `VerifiedRecordExtractor.verify` holds; otherwise `return nil` and the rules answer stands (`Brain/MasterBrain.swift:2213-2225`, `Brain/VerifiedRecordExtractor.swift:84-188`).
- **No model-written composition anywhere.** Every body is a template plus a verbatim quote.
- **The case-scoped brain gets none of the three cloud parts.** `App/AppState.swift:2494-2502`; the harness records in-case calls as `aiCalls: [:]`.

**Material** (`~/CaseBench/realcase/`):
- `keys/<case>.json`: sealed outcomes.
- `runs-opus5/<case>/r1..r5/answers.md`: 30 valid rounds (no INVALID/INCOMPLETE flags) plus `rc-f…/smoke-o`.
- `memos/app-opus5/<case>.md`: three fresh investigator agents, one per case, ≤5 rounds each, app only.
- For comparison:
  - the first arm, `runs/`, `memos/app/`, scored in `docs/agent-reviews/real-case-evaluation-2026-11-03.md`;
  - the reading baseline, `memos/baseline/`, used only as a reference for what the documents allow.

**Method:**
1. Six AGENT sub-judges, one per case, scored every Ask and in-case answer against the key (found / found-but-wrong / missed / refused wrongly). They also:
   - listed distinct wrong statements at normal confidence, traps and must-not-conclude items, and the workflow block;
   - checked every failure the memo quotes against `answers.md`;
   - scored the final memo against the key.
2. I did the model-contribution analysis myself:
   - parsed all 1,990 answer blocks of both arms (`/tmp/rcj/parse.py`);
   - counted Claude calls, rewrites (`_(answered as: …)_`) and extractor answers. An extractor answer has confidence 0.85, one citation, the extractor's body template and ≥1 call; this signature cannot be produced by `ProceedingAnswerer`, whose maximum is 0.8.
   - compared every question asked word-for-word in both arms (49), and every Ask-vs-in-case pair that used the cloud (48);
   - read the code paths, read-only.
3. I spot-checked sub-judge quotes against `answers.md`; all checked matched.

**Contamination status:**
- **This arm is not contaminated by the outcome table.** `README-opus5.md` has no outcome table (verified), so the memos count as independent work.
- **Memory caveats, disclosed by the investigators themselves:**
  - C: "I recognise this accident … These map closely onto what I remember of the official finding".
  - D: "I recognise this episode"; it flags its outside-knowledge points.
  - E: recognised in general terms only.
  - A, B and F: no recognition.
- **C's cause ranking therefore cannot be fully credited to the app.** Fact scoring is unaffected, because every memo fact was traced to an app answer.
- **The first arm was contaminated** (its README carried the outcomes). Its memos were not credited as independent; its answer scoring is valid.

**Limits:**
1. **n = 6 cases, one investigator agent per case per arm, no humans.**
2. **Harness, not GUI.** ACH, Watchlists, deconfliction, the chronology and timeline export were not exercised.
3. **The two arms asked different questions.** Only 49 questions recur word-for-word, so arm-to-arm differences in facts found mix the model's effect with the investigators' wording. I separate them in section 3.
4. **The model's raw replies are not logged.** Where an extractor call produced no shown answer, I cannot tell whether the model returned null, returned an unverifiable quote, or the call failed.
5. **Counting.** Sub-judges counted wrong statements and non-answers slightly differently. Use the counts as direction, not as precise rates.
6. **The run footer reads "AI model: none (rules path)"** in every round, because the harness sets `NOAI=1` alongside the cloud key. That is a harness label. The call counts show the cloud was used.

---

## 1. Totals

| | key facts | found | found but wrong | missed | refused wrongly |
|---|---|---|---|---|---|
| **App answers, Opus 5 arm** | 77 | **59** (about 20 partial) | **6** | **10** | **2** |
| App answers, rules arm (first report) | 77 | 50 (many partial) | 6 | 16 | 5 |
| **Investigator memo, Opus 5 arm** (uncontaminated) | 77 | **62** (about 12 partial) | **1** | **14** | — |
| Investigator memo, rules arm (README-contaminated) | 77 | 57 | 3 | 17 | — |
| Reading baseline (README-contaminated) | 77 | 76 | 0 | 1 | — |

Per case, app answers in the Opus arm:

| case | found / wrong / missed / refused wrongly |
|---|---|
| A | 8 / 1 / 3 / 1 |
| B | 6 / 2 / 2 / 0 |
| C | 12 / 0 / 1 / 0 |
| D | 12 / 1 / 2 / 0 |
| E | 11 / 1 / 0 / 0 |
| F | 10 / 1 / 2 / 1 |

**Other measures, Opus 5 arm:**
- **Wrong statements at normal confidence (not refused):** about 76 distinct (A 7, B 11, C 7, D ~24, E ~20, F 7). The rules arm had 108 distinct, but its question set was larger and different.
- **Non-answers presented as answers:** about half of all Ask answers (≈ 230 of 467): defence-counsel or "Hutchins:" cards, off-target "(Quoted verbatim from the cited document; no model was consulted.)" passages, false "conflicting values" dumps, and "Interceptthatcourseat1100" junk.
- **Refusals:** about 22 wrongful against 7 correct. The rules arm had about 36 against about 10.
- **Workflow contradictions flagged:** 0 in 30 of 30 runs. **0 of the 4 keyed contradictions** (A transacting-in-proceeds; F $75k vs $50k, who spread the fuel, which camera). This is identical to the rules arm; no model touches the workflow.
- **Effort:**
  - Opus arm: 30 rounds, 467 Ask questions (plus 2 smoke), each also answered in-case.
  - Rules arm: 30 rounds, 523 questions (plus 3 smoke).
  - Baseline: about 70,000 words read, about 2–2.5 h human-equivalent.

**The headline gain (+9 facts found, −6 missed) is mostly not the model's** (section 3). The investigators asked in the documents' own words, by e-mail subject and by record ID. Wording-for-wording, the cloud steps moved **one** key fact from wrong to right: A #9, Mignott's three years.

---

## 2. Per-case scorecards

### A — rc-a-upfront-fee (13 key facts; 5 rounds, 70 questions; 54 Ask answers used Claude, 78 calls)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 8 (#1, #3, #5, #6, #9 in Ask, #11, #12, #13) | 1 (#10) | 3 (#4, #7, #8) | 1 (#2: r3 q09 "don't mention the lies") |
| Memo | 9 (#1, #3, #5, #6, #8, #9, #11, #12, #13) | 1 (#10 "Jun 23, 2023: Gillar and Mignott sentenced") | 3 (#2, #4, #7) | — |

**Wrong statements, 7 distinct:**
1. **#10, an explicit falsehood.** r2 q08: "The document dated June 23, 2023 reports that Harold Mignott was sentenced; it gives no other day". Release-04 says "imposed the sentences on June 22, 2023".
2. **Release dates given as event dates.** r1 q11, r3 q01, r3 q04 and r5 q10: "October 24, 2022 — convicted" (the verdict was Oct. 21), and "June 23, 2023 — sentenced".
3. **A conviction invented.** r3 q05 (0.7): "Jerrid Douglas was convicted on October 21, 2022 and again on October 24, 2022".
4. **A misleading "Yes" on Adkins.** r3 q14 asked whether any record shows Adkins tried, convicted, sentenced or dismissed: "Yes — “…were indicted today on additional charges…”".
5. **A false amount conflict, 7 times.** r1 q03, r1 q15, r3 q13 and r4 q01/q04/q10/q11: "conflicting values for amount: • $250,000 • $800,000 • $90,000". These are three victims' payments.
6. **The in-case rules answer still gives the wrong term.** r2 q06: "Harold Mignott was sentenced to six years in prison". The Ask answer is right.
7. **Either/or answered "No —".** r1 q08.

**Non-answers and refusals:**
- About 35 of 70 were non-answers, including 11 defence-counsel lines, e.g. r2 q10 "What were Mignott, Douglas and Gillar convicted of?" → "Mignott: Eric Breslin Esq., Newark."
- Refusals: 9 wrongful (the role questions r1 q04–q07, the restitution questions r2 q13/q14, among others); 2 correct (Adkins: r1 q09, r2 q05).

**Traps and must-not-conclude:**
- **Avoided:**
  - Adkins's outcome, borderline at r3 q14;
  - the pleas;
  - "Douglas sentenced in June" (r1 q14 gives "scheduled to be sentenced on July 26, 2023").
- **Fell in:**
  - the transacting-in-proceeds inconsistency (no answer mentions "criminal proceeds");
  - June 23 for June 22.

**Workflow block (the same in r1–r5):**
- "contradictions found: 0; gaps found: 0". There is no gap for Adkins, who was charged and has no disposition.
- The judge is listed as a defendant: "On 2018-04-15 — John Michael Vazquez charged", "On 2022-10-23 — Judge John Michael Vazquez convicted".
- Anchor dates are one day early.
- "Roy Gillar" and "Roy Johannes Gillar" are split into two people.

**Memo claims checked:** all confirmed except two.
- It marks the correct "2023-06-22 — Gillar sentenced" as wrong.
- It says the in-case answers are "word-for-word the same" and the calls "bought nothing visible". Both are rejected: r2 q06 differs (Ask three years, case six), and so do r1 q08, r3 q08 and r5 q02.

**Direction: partly.**
- **Right:**
  - the conclusion: three convicted at trial on Oct. 21, 2022, with the right terms, including Mignott's three years from the extractor (r2 q06);
  - **Adkins's missing outcome noticed and left open**;
  - the amount card reframed as three victims.
- **Missed:**
  - the transacting inconsistency (the app never surfaced it);
  - the gold-bond pretext (wrongly refused);
  - the added counts.
- **Led away by** r2 q08, the "Oct 24 — convicted" timeline steps and r3 q05.

### B — rc-b-hutchins (10 key facts; 5 rounds, 69 questions; 62 used Claude, 80 calls)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 6 (#1, #8 full; #2, #4, #5, #10 partial) | 2 (#7 Soliman, #9 restitution) | 2 (#3, #6) | 0 (the r2 q08 refusal is counted under #9) |
| Memo | 7 (#1, #8 full; #2, #3, #4, #5, #10 partial) | 0 | 3 (#6; #7 and #9 left "Unknown") | — |

**Wrong statements, 11 distinct:**
1. **Must-not-conclude broken: Soliman pleaded guilty.**
   - r2 q09 and r3 q12: "Yes — “Rapids Theatre owner pleads guilty…”".
   - r4 q01: "The document dated March 20, 2025 reports that Roberto Soliman was pleaded guilty".
   - The same release says "Charges remain pending against Roberto Soliman."
2. **New in this arm: a jury trial for Soliman.** r4 q02 "Was Roberto Soliman convicted by a jury after a trial?" → "Yes — “…who were convicted of conspiracy…”".
3. **Restitution denied.** r1 q11: "No — the documents give hutchins: • Rapids Theatre Niagara Falls, USA, Inc."; r2 q08 refused.
4. **Restitution and loan amounts answered with a false conflict.** "conflicting values for amount: • $1.80 • $750,000 • $20,052.00 • $250,000" (r3 q07, r5 q02 and others).
5. **Personal spending denied.** r4 q12: "No — the documents give hutchins…". The releases say "used the loan funding for their own personal expenses".
6. **William's prosecutor given for John's case.** r3 q10 and r2 q13: "According to Assistant U.S. Attorney Timothy C. Lynch, who handled the case … distribute cocaine".
7. **Patricia's plea schedule given for John.** r5 q09: "On May 1, 2024, she pleaded guilty…". This is the 3/19 vs 3/20 one-day trap.
8. **False role conflict.** r2 q01, r2 q02 and r5 q08: "conflicting values for role: • Director • Theatre Owner And Associate".
9. **One prosecution called two.** r1 q01: "(two prosecutions, or two people of that name)".

The other two were John's and Patricia's passages mixed into one answer (r1 q14) and dates one day early.

**Non-answers and refusals:**
- 22 answers were the card "Hutchins: • Rapids Theatre Niagara Falls, USA, Inc. … Role Director", even for "Who is Patricia/William Hutchins?" (r2 q11/q12).
- Refusals: 1, wrongful (r2 q08).

**Traps:**
- **Avoided:** John was never given 16 or 37 months, or the judges Geraci or Arcara. The extractor attributed Patricia's 16 months (r4 q10) and William's 37 months (r4 q11) to the right people; the rules arm had refused both.
- **Fell in:** Soliman, and the one-day trap.
- **Partly fell in:** William's facts attached to John's case.

**Workflow block (identical in every round):**
- 0 contradictions.
- 1 gap: "William Hutchins: no charging document on file".
- Officials listed as defendants: "Trini E. Ross charged", "Michael DiGiacomo … pleaded guilty / convicted / sentenced", "Judge Meredith A. Vacca sentenced".
- Every person-event finding is the release date minus one.
- No plea finding at all.

**Memo claims checked:** confirmed, except two.
- It calls r5 q05 "header-only"; that is rejected.
- It says there was "no visible model contribution"; that is partly rejected, because of r4 q10/q11.

**Direction: partly, and the right way.**
- The memo kept the look-alikes apart.
- It **rejected the app's Soliman "Yes" answers** as headline misattribution and left Soliman "NOT established".
- It read 2022 vs 2024 as a superseding indictment, not a contradiction.
- It missed restitution because the app denied it (r1 q11, r2 q08).
- The investigator resisted every misleading answer.

### C — rc-c-ntsb-moncks-corner (13 key facts; 5 rounds, 80 questions; 73 used Claude, 137 calls; 0 rewrites)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 12 (6 partial) | 0 | 1 (#12: 40 s, 300 kt) | 0 key facts (4 wrongful refusals on facts found elsewhere) |
| Memo | 12 (#1, #8, #10 partial) | 0 (one citation error) | 1 (#12) | — |

This arm found #5, #7, #8 and #10, which the rules arm missed. The in-case rules answers to the same questions are identical (r2 q09, r2 q14, r4 q04, r4 q14), so **the gain came from wording that quotes the analysis, not from the model**.

**Wrong statements, 7 distinct:**
- The San Diego accident's date: "16 August 2015 — In November 2016, we issued safety recommendations…" (r1 Ask q01, 0.85).
- The F-16 pilot's hours given as the controller's experience: "His recent experience included 35 hours in the 90 days … all in the F-16." (r3 q15).
- Junk fields:
  - "Status: pending/filed" and "Employer In Systems";
  - "Interceptthatcourseat1100: 56, one second before the collision…" (r3 q01, r3 q12, r4 q13, r5 q10);
  - "Location: Moncks Corner, SC." as what the pilot asked (r3 q02).
- Generic FAA guidance given as the analysis's factors (r1 q16).

**Refusals:**
- Wrongful, 4:
  - clock times, "A when-question whose evidence states no date." (r1 q05, r2 q07, r4 q12);
  - r2 q16, "None of the documents on file states the investigators' conclusion".
- Correct, 2: the probable cause (r1 q15, r5 q01).

**Traps:**
- **Avoided:**
  - no probable cause invented;
  - the Cessna pilot not faulted;
  - the serial number handled correctly.
- **Fell in:** the San Diego date. The memo caught it.
- **Never surfaced:** "not contrary to FAA guidance".

**Workflow:**
- 0 contradictions and 0 gaps. It missed "2 miles" vs 3.5 nm, "about 1101" vs 1100:57, and 900 ft vs radar altitude.
- The findings are mostly junk fields.

**Memo claims checked:** confirmed, except two rejected points.
- r1 q17 is the Cessna's equipment, not the F-16's.
- The cited excerpts of the when-refusals hold no clock time; the times are elsewhere in the documents.

**Cause assessment vs the real NTSB probable cause:**
- The real cause: "The approach controller's failure to provide an appropriate resolution to the conflict … Contributing … the inherent limitations of the see-and-avoid concept".
- The memo, labelled "MY assessment, not a record statement", puts the **controller first**: the late advisory from a pattern assumption (r2 q14, r3 q11), the conditional instruction, and the turn that crossed the Cessna (r2 q09). It puts **see-and-avoid second**.
- That is the right direction.
- **Overreach:** it adds "the Cessna pilot was not talking to CHS approach" as a contributing factor.
- **Caveat:** the investigator recognised the accident from memory.

**Direction: partly → yes on the cause, with that caveat.** The app supplied the controller-critical sentences only when asked in the analysis's own words. The rules arm had surfaced only the F-16-critical sentence, so its evidence was one-sided.

### D — rc-d-enron-watkins (15 key facts; 5 rounds, 82 questions; 52 used Claude, 96 calls)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 12 (6 full: #1, #3, #9, #13, #14, #15; 6 partial) | 1 (#10: r3 q03 "From: cindy.olson@enron.com" as author of the original) | 2 (#2 Buy's reply, #12 McMahon "what did you expect?") | 0 key facts |
| Memo | 12 (7 full) | 0 | 3 (#2, #10, #12) | — |

**Wrong statements, about 24 distinct:**
- A fabricated date conflict for "When did Kenneth Lay learn of the accounting concerns?" (r1 q03): "conflicting values for date: • 14/08/2001 • 23/01/2002", citing Hubbard's "Concern about EBS".
- Wrong-message "verbatim" answers:
  - r2 q01, the letter's author: "Thanks, Liz --- Kenneth.Lay@enron.com wrote:";
  - r2 q10, Watkins to Buy: "Fri, 2 Nov 2001 09:08:28 -0800 (PST)";
  - r5 q08: "Published: May 24, 1996.";
  - r3 q10/q16 and r5 q10: "Ken: I started buying Enron again this morning because I know.".
- The fragment "Summaryofallegedissues: RAPTOR Entity was capitalized with LJM equity. That equity is at." ×10.
- UTC one-day shifts in the in-case timeline.

**Non-answers and refusals:**
- About 39 of 82 were non-answers.
- Refusals: 3 wrongful (r3 q01 "don't mention the messages"; r2 q15; r5 q09); 2 correct.

**Traps:**
- **Fell in:** Hubbard as a look-alike for Lay (r1 q03/q09/q14), and the Carson note inside a mash-up.
- **Avoided:**
  - portrac 07:53 and 15:27 kept apart;
  - no Aug 15 letter date;
  - never "Lay learned in October", though r1 q03 misleads.

**Workflow:**
- 0 contradictions; "gaps found: 39", never listed.
- The findings open "On 1996-05-24 — … MICHAEL BERRY campaign".
- They are truncated mid-line.
- A "commitment" line changes between identical runs.

**Memo claims checked:** none rejected.

**Who-knew-when vs the key:**
- The memo has:
  - Watkins → Buy on Aug 14 ("unwind raptor", r4 q02/q03);
  - the unsigned letter, author later identified (r4 q17, r5 q07);
  - Lay by Aug 22 (r2 q07, r3 q05);
  - Olson → Lay on Oct 24;
  - Haedicke/Schuler on Oct 30.
- **That chronology matches the key.**
- It avoided every must-not-conclude: "nothing connects" Hubbard; Carrington is only a worried employee.
- It missed McMahon as an earlier knower, and Buy's actual reply.

**Direction: partly, better than the rules arm.** The gain came from asking by subject line through the rules e-mail header path. Those answers made no model calls (e.g. r4 q02/q03).

### E — rc-e-fda-bluebell (12 key facts; 5 rounds, 83 questions; 68 used Claude, 112 calls)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 11 | 1 (#8: rows from other events) | 0 | 0 net (#9 refused at r1 q12, found at r2 q09) |
| Memo | 12 | 0 key facts (1 wrong non-key statement: r4 q01 distribution adopted, flagged Low) | 0 | — |

**Wrong statements, about 20 distinct:**
- The 2015 "why" answered with "Reasonforrecall: Product may have been mispackaged and contain undeclared wheat and soy." (r1 q01).
- "F-1407-2016 | BLUE BELL ICE CREAM Rocky Road pint | 23,973 pints" for the 2015 products (r1 q02/q03, r3 q18).
- 18 false conflicts pooled across separate events ("Class I • Class II • Class III"); the termination "conflict" omits the true November 3, 2016.
- 80360's distribution given for 70738 (r4 q01).
- The 2025 row given for the 2016 cookie-dough question (r5 q09).
- "Employer: Splendid Ice Creams LLC", and "Date: 2020-10-05" from best-by 5/10/2020.

**Traps:**
- **Must-not-conclude: none breached.** The app never stated deaths, charges, an FDA mandate, or an Aspen Hills link to 2015.
- **Partly fell in:** Jeni's and 75254 were kept apart only when the question named the event ID.

**Workflow:**
- 0 contradictions, which is correct; the key has none. This is inconsistent with the 18 false conflicts on the Ask path.
- Findings: "0 dated and 66 undated finding(s)", truncated mid-word.

**Memo:**
- Correct throughout.
- But 43 of the 67 questions in r2–r5 name an event ID: "I had to translate every natural question into 'recall event NNNNN + field'". This is the same file-name and header artefact as in the first arm.

**Direction: yes on the conclusion; the app's part in it is partly.** It works by record ID. On plain wording it misled (r1 q01, r1 q02/q03, r4 q01).

### F — rc-f-logan-arson (14 key facts; 5 rounds plus a smoke round, 83 + 2 questions; 77 of 83 used Claude, 136 calls, plus 4 in the smoke round)

| | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 10 (#3 and #10 partial) | 1 (#12: Williams given Simon's 22 months) | 2 (#8 "yesterday" never resolved; #14 Workman) | 1 (#6: r4 q04 "don't say whether Michael D. Williams was charged") |
| Memo | 10 | 0 (#12 inferred "about 56 months", labelled "my inference only, with low confidence") | 4 (#6, #8, #12, #14) | — |

**OCR:** worked, with 0 errors. The scanned release-01 ingested in every round, and its quotes ($75,000; 36 counts) came back.

**Wrong statements, 7 distinct:**
1. "Michael D. Williams was sentenced to 22 months in prison…" (r3 q03, r5 q01, plus in-case).
2. "Guy Miller was pleaded guilty on November 6, 2013 and again on December 12, 2013" (r2 q06).
3. "Guy Miller was sentenced on May 28, 2014 and again on May 29, 2014" (r3 q06).
4. "conflicting values for amount: • $50,000 • $50 • $10,000", 14 times, for:
   - the policy;
   - the payout (r2 q01 at 0.90, r3 q01; the real figure is $1,010,000);
   - restitution;
   - payments to Miller, Williams or Simon;
   - total prison years.
5. "Date: 12/12/2013." for the fire date (r1 q08) and the indictment (r2 q15, r3 q16, r4 q17).
6. Wrongful refusals: "The release doesn't say which office announced it" (r5 q13); "Not found in the 11 documents searched: identity." (r2 q16).

The rules arm's "insurer paid $75k" error did not recur.

**Traps and must-not-conclude:**
- **The $75k must-not-conclude is breached by individual answers.** smoke-o q02, r1 q04 and r4 q09 give $75,000 alone with no $50k note.
- **The memo does not breach it.** It found both $75k and $50k by asking by figure (r4 q08/q09).

**Workflow (identical):**
- **0 of 3 contradictions.**
- The U.S. Attorney is listed as a defendant: "On 2013-09-02 — Booth Goodwin charged".
- Dates are one day early: 2013-12-11 and 2014-05-20.
- False gaps: "Guy R. Miller / Shawn C. Simon: no charging document on file".

**Memo claims checked:** all confirmed (with minor id miscounts).

**Direction: partly.**
- **Noticed by hand, against the app:**
  - $75k vs $50k, despite r5 q10's canned block;
  - the two fuel accounts (r1 q07 vs r2 q09);
  - Williams's absence from the indictment.
- **Missed:**
  - the camera discrepancy (the courthouse video was never surfaced);
  - Workman.
- **Led away** from Williams's real 32 months by r3 q03 and r5 q01.

---

## 3. Model-contribution analysis

### 3.1 How much the model was used

| | Ask answers | with ≥1 Claude call | calls | 0 / 1 / 2 calls |
|---|---|---|---|---|
| Opus 5 arm | 467 | **386 (83 %)** | **639** | 81 / 133 / 253 |
| In-case answers (same questions) | 467 | 0 by design | 0 | — |
| Rules arm | 523 | 0 | 0 | — |

Per case:

| case | answers with calls | calls |
|---|---|---|
| A | 54 / 70 | 78 |
| B | 62 / 69 | 80 |
| C | 73 / 80 | 137 |
| D | 52 / 82 | 96 |
| E | 68 / 83 | 112 |
| F | 77 / 83 | 136 |

**What the calls were:**
- **Two calls** is almost always interpreter plus rewriter. Of the 253 two-call answers:
  - 165 still ended as a rules passage labelled "(Quoted verbatim from the cited document; no model was consulted.)";
  - 35 as a "conflicting values" dump;
  - 26 as a field line;
  - 2 as extractor answers after a rewrite.
- **One call** is either the interpreter or the extractor.
- **No answer body anywhere was written by the model.**

### 3.2 The three cloud parts, one by one

**Rewriter: 6 visible rewrites in 467 questions.**

| outcome | count | rewrites |
|---|---|---|
| Better | 2 | B r4 q11 "What was William Hutchins sentenced to?" → the extractor's correct 37 months (in-case gave the "Hutchins:" card); D r4 q12 → the full "WSJ additional questions" body (in-case gave the signature line) |
| Worse | 1 | F r5 q01 "Michael D. Williams was sentenced to how long in prison?" → "What sentence did Michael D. Williams receive?" → "Michael D. Williams was sentenced to 22 months…". In-case, unrewritten, showed Simon's sentence only as a plain quote |
| Sideways | 1 | A r3 q08 "How much supervised release did Jerrid Douglas receive?" became "What sentence…", answered "45 months in prison". The question asked for 3 years' supervised release |
| No-op | 2 | A r3 q13 and B r3 q13: a "?" was added |

**Extractor: 14 verified answers shown**, all in the three prosecution cases (A 5, B 5, F 4). C, D and E have no proceeding questions.
- **Every quote verifies, and every stated value is true.**
- **They differ from the rules answer in 9 cases:**
  - A r2 q06: Mignott "three years". This was **wrong in the rules arm and wrong in this arm's own in-case rules answer**: "six years".
  - F r2 q05: Thompson "five years". The rules arm and in-case refused: "don't state a sentence for William Jamey Thompson".
  - B r4 q10 and r4 q11: Patricia's 16 months, William's 37 months. The rules arm refused or gave the card.
  - A r1 q08: the verdict sentence instead of the headline.
  - Cleaner or narrower wordings: F r1 q11, F r2 q04, B r1 q02, B r1 q08.

**Proceeding questions where the extractor engaged but its proposal was not shown: about 22.** These are answers with one Claude call (the interpreter and rewriter skip questions the proceeding reader parses, `QuestionUnderstanding.handledByAGate`). They ended as a rules proceeding answer.
- **About 8 were right:**
  - Adkins refusals (A r1 q09, r2 q05);
  - Douglas 45 months (A r1 q10);
  - plea dates (B r1 q07, F r1 q10, F r2 q07);
  - a correct Williams no-plea refusal (F r3 q05);
  - one right date resting on Simon's quote (F r3 q04).
- **About 14 were wrong or misleading, the same errors as the rules arm:**
  - Soliman "pleaded guilty" or "Yes —" (B r2 q09, r3 q12, r4 q01) and the jury "Yes —" (B r4 q02);
  - "gives no other day" (A r2 q08);
  - "again on October 24" (A r3 q05);
  - the Adkins "Yes —" (A r3 q14);
  - "two prosecutions" (B r1 q01);
  - Miller's two pleas and two sentencings (F r2 q06, r3 q06);
  - Williams 22 months (F r3 q03, r5 q01);
  - a wrongful Williams-charged refusal (F r4 q04).
- **The design gap.** When the model's reading does not verify, or the model says the record is silent, `answer()` returns nil and **the rules answer ships unchanged, even when it is the wrong-person answer** (`Brain/MasterBrain.swift:2213-2225`).
  - Soliman's plea is the clearest case. The record says "Charges remain pending against Roberto Soliman", which leaves the extractor nothing to verify. The rules headline "Yes —" was shown anyway.
  - Because the model's replies are not logged, I cannot say what it returned for each of these.

**Interpreter: its field choice made several answers worse.**
- **Conflict dumps rose fourfold.** "Your archive carries conflicting values" answers went from 11 of 523 (rules arm) to **49 of 467**.
- **Four questions asked word-for-word in both arms lost a correct or better answer:**
  - F "How much did General Star pay Glick on the insurance claim?" and "Without sufficient evidence of the arson, how much did General Star pay Glick?"
    - Rules arm: "General Star paid Glick the $1,010,000 insurance policy proceeds in May 2012".
    - Opus arm: "conflicting values for amount: • $50,000 • $50 • $10,000".
  - F "When were the conspirators indicted?"
    - Rules arm: "The conspirators were indicted in late August 2013…".
    - Opus arm: "Date: 12/12/2013."
  - B "Who is Roberto Soliman?"
    - Rules arm: the Vacca sentencing quote.
    - Opus arm: "conflicting values for role: • Director • Theatre Owner And Associate".
- **The mechanism.** "amount", "date" and "role" are the rules' weak fields.
  - With models allowed, the interpreter is asked, picks the field, and `remember`s it.
  - `SlotFieldResolver.resolve` then answers from that field's pooled values instead of the passage path.
  - With no model allowed (the rules arm), nothing is remembered and the passage path answered.
- **Same build, same questions.** The only difference is the cloud.

**A side effect that weakens the in-case control.** The interpreter's choice lives in a process-wide table keyed by question text (`QuestionUnderstanding.chosen`). The case-scoped brain has no interpreter, so it never resets that entry. It reads the Ask pass's choice for the same question (`SlotFieldResolver.swift:430`).
- That is why the four regressions above also appear in this arm's in-case answers.
- The conflict-dump count is identical: Ask 49, in-case 49.
- So in-case is "rules plus the cloud's field choice", not pure rules.
- In the shipped app the same leak would carry a field choice from Ask into an opened case for an identical question.

### 3.3 Same question, two arms

**49 questions were asked word-for-word in both arms.** 37 got the same answer; 12 differed:

| better with Opus 5 | worse with Opus 5 | neutral |
|---|---|---|
| A Mignott three years (rules: "six years") | F General Star payout (×2): correct $1,010,000 quote → false amount conflict | A victims fact dump, reordered |
| F Thompson five years (rules: refused) | F indictment: "late August 2013" → "Date: 12/12/2013." | D Lay learned: Hubbard header mash-up → fabricated date conflict, both wrong |
| F Glick sentence, cleaner wording | B "Who is Roberto Soliman?": a sentencing quote → role-conflict card | E 2015 "why": wrong either way |
| F Thompson plea, grammar ("pleaded guilty" vs "was pleaded guilty") | | |

**Substantively:**
- Better: 2 (A #9, F Thompson's sentence).
- Worse: 3 lost correct answers (the F payout twice, the F indictment date), plus 1 worse non-answer (B).

**Ask vs in-case within this arm, cloud-using answers that differ (48; the rules arm has 49 such differences from scope alone):**
- The extractor answers above are the only consistent improvement.
- **C:** Ask was better in 1–2 and worse in about 6 (e.g. r3 q01 "Interceptthatcourseat1100…" vs the 1100:16/1100:24 exchange in-case).
- **E:** both differences were worse in Ask (r3 q18, r4 q03).
- **D:** r3 q08 turned the in-case refusal into a wrong-message mash-up.

### 3.4 Did Opus 5, as wired today, change outcomes?

**Plainly: barely.**
- **Key facts.** In 386 cloud-assisted answers (639 calls), exactly **one key fact moved from wrong to right**: A #9, Mignott's term.
  - It fixed two wrongful refusals on facts already found elsewhere (F Thompson's sentence) or on look-alikes (B Patricia, William).
  - It made **no key fact newly found, and none newly wrong**.
- **Regressions.** It caused several direct-question regressions: the F payout, the F indictment date, B Soliman, F r5 q01, E r3 q18/r4 q03, D r3 q08.
- **Memo conclusions.** No investigator's conclusion changed because of a model answer. All six memo outcomes trace to rules-path answers, chiefly the per-person timelines, the e-mail-subject reader and the record-ID fields, or to the investigators' own cross-checking.
- **Structural.** The workflow block (contradictions, gaps, findings) is untouched by the model. It is identical in failure to the rules arm: 0 of 4 contradictions, officials as defendants, one-day-early dates.
- **Labelling.** About 170 answers whose field or wording Claude chose still carry "(Quoted verbatim from the cited document; no model was consulted.)". It is true that the model wrote no words, but the label says no model was consulted when one was. The harness footer "AI model: none (rules path)" is likewise a harness label (`NOAI=1`).

---

## 4. Arm comparison

| | rules arm (AI off) | Opus 5 arm (Online) |
|---|---|---|
| Contamination | README outcome table seen by both arms; memos not credited as independent | none (README-opus5 has no outcomes); memory disclosed in C and D, general recognition in E |
| App answers: found / wrong / missed / refused wrongly | 50 / 6 / 16 / 5 | 59 / 6 / 10 / 2 |
| Of the change, attributable to the model | — | +1 fact right (A #9); the rest come from different question wording (C quoting the analysis, D asking by subject line, A asking for timelines) |
| Distinct wrong statements at normal confidence | 108 (523 q) | ~76 (467 q) |
| Wrongful / correct refusals | ~36 / ~10 | ~22 / ~7 |
| Non-answers | ~half | ~half |
| Contradictions flagged (keyed 4) | 0 | 0 |
| Findings report errors (officials as defendants, −1 day, junk) | present in A, B, F (and C, D, E junk) | identical |
| Memo: found / wrong / missed | 57 / 3 / 17 | 62 / 1 / 14 |
| Memo conclusion correct? | A partly, B partly, C partly, D partly, E yes, F partly (contaminated) | A partly, B partly, C yes (memory caveat), D partly, E yes, F partly (independent) |
| Effort | 30 rounds, 523 q | 30 rounds, 467 q (~78 per case) |
| Baseline (reading) | 76 / 0 / 1 in ~2–2.5 h | same reference |

- **The Opus 5 memos are slightly better and, unlike the first arm's, independent.** That matters more than the +5 facts: three uncontaminated investigators reached the right overall picture in every case. They did it by cross-examining the app and refusing its wrong answers (B Soliman, D Olson-as-author, A "Yes" on Adkins).
- **The app still does not save reading effort.** It took about 78 questions per case to reach 62 of 77 facts. One read reached 76.

---

## 5. Verdict

**The verdict is still no, though it is closer than the rules arm. The pipeline with Opus 5, as wired today, did not change what an investigator can crack in these six cases.**

**Investigators' direction: right in all six cases, mainly despite the app's wrong answers rather than because of the model:**
- A: three convicted at trial; Adkins's fate correctly left open.
- B: look-alikes separate; Soliman unresolved.
- C: controller first, see-and-avoid contributing, matching the real NTSB cause. The investigator recognised the accident from memory.
- D: the Aug 14 → Aug 22 → Oct 24 chronology.
- E: one 2015 event, look-alikes apart.
- F: the scheme and roles; two of three discrepancies found by hand.

**What helped (all rules-path, plus one extractor class):**
- Format reading: the scanned F indictment was read by OCR with 0 errors.
- Verbatim citations, which let investigators reject wrong answers.
- Per-person "case against X" timelines (A r3 q01–q04, B r3 q01–q04).
- The e-mail subject reader (D r4 q02/q03, the full "unwind raptor" body).
- Record-ID field answers (E).
- Correct refusals on absent outcomes: Adkins; the NTSB probable cause, "None of the documents on file states the investigators' conclusion" (r1 q15, r5 q01).
- The extractor's correct, verified sentence and plea answers (Mignott three years; Thompson five years; Patricia 16 months; William 37 months).

**What blocked it:**
1. **Wrong answers at normal confidence.** These are the rules arm's defects D1–D8, unchanged: Soliman "pleaded guilty" (and now "convicted by a jury"), Williams 22 months, Miller's double pleas and sentencings, restitution denied, release dates used as event dates.
2. **The extractor never vetoes a rules answer.** When its reading does not verify, the wrong rules answer ships.
3. **The interpreter's field choice turns correct passages into false "conflicting values" dumps.** Conflict dumps went from 11 to 49; the F payout and the indictment date were lost. The choice also leaks into case answers.
4. **The workflow found 0 of 4 real contradictions** and still lists prosecutors and judges as defendants, one day early.
5. **About half of all answers are non-answers** labelled "Quoted verbatim … no model was consulted".

**Which investigator tasks it already serves, as an aid:**
- getting every format, scanned ones included, into one searchable place;
- pulling a person's proceeding steps into a dated, quoted timeline that must be checked against the dates;
- finding a passage when the investigator already knows its words, subject line or record ID;
- confirming that an outcome is *not* in the record (Adkins, the probable cause);
- sentence and plea answers for a named defendant when the extractor verifies.

**Which it does not serve yet:**
- telling the investigator what is inconsistent (contradictions);
- what is missing (gaps: Adkins, Workman);
- which of several people a fact belongs to, reliably;
- answering plain-wording questions about amounts, dates and roles;
- producing a findings report that can be handed on.

**For Opus 5 to change outcomes:**
- (a) The extractor's "not stated" or unverified result must suppress a contradicting rules answer, at least refusing the rules wrong-person answer, instead of falling back to it.
- (b) The interpreter must not route a question to a pooled field when the values belong to different events or people. The remembered choice must be per brain or per scope, not process-wide.
- (c) Either let the model check whether a shown passage answers the question (the D3 gate), or say plainly that it did not.
- (d) Fix the labels: "no model was consulted" on cloud-assisted answers, and the harness footer.

These must then be re-measured on fresh real cases.
