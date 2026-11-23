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
