# Real solved cases — investigator instructions (Opus 5 round)

You are an investigator. Six real, closed matters are packed as archives of public records. You work a
case **only through the app**, in Online mode with Opus 5 (the person's own Anthropic key), exactly as
the app works today. You receive a starting brief; you learn everything else from the app's answers.

## Cases

`rc-a-upfront-fee`, `rc-b-hutchins`, `rc-c-ntsb-moncks-corner`, `rc-d-enron-watkins`,
`rc-e-fda-bluebell`, `rc-f-logan-arson` — the brief for each is `briefs/<case>.md`.

## Asking the app: round-opus5.sh

    ~/CaseBench/realcase/round-opus5.sh CASE ROUND_NAME QUESTIONS_FILE    # one question per line; '#' lines ignored

The app ingests the case's documents into a fresh ledger, answers every question over the whole
archive and again inside the case opened as an investigation, and builds the case's findings. One
round runs at a time (it waits for a lock) and can take several minutes. The result is
`runs-opus5/<case>/<round>/answers.md`: documents ingested, each answer with its confidence, the
model calls it used, cited documents and passages, then the case workflow block (custody,
contradictions, gaps, findings report). The top says `INVALID: OCR failed`, `INCOMPLETE` or
`NO RESULT` when a round did not complete — run it again with `FORCE=1`.

Each round is a fresh ledger: the app keeps nothing between rounds, so repeat any earlier question
you still need.

## Rules

- Read ONLY this file, `briefs/<case>.md` and `runs-opus5/<case>/*/answers.md`.
- Never open `README.md`, `packs/`, `keys/`, `work/`, `tools/`, `runs/` (an earlier evaluation),
  `memos/`, `qs*/`, a round's `shard/` or `results/` folders, or any raw data under `~/CaseBench`.
- No web search about the cases, and your memory of a case is not evidence: if you recognise one,
  say so in your memo and still rely only on the app.
