# rc2-g-vendstar — investigator memo (app v2, Online mode, Opus 5)

Recognition: I have only a vague general memory that a "Vendstar" vending-machine fraud was prosecuted federally; I recalled no names, dates or sentences. Everything below rests on the app's answers and cited passages.

Rounds: 2. r1 (14 questions) ran fully online (cloud readers 0 failed). r2 (16 questions) ran with **every cloud call failing** ("HTTP 400: Your credit balance is too low to access the Anthropic API"), so r2 is an evidence-only (rules) run; I use it only where it is clearly right and log its failures separately. No further rounds were run because the API key had no credit left.

## Conclusion

1. **Charges (Oct 2012).** On Oct 10, 2012 the Justice Department announced the unsealing of an indictment charging 10 individuals; it was returned by a federal grand jury in Miami (Southern District of Florida). Each was charged with conspiracy to commit mail and wire fraud with a telemarketing enhancement (max 10 years); "Weaver, Kaplan, Benowitz, Goldberg, Linick, Raia, Strauss and DiRenzo also are charged with mail fraud, and/or wire fraud" (max 20 years each). — release-01-2012-10-10.pdf; release-02-2012-11-15.pdf. Confidence: high.
2. **Who and role** (release-01, ages as of 2012): Edward Morris "Ned" Weaver, 39, Perrysburg OH — president and CEO (2004–2010 per release-05); Lawrence A. Kaplan, 54, Brooklyn — technical support manager "whose primary job was to suppress the large number of complaints" (release-05); Scott M. Doumas, 40 — salesman and sales manager (1999–2009, release-06); salesmen Mark Benowitz 65, Richard R. Goldberg 40, Richard Linick 70, Paul E. Raia 61 (2006–2010 per release-06), Howard S. Strauss 63; James P. Ellis, 42, Northport AL — operated locating companies Vending Dreams, Priority Placements, Clear Vision Marketing, Map Marketing and Secure Placement. The tenth defendant is "DiRenzo" — named only by surname in the charge sentence; the app surfaced no full name, role or outcome. Confidence: high (9 names), DiRenzo identity unknown.
3. **Pleas.** Strauss and Benowitz "pleaded guilty last year" (i.e. 2014) to fraud charges — release-03-2015-07-16.pdf. "Prior to this trial, 16 other Vendstar managers, … sales representatives and locating company operators pleaded guilty" — release-04-2015-11-06.pdf. No plea dates or names of the 16 in the record. Confidence: high for the fact, silent on dates.
4. **Trial and verdict.** A jury in Central Islip, NY "convicted six men yesterday" after a six-week trial before U.S. District Judge Joan M. Azrack (E.D.N.Y.) — release dated Fri Nov 6, 2015, so the verdict was Nov 5, 2015 (my date arithmetic; the app in r2 said "The documents don't give a date for this"). Weaver and Kaplan: conspiracy, six counts of fraud, one count each of false statements to federal agents; Doumas: conspiracy + one mail fraud; Goldberg and Linick: conspiracy + one wire fraud; Raia: conspiracy + two wire fraud. — release-04. Confidence: high.
5. **Sentences** (all by Judge Azrack):
   - Strauss: 28 months, $2,291,844 restitution to 230 victims; Benowitz: 24 months, $997,210 to 103 victims — release-03 (dated Thu July 16, 2015; exact sentencing day not stated in what the app showed).
   - Weaver: 60 months; Kaplan: 54 months; "imposed Thursday" — release-05 dated Thu Nov 3, 2016 → Nov 3, 2016. Restitution / supervised release for these two: **not found** (r1 never surfaced it; r2 rules: "The documents searched don't mention the restitution forfeiture"). Treat as silent/unverified.
   - Doumas: four years, $290,664; Raia: three years, $339,354 — "imposed this week", release-06 dated Fri Jan 6, 2017.
   - Goldberg: 36 months + 3 years supervised release, $546,487.77 — release-07 dated Feb 2, 2017.
   - Linick: 36 months + 3 years supervised release, $382,126 — release-08 dated Mar 23, 2017.
   Confidence: high on terms and amounts; day-level dates are inferred from release dates.
6. **Scale.** "From 2005 to 2010, the Vendstar scheme cost consumers $60 million"; typical buyer paid about $10,000 and lost all or nearly all (release-04). Release-03 headline: "more than 330 Victims"; release-01: "thousands of victims". Investigation began 2010; "charges filed against 22 individuals in 2012 and 2013. All 22 … were convicted, and 18 … sentenced" (release-06). No acquittals or dismissals are reported. Investigators: U.S. Postal Inspection Service; prosecutors: Trial Attorneys (later Senior Litigation Counsel) Patrick Jasperse and Alan Phelps (later Assistant Director), Civil Division Consumer Protection Branch; Adrienne Fowler is named as a Trial Attorney in one release.
7. **What happened to Ellis and DiRenzo: the record as surfaced by the app is silent.** (App gap: "The outcome for James P. Ellis … is not in any document of this case.") Given "All 22 … were convicted", both were probably convicted, but no document the app showed names their outcome.

## Timeline

| date | event | source |
|---|---|---|
| 2004–2010 | Weaver president/CEO; Vendstar (Deer Park, NY) sold until 2010 | release-05, release-03 |
| 2005–2010 | $60M cost to consumers | release-04 |
| 2010 | investigation began | release-06 |
| 2012-10-10 | indictment of 10 unsealed (S.D. Fla., Miami grand jury) | release-01, -02 |
| 2012–2013 | 22 people charged in total | release-06 |
| 2014 | Strauss and Benowitz plead guilty ("last year") | release-03 |
| ≤2015-07-16 | Strauss 28 mo / Benowitz 24 mo sentenced | release-03 |
| 2015-09 | six scheduled for trial | release-03 |
| 2015-11-05 | jury verdict, six convicted (E.D.N.Y., Central Islip) | release-04 ("yesterday") |
| 2016-11-03 | Weaver 60 mo, Kaplan 54 mo | release-05 |
| week of 2017-01-06 | Doumas 4 yrs, Raia 3 yrs | release-06 |
| ≤2017-02-02 | Goldberg 36 mo | release-07 |
| ≤2017-03-23 | Linick 36 mo | release-08 |

## Contradictions / inconsistencies

Flagged by the app (AI reading, both quotes checked):
- **22 vs 24 defendants convicted** — release-07 (Goldberg: "one of 24 defendants") vs release-06 ("22 individuals") and release-08 (Linick: "one of 22"). Genuine inconsistency; right to flag. Release-04's headline "Total of 22 Individuals Convicted" (6 + 16) agrees with 22; release-07 is the outlier.
- Linick "Coram" (2012/2015) vs "Setauket" (2017); Goldberg "Bay Shore" vs "Holbrook" — true differences, almost certainly moves over time, not contradictions. Each listed twice (duplicate pairs).
- Jasperse "Trial Attorneys" vs "Senior Litigation Counsel"; Phelps "Trial Attorneys" vs "Assistant Director" — title changes over years, not contradictions; Phelps mislabelled "Director Alan Phelps".

Found by me, not flagged by the app:
- **Venue:** indicted in the Southern District of Florida (Miami grand jury) but tried and sentenced in the Eastern District of New York. The record surfaced does not explain this (transfer or a separate E.D.N.Y. charge). App never flagged it; r2 question on it got an irrelevant quote.
- "10 individuals" indicted but q1's AI answer named only 8 and the cast of characters omits DiRenzo entirely.
- Victims "thousands" (2012) vs "more than 330" (2015) — the app dropped this pair as "the values do not differ"; it is a real difference in characterisation (the 330 may be only the Strauss/Benowitz victims, 230 + 103 = 333).
- Strauss/Benowitz described as "Two New York Salesmen" while Benowitz is "of Midlothian, Virginia" in the same release (minor).

## Open questions (record silent)
DiRenzo's full name, role and outcome; Ellis's outcome; names of the 16 who pleaded and of the 22/24; exact plea dates; Weaver/Kaplan restitution and supervised release; Doumas/Raia supervised release; why S.D. Fla. → E.D.N.Y.; exact sentencing days for Strauss/Benowitz, Goldberg, Linick.

## Round log
- r1 (online, 14 Qs, ~12 min): all answered, AI-written with checked quotes; 5 "Needs review".
- r2 (16 Qs, follow-ups on DiRenzo, Ellis, Weaver/Kaplan restitution, dates, venue, prosecutors): **cloud key out of credit** — 72 cloud calls all failed; answers evidence-only. Only usable new facts: none beyond r1. Questions file: /tmp/invv2/g-r1.txt, g-r2.txt.

## Experience log

**Where it helped (r1, online):**
- q8/q9 assembled every sentence and restitution figure across five releases with verbatim quotes and release dates in one answer — that is most of the case in two questions. Correct against every quote.
- q7 trial answer: six names, counts per person, judge, district, plus the "16 other … pleaded guilty" context. Correct.
- q12 surfaced "All 22 … were convicted, and 18 … sentenced" — the closest thing to a disposition summary.
- The 22-vs-24 contradiction was a real, useful catch I would have missed reading quickly.
- Gap "The outcome for James P. Ellis … is not in any document" is a correct and useful lead.

**Where it slowed or misled:**
- q1 said "indicted 10 individuals" but listed 8; Ellis and DiRenzo silently missing ("Those named as defendants included …" — hedged but incomplete).
- "Needs review" on q3, q6, q7, q8 was **not justified**: in each case the AI reading was right and the "evidence-only reading" was off-target junk, e.g. q3 evidence-only: "Tony Gomez, Acting Inspector in Charge … U.S. Department of Justice Civil Division FOR IMMEDIATE RELEASE Friday, November 6, 2015 Six Convicted …"; q8 evidence-only: "During the last five years it was open, Vendstar made more than $60 million in sales."; q7 evidence-only: "Each of the defendants faces a statutory maximum sentence of 10 years …". These downgraded correct answers to confidence 0.45.
- False gaps (7): "Documents record Lawrence A. Kaplan's plea, verdict or sentence, but none records the charge, arrest or indictment." — false; release-01 names Kaplan and every other trial defendant in the indictment. Same for Strauss, Benowitz, Raia, Linick, Goldberg, Doumas.
- Off-target material from the Nov 15, 2012 sweep release leaked into the case: chronology items 1–2 are "Regina Rush charged" and "Pearl Pastilock charged" (other schemes); cast lists Billie Joyce Sanders, Michael Cupina, Pearl Pastilock, Regina Rush, Mel Hendricks and "Mark Five" as defendants; gaps ask for their outcomes.
- Bad cast entries: "Fraudulent Business Opportunity Seller Sentenced — defendant" (a headline), "Mark Five — defendant" (a company), "General Chad", "General Readler", "Director Alan Phelps", "Litigation Counsel Patrick Jasperse", "Bay Shore — role not stated"; Weaver split into "Edward Morris" and "Ned Weaver"; DiRenzo absent. Role reader dropped "role Ned Weaver as defendant: the quote does not state the role".
- Chronology misses the indictment date of the Vendstar defendants, the verdict, and most sentencings; it has "Fraudulent Business Opportunity Seller Sentenced convicted". No interview plan was produced.
- Findings report: "21 finding(s) … from 6 source document(s)" (the case has 8); findings include "amount: $10 USD", "http: //www.justice.gov/civil/consumer-protection-branch ."; conflicts say "An opposing source outside this export's scope disagrees (withheld)" although all documents are in scope.
- Contradiction list: 9 items but only 5 distinct, 4 of which are moves/promotions, not conflicts.
- r2 (out-of-credit) answers were frequently off-target with confidence 0.8: "Who prosecuted the Vendstar trial?" → "Edward Morris "Ned" Weaver, 39, … president and chief executive officer"; "Were Weaver and Kaplan ordered to serve supervised release?" → Linick's sentence quote; "Who is DiRenzo …?" and "How many people in total were convicted?" → a "History of the user's archive" with "Nov 13, 2012: … charging Regina Rush" (confidence 0.2); "On what date did the jury convict …?" → "The documents don't give a date for this." The answers only say "the AI reader did not answer"; the out-of-credit reason appears only in the run summary, not to the user in the answer.

**Effort:** ~30 questions over 2 rounds; ~1.5 h of which most was queue waiting. Reading each answers.md: ~20 min.

**Would I rely on it?** Online: yes, as an aid for assembling who/what/sentence/restitution tables with quotes — I would re-read the quote for each row (all checked out here). Not for completeness (missed 2 of 10 defendants), not for its gaps (mostly false), not for its cast/chronology drafts (polluted by a sweep release), and I'd ignore "Needs review" when the evidence-only side is visibly off-target. Offline/no-credit: no — it confidently answers the wrong question.
