# Real solved cases, with an agent as the AI reader (2026-11-23)

**Agent-simulated AI reader (Claude acting as the reader), not a live AI run.** The owner's bench key has no credit, so no live run was possible.

**How it ran.** The real app code did the work: import, ledger, case, permission, briefing, parts, Brain steps, merge, second look and verifier. The agent read only the exact requests the app would send, and wrote the replies the AI would give.

- Harness: `KalsmritikoshTests/AgentReaderEvalTests.swift` (commit `6ccc570e`). It is Debug-only and runs only with `AGENT_EVAL=1` or `build/agent-eval.trigger`, so CI never runs it.
- Runs: three real runs. Product code was unchanged.

## Cases (10, public and solved, answer keys from the publisher)

| Source | Case |
|---|---|
| DOJ | West Point embezzlement |
| DOJ | Goodyear trade secrets |
| DOJ | State Department false statements |
| DOJ | Grant fraud |
| DOJ | Staged accidents |
| DOJ | Keepseagle false claim |
| Court opinion (CAP) | Corp. of America v. McLaughlin |
| Court opinion (CAP) | Estate of Cervin v. Commissioner |
| NTSB | SEA08LA057 (Sonoma mid-air) |
| Acceptance case (multi-document) | INV-104 supplier payment |

## Results

| | Result |
|---|---|
| Questions | 34 |
| Correct | 31 (3 of them wrongly flagged "Needs review") |
| Partly correct | 2 (INV-104: no net figure; no "not established" line) |
| Wrong or misleading | 1 (INV-104 "Was Kestrel paid twice?") |
| Refused when the answer existed | 0 |
| Correct claims dropped by the verifier | 7 of 68 |
| Answered by the briefing alone | 2 of 34 |
| AI-off tools (contradictions, drafted timeline) | 0 conflicts; 1 dated item across all 10 cases |
| App time per question, without AI | 0.1–0.4 s; 2–3 AI calls per question |

Earlier verdicts:
- 2026-11-04, real Opus: 44 % correct.
- 2026-11-18, rules only: 4 of 9 case types.

Today's 91 % is an **upper bound** for a careful reader working mostly on single-document material. It is not a prediction of what a live model would score.

## Verdict

**Not yet.** For look-up questions, a good AI reader with the app's verifier gives correct, quoted answers, and nothing invented reached the screen. But on the one realistic multi-document case (INV-104), the main question ("Was Kestrel paid twice?") came out misleading, and the app's own ledger work added almost nothing.

## Top 5 to fix

1. **The verifier treats companies as people.** `ProceedingAnswerer.person(in:)` took "Kestrel Supplies" as the person in the question. `VerifiedAnswerComposer.whyNot` then required every cited document to name it in full, which dropped both bank debits and the report amendment. Only the witness's "one payment" was left.
2. **The reader's own conclusion never reaches the person.** The shown answer is the claim sentences joined together, so "No", "Not established" and "no net figure stated" are lost, and there is no money arithmetic. The second look is also checked against the answer before it was verified (`CaseReader+Path.swift`, `readCase`).
3. **The briefing is mostly noise.**
   - Wrong labels: "DENMAN — location", "95-60541 — phoneNumber".
   - Amounts lose their scale: "$2.75", "$5", "$710".
   - Relationships are only names that appear together.
   - Cutting a line at 300 characters drops its `[D<n>]` tag.
4. **The cached prefix changes on every question.** The "verified answers" and "AI suggestions" sections grow each time: 30 different prefixes for 34 questions. So every question pays the full input price.
5. **False alarms and weak tools.**
   - "Needs review" fired from an off-target headline.
   - The `timeline` and `field` ledger tools returned nothing, even though the briefing held that event and those amounts.
   - The injection guard rejected an ordinary sentence from a judgment.

## After X1 (AI-41, AI-42, AI-43 — commits 7b06b147, 902e6321, 9f7fef5b)

**Still an agent-simulated reader, not a live AI run.** The same harness (`AgentReaderEvalTests`, trigger file), all 10 cases, on the X1 code.

**Replies reused.**
- Every request text changed. The question task's `about` rule now says "written exactly as it appears in the cited document", and the briefing changed (AI-43). So no saved reply matches its request byte for byte.
- The harness reads replies by file name, so all 71 saved replies were reused by name and no placeholder was sent.
- For the 9 single-document cases the only change is that one rule line plus the briefing. I judged the saved replies still to be what a reader would answer, and reused them unchanged.
- For INV-104 the agent acted as the reader again, from the dumped request text only. q1 and q2 were rewritten: q1 now also cites the invoice amount and the 19 March refund; q2 answers directly, with no tool round. The q1 second look was rewritten too. q3–q5 were reused. The pre-X1 INV-104 replies are kept in `build/agent-eval-before-x1/`.

| | Before X1 | After X1 |
|---|---|---|
| Correct | 31 of 34 (3 wrongly flagged "Needs review") | **32 of 34** (0 flagged) |
| Partly correct | 2 | 2 (INV-104 q2: no net figure; q5: the "not established" line is not shown) |
| Wrong or misleading | 1 (INV-104 q1) | **0** |
| Correct claims dropped by the verifier | 7 of 68 | **0 of 87** |
| False "Needs review" from the rules | 3 | 0 (the rules no longer cross-check on the case path) |
| Rules contradictions / drafted timeline | 0 conflicts, 1 dated item | switched off as deciders (0 by design) |

**INV-104 "Was Kestrel paid twice?"** The answer now shows all of the following, each quote checked:
- both INR 50,000 debits (KS-77120, KS-77985);
- FR-12's duplicate finding;
- Amendment A withdrawing it: the second debit settles PO-561 / INV-109, and "the two settlements are distinct payments";
- the 19 March refund;
- the witness, who approved one payment.

Before X1, the person veto dropped the debits and the amendment. Now nothing is dropped.

**Still open (X2 and later):**
- The shown answer is still the claims joined together. The AI's own conclusion ("No", "Not established") and the app's arithmetic (the net outflow) are not shown yet (AI-46).
- The briefing still carries typed-field noise ("phone: 20260306") and the claims register (AI-45).
- The second look is still checked against the unverified answer (AI-46).

## After X2 (AI-44, AI-45, AI-46 — commits 9e4867c1, 8a301cd2, 26d5ccb2)

**Still an agent-simulated AI reader, not a live AI run.** The same harness and the same 10 cases, on the X2 code. The harness now also dumps the case-picture requests (`_picture/picture-p<part>-r<step>.txt`), the picture records and the briefing as the questions saw it, and counts the distinct question prefixes per case.

**What the agent did as the reader (from the dumped request text only).**
- **Case picture:** wrote one picture reply per case — 139 write requests in all (people and organisations with type and role, dated events, facts and money, relationships, conflicts, one hypothesis, tasks and a question for the investigator). The verifier rejected 3 and returned the reason; the agent corrected them in the next step (INV-104: "the number 104 not in the quote", "the number 17 not in the quote"; lawyer: "the number 1926 not in the quote"). Stored: 139 records, all "found by AI, quote checked".
- **Questions:** added a `conclusion` to every reply. Two old tool rounds (NTSB q1, Sledgehammer q3) were dropped because the picture already held the answer. INV-104 q2 now first asks the `sum` tool, then answers with the app's totals.
- **First pass:** 2 conclusions were withheld by the mechanical check, because the count word "two" was in no quote (INV-104 q2 and q5). The agent rephrased them and the run was repeated. The saved X1 replies are kept in `build/agent-eval-before-x2/`.

| | After X1 | After X2 |
|---|---|---|
| Correct | 32 of 34 | **34 of 34** |
| Partly correct | 2 (INV-104 q2 no net figure; q5 "not established" not shown) | 0 |
| Wrong or misleading | 0 | 0 |
| Correct claims dropped by the verifier | 0 of 87 | 0 |
| AI's conclusion shown first | — | 34 of 34 (2 withheld on the first pass, then rephrased) |
| App arithmetic shown | none | INV-104 q2: "INR 50,000 + INR 50,000 = INR 100,000"; "INR 50,000 + INR 50,000 − INR 50,000 = INR 50,000" |
| Distinct cached prefixes | 30 for 34 questions | **1 per case** (10 for 34 questions) |
| Questions whose answer material is in the picture alone | 2 of 34 | 33 of 34 (INV-104 q2 also needs the sum) |

**INV-104 "Was Kestrel paid twice?"** The answer now opens with: "AI's conclusion: No — Kestrel was paid once for INV-104; the second debit KS-77985 settles a different invoice, INV-109 (Amendment A), and INR 50,000 was later refunded." The 8 checked quotes come after it. The second look was asked about this verified text.

**Limits of these numbers.**
- The 34 of 34 is an **upper bound**. The same agent wrote the picture and the answers, and it knew the questions while it built the picture, so "33 of 34 in the picture alone" overstates what a reader building the picture blind would reach.
- The prefix count holds because each case's documents did not change between questions. A changed document gives one new prefix: it is read again in the background after the next answer.
- The first question of each case now waits for the picture. In this run that was 2 to 3 extra picture steps per case.

**Still open:**
- A live run once the bench key has credit.
- X3 rows: instruction-like quotes are still dropped in `AIConflictContract` and `CaseDraftBuilder`, and the archive-wide Ask still uses the rules cross-check.
- There is no screen that lists the AI's records outside the briefing and the answers.
