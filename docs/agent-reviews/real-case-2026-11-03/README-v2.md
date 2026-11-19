# Real solved cases, set 2 — investigator instructions

You are an investigator. Six real, closed matters are packed as archives of public records. You work a
case **only through the app**, exactly as the app works today. You receive a starting brief; you learn
everything else from the app's answers.

## Cases

`rc2-g-vendstar`, `rc2-h-kamara`, `rc2-i-ntsb-iliamna`, `rc2-j-enron-savings-plan`, `rc2-k-fda-sabra`,
`rc2-l-hope-loanmod` — the brief for each is `briefs/<case>.md`.

## Asking the app: round-v2.sh

    bash ~/CaseBench/realcase/round-v2.sh CASE ROUND QUESTIONS_FILE    # one question per line; '#' lines ignored

The app ingests the case's documents into a fresh ledger, answers every question over the whole
archive and again inside the case opened as an investigation, and builds the case's workflow output.
One round runs at a time (it waits for a lock) and can take several minutes. The result is
`~/CaseBench/realcase/runs-v2/<case>/<round>/answers.md`: documents ingested, each answer with its
confidence, the model calls it used, cited documents and passages, then the case workflow block
(custody, contradictions, gaps, drafts, findings report). The top says `INVALID: OCR failed`,
`INCOMPLETE` or `NO RESULT` when a round did not complete — run it again with `FORCE=1`
(`FORCE=1 bash ~/CaseBench/realcase/round-v2.sh CASE ROUND QUESTIONS_FILE`). A round name that
already exists is refused unless `FORCE=1`.

Each round is a fresh ledger: the app keeps nothing between rounds, so repeat any earlier question
you still need. Keep your question files and notes in your own working folder.

## Rules

- Read ONLY this file, `briefs/<case>.md` and `runs-v2/<case>/*/answers.md`.
- Never open `README.md`, `README-opus5.md`, `packs/`, `keys/`, `work/`, `tools/`, `runs/`,
  `runs-opus5/`, `memos/`, `qs*/`, `shard/` or `results/` folders (including a round's own), or any
  raw data under `~/CaseBench` (`raw/` and the other bench folders).
- No web search or other outside source about the cases. Your memory of a case is not evidence: if
  you recognise one, say so in your memo and still rely only on the app's answers.
- Every claim in your final memo must cite the document (and, for e-mail, the sender and date) that
  the app's answer or cited passage gives. Where the app's answers disagree, say so and show both.
  Where the record is silent, say it is silent — do not fill the gap.
