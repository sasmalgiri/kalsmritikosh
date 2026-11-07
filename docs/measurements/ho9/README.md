# Held-out chronology set 9 — measurement record

The provenance the ship-readiness review asked for: what was measured, on which code, with which questions, and
what the app answered. Everything here is public (U.S. Department of Justice press releases). Nothing from the
owner's ledger is included.

## Identity

| Item | Value |
|---|---|
| Code measured | `f685315c` on `investigations-next` (built in a clean worktree by `chain-ho9.sh`; both modes) |
| Generated | 2026-10-28, **after** the fixes it measures; no case or question was seen before the run |
| Generator | `scripts/casebench/chronology.py --cases 60 --seed 4747 --skip-keys skip-chron` (sets 1–8 skipped, so no prosecution repeats) |
| Rewording | `scripts/casebench/paraphrase.py --per 2`: each question in two new wordings by Claude. Public text only; the key file lives outside the repo. |
| Scorer | `scripts/casebench/ccsscore.py` (copied from the bench workspace for reproducibility) |
| Modes | **rules**: evidence engine only, AI off. **claude**: Online record reading on (Claude), with the same verification. |
| Questions | `questions/shard-*.truth.jsonl` (932, with the expected answer and how it is scored) |
| Answers | `results/results-{rules,claude}.tar.gz` (every answer, its citations and its confidence) |
| Scores | `score-rules.txt`, `score-claude.txt` (by question kind) |

## Results

| Mode | n | Right (incl. honest refusals) | Wrong | Answerable questions right | Wrong on answerable | Honest refusals of unanswerable questions |
|---|---|---|---|---|---|---|
| rules | 932 | 96.6 % | 1.7 % (16) | 782 / 812 = 96.3 % | 14 / 812 = 1.7 % | 118 / 120 (2 answered wrongly) |
| claude | 932 | 97.2 % | 1.5 % (14) | 786 / 812 = 96.8 % | 14 / 812 = 1.7 % | 120 / 120 |

"Right" counts an honest refusal of a question the record cannot answer. The "answerable" columns exclude those
120 questions. Not right and not wrong: rules 13 missed and 3 dumps (raw text); claude 10 missed and 2 dumps.

The previous held-out set (ho8, on `a68e64d5` / `2e7d54e6`): rules 93.9 % / 3.4 % wrong; Claude 96.8 % / 1.5 %.

**The ≤ 1 % wrong target is not met** in either mode.

## Not yet done

- **Human adjudication.** Every "wrong" was scored by the automatic scorer against generated truth. The dev-set review on
  2026-10-28 found several "wrong" charge answers that quote the actual charges while the truth holds a vaguer
  paraphrase (scoring-truth disagreements). An independent person should adjudicate all 14–16 wrong answers per mode
  and a sample of the right ones before any figure is used externally.
- Measurement of the other answer families (email, workplace, finance) on held-out material. Enron has no fresh
  mailboxes of useful size left (see `docs/FINAL_BRIEF_EXECUTION.md` §B).
