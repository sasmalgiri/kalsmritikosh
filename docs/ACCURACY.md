# Accuracy — what was measured, and the bar it is held to

**Not measured on this version (2026-11-04).** The release candidate (`investigations-next`, plan A: the whole-case
reader, plans and credits) changed the answer path after every measurement below, and testing of this candidate is
simulation-only by owner decision. The figures below describe EARLIER code; no public page quotes them as the
product's accuracy. The website's FAQ says accuracy has not been measured on this version (CLAIMS.md
`accuracy.declared`).

**Bar (owner decision, 2026-11-02): at most 3 % of answers wrong, per answering path.** The original target was
≤1 %. It was raised because seven fresh measurement rounds (ho14–ho20, 2026-11-01/02) showed the wrong-answer rate
of the rules path moving between 0.22 % and 2.23 % from one fresh set to the next (pooled about 1.2 %), and the cause
is not yet removed (see "Why it does not stay under 1 %"). The raise is declared here rather than hidden.

## What was measured

- **Material:** public U.S. Department of Justice press releases following one prosecution across several releases;
  60 prosecutions per round, drawn fresh each time (no prosecution reused across rounds), English only.
- **Questions:** when a person was charged / pleaded / was sentenced, what they were charged with, what sentence
  they received, which office prosecuted, how many releases name them, the case timeline, and questions about a person
  no document names (which must be refused). Each question is also asked in two reworded forms.
- **Paths:** *rules* — AI off, answers read from the documents by fixed rules; *Opus 5* — Online mode with the person's
  own Anthropic key, Claude's reading shown only if it verifies against the documents.
- **Judging:** every answer the automatic scorer flagged, every date and charge answer, and a random sample of the rest
  were judged against the documents by an **AI agent adjudicator** (not a person) — by the owner's direction of
  2026-11-01. The automatic scorer's own answer key is wrong more often than the app, so its raw figure is not used.

## Result on the release measurement (ho20, 936 questions per path)

| path | wrong | wrong + missed | wrong + partly correct | meets ≤3 % |
|---|---|---|---|---|
| rules (AI off) | 0.75 % | 1.18 % | 5.24 % | yes |
| Opus 5 (Online) | 0.21 % | 0.64 % | 4.27 % | yes |

Every question family is at or below 2.8 % wrong on both paths. **Partly correct answers are common in timelines**
(about one timeline in five misses a step or dates one step from the release day). Read every timeline against its
sources. Questions refused because no document names the person were refused correctly in every round.

## Why it does not stay under 1 %

The app decides *whose* step a sentence reports, *which* date belongs to it, *which* case it is (this one or an
earlier one) and *what* offence is named by matching wording against rules. Each fresh set states those four things
in new wordings; about 7 in 10 wrong answers fall in "whose step" and "which date". No new kind of error has appeared
since ho16 — only new wordings of the same kinds. With Online mode on, the AI path still inherits some rules answers:
the rules decide the question type first, timelines, offices and counts are answered by rules only, and when Claude's
reading fails verification the rules answer is shown. This is a design limit of the current answering path, not a
limit of current technology; the planned change is to let the verified AI reading answer every proceeding question,
with the rules as a cross-check that marks the answer "needs review" when they disagree.

## Limits

These figures hold for the material measured (DOJ prosecution releases, English). Other kinds of documents were not
measured this way. Every answer quotes and cites its source; check it before relying on it. Records:
`docs/agent-reviews/accuracy-adjudication-ho14.md` … `-ho20.md`, `docs/agent-reviews/accuracy-root-cause-ho14-ho20.md`.
