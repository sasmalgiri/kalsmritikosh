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
