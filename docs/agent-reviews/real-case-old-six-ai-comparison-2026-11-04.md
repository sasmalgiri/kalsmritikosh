# The six earlier real cases with AI: three arms compared

**AGENT-run** (AI judge, no human review) · **Date:** 2026-11-04 · No app code was edited and nothing was committed. This file is the only output.

## What was compared

| arm | build | what the AI did | data used here |
|---|---|---|---|
| **1 · AI off** | `c3e8c5b0` | nothing (rules path) | `runs/<case>/r1..r5`; judged in `real-case-evaluation-2026-11-03.md` |
| **2 · Opus 5 as wired then** | `c3e8c5b0` | question interpreter, rewriter and verified record extractor; no AI-written answers; no AI in the workflow | `runs-opus5/<case>/r1..r5`; judged in `real-case-evaluation-opus5-2026-11-03.md` |
| **3 · Opus 5 everywhere** | `14e0708b` | AI-written verified answers with a rules cross-check ("Needs review"), AI contradiction reader, role reader, draft reader | `archive-v2a/runs-v2/<case>/r1` only |

## Method

1. **Which arm-3 data counts.** Only round r1 of rc-a, rc-b, rc-c, rc-d and rc-f is used for arm 3.
   - In each of those r1 files every Ask answer made 1–3 Claude calls, and the footer reads "cloud readers (claude-opus-5) … 0 failed".
   - "credit balance is too low" appears 0 times in r1.
   - It appears 8–9 times in every later round (r2/r3), and those rounds fell back to rules. They are excluded.
   - rc-e has no AI data at all (see §6).
2. **Judging.** Five AGENT sub-judges, one per case, worked from the sealed key `keys/<case>.json` and the document texts. They followed one protocol (`/tmp/oldsix/PROTOCOL.md`).
   - **Arm 3 r1:** every Ask answer got a verdict. In-case answers were noted wherever they differed from Ask. The sub-judges also audited every "Needs review" banner, every contradiction, the drafts (chronology, cast, gaps and leads), the findings text, the key facts and the traps.
   - **Arms 1 and 2 r1:** every Ask answer was rescored under the same protocol, so all three arms have r1-versus-r1 rates.
   - **Like-for-like:** each arm-3 question was matched to the same or the closest equivalent question in arm 1 and in arm 2, from any of their five rounds.
3. **Verdicts:**
   - **C**: correct.
   - **P**: partly; true but incomplete, or right but under a banner.
   - **W**: wrong; at least one false statement shown as an answer.
   - **WAC**: wrong at normal confidence; W at ≥ 0.5 with no "Needs review" or "may not answer" caveat.
   - **N**: non-answer, with no false claim.
   - **RW**: refused wrongly. **RC**: refused correctly.
   - Correct % = (C + RC) / n.
4. **Spot checks.** I checked the quotes used below against `answers.md` myself, e.g. rc-a q13 "June 23, 2023 — sentenced", rc-f contradictions 1/4/7, rc-d q14, rc-b in-case q01, rc-c q11, rc-f chronology 23 and q11. Every one matched.

## Limits

1. **Arm 3 had one round; arms 1 and 2 had five.**
   - Key-fact totals across rounds are **not comparable**: arm 3 has 81 questions in 1 round; arm 1 has about 442 in 25 rounds and arm 2 about 386 in 25 rounds on these five cases.
   - The comparable measures are per-question rates (r1 vs r1, and matched questions) and key facts reached **in round 1**.
   - Round 1 sizes are similar: 81 / 85 / 83 questions for arms 3 / 1 / 2.
2. **Arm 3 is tuned on these cases. It is a regression check, not an independent measure.**
   - The fixes in `14e0708b` and its parents were partly designed against defects found in these same six cases, e.g. `ac0733b2`: "real-case evaluations: 0 of 4 contradictions in every run; judges and U.S. Attorneys listed as defendants; every date a day early".
   - Gains here show those defects were fixed on the cases they came from. They do not show the gain carries over to new cases. Use the second real-case set (rc2-*) for that.
   - The later commit `90c2643d` (EvidenceOnTarget, contradiction filters) is **not measured here**.
3. **Matching favours arms 1 and 2.** Their equivalents could come from any of five rounds, after the investigators had refined their wording. Arm 3's questions are first-round wording.
4. **The question sets differ.** The arm-3 r1 questions were written for that run, so equivalence is judged and some matches are loose (marked in the per-case notes).
5. **Judging limits.** There are no humans, and n = 5 cases with one sub-judge each. Counts are direction plus magnitude, not precise rates. The arm-1/2 r1 rescoring used a stricter per-answer protocol than the 2026-11-03 reports, so the numbers are not identical to those reports.
6. **Harness, not the GUI.** The ACH matrix, Watchlists, deconfliction and the chronology UI were not exercised.

---

## 1. Headline: per arm, round 1

**Ask answers, all r1 questions:**

| | arm 1 · AI off | arm 2 · Opus 5 as wired | **arm 3 · Opus 5 everywhere** |
|---|---|---|---|
| questions (5 cases, r1) | 85 | 83 | **81** |
| correct (C+RC) | 12 (**14.1 %**) | 11 (**13.3 %**) | 36 (**44.4 %**) |
| partly | 13 (15.3 %) | 15 (18.1 %) | 26 (32.1 %) |
| wrong (any) | 13 (**15.3 %**) | 21 (**25.3 %**) | 8 (**9.9 %**) |
| **wrong at normal confidence, per 100 q** | **9.4** | **20.5** | **2.5** |
| non-answer | 37 (43.5 %) | 30 (36.1 %) | 11 (13.6 %) |
| refused wrongly | 10 (11.8 %) | 6 (7.2 %) | **0** |

**Matched questions, the same or equivalent question in each arm:**

| | arm 1 (75 rows) | arm 2 (76 rows) | arm 3 on arm 1's rows (75) |
|---|---|---|---|
| correct | 17.3 % | 17.1 % | **46.7 %** |
| wrong | 16.0 % | 25.0 % | **9.3 %** |
| WAC per 100 | 10.7 | 19.7 | **2.7** |
| non-answer + wrongly refused | 54.7 % | 43.4 % | 12.0 % |

**Workflow and coverage:**

| | arm 1 | arm 2 | arm 3 |
|---|---|---|---|
| **contradictions flagged, real / false** | 0 / 0 | 0 / 0 | **13 / 9** (+1 doubtful), 23 items |
| keyed contradictions caught | 0 of 4 | 0 of 4 | **3 of 4** (all 3 in F; A's transacting missed) |
| **key facts reached in round 1** (65 for the five cases): yes / partly / wrong / no | 10 / 20 / 6 / 29 | 16 / 18 / 5 / 26 | **44 / 15 / 0 / 6** |

**Other measures:**
- **Wrong statements in arm 3's in-case answers** (AI on, 2 calls each): 9 W, 3 WAC.
- **The arm-3 "Needs review" banner.** 17 Ask answers carried the "different values" banner; **all 17 were false alarms**. In every one the AI reading was right and the rules reading was off-target or wrong. There were 10 "could not confirm" banners: 5 were justified and 5 were retrieval misses where the record holds the answer.

**Context for the round-1 key facts:**
- Over all five rounds (prior reports, looser "found incl. partial" scoring), arm 1 reached 39 of 65 key facts with 5 wrong, and arm 2 reached 48 of 65 with 5 wrong.
- **Arm 3 reached 59 (44 yes + 15 partly) of 65 in one round with 0 wrong.**
- This is a coverage-per-round comparison, not a total comparison. Arm 3 never ran rounds 2–5 with AI.

## 2. Per case

### Per-question rates (Ask, r1)

| case | arm | n | C+RC | P | W | WAC | N | RW |
|---|---|---|---|---|---|---|---|---|
| **A** upfront-fee | 1 | 16 | 2 | 2 | 2 | 2 | 5 | 5 |
| | 2 | 16 | 2 | 3 | 3 | 3 | 3 | 5 |
| | **3** | 18 | **8** | 7 | 2 | 1 | 1 | 0 |
| **B** hutchins | 1 | 15 | 5 | 2 | 2 | 2 | 6 | 0 |
| | 2 | 15 | 5 | 1 | 2 | 2 | 7 | 0 |
| | **3** | 17 | **9** | 3 | 1 | 0 | 4 | 0 |
| **C** NTSB Moncks Corner | 1 | 19 | 0 | 4 | 6 | 1 | 8 | 1 |
| | 2 | 18 | 1 | 4 | 6 | 3 | 6 | 1 |
| | **3** | 16 | **10** | 3 | 1 | 0 | 2 | 0 |
| **D** Enron/Watkins | 1 | 15 | 0 | 2 | 1 | 1 | 11 | 1 |
| | 2 | 16 | 0 | 2 | 4 | 3 | 10 | 0 |
| | **3** | 15 | **4** | 6 | 1 | 1 | 4 | 0 |
| **F** Logan arson | 1 | 20 | 5 | 3 | 2 | 2 | 7 | 3 |
| | 2 | 18 | 3 | 5 | 6 | 6 | 4 | 0 |
| | **3** | 15 | **5** | 7 | 3 | 0 | 0 | 0 |

### Matched questions (correct / wrong / WAC)

| case | rows | arm 1 | arm 2 | arm 3 |
|---|---|---|---|---|
| A | 18 / 17 | 3 / 3 / 3 | 4 / 5 / 5 | 8 / 2 / 1 |
| B | 16 / 17 | 5 / 2 / 2 | 5 / 3 / 3 | 9 / 1 / 0 |
| C | 16 / 15 | 2 / 4 / 0 | 2 / 5 / 2 | 10 / 1 / 0 |
| D | 14 / 14 | 0 / 1 / 1 | 1 / 2 / 1 | 4 / 1 / 1 |
| F | 11 / 13 | 3 / 2 / 2 | 1 / 4 / 4 | 4 / 2–3 / 0 |

### Contradictions, key facts and workflow

| case | contradictions, arm 3 (real / false) | keyed caught (arm 1 · 2 · 3) | key facts in r1, yes+partly (arm 1 · 2 · 3) | arm-3 drafts and findings |
|---|---|---|---|---|
| A | 0 / 3 | 0 · 0 · 0 of 1 | 4 · 5 · **12** of 13 | chronology 10 of 12 right, 1 wrong (release date); cast 4 defendants right, 4 junk; gaps 1 useful of 8; findings still have "Judge John Michael Vazquez convicted" |
| B | 3 / 4 (+1 doubtful) | key has none | 5 · 5 · **10** of 10 | chronology 15 of 23 right, 4 conviction steps on release dates, no John plea; about 17 non-person cast "others"; gaps 13 useful, 8 false |
| C | 0 / 0 | reference tensions 0 · 0 · 0 | 6 · 6 · **13** of 13 | chronology 3 of 3 right but day-level only; **cast has 0 persons**; leads 3 useful, 3 false; findings keep the San Diego date and "employer: In Systems" |
| D | 0 / 1 | key has none (Fastow leave vs ousted missed in all arms) | 9 · 11 · **10** of 15 | chronology dates right after the UTC fix, but only 2 of 27 items relevant; 26 of 40 cast junk; about 14 false gaps; findings still open "On 1996-05-24" |
| F | **10 / 1** | 0 · 0 · **3 of 3** | 6 · 7 · **14** of 14 | chronology 21 of 24 right, 2 wrong-person; defendants right, no official as defendant; about 6 false gaps; findings dates no longer a day early |

---

## 3. Per-case detail and examples

### A — rc-a-upfront-fee

**What arm 3 fixed:**
- **Role questions.** Arms 1 and 2 refused every role question: "The documents searched don't mention the role." Arm 3 q03: "Adkins, along with Mignott, Douglas, and Gillar, allegedly agreed to defraud an entity identified as "Victim Company A" out of approximately $1 million … A superseding indictment added three counts of wire fraud against Adkins."
- **Mignott's term.** Arm 1 r1 q12 said "Harold Mignott was sentenced to six years in prison." Arm 3 q10: "Harold Mignott was sentenced to three years in prison."
- **The amount paid.** Arm 2 r1 q03 dumped "conflicting values for amount: • $250,000 • $800,000 • $90,000". Arm 3 q06: "transmitted $800,000 of the $1 million".
- **Adkins as a gap.** The drafts raise the gap the old workflow never raised: "The outcome for James Adkins — a plea, verdict, dismissal or sentence — is not in any document of this case."

**What is still wrong:**
- **Release date as the event date, at 0.8.** q13: "June 23, 2023 — sentenced: …". The findings say "On 2023-06-23 — Roy Johannes Gillar sentenced". The sentences were imposed June 22, and q14 gets that right.
- **Restitution and forfeiture not read.** q15 (0.35, Needs review) falls back to "Your archive carries conflicting values for amount: • $1,000,000 • $250,000 • $800,000 • $90,000".
- **All 3 contradictions are false:**
  - "Amount — Million Advance Fee Scheme: $1 Million vs $800,000" (headlines; case growth);
  - "four victims vs two individual victims" (growth);
  - "approximately $250,000 vs $1 million" (fee vs paid, same document).
- **The keyed transacting-in-proceeds inconsistency is missed.** q04 silently states the release-03 version as fact.
- **False gaps:** "The terms of the sentence … imposed on Jerrid Douglas", although release-05 gives them.
- **An official as a defendant** in the findings: "On 2022-10-21 — Judge John Michael Vazquez convicted".

### B — rc-b-hutchins

**What arm 3 fixed:**
- **Restitution.** Both earlier arms said "No — the documents give hutchins: • Rapids Theatre Niagara Falls, USA, Inc." (WAC). Arm 3 q13: "John L. Hutchins was ordered to pay full restitution to the Small Business Administration and the victim banks."
- **Loan amounts.** q04 now reads "Economic Injury Disaster Loans totaling $779,500.00, SVOG loans totaling $989,905.05 and PPP loans totaling $115,978". Before, it was the card.
- **Soliman.**
  - The must-not-conclude held: no Soliman plea was claimed. Arm 2 had "Yes — “Rapids Theatre owner pleads guilty…”".
  - "Charges remain pending against Roberto Soliman." surfaced, as a gap.
- **A real age contradiction:** "Roberto Soliman, age: 40 vs 45."

**What is still wrong:**
- **False contradictions from growth** (the key lists this as a trap): "Count — Economic Injury Disaster Loans: four vs five." It appears twice, plus a $749,500 vs $779,500 pair and a PPP pair.
- **In-case q01: the wrong rules reading leads at 0.65 with no banner.** "The documents state more than one charge for John L. Hutchins (two prosecutions, or two people of that name)". The correct AI reading is demoted to a note.
- **A false Needs review on a right answer.** q12: both readings say "Judge Meredith A. Vacca".
- **Look-alikes and retrieval misses:**
  - q07 shows Patricia's "As part of her plea agreement, Hutchins must pay restitution…" for John's spending.
  - q16 gives "Western District of New York" for the prosecutor.
  - q17 gives William's cocaine release and "No reasoning provider available".
- **The chronology has no John plea.** It dates convictions on release dates: "2026-01-21 — John L. Hutchins convicted".

### C — rc-c-ntsb-moncks-corner

**What arm 3 fixed:**
- **The ATC sequence, verbatim.** q03: "The controller responded, "if you don't have that traffic in sight turn left heading 180 immediately."" No earlier r1 reached this.
- **The analysis's controller findings.** These were missed by the rules arm. q14: "the controller did not recover from her ineffective visual separation plan…" and "the term "immediately" held different expectations for both parties".
- **Clock times are no longer refused.** q04: "aurally alarmed at 1100:13". q16: "about 40 seconds before the eventual collision, the F-16 and the Cessna had a closure rate of about 300 knots" (key fact #12, missed in every earlier round of both arms).
- **No more junk lines.** The "Status pending" and "Interceptthatcourseat1100" lines are gone from Ask.

**What is still wrong:**
- **q11 (occupants) falls into the history path.**
  - It shows the San Diego accident's date: "Aug 16, 2015: In November 2016, we issued safety recommendations…".
  - It says "(No reasoning provider available — chapters ship without LLM prose)" with Claude on.
- **q15 (probable cause) is no longer a clean refusal.** Arms 1 and 2 said "None of the documents on file states the investigators' conclusion". Arm 3 shows a Needs-review evidence-only line: "In fact, Garmin guidance stated that TIS does not relieve pilots…".
- **The workflow:**
  - 0 contradictions; the witness's 900 ft vs the radar's 1,400–1,500 ft and "no evasive maneuvers" vs "pull up" were missed.
  - **The cast has no person at all.** It lists "Avoid Concept", "Lockheed Martin F-" and "Controller Glossary".
  - False leads, e.g. "The outcome for the occupants of either aircraft…", which the narrative states.

### D — rc-d-enron-watkins

**What arm 3 fixed:**
- **The letter's author.** q01: "The letter's author was later identified as Sherron S. Watkins". Arm 1 gave a Waste Management quote; arm 2 r2 gave "Thanks, Liz --- Kenneth.Lay@enron.com wrote:".
- **The concerns, verbatim.** q02: "Enron has been very aggressive in its accounting -- most notably the Raptor transactions and the Condor vehicle."
- **The arm-2 false date conflict is gone.** That was "14/08/2001 • 23/01/2002".
- **The chronology shows senders' local days.** "2001-10-24 — Email sent", from the 17:09 PDT header.

**What is still wrong:**
- **The Hubbard/Carrington look-alikes win at 0.8 (WAC).** q14: "In that message he asked what Lay and Enron could do about the concerns he and his reports had. She wrote that employees were worried about the stock price and that rumors were flying."
- **The core messages 005, 015 and 056 are never retrieved on Ask.** q12: "The AI reader found no passage stating it among the 2 passages it read." Message 005 holds "the page I reviewed with Lay on 8/22". Key facts #2 and #9–#12 are therefore missed.
- **A false contradiction:** "Date — Ken Lay: Fri, 9 Nov 2001 15:56:33 … vs Thu, 8 Nov 2001 15:35:50" (two different chairman messages).
- **False gaps (about 14).** One says message 015's "recipients and content of the message are not recorded"; it is To: kenneth.lay with a full body.
- **The cast leaves out the key people.** "Average Daily Transactions" and "Vice President" are cast; Watkins, Buy and McMahon are not.
- **The findings still misdate by years.** "On 1996-05-24 — Email correspondence involving iam@michaelberry.com". They are truncated at "rick.buy@en".

### F — rc-f-logan-arson

**What arm 3 fixed:**
- **All three keyed contradictions, against 0 in 10 earlier workflow runs:**
  - "Amount — William Jamey Thompson: $50,000 vs approximately $75,000";
  - who spread the fuel;
  - "what recorded it: 317’s security camera vs the Logan County Courthouse video security system".
  - Caveat: the sub-judge notes the camera item may be two recordings of different things. `90c2643d`'s new "two recordings" rule may now suppress it; re-check.
- **Williams's sentence.** Arm 1 r1 q15 said "Michael Williams was sentenced to 22 months" (Simon's). Arm 3 q11 (AI reading): "Michael D. Williams received a reduced sentence of 32 months in prison on Thursday". The in-case answer also resolves the relative dates: "Glick and Thompson were sentenced in federal court the day before that release".
- **The payout.** q08: "General Star paid Glick $1,010,000 in insurance policy proceeds in May of 2012". Arm 1 gave the $75k Thompson quote; arm 2 gave "$50,000 • $50 • $10,000".
- **The findings no longer list Booth Goodwin as a defendant,** and their dates are no longer a day early.
- **WAC is 0 of 15**, against 2 of 20 (arm 1) and 6 of 18 (arm 2).

**What is still wrong:**
- **Needs review on 9 of 15 answers, all false alarms.**
  - Each banner's evidence-only half carries the old errors: q06 "Evidence-only reading: Date: 12/12/2013."; q08 and q12 "Your archive carries conflicting values for amount: • $50,000 • $1,000,000".
  - The AI half was right every time, so all 3 W verdicts come from the rules half.
- **Wrong-person chronology rows:** "2014-05-29 — Michael Williams sentenced 22 months in prison for destroying the digital video recorder…". Item 22 does the same for Guy Miller.
- **A false contradiction:** "Guy Miller: February 19, 2014 vs May 28, 2014" (a rescheduled sentencing).
- **A false gap:** "none records the charge … for Michael D. Williams". Release-03 says an information was filed.
- **q15 "what do the documents disagree on" misses what the workflow found.** It offers only age drift: "Earlier releases give Miller's age as 39. A later release gives Miller's age as 40."

---

## 4. Top 3 improvements in arm 3

1. **Answers now answer.**
   - Round-1 correct rate rose from 14 % and 13 % to 44 %. Non-answers fell from 44 % to 14 %, and wrongful refusals from 12 % to 0.
   - Examples: rc-a q03 (Adkins's role, refused before); rc-c q03 "if you don't have that traffic in sight turn left heading 180 immediately."; rc-b q04 (loan totals, a "Hutchins:" card before).
   - Key facts reached in one round: 59 of 65 (44 full), against 30–34 in arms 1–2's first rounds.
2. **Wrong-at-confidence fell to 2.5 per 100 questions,** from 9.4 (AI off) and 20.5 (arm 2). The headline errors of the first two evaluations are gone in r1:
   - "Harold Mignott was sentenced to three years in prison." (was six);
   - "Michael D. Williams received a reduced sentence of 32 months" (was 22);
   - "ordered to pay full restitution" (was "No — the documents give hutchins…");
   - "General Star paid Glick $1,010,000" (was $75k or a conflict dump).
3. **The workflow finds real contradictions and roles.**
   - 3 of 4 keyed contradictions were caught (all of F's), plus a real Soliman age discrepancy (B).
   - No official appears as an actor in any arm-3 chronology. One findings line remains, in A.
   - Day-precision dates are no longer a day early.
   - A real open-outcome lead was raised: "The outcome for James Adkins … is not in any document of this case."

## 5. Top 3 remaining problems in arm 3

1. **"Needs review" is noise, and its rules half carries the old wrong statements.**
   - 17 of 17 "different values" banners were false alarms.
   - The evidence-only half shows "Date: 12/12/2013." (F q06), "conflicting values for amount: • $50,000 • $1,000,000" (F q08, q12) and "(two prosecutions, or two people of that name)". The last leads the in-case B q01 at 0.65 with no banner.
   - The banner downgrades right AI answers to 0.45. Investigators will learn to ignore it.
   - (`90c2643d` targets exactly this; it is unmeasured here.)
2. **False contradictions and false gaps.**
   - 9 of 23 contradictions are false:
     - growth over time: "four vs five" (B), "$1 Million vs $800,000" (A);
     - different roles: fee vs paid (A);
     - different messages: "Ken Lay: Fri, 9 Nov 2001 … vs Thu, 8 Nov 2001" (D);
     - a reschedule (F).
   - A's keyed transacting-in-proceeds inconsistency is missed.
   - About 35 false gaps say something "is not recorded" when it is, e.g. D: "The recipients and content of the message are not recorded"; A: Douglas's sentence terms.
3. **Retrieval misses, look-alikes, release dates and junk drafts.**
   - D q14 gives the Hubbard/Carrington look-alikes at 0.8 (WAC). D q12: "The AI reader found no passage stating it" (message 005 holds it).
   - A q13 "June 23, 2023 — sentenced" at 0.8 (WAC; the sentences were imposed June 22).
   - C q11 shows the San Diego date and "No reasoning provider available".
   - Wrong-person chronology rows: F "Michael Williams sentenced 22 months".
   - Junk casts: C has 0 persons ("Avoid Concept", "Lockheed Martin F-"); D omits Watkins, Buy and McMahon.

## 6. rc-e-fda-bluebell

**Arm 3 has no AI data for rc-e.** Every answer in `archive-v2a/runs-v2/rc-e-fda-bluebell/r1–r3` shows "model calls: none" because the credit had run out. Those rounds are the rules path on a newer build and say nothing about Opus 5. rc-e is excluded from every arm-3 figure above, and from the arm-1/2 comparison rows. Its arm-1/2 results stand as reported on 2026-11-03.

## 7. Verdict

**As a regression check on the cases it was tuned on, arm 3 is a large improvement.** Per question it is about 3× as often correct, about ¼ as often wrong at confidence as AI-off, and about ⅛ as often as arm 2. It is the first arm to surface real contradictions. One round reached more key facts than either earlier arm did in its first round, and with no wrong key fact.

**It is not yet clean:**
- 2 WAC in 81 Ask answers and 3 more in-case;
- 9 false contradictions;
- about 35 false gaps;
- a "Needs review" banner that was wrong every time it claimed a disagreement.

**Because the fixes were drawn from these cases, none of this shows the gain carries over.** That must come from the rc2-* set, re-run on `90c2643d` with enough credit for all rounds.
