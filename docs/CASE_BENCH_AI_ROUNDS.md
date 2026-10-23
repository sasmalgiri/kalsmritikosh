# Case bench — full-AI answer quality, rounds 3–6 (2026-10-23/24)

The same 190 public cases (10 per category, 19 categories) were used in every round. Every case was asked, and every
second case was worked as an investigation. Apple's on-device model ("AFM 3 Core Advanced") was on, with 4 parallel
test hosts.

"Right" means correct, or an honest refusal where the documents don't contain the answer. Scoring is by
`scripts/casebench/ai1000_report.py`. The raw results are in `~/CaseBench/ai200/`:
- `round3/` holds round 3;
- `results/` holds round 4;
- `results5/` and `results6/` hold rounds 5 and 6;
- `REPORT-round*.md` holds each round's report.

| Round | Build | What changed | Scope |
|---|---|---|---|
| 3 | f39cedad (main) | baseline | all 19 categories |
| 4 | 64715db2 | case file, studio name/amount digest, schema repair | all 19 categories |
| 5 | f1b74753 | + when-questions need a date (DateQuestionGate), which-office gate, named-document focus | court-civil + 11 DOJ |
| 6 | 630e178c | + the office gate reads the cited documents | the 4 DOJ categories with the most office misses |

**Overall: 62.8% (round 3) → 80.4%** right over 621 answers, using each category's latest measurement.

| Category | Round 3 | Latest | Latest from |
|---|---|---|---|
| court-civil | 42.9% | 55.4% | r5 |
| court-criminal | 75.9% | 79.6% | r4 |
| doj-cybercrime | 48.1% | 81.5% | r5 |
| doj-drug-trafficking | 50.0% | 76.9% | r5 |
| doj-environmental-crime | 48.1% | 70.4% | r5 |
| doj-financial-fraud | 28.0% | 84.0% | r6 |
| doj-health-care-and-pharma-fraud | 52.0% | 76.0% | r5 |
| doj-immigration-crime | 50.0% | 77.3% | r5 |
| doj-other-federal-crime | 38.5% | 76.9% | r5 |
| doj-police-misconduct | 16.0% | 68.0% | r6 |
| doj-public-corruption | 52.0% | 80.0% | r5 |
| doj-tax-crime | 37.0% | 85.2% | r6 |
| doj-violent-crime | 32.0% | 72.0% | r6 |
| fda-device-recall | 95.0% | 95.0% | r4 |
| fda-drug-recall | 92.5% | 92.5% | r4 |
| fda-food-recall | 100.0% | 100.0% | r4 |
| nhtsa-defect | 85.0% | 85.0% | r4 |
| ntsb-aviation | 87.5% | 87.5% | r4 |
| osha-workplace | 83.9% | 80.6% | r4 |

Round 4 → round 5 on the 12 weak categories (336 answers):

| Outcome | Round 4 | Round 5 |
|---|---|---|
| Correct | 87 | 92 |
| Honest refusal | 73 | 142 |
| Wrong | 60 | 25 |
| Unsupported | 96 | 27 |
| Missed | 14 | 46 |

All 46 misses were "which office" questions. Round 6's fix raised office answers to 30–60% correct on the four
shards it measured.

**Still open (Q-2):** court-civil is at 55%, against an 80% target. The remaining misses are:
- opinion authors and outcomes in decisions the question doesn't name by caption;
- outcome wording such as "affirmed in part".

**Release dates:** most DOJ releases carry no calendar date in their text, so an honest refusal is the right answer
there. That is a limit of the benchmark, not a defect.

**Speed:** median answer time is 29 s (90th percentile 78 s).
