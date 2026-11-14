# Real solved cases, v2 (Opus 5 everywhere) — INTERIM, measurement incomplete (AGENT)

**Status: NOT A RESULT.** The bench's Anthropic account ran out of credit during the runs: every cloud call after
the first round of most cases failed with `HTTP 400: Your credit balance is too low to access the Anthropic API`.
No judge has scored these runs against the sealed keys. This file records what was observed, so the re-run can be
compared.

- **Build:** commit 14e0708b (P1 verified answer composer, P2 proceeding cross-check, P3 contradiction finder,
  P4 roles/dates/identities, P5 drafts, reader fixes with thinking room). Harness: `~/CaseBench/realcase/round-v2.sh`,
  test host `~/CaseBench/dd-v2`, worktree `src-wt-14e0708b`.
- **Investigators:** six fresh agents (AGENT runs) using only the app; investigator README without outcomes
  (`README-v2.md`).
- **Cases:** six new solved cases (rc2-g … rc2-l, prepared 2026-11-03, 141 key quotes verified) and the six earlier
  ones (rc-a … rc-f) as a regression check (fixes were drawn from them, so they are tuned).

## Which rounds actually used Opus 5

| Case | Rounds | Online (Opus 5 answered) |
| --- | --- | --- |
| rc-a, rc-b, rc-f | 3 | r1 only |
| rc-c, rc-d | 2 / 1 | r1 only |
| rc-e | 3 | none (credit already out) |
| rc2-g, rc2-h (new) | 2 | r1 only |
| rc2-k, rc2-l (new) | 4 | none |
| rc2-i, rc2-j (new) | 0 | not run (the investigator agent stopped on a server error) |

## Observed (from the investigators' memos, quoted there)

With Opus 5 answering (r1 rounds):
- Core who / charge / plea / sentence / restitution answers were correct with checkable verbatim quotes in every
  online round (e.g. Vendstar: every sentence and restitution figure across five releases; Kamara: each step;
  Logan: one answer covered nearly the whole case; NTSB: a minute-by-minute timeline in two rounds; Enron: the
  one relevant message among 60 found on the first question).
- The app never claimed a document states the NTSB probable cause; same-surname people (Hutchins, Kamara) kept
  apart in the AI answers; officials separated from defendants in the cast.
- Real contradictions surfaced: Logan $50k/$75k and Simon's role (both quotes); Soliman's impossible ages;
  Vendstar 22 vs 24 convicted.

Still wrong or noisy (all paths):
1. **False "Needs review"** — the cross-check compares a correct AI answer with an off-target rules reading
   ("Date: 12/12/2013") and flags a disagreement; 10 of 15 Logan answers, all four in rc-a and rc-b.
2. **False contradictions** — the case growing over time (counts, victims, amounts), an agreed fee vs the loss,
   different events' product counts (Blue Bell "286 vs 1"), send dates of two different messages; leads then
   point to "the charging document" / "the court docket".
3. **Drafts** — cast includes non-persons ("Avoid Concept", "Daily Update", "Launch Date"); chronology polluted
   by other matters in the archive (Vendstar sweep release, the other Mohamed Kamara's crash) and junk (Enron
   "1996-05-24 — a favorite dish"); rules chronology gives Simon's 22 months to Miller and Williams.
4. **Gaps** — "none records the charge" for defendants the indictment names; Williams "never charged" because
   two name forms were not merged.
5. **Findings report** — "Judge John Michael Vazquez convicted", "Christy Romero sentenced" (a SIGTARP
   official), "amount: $10 USD", in-scope sources marked "outside this export's scope (withheld)".
6. **Offline (rules) answers** — off-target quotes at confidence 0.8; "History of the user's archive" dumps
   (one claims "No reasoning provider available" while one was); a wrong recall answered at 0.8 (Sabra 2021 for
   April 2015); headline question refused ("Why was Blue Bell recalled in 2015?").
7. **A failed cloud call is hidden** — the answer says "the AI reader did not answer"; the reason (credit balance)
   appears only in the run summary. A person on their own key must be told why ("your AI account has no
   credit") in the answer.

## To finish the measurement

Top up the bench key's credit, fix 1–7, then re-run all twelve cases (new investigators, `README-v2.md`) and judge
against the sealed keys.
