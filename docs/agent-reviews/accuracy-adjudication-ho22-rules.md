# AGENT ADJUDICATION — not a human adjudicator (owner direction 2026-11-01)

This adjudicates the fresh held-out set **ho22-chron** on the **rules** path (AI off). An AI agent (Claude) did the work as an independent adjudicator, on the owner's written direction of 2026-11-01. It is not a human sign-off. The opus5 path of the same set is adjudicated separately, in its own file, by another agent.

| | |
|---|---|
| Set | ho22-chron. FRESH: seed 20261109, 60 public DOJ prosecution cases, skip-chron x1–x23, so 0 overlap with earlier sets. Generated 2026-11-03 before any run. |
| App commit | e49783fd. Unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1. |
| Path | rules (AI off), 0 Claude calls. Run 2026-11-03T07:03:57Z–07:06:47Z. 928 questions. Valid: 0 OCR failures. |
| Automatic score | n=928, right 96.8 %, **wrong 2.4 %** (22 wrong, 8 missed, 120 honest refusals, 778 correct). Scorer sha256 060e98b9… (same as ho14–ho20; still not pinned to a file in the tree). |
| Inputs (sha256) | sheet `~/CaseBench/adjudication/ho22-rules-sheet.csv` d355439f70a2b7ed276b3ee76e4d6526cb5b4eb1a21a71dd0e5f37d037f0db59 · key `ho22-rules-key.csv` bf1ac7848aea7fdc9cdb3d5db3722c81080dc00328589be016f0bd438b2a7ffc · results `~/CaseBench/ho22-chron/results-rules/*.jsonl` (6 shards, concatenated) bd94a641375267c15b7754c4279a7685851f348517071231ac5ee0a8f7391e68 · score-rules.txt 4a372bf9… · MEASUREMENT-rules.txt e9f2b08c… |
| Output | `~/CaseBench/adjudication/ho22-rules-adjudicated.csv` (sheet + verdict, note, adjudicator = "AGENT (Claude)", cause class), sha256 fb15488f93e9713298dd6535ce32a97b01057830ee8ae34fa1160229e84586c3. |
| Release bar | **≤ 3 % wrong per path (owner decision 2026-11-02).** The earlier ≤ 1 % bar is also reported. |

## Method

The judgement rules are the same as in ho20 (`accuracy-adjudication-ho20.md`, Method step 3). Coverage is different. This round uses the blinded adjudication pack (`scripts/casebench/adjudication_pack.py`): **every** item the scorer did not count correct or honest refusal (30), plus a seeded **simple random sample of 100** of the other 898, shuffled together. ho20 instead ran full scans of the date, charge, timeline, office and count families. So the primary rate below is an **estimate** from the sample, not a census.

1. **Blind first.** I judged all 130 items against the case documents before I opened the key. After that, the key was used only to map items to cases and families and to name the key's defects. The sheet's cited sources map items to cases too.
2. **Documents.** Work folder: `~/CaseBench/adjudication/ho22-rules-work/`. All 136 case documents were extracted:
   - PDFKit text layer for the PDFs (`ext.swift`, with **no** OCR fallback);
   - `textutil` for doc, docx, html and rtf;
   - plain text as it is.

   Nine PDFs in four cases have no text layer: Murillo Prijic, John Thompson, Payne and Coley. For those I used the source releases from `~/CaseBench/raw/doj` (`src.py`), matched on title and date: `release-N-src-*.src.txt`. No OCR or Vision was run. Kelly's release-2 and release-3 are byte-identical (MD5 8931397…).
3. **Verdicts:** correct / wrong / partly correct / should have refused / refusal was wrong (= MISSED) / honest refusal. The ho20 rules apply:
   - PARTLY means the main claim is true but incomplete, or a secondary row or value is misdated or spurious.
   - An offence named only by reference back ("the charge") is PARTLY.
   - "It gives no other day" is PARTLY where the release states another day for the step.
   - A hedged "(date of the report)" row that is otherwise true is a minor CORRECT.
   - A "who was convicted of …, was sentenced" row dated on the sentencing day is a minor CORRECT.
   - Office: the investigating component alone is a minor CORRECT when no district is named.
4. **Progress file:** `verdicts.csv` (item, verdict, cause, note), appended per item. `tally.py` produces the CSV and the tables below.
5. **Estimate.** Let F be the flagged items and S the sample, with weight w = 898 / 100 = 8.98 per sampled item:

   est(class) = (# of F judged class) + w × (# of S judged class)

   rate = est / 928.

   Per family, w_f = (unflagged items in family f) / (sampled items in family f), which is post-stratified. The bound comes from the sample: with 0 sampled wrongs in 100, the exact (Clopper–Pearson) upper bound on the unflagged wrong rate is 2.95 % one-sided 95 % (3.62 % two-sided 95 %). Applied to 898 of 928 items, that gives 2.85 % (3.50 %) overall.

## Results

| measure | flagged (30) | sample (100) | estimate | % of 928 |
|---|---|---|---|---|
| wrong + should have refused (**primary**) | 0 | 0 | 0 | **0.00 %** (95 % upper bound 2.85 % one-sided / 3.50 % two-sided) |
| missed (refusal was wrong) | 8 | 0 | 8 | 0.86 % |
| partly correct | 8 | 5 | 8 + 5 × 8.98 = 52.9 | 5.70 % |
| **wrong + missed** | | | 8 | **0.86 %** |
| **wrong + partly** (strict) | | | 52.9 | **5.70 %** |
| wrong + partly + missed | | | 60.9 | 6.56 % |
| correct / honest refusal | 14 / 0 | 81 / 14 | | |

### By family (estimates; n per family from score-rules.txt)

| family | n | flagged | sampled | unflagged | wrong F/S | wrong % | missed F+S | wrong+missed % | partly F+S | wrong+partly % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 1 | 9 | 119 | 0/0 | 0.00 % | 1+0 | 0.83 % | 0+1 | 11.02 % |
| timeline | 120 | 2 | 18 | 118 | 0/0 | 0.00 % | 0+0 | 0.00 % | 2+1 | 7.13 % |
| count | 120 | 2 | 10 | 118 | 0/0 | 0.00 % | 0+0 | 0.00 % | 0+0 | 0.00 % |
| office | 120 | 2 | 17 | 118 | 0/0 | 0.00 % | 0+0 | 0.00 % | 0+1 | 5.78 % |
| absent | 120 | 0 | 14 | 120 | 0/0 | 0.00 % | 0+0 | 0.00 % | 0+0 | 0.00 % |
| charge | 110 | 13 | 11 | 97 | 0/0 | 0.00 % | 1+0 | 0.91 % | 6+1 | 13.47 % |
| plea | 98 | 2 | 9 | 96 | 0/0 | 0.00 % | 2+0 | 2.04 % | 0+0 | 0.00 % |
| sentence | 82 | 8 | 7 | 74 | 0/0 | 0.00 % | 4+0 | **4.88 %** | 0+0 | 0.00 % |
| charged | 38 | 0 | 5 | 38 | 0/0 | 0.00 % | 0+0 | 0.00 % | 0+1 | 20.00 % |

**Families above 3 %:**
- **Primary (wrong):** none.
- **Wrong + missed:** *sentence* (4.88 %: Roark ×2 and Payne ×2 false refusals).
- **Wrong + partly:** *charged* 20.0 %, *charge* 13.5 %, *sentenced* 11.0 %, *timeline* 7.1 % and *office* 5.8 %. Four of these five come from one sampled PARTLY each, multiplied by a family weight of 7–13. They are very noisy.

## Every wrong item

**None.** No answer on the sheet states something the documents do not support or contradict, or answers about the wrong person or case. The sample found no FALSE CORRECT. Therefore no WRONG item and no wrong cause class are listed. The misses and PARTLY items follow, with their causes. The verdict and decisive quote for every item are in the adjudicated CSV.

### Misses (refusal was wrong) — 8, all scorer-flagged, all confirmed

| items | case | cause | decisive passage |
|---|---|---|---|
| A0048, A0059 (plea ~p2, ~p1), A0093 (charge ~p2), A0094 (sentenced ~p1) | Murillo Prijic | **X (NEW): the person's four-word name shortened to three words, then the new full-name gate (dabb91f1) refuses.** The refusal reads "No readable document in your archive names *Arturo Carlos Murillo*". The documents name him "Arturo Carlos Murillo Prijic", so `namesFully` sees a further capitalised surname ("Prijic") after "Arturo Carlos Murillo" and treats it as another person. Other paraphrases (timeline, count, office, charge ~p1, sentenced ~p2) parsed the full name and answered from the same documents. On "Did Arturo Carlos Murillo Prijic …", the 2–4-word name pattern in `ProceedingAnswerer.person(in:)` (l.60) takes "Did Arturo Carlos Murillo" and then drops "Did", which explains plea ~p1. The path that shortened the other three wordings was not reproduced: no harness run this round. **This is a regression introduced by the ho21 fix** (it fails closed: a miss, not a wrong). | "Arturo Carlos Murillo Prijic, 58, of Bolivia, pleaded guilty on Oct. 20, 2022, to one count of conspiracy to commit money laundering." / "The former Bolivian Minister of Government was sentenced today to 70 months in prison …" (Jan. 4, 2023; scanned PDF, source release text) |
| A0066, A0103 (sentence ~p1, ~p2) | Charles Allen Roark | **F (term not read):** "don't state a sentence". The sentencing sentence states the term after the judge's name and a dash-and-parenthesis structure. No sentencing hit carried a term (`.sentenceImposed` l.545 needs `detail`). The exact failing step was not reproduced. | "Charles Allen Roark, 38, of Jefferson City, was sentenced by U.S. District Judge Stephen R. Bough to 12 years in federal prison without parole – 10 years, which is the statutory maximum penalty for the offense, plus a consecutive sentence of two years for his supervised release revocation (…)" (Nov. 9, 2016) |
| A0072, A0085 (sentence ~p2, ~p1) | Philip G. Payne | **K (descriptive lead):** the term sentence names no person ("The former Operations Manager …"). The next sentence names Payne but holds no term. | "The former Operations Manager of Midamar Corporation (Midamar) of Cedar Rapids, Iowa, … was sentenced yesterday to serve a three year term of probation. Philip G. Payne, 50, of Ryan, Iowa, received the sentence after having pleaded guilty …"; "In addition to the three year term of probation, Payne was ordered to pay a fine of $20,000." (Oct. 2, 2015; scanned PDF, source release text) |

### Partly correct — 8 flagged + 5 sampled

| items | case | cause | decisive passage |
|---|---|---|---|
| A0005, A0128 (charge) | Fry | E: the headline alone; one of two counts | Quote "Jerseyville Man Charged With Conspiracy to Distribute Methamphetamine"; the indictment also charges "possession of a firearm while being a user of a controlled substance" (Nov. 17, 2017) |
| A0064, A0091 (charge) | Joshua Mark Davis | E/S: offence only by reference back (ho20 Freddie Lewis rule; **sensitivity: WRONG**) | Answer "Davis entered a plea of guilty to the charge."; the document says "pleaded guilty on March 19, 2026, to the charge of threatening to unlawfully damage and destroy a building on the Choctaw Indian Reservation" |
| A0058, A0076 (charge) | Montes-Villalpando | G′: one case framed as "two prosecutions, or two people of that name"; quotes cut before or at the offence | "…pleaded guilty before U.S. District Judge Lawrence …" / "…who were convicted of conspiring to harbor aliens f…" (May 6 / Sept. 28, 2021) |
| A0063 (charge, sample) | Shriver | G′: same framing; offence right | "On Oct. 22, 2010, Shriver pleaded guilty to a one-count criminal information charging him with conspiracy to communicate national defense information …" |
| A0036, A0097 (timeline) | Sanchez-Lopez | F (NEW form): "agreed to plead guilty" not read as the plea, so release-1 is unused. The plea is listed only as a hedged row on the sentencing day, and the June 2016 charge is missing. Order still possible. | "Jorge Luis Sanchez-Lopez, 43, of Pawtucket, R.I., agreed to plead guilty to one count of conspiracy …" (Sept. 6, 2017) |
| A0101 (timeline, sample) | Mammen | B′: a duplicate plea row hedged to the release day, though its own quote states the day | "January 5, 2022 (date of the report) — pleaded guilty: 'A man who … pled guilty January 4, 2022'" |
| A0021 (sentenced, sample) | Payne | B′: "it gives no other day" is untrue | "…was sentenced yesterday to serve a three year term of probation." (Oct. 2, 2015 → Oct. 1) |
| A0060 (charged, sample) | Tinkle | B′: "it gives no other day" is untrue | "A federal grand jury returned the 13-count indictment under seal on July 21, 2015, which was unsealed today upon Tinkle’s arrest." (Aug. 4, 2015) |
| A0046 (office, sample) | Francisco Gabriel Diaz | O′: a spurious second office, "the Justice Department's Criminal Division". It is the U.S. Attorney's Office's own Criminal Division. | "Assistant U.S. Attorney Benjamin A. Saltzman of the Criminal Division is prosecuting the case" (July 10, 2024); "… of Rollins’ Criminal Division" (Dec. 19, 2022) |

## Comparison with the scorer

- **The scorer flagged 30 items: 22 wrong and 8 missed.** Adjudicated:
  - 0 wrong;
  - 8 missed (all 8 confirmed);
  - 8 PARTLY (Fry ×2, Davis ×2, Montes-Villalpando ×2, Sanchez-Lopez ×2);
  - **14 correct**, which are scorer or key errors (below).
- **The sample of 95 items the scorer scored correct or honest refusal:** 0 wrong and 5 PARTLY (Payne *sentenced*, Tinkle *charged*, Mammen timeline, Shriver charge, Diaz office). There are no FALSE CORRECT wrongs.
- **Net:**
  - automatic: 2.4 % wrong + 0.9 % missed;
  - adjudicated: **0.00 % wrong (estimate)** + 0.86 % missed.

**Scorer and key errors** (bench fixes, not app fixes):

| type | case | the defect |
|---|---|---|
| truth-label | Narsan Lingala *sentence* ×2 | The key wants "63 months", which is co-conspirator Sandya Reddy's term. His own sentence is "sentenced today to 222 months". |
| truth-label | Eugene A. Kelly *count* ×2 | The key wants 3. Release-2 and release-3 are byte-identical, so there are 2 distinct releases (the same defect as ho20 Durante). |
| truth-label (not decisive here) | Payne *sentence* | The key accepts "1 year / 11 years / 12 months / 132 months", which are the maximum penalties. The actual sentence is "a three year term of probation". |
| scorer | Marcia Abbott *sentence* ×2 | "one month" is rejected: the key lists "one months" and the 8-month government *recommendation*. |
| scorer | Shriver *office* ×2 | The key lists NSD only. Both prosecute: "Assistant U.S. Attorney Stephen M. Campbell of the U.S. Attorney’s Office for the Eastern District of Virginia and Trial Attorney Brandon L. Van Grack … in the National Security Division are prosecuting the case." |
| scorer (`offence_sentences` wants one release's wording) | Tinkle *charge* ×2 | The plea's "charges of wire fraud and money laundering" is right. |
| scorer (as above) | Michelle Smith *charge* ×2 | The indictment's "14 counts of wire fraud and four counts of aggravated identity theft" is right. |
| scorer (as above) | Carter Reese *charge* ×2 | The plea "to one count of wire fraud and one count of mail fraud" is right. The key wants the reference-back sentence "charged by information with those offenses earlier this month". |
| scorer (as above) | Fry *charge* | The key wants "the charges in June and has been in federal custody since January 23", which names no offence. The app's answer is PARTLY for another reason. |

## Bar

- **≤ 3 % (owner bar 2026-11-02): MET on the primary estimate (0.00 %)**, and also with misses counted as wrong (0.86 %). With Davis ×2 counted WRONG instead of PARTLY, the rate is 0.22 %; with that and the misses, 1.08 %.
- **The strict measure, 5.70 %, does not meet 3 %.**
- **The sample does not prove ≤ 3 % at 95 % confidence two-sided** (upper bound 3.50 %). It does one-sided (2.85 %). Paraphrase pairs make the effective sample smaller than 100, which widens the bound.
- For context, the seven full-scan rounds ho14–ho20 pooled 1.24 % wrong on rules (`accuracy-root-cause-ho14-ho20.md` §1). A wrong rate of about 1 % produces 0 of 100 sampled wrongs about 37 % of the time. So 0.00 % here should be read as "consistent with about 1 %", not as zero.
- **≤ 1 %: MET on the point estimate** (0.00 %; 0.86 % with misses). It is **not** demonstrable from a 100-item sample.

## New cause classes

- **X (new): the four-word name is shortened, then the ho21 full-name gate refuses** (Murillo Prijic, 4 misses). This is a regression introduced by dabb91f1, though a fail-closed one. Fixable:
  - `person(in:)` should not count a question-initial "Did/Was/When …" against the four-word limit;
  - the absent-person check should run on the longest capitalised run in the question.
- **F, new form: "agreed to plead guilty" is not a plea step** (Sanchez-Lopez timeline PARTLY).
- Recurring classes this round: K (descriptive lead, Payne miss), B′, E/S, G′ and O′ (PARTLY only). No P, A, B, H or C wrong occurred.
