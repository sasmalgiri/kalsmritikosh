# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

Accuracy adjudication of the fresh held-out set **ho15-chron**, both answer paths. An AI agent did this work as an independent adjudicator, on the owner's written direction of 2026-11-01. It is not a human sign-off.

| | |
|---|---|
| Set | ho15-chron. FRESH: seed 20261102, 60 public DOJ prosecution cases, 940 questions (incl. paraphrases). skip-chron x1–x16, so 0 overlap with the 1,140 cases of earlier sets. Generated 2026-11-01 before any run |
| App commit | 78e6d00d (includes the ho14 fixes A–D). Unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1 |
| Runs | opus5 2026-11-01T20:23:55Z–21:00:45Z; rules 21:00:45Z–21:02:48Z |
| Scorer sha256 (recorded in MEASUREMENT-*.txt) | 060e98b92d814d24e759ac09e1e7dffcdac54c13d8a12b597c8c4e9c26df32f0. This is the same value as ho14. It still matches none of today's files: scripts/casebench/score.py 04a26faa…, common.py 7e055679…, ccsscore.py b5d79621… (last changed 24eb3ae7). Pin it before the result is frozen. |
| Automatic score | rules: right 98.3 %, wrong 1.6 % (13 wrong, 1 dump, 2 unsupported, 118 honest refusals). opus5: right 98.4 %, wrong 1.6 % (15 wrong, 120 honest refusals). I re-ran the scorer's `classify` over the result files and got the same counts. |
| Release bar | ≤ 1 % wrong per path |

## Method

The method is the same as ho14 (see `accuracy-adjudication-ho14.md`), with wider coverage.

1. **Blind first.** I read all 31 scorer-flagged items (rules 16, opus5 15) and judged each against the case documents before opening the keys. The keys were then used only to map items to cases and paths.
2. **Documents.** I extracted the text of all 130 case documents (122 converted, 8 plain text): PDFKit for PDFs, `textutil` for doc/docx/rtf/html. None needed OCR. No byte-identical duplicate files exist in this set (MD5 checked), so the ho14 duplicate-file key defect does not occur.
3. **Verdicts.** The categories are the ho14 ones: *TRUE WRONG*, *SCORER ERROR*, *TRUTH-LABEL ERROR*, *PARTLY* and *FALSE CORRECT*.
   - **PARTLY** means the main claim is true but incomplete, a secondary element is misdated, or the answer contains a row about another person. It is not counted in the primary measure. It is counted in the strict measure.
   - **Answers that name no charge.** A charge answer that does not name an offence at all ("pleaded guilty to one count in a federal indictment") answers nothing, so I counted it as WRONG. This is stricter than ho14 E: there the headline "Charged With Covid-19 Loan Fraud" at least named an offence, and was scored PARTLY. The sensitivity to this choice is given under Result.
4. **Search for false "correct" verdicts. This was the full check, not a sample.**
   - **Every *charge* answer**, 192 scored correct (86 distinct bodies), read against the releases.
   - **Every *sentenced* and *charged* answer**, 236 + 72 (128 distinct). I checked each stated day against the release date and against any "today / yesterday / weekday / on <date>" in the source sentence.
   - **Every *timeline* answer**, 236 (60 distinct). I read each row for its date, its order and whose event it is.
   - **Every *sentence* answer**, 175 (83 distinct).
   - **Every *plea* answer**, 220. I added this family beyond the brief.
   - **The rest.** A seeded random sample of 40 (20 per path, seed 20261102) from the remaining *count*, *office* and *absent* items.

   Undetected false corrects remain possible only in *count*, *office* and *absent* outside that sample.
5. **Counting.** Wrong % counts dumps and unsupported answers as wrong. A missed item would be reported separately; there were none.

## Per-item table

Item IDs are the blinded-sheet IDs. "—" means the adjudicator's full scan found the item; it was not on the sheet. Every item not listed is CORRECT or HONEST REFUSAL, as the scorer said.

| item | path | case | question | family | scorer | adjudicated | judgement | cause | reason |
|---|---|---|---|---|---|---|---|---|---|
| — | rules | chron-AnthonyQuinHodges-0024 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes his admission ("viewing child pornography … storing the images") - conduct, not the charge; release-1: pleaded guilty "to receiving and distributing child pornography" (the charge in the Feb. 15, 2017 indictment). |
| — | rules | chron-AnthonyQuinHodges-0024 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes his admission ("viewing child pornography … storing the images") - conduct, not the charge; release-1: pleaded guilty "to receiving and distributing child pornography" (the charge in the Feb. 15, 2017 indictment). |
| — | rules | chron-AntoineGibson-0050 | sentenced~p1 | sentenced | correct | **PARTLY** | DEFECT | B′ | "sentenced on November 4, 2015 and again on November 5, 2015" - one sentencing (Nov. 4); Nov. 5 is the release day ("has been sentenced"). |
| — | rules | chron-AntoineGibson-0050 | sentenced~p2 | sentenced | correct | **PARTLY** | DEFECT | B′ | "sentenced on November 4, 2015 and again on November 5, 2015" - one sentencing (Nov. 4); Nov. 5 is the release day ("has been sentenced"). |
| A0111 | rules | chron-BabakBroumand-0052 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "The complaint charges Broumand with one count of conspiracy to commit bribery of a public official" is the charging instrument of release-1 (true). Minor: the later four-count verdict (conspiracy, 2 bribery, monetary transaction) is not mentioned; opus5 p1 gives it. |
| A0085 | rules | chron-BabakBroumand-0052 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "The complaint charges Broumand with one count of conspiracy to commit bribery of a public official" is the charging instrument of release-1 (true). Minor: the later four-count verdict (conspiracy, 2 bribery, monetary transaction) is not mentioned; opus5 p1 gives it. |
| — | rules | chron-BabakBroumand-0052 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Rows include ANOTHER person's conviction as a Broumand step ("Termendzhyan … was convicted last month") and label the partial acquittal "convicted". |
| — | rules | chron-BabakBroumand-0052 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Rows include ANOTHER person's conviction as a Broumand step ("Termendzhyan … was convicted last month") and label the partial acquittal "convicted". |
| A0050 | rules | chron-BrandonLeePrice-0040 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "his plea to four counts of bank fraud" names the charge (release-1 headline: bank fraud); key wants a quote fragment ("bank fraud, United States Attorney David J"). |
| A0028 | rules | chron-BrandonLeePrice-0040 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "his plea to four counts of bank fraud" names the charge (release-1 headline: bank fraud); key wants a quote fragment ("bank fraud, United States Attorney David J"). |
| — | rules | chron-BrandonMCrumady-0016 | sentenced~p1 | sentenced | correct | **PARTLY** | DEFECT | A′ | "sentenced on August 17, 2012 and again on September 12, 2017" - 2012 is the PRIOR federal case; this case: Sept. 12, 2017 (opus5 gives only that). |
| — | rules | chron-BrandonMCrumady-0016 | sentenced~p2 | sentenced | correct | **PARTLY** | DEFECT | A′ | "sentenced on August 17, 2012 and again on September 12, 2017" - 2012 is the PRIOR federal case; this case: Sept. 12, 2017 (opus5 gives only that). |
| A0052 | rules | chron-BrandonMCrumady-0016 | timeline~p1 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts the 2012 prior-case sentence after the 2017 plea. Answer order is right (May 9, 2016 arrest, June 14, 2017 plea, Sept. 12, 2017 sentence). Minor defect: the March 2007 state conviction is listed under the 2017 report date (hedged "date of the report"), as Eaton in ho14. |
| A0081 | rules | chron-BrandonMCrumady-0016 | timeline~p2 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts the 2012 prior-case sentence after the 2017 plea. Answer order is right (May 9, 2016 arrest, June 14, 2017 plea, Sept. 12, 2017 sentence). Minor defect: the March 2007 state conviction is listed under the 2017 report date (hedged "date of the report"), as Eaton in ho14. |
| A0002 | rules | chron-CurtisSnyder-0010 | absent~p2 | absent | unsupported | **WRONG** | TRUE WRONG (dump) | C | Same paraphrase; "The source says: Date: 2026 …" followed by headers of ANOTHER case (Brandon M. Crumady, Rhode Island) and "your sources disagree". Should refuse (opus5 refused). |
| A0113 | rules | chron-DaveyJonathanSisk-0009 | sentenced~p1 | sentenced | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: release dated Oct. 23, 2024 reports he "was sentenced this week" (true). Key wants 2024-11-04, a later re-issue that says "sentenced recently". |
| A0031 | rules | chron-DaveyJonathanSisk-0009 | sentenced~p2 | sentenced | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: release dated Oct. 23, 2024 reports he "was sentenced this week" (true). Key wants 2024-11-04, a later re-issue that says "sentenced recently". |
| — | rules | chron-DaveyJonathanSisk-0009 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "February 15, 2024 - pleaded guilty" from "was arrested on February 15, 2024, and pled guilty last month" - the arrest day; the June 2024 plea appears only under report dates. |
| — | rules | chron-DaveyJonathanSisk-0009 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "February 15, 2024 - pleaded guilty" from "was arrested on February 15, 2024, and pled guilty last month" - the arrest day; the June 2024 plea appears only under report dates. |
| A0009 | rules | chron-DavidCampbell-0033 | sentenced~p1 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on November 16, 2020" (the release day, a Monday). Release-2: "was sentenced to 18 months … on Friday, United States Attorney … announced today" = Nov. 13, 2020. "announced today" (the announcement) beat the step's own weekday. Key lists the release day. |
| — | rules | chron-DavidCampbell-0033 | sentenced~p2 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on November 16, 2020" (the release day, a Monday). Release-2: "was sentenced to 18 months … on Friday, United States Attorney … announced today" = Nov. 13, 2020. "announced today" (the announcement) beat the step's own weekday. Key lists the release day. |
| A0046 | rules | chron-DavidCampbell-0033 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "November 16, 2020 - sentenced" - really Friday Nov. 13 (as sentenced~); plea shown twice (July 24 and the July 27 release day). |
| — | rules | chron-DavidCampbell-0033 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "November 16, 2020 - sentenced" - really Friday Nov. 13 (as sentenced~); plea shown twice (July 24 and the July 27 release day). |
| — | rules | chron-DavidEWarren-0034 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Row "acquitted" is the co-defendant brother ("Montez Warren … was acquitted by the jury of all charges"), shown as a step of the case against David Warren. |
| — | rules | chron-DavidEWarren-0034 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Row "acquitted" is the co-defendant brother ("Montez Warren … was acquitted by the jury of all charges"), shown as a step of the case against David Warren. |
| A0080 | rules | chron-DelvinPerkins-0045 | sentence~p2 | sentence | dump | **WRONG** | TRUE WRONG (dump) | C | "I'm looking for the sentence that X received — what was it?" unwrapped badly ("resolved": "I'm looking for the sentence that X received?"); header dump incl. OTHER cases (Adamsky, Pelchat). Correct 51 months (p1 and opus5 got it). |
| — | rules | chron-DineshSah-0032 | charge~p1 | charge | correct | **PARTLY** | DEFECT | G′ | Charge right (wire fraud, money laundering) but framed "more than one charge … (two prosecutions, or two people of that name)" - one prosecution; the second quote names no charge. |
| — | rules | chron-DineshSah-0032 | charge~p2 | charge | correct | **PARTLY** | DEFECT | G′ | Charge right (wire fraud, money laundering) but framed "more than one charge … (two prosecutions, or two people of that name)" - one prosecution; the second quote names no charge. |
| — | rules | chron-GeorgeAntonioNewman-0021 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes the group indictment of 15 people "for their various roles in the distribution of cocaine, crack, pills, heroin, MDMA and marijuana"; his own charge is possession of cocaine with intent to distribute (opus5 gives it). |
| — | rules | chron-GeorgeAntonioNewman-0021 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes the group indictment of 15 people "for their various roles in the distribution of cocaine, crack, pills, heroin, MDMA and marijuana"; his own charge is possession of cocaine with intent to distribute (opus5 gives it). |
| — | rules | chron-JerrellJackson-0011 | charge~p1 | charge | correct | **PARTLY** | DEFECT | G′ | Both quotes describe the same Feb. 2015 jury verdict, but the answer says "two prosecutions, or two people of that name". |
| — | rules | chron-JerrellJackson-0011 | charge~p2 | charge | correct | **PARTLY** | DEFECT | G′ | Both quotes describe the same Feb. 2015 jury verdict, but the answer says "two prosecutions, or two people of that name". |
| — | rules | chron-JohnAndersonRankin-0035 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | J | Lead says "tax loss of approximately $8." - cut at "$8.1 million". |
| — | rules | chron-JohnAndersonRankin-0035 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | J | Lead says "tax loss of approximately $8." - cut at "$8.1 million". |
| — | rules | chron-JohnDavidClark-0042 | charged~p1 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "charged on June 25, 2013"; the sentence it quotes says "charged by a Federal Grand Jury in July 2013 with possessing the pseudoephedrine on June 25, 2013" - the offence day. Release-1: indictment "returned … on July 9th". Key accepts the offence day. |
| — | rules | chron-JohnDavidClark-0042 | charged~p2 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "charged on June 25, 2013"; the sentence it quotes says "charged by a Federal Grand Jury in July 2013 with possessing the pseudoephedrine on June 25, 2013" - the offence day. Release-1: indictment "returned … on July 9th". Key accepts the offence day. |
| A0016 | rules | chron-JohnDavidClark-0042 | charge~p1 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: charged with possessing pseudoephedrine (with intent to manufacture methamphetamine) - exactly the indictment. Key is a fragment "that offense on October 11th". |
| A0033 | rules | chron-JohnDavidClark-0042 | charge~p2 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: charged with possessing pseudoephedrine (with intent to manufacture methamphetamine) - exactly the indictment. Key is a fragment "that offense on October 11th". |
| — | rules | chron-JohnDavidClark-0042 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | H | Steps "June 25, 2013 - charged" (offence day) and "October 11, 2014 - pleaded guilty" AFTER the Jan. 16, 2014 sentencing: "He pled guilty … on October 11th" in a Jan. 16, 2014 release is Oct. 11, 2013; the year-less date took the release year and lands after the document itself. |
| — | rules | chron-JohnDavidClark-0042 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | H | Steps "June 25, 2013 - charged" (offence day) and "October 11, 2014 - pleaded guilty" AFTER the Jan. 16, 2014 sentencing: "He pled guilty … on October 11th" in a Jan. 16, 2014 release is Oct. 11, 2013; the year-less date took the release year and lands after the document itself. |
| — | rules | chron-JulianoFernandes-0048 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: release-1 says "arrested yesterday and charged" (Jan. 14, 2021). |
| — | rules | chron-JulianoFernandes-0048 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: release-1 says "arrested yesterday and charged" (Jan. 14, 2021). |
| — | rules | chron-KevinLBrown-0020 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT (non-answer) | E | Answer: "Kevin Brown had previously pleaded guilty to one count in a federal indictment." - names no offence. Release-1: indicted on methamphetamine-related charges (conspiracy to manufacture methamphetamine). Key matched the fragment. |
| — | rules | chron-KevinLBrown-0020 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (non-answer) | E | Answer: "Kevin Brown had previously pleaded guilty to one count in a federal indictment." - names no offence. Release-1: indicted on methamphetamine-related charges (conspiracy to manufacture methamphetamine). Key matched the fragment. |
| A0055 | rules | chron-KeyonSlaughter-0002 | absent~p1 | absent | unsupported | **WRONG** | TRUE WRONG (dump) | C | "Is there a date on record for when X was pardoned?" not parsed ("is there" unwrapped, "a date on record for when …" matches no pattern); answer is a run-on of release headers incl. ANOTHER case (Joshua Sneed, W.Va.). Should refuse (opus5 refused). |
| A0021 | rules | chron-KeyonSlaughter-0002 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Two "pleaded guilty" rows are the co-defendant wife's plea ("the wife of Mr. Bailey, who was indicted with Slaughter and pleaded guilty to obstructing justice"). |
| — | rules | chron-KeyonSlaughter-0002 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Two "pleaded guilty" rows are the co-defendant wife's plea ("the wife of Mr. Bailey, who was indicted with Slaughter and pleaded guilty to obstructing justice"). |
| — | rules | chron-RubenChavezIII-0012 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: "a federal grand jury indicted him on Thursday" (June 9, 2022). |
| — | rules | chron-RubenChavezIII-0012 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: "a federal grand jury indicted him on Thursday" (June 9, 2022). |
| — | rules | chron-SamuelJCusumano-0037 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | J | Lead says "ordered to pay $7." - cut at the decimal point of "$7.8 million" (the quote after it is complete). |
| — | rules | chron-SamuelJCusumano-0037 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | J | Lead says "ordered to pay $7." - cut at the decimal point of "$7.8 million" (the quote after it is complete). |
| A0078 | rules | chron-ShelleyKimbrell-0029 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "Corkins [aka Kimbrell] pleaded guilty to three counts of wire fraud on February 10, 2015" names the charge; key wants the longer lead sentence. |
| A0082 | rules | chron-TonyDerrickTorrez-0013 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer lists the five-count indictment (marijuana PWID, maintaining a drug place, cocaine/testosterone possession, firearms by drug user, firearms in relation to drug trafficking) exactly as release-2 states; key wants the generic phrase "drug trafficking and firearms charges". |
| A0048 | rules | chron-TonyDerrickTorrez-0013 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer lists the five-count indictment (marijuana PWID, maintaining a drug place, cocaine/testosterone possession, firearms by drug user, firearms in relation to drug trafficking) exactly as release-2 states; key wants the generic phrase "drug trafficking and firearms charges". |
| — | rules | chron-TonyDerrickTorrez-0013 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | F | "101 months … (February 5, 2018) and, in another proceeding, to 101 months followed by …" - the second is the plea agreement's 93-101 month recommendation, not another proceeding. |
| — | rules | chron-TonyDerrickTorrez-0013 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | F | "101 months … (February 5, 2018) and, in another proceeding, to 101 months followed by …" - the second is the plea agreement's 93-101 month recommendation, not another proceeding. |
| A0017 | rules | chron-TonyDerrickTorrez-0013 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | H | Last step "October 21, 2018 - charged" (after the Feb. 5, 2018 sentencing): from "charged Torrez with committing the crimes on Oct. 21 and 22, 2015" - "Oct. 21" read year-less, given the release year 2018; it is also the offence day, not a charge day (complaint: Oct. 2015). |
| — | rules | chron-TonyDerrickTorrez-0013 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | H | Last step "October 21, 2018 - charged" (after the Feb. 5, 2018 sentencing): from "charged Torrez with committing the crimes on Oct. 21 and 22, 2015" - "Oct. 21" read year-less, given the release year 2018; it is also the offence day, not a charge day (complaint: Oct. 2015). |
| — | opus5 | chron-AnthonyQuinHodges-0024 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes his admission ("viewing child pornography … storing the images") - conduct, not the charge; release-1: pleaded guilty "to receiving and distributing child pornography" (the charge in the Feb. 15, 2017 indictment). |
| — | opus5 | chron-AnthonyQuinHodges-0024 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E | Answer quotes his admission ("viewing child pornography … storing the images") - conduct, not the charge; release-1: pleaded guilty "to receiving and distributing child pornography" (the charge in the Feb. 15, 2017 indictment). |
| A0110 | opus5 | chron-BabakBroumand-0052 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Same as rules. |
| — | opus5 | chron-BabakBroumand-0052 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Rows include ANOTHER person's conviction as a Broumand step ("Termendzhyan … was convicted last month") and label the partial acquittal "convicted". |
| — | opus5 | chron-BabakBroumand-0052 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Rows include ANOTHER person's conviction as a Broumand step ("Termendzhyan … was convicted last month") and label the partial acquittal "convicted". |
| A0016 | opus5 | chron-BrandonLeePrice-0040 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Same as rules. |
| — | opus5 | chron-BrandonLeePrice-0040 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (non-answer) | E | Answer: "pleaded guilty to four counts before United States District Judge Terrence McVerry" - names no offence (bank fraud). Key matched the fragment "four counts before …". |
| A0082 | opus5 | chron-BrandonMCrumady-0016 | timeline~p1 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts the 2012 prior-case sentence after the 2017 plea. Answer order is right (May 9, 2016 arrest, June 14, 2017 plea, Sept. 12, 2017 sentence). Minor defect: the March 2007 state conviction is listed under the 2017 report date (hedged "date of the report"), as Eaton in ho14. |
| A0048 | opus5 | chron-BrandonMCrumady-0016 | timeline~p2 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts the 2012 prior-case sentence after the 2017 plea. Answer order is right (May 9, 2016 arrest, June 14, 2017 plea, Sept. 12, 2017 sentence). Minor defect: the March 2007 state conviction is listed under the 2017 report date (hedged "date of the report"), as Eaton in ho14. |
| A0055 | opus5 | chron-DaveyJonathanSisk-0009 | sentenced~p1 | sentenced | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: release dated Oct. 23, 2024 reports he "was sentenced this week" (true). Key wants 2024-11-04, a later re-issue that says "sentenced recently". |
| A0112 | opus5 | chron-DaveyJonathanSisk-0009 | sentenced~p2 | sentenced | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: release dated Oct. 23, 2024 reports he "was sentenced this week" (true). Key wants 2024-11-04, a later re-issue that says "sentenced recently". |
| — | opus5 | chron-DaveyJonathanSisk-0009 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "February 15, 2024 - pleaded guilty" from "was arrested on February 15, 2024, and pled guilty last month" - the arrest day; the June 2024 plea appears only under report dates. |
| — | opus5 | chron-DaveyJonathanSisk-0009 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "February 15, 2024 - pleaded guilty" from "was arrested on February 15, 2024, and pled guilty last month" - the arrest day; the June 2024 plea appears only under report dates. |
| — | opus5 | chron-DavidCampbell-0033 | sentenced~p1 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on November 16, 2020" (the release day, a Monday). Release-2: "was sentenced to 18 months … on Friday, United States Attorney … announced today" = Nov. 13, 2020. "announced today" (the announcement) beat the step's own weekday. Key lists the release day. |
| — | opus5 | chron-DavidCampbell-0033 | sentenced~p2 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on November 16, 2020" (the release day, a Monday). Release-2: "was sentenced to 18 months … on Friday, United States Attorney … announced today" = Nov. 13, 2020. "announced today" (the announcement) beat the step's own weekday. Key lists the release day. |
| — | opus5 | chron-DavidCampbell-0033 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "November 16, 2020 - sentenced" - really Friday Nov. 13 (as sentenced~); plea shown twice (July 24 and the July 27 release day). |
| — | opus5 | chron-DavidCampbell-0033 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Row "November 16, 2020 - sentenced" - really Friday Nov. 13 (as sentenced~); plea shown twice (July 24 and the July 27 release day). |
| A0081 | opus5 | chron-DavidEWarren-0034 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "The jury convicted Warren of two counts of first-degree murder while armed during the commission of two separate felonies, second-degree murder while armed, kidnapping …" - the full list from release-1; key wants the headline wording. |
| A0078 | opus5 | chron-DavidEWarren-0034 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "The jury convicted Warren of two counts of first-degree murder while armed during the commission of two separate felonies, second-degree murder while armed, kidnapping …" - the full list from release-1; key wants the headline wording. |
| A0007 | opus5 | chron-DavidEWarren-0034 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Row "acquitted" is the co-defendant brother ("Montez Warren … was acquitted by the jury of all charges"), shown as a step of the case against David Warren. |
| — | opus5 | chron-DavidEWarren-0034 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Row "acquitted" is the co-defendant brother ("Montez Warren … was acquitted by the jury of all charges"), shown as a step of the case against David Warren. |
| A0053 | opus5 | chron-JerrellJackson-0011 | charge~p1 | charge | correct | **PARTLY** | DEFECT | G′ | Both quotes describe the same Feb. 2015 jury verdict, but the answer says "two prosecutions, or two people of that name". |
| — | opus5 | chron-JerrellJackson-0011 | charge~p2 | charge | correct | **PARTLY** | DEFECT | G′ | Both quotes describe the same Feb. 2015 jury verdict, but the answer says "two prosecutions, or two people of that name". |
| A0050 | opus5 | chron-JohnAndersonRankin-0035 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "A federal grand jury indicted Rankin in July 2015 with seven counts of failing to … pay over employment taxes, six counts of … false individual returns, three counts …" - the indictment (17 counts); key wants "17 tax-related charges". |
| A0028 | opus5 | chron-JohnAndersonRankin-0035 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "A federal grand jury indicted Rankin in July 2015 with seven counts of failing to … pay over employment taxes, six counts of … false individual returns, three counts …" - the indictment (17 counts); key wants "17 tax-related charges". |
| A0069 | opus5 | chron-JohnDavidClark-0042 | charged~p1 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "charged on June 25, 2013"; the sentence it quotes says "charged by a Federal Grand Jury in July 2013 with possessing the pseudoephedrine on June 25, 2013" - the offence day. Release-1: indictment "returned … on July 9th". Key accepts the offence day. |
| — | opus5 | chron-JohnDavidClark-0042 | charged~p2 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "charged on June 25, 2013"; the sentence it quotes says "charged by a Federal Grand Jury in July 2013 with possessing the pseudoephedrine on June 25, 2013" - the offence day. Release-1: indictment "returned … on July 9th". Key accepts the offence day. |
| A0033 | opus5 | chron-JohnDavidClark-0042 | charge~p1 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: charged with possessing pseudoephedrine (with intent to manufacture methamphetamine) - exactly the indictment. Key is a fragment "that offense on October 11th". |
| A0080 | opus5 | chron-JohnDavidClark-0042 | charge~p2 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: charged with possessing pseudoephedrine (with intent to manufacture methamphetamine) - exactly the indictment. Key is a fragment "that offense on October 11th". |
| — | opus5 | chron-JohnDavidClark-0042 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | H | Steps "June 25, 2013 - charged" (offence day) and "October 11, 2014 - pleaded guilty" AFTER the Jan. 16, 2014 sentencing: "He pled guilty … on October 11th" in a Jan. 16, 2014 release is Oct. 11, 2013; the year-less date took the release year and lands after the document itself. |
| — | opus5 | chron-JohnDavidClark-0042 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | H | Steps "June 25, 2013 - charged" (offence day) and "October 11, 2014 - pleaded guilty" AFTER the Jan. 16, 2014 sentencing: "He pled guilty … on October 11th" in a Jan. 16, 2014 release is Oct. 11, 2013; the year-less date took the release year and lands after the document itself. |
| — | opus5 | chron-JulianoFernandes-0048 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: release-1 says "arrested yesterday and charged" (Jan. 14, 2021). |
| — | opus5 | chron-JulianoFernandes-0048 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: release-1 says "arrested yesterday and charged" (Jan. 14, 2021). |
| A0100 | opus5 | chron-KevinLBrown-0020 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT (non-answer) | E | Answer: "Kevin Brown had previously pleaded guilty to one count in a federal indictment." - names no offence. Release-1: indicted on methamphetamine-related charges (conspiracy to manufacture methamphetamine). Key matched the fragment. |
| A0072 | opus5 | chron-KevinLBrown-0020 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (non-answer) | E | Answer: "Kevin Brown had previously pleaded guilty to one count in a federal indictment." - names no offence. Release-1: indicted on methamphetamine-related charges (conspiracy to manufacture methamphetamine). Key matched the fragment. |
| A0077 | opus5 | chron-KeyonSlaughter-0002 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | A′ | Two "pleaded guilty" rows are the co-defendant wife's plea ("the wife of Mr. Bailey, who was indicted with Slaughter and pleaded guilty to obstructing justice"). |
| — | opus5 | chron-KeyonSlaughter-0002 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | A′ | Two "pleaded guilty" rows are the co-defendant wife's plea ("the wife of Mr. Bailey, who was indicted with Slaughter and pleaded guilty to obstructing justice"). |
| — | opus5 | chron-RubenChavezIII-0012 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: "a federal grand jury indicted him on Thursday" (June 9, 2022). |
| — | opus5 | chron-RubenChavezIII-0012 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "it gives no other day" is untrue: "a federal grand jury indicted him on Thursday" (June 9, 2022). |
| A0052 | opus5 | chron-ShelleyKimbrell-0029 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Same as rules p1. |
| A0031 | opus5 | chron-TonyDerrickTorrez-0013 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer lists the five-count indictment (marijuana PWID, maintaining a drug place, cocaine/testosterone possession, firearms by drug user, firearms in relation to drug trafficking) exactly as release-2 states; key wants the generic phrase "drug trafficking and firearms charges". |
| A0002 | opus5 | chron-TonyDerrickTorrez-0013 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer lists the five-count indictment (marijuana PWID, maintaining a drug place, cocaine/testosterone possession, firearms by drug user, firearms in relation to drug trafficking) exactly as release-2 states; key wants the generic phrase "drug trafficking and firearms charges". |
| — | opus5 | chron-TonyDerrickTorrez-0013 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | H | Last step "October 21, 2018 - charged" (after the Feb. 5, 2018 sentencing): from "charged Torrez with committing the crimes on Oct. 21 and 22, 2015" - "Oct. 21" read year-less, given the release year 2018; it is also the offence day, not a charge day (complaint: Oct. 2015). |
| — | opus5 | chron-TonyDerrickTorrez-0013 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | H | Last step "October 21, 2018 - charged" (after the Feb. 5, 2018 sentencing): from "charged Torrez with committing the crimes on Oct. 21 and 22, 2015" - "Oct. 21" read year-less, given the release year 2018; it is also the offence day, not a charge day (complaint: Oct. 2015). |

Further minor defects, recorded as CORRECT:

- Several rules *sentence* answers (Snyder, Radford, Johnson, Lose, Jordan): the lead sentence ends in a dangling "by."
- Surjit Singh rules *sentence*: the lead runs on into the son's sentence.
- Sisk *charge* (rules): gives the complaint charge (receipt of child pornography); the later plea added two exploitation counts.
- Crowe *charge* (rules): gives the 2011 complaint charges; opus5 gives the superseding indictment.

## Random spot check (count / office / absent, 20 per path, seed 20261102)

**rules — 20 of 20 confirmed:** JulianoFernandes absent~p1 → HONEST REFUSAL; RickyHubbard absent~p1 → HONEST REFUSAL; DineshSah office~p2 → CORRECT; VictorSoto count~p1 → CORRECT; BillyDouglasThorne count~p1 → CORRECT; TonyDerrickTorrez absent~p2 → HONEST REFUSAL; CurtisSnyder office~p2 → CORRECT; JohnAndersonRankin absent~p1 → HONEST REFUSAL; RitzDWilliamsJr absent~p2 → HONEST REFUSAL; BillyDouglasThorne absent~p1 → HONEST REFUSAL; JoseManuelIglesias office~p2 → CORRECT; DavidEWarren absent~p2 → HONEST REFUSAL; AaronPelchat office~p1 → CORRECT; BabakBroumand absent~p2 → HONEST REFUSAL; BrandonLeePrice count~p2 → CORRECT; BrandonMCrumady absent~p1 → HONEST REFUSAL; MagicMike office~p1 → CORRECT; BrandonMCrumady count~p2 → CORRECT; JulianoFernandes count~p1 → CORRECT; JohnAndersonRankin count~p1 → CORRECT.

**opus5 — 20 of 20 confirmed:** JulianoFernandes count~p2 → CORRECT; SamuelJCusumano absent~p1 → HONEST REFUSAL; AntoineGibson office~p2 → CORRECT; NicholasKarov office~p2 → CORRECT; JoseManuelIglesias count~p1 → CORRECT; DetrekBaker office~p2 → CORRECT; MichaelAndrewScott count~p2 → CORRECT; JohnDavidClark absent~p1 → HONEST REFUSAL; JoshuaSneed absent~p1 → HONEST REFUSAL; VictorSoto count~p1 → CORRECT; DavidJohnson office~p1 → CORRECT; DoranKingBurroughsJr absent~p1 → HONEST REFUSAL; VictorSoto office~p2 → CORRECT; RandallLose count~p2 → CORRECT; AaronPelchat absent~p2 → HONEST REFUSAL; GaryBellinger office~p1 → CORRECT; DetrekBaker count~p2 → CORRECT; KelseyRJones count~p2 → CORRECT; ShariefDeonaMcDowell absent~p1 → HONEST REFUSAL; ZachkeyJames absent~p2 → HONEST REFUSAL.

## Adjudicated totals

### rules

n = 940. Correct 781, honest refusal 118, partly 28, missed 0, **wrong 13 = 1.38 %**. Strict (wrong + partly) 41 = **4.36 %**.

| family | n | correct | honest refusal | partly | missed | wrong | wrong % | strict % |
|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 114 | 0 | 4 | 0 | 2 | 1.7 % | 5.0 % |
| timeline | 120 | 106 | 0 | 10 | 0 | 4 | 3.3 % | 11.7 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| office | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| absent | 120 | 0 | 118 | 0 | 0 | 2 | 1.7 % | 1.7 % |
| plea | 110 | 110 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| charge | 106 | 96 | 0 | 8 | 0 | 2 | 1.9 % | 9.4 % |
| sentence | 88 | 81 | 0 | 6 | 0 | 1 | 1.1 % | 8.0 % |
| charged | 36 | 34 | 0 | 0 | 0 | 2 | 5.6 % | 5.6 % |

### opus5

n = 940. Correct 795, honest refusal 120, partly 14, missed 0, **wrong 11 = 1.17 %**. Strict 25 = **2.66 %**.

| family | n | correct | honest refusal | partly | missed | wrong | wrong % | strict % |
|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 118 | 0 | 0 | 0 | 2 | 1.7 % | 1.7 % |
| timeline | 120 | 106 | 0 | 10 | 0 | 4 | 3.3 % | 11.7 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| office | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| plea | 110 | 110 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| charge | 106 | 99 | 0 | 4 | 0 | 3 | 2.8 % | 6.6 % |
| sentence | 88 | 88 | 0 | 0 | 0 | 0 | 0.0 % | 0.0 % |
| charged | 36 | 34 | 0 | 0 | 0 | 2 | 5.6 % | 5.6 % |

**Comparability with ho14.** In ho14, timeline rows were checked only for their dates. This review also read whose event each row is. That adds 6 partly items per path (Broumand, Slaughter, Warren). Counted on the ho14 basis, strict is rules 35 = 3.72 % and opus5 19 = 2.02 %.

## The automatic score versus the adjudicated score

- **Scorer flags that were not real wrongs.** On rules, 13 of the 16 flagged items are acceptable answers; the other 3 are the C dumps. On opus5, all 15 of 15 are acceptable.
  - Charge keys that are quote fragments: Clark "that offense on October 11th"; Price "bank fraud, United States Attorney David J" / "four counts before …".
  - Charge keys that want the generic headline wording: Torrez, Warren, Rankin, Kimbrell, Broumand.
  - A date key that wants a later re-issued release: Sisk 2024-11-04.
  - A timeline key in release order: Crumady.
- **"Correct" scores that were really wrong.** These came from keys that accept the wrong value or from loose order keys: 10 on rules, 11 on opus5.
  - Campbell: the key is the release day.
  - Clark charged: the key accepts the offence day 2013-06-25.
  - Clark and Torrez timelines: `order_any` checks only two anchors, so a plea or charge placed after the sentencing passes.
  - Kevin Brown and Price charge: the key is a fragment ("one count in a federal indictment", "four counts before …").
- **Net effect.** Rules: automatic 16 wrong, adjudicated 13. Opus5: automatic 15, adjudicated 11. The near-equal totals hide that most of the individual items differ.
- **The bench generator defects reported for ho14 are still present in ho15.** These are bench fixes, not app fixes. ho15 should be re-labelled before any further figure is quoted from it.
  - `stated_days` takes the release day or the offence day.
  - `offence_sentences` produces fragments.
  - Timeline `order_any` follows release order and uses only 2 anchors.

## Root causes of the TRUE WRONG items

| cat | root cause | rules | opus5 | example | fixable? | likely code area |
|---|---|---|---|---|---|---|
| B | **Event date taken from the wrong part of the sentence** (recurred in new forms). (1) "was sentenced … on Friday, United States Attorney … announced today": `stepDay` checks `\btoday\b` anywhere in the sentence *before* the weekday rule, so the announcement's "today" beats the step's own "on Friday". (2) "charged … in July 2013 with possessing the pseudoephedrine on June 25, 2013": the month-only guard needs "in <Month> <Year>" *immediately* after the verb ("by a Federal Grand Jury" intervenes). The conduct-verb list in `belongs` has "possessed" but not "possessing" or "committing", so the offence day is taken. | 4 | 4 | Campbell sentenced: "November 16, 2020" (really Fri. Nov. 13) | **FIXABLE** | `Kalsmritikosh/Knowledge/Events/ProceedingEventExtractor.swift` `stepDay` (l.364–415). A weekday or "on <date>" attached to the step verb should beat a "today" governed by "announced" / "said". The month-only guard should allow an intervening agent phrase ("by a … grand jury"). Gerunds should join the conduct list ("possessing", "committing", "distributing"). Treat a "with <conduct> on <date>" object as the conduct's day. |
| H | **Year inference for a date written without a year (NEW).** A year-less "October 11th" or "Oct. 21" takes the release's year even when that puts the event *after the release itself* (Clark: plea Oct. 11, 2014 in a Jan. 16, 2014 release). "Oct. 21 and 22, 2015" is read as a year-less "Oct. 21". Both produce a timeline in which a plea or charge follows the sentence. | 4 | 4 | Clark timeline: "October 11, 2014 — pleaded guilty" after the Jan. 16, 2014 sentencing | **FIXABLE** | `stepDay` l.386 (`printed?.year`): if month/day is after the printed date, use year − 1. Parse "Month D and D, YYYY" / "Month D–D, YYYY" ranges with the trailing year. Add a cross-step sanity check in `ProceedingAnswerer` timeline assembly: a plea or charge after that case's sentencing is impossible, so drop or flag the step. This is the check ho14 already recommended and that is still absent. |
| E | **Charge sentence that names no offence.** `.chargedWith` accepts "pleaded guilty to one count in a federal indictment" / "pleaded guilty to four counts before Judge …" as a charge statement. The AI path's verifier keeps it (Price p2), and the rules path picks it (Kevin Brown). | 2 | 3 | Kevin Brown charge: "pleaded guilty to one count in a federal indictment" | **FIXABLE** | `Kalsmritikosh/Brain/ProceedingAnswerer.swift` `.chargedWith` scoring: require an offence noun phrase (not just "N counts" or "the charge"); prefer the body sentence that states the offence (Kevin Brown release-1: "indicted … on methamphetamine related charges … conspired to manufacture methamphetamine"). Mirror this in `Kalsmritikosh/Brain/VerifiedRecordExtractor.swift` `verify`. |
| C | **Paraphrase not parsed, so a header dump containing OTHER cases' text (rules only; scope breach).** "Is there a date on record for when X was pardoned?" (after the "is there" unwrap, "a date on record for when …" matches no when-pattern). "I'm looking for the sentence that X received — what was it?" ("I'm looking for" is unwrapped only before "details/information … on/about"). The dumps came out of composers *other than* the `DeterministicEvidenceFallback` path that 78e6d00d fixed: one uses ReasoningExpert's "The source says:" frame (`Kalsmritikosh/Experts/ReasoningExpert.swift` l.197), two are raw header concatenations. On opus5, the AI rewrote all three questions and answered or refused correctly. | 3 | 0 | Slaughter absent~p1: Slaughter headers + Joshua Sneed (W.Va.) headers | **FIXABLE** | `ProceedingAnswerer.unwrap` / `parse` (l.78–130): accept "a date (on record )?for when …", "the date on which …", "I'm looking for the <X> that …(— what was it)?". More important is the scope rule: **every** composer, not only `DeterministicEvidenceFallback`, must restrict a person-naming question to passages that name that person and must never emit concatenated release headers. |

**No TRUE WRONG item is a limit of current technology.** All four causes are rule gaps in deterministic code, and each has an exact sentence that reproduces it. The bar is not raised.

### Partly-correct items (strict measure only)

| cat | cause | rules | opus5 | fixable? | area |
|---|---|---|---|---|---|
| A′ | Another person's event shown as the subject's: a co-defendant's plea through a relative clause ("the wife of Mr. Bailey, who was indicted with Slaughter and pleaded guilty"); another person's conviction ("Termendzhyan … was convicted"); the co-defendant brother's acquittal; a prior case's sentence offered as "again on" (Crumady) | 8 | 6 | FIXABLE | the ho14-A relative-clause / other-subject rule was applied to `.chargedWith` only; timeline step extraction (`ProceedingEventExtractor`) and the `.sentencedOn` multi-date answer still need it |
| B′ | Misdated secondary row or second date (Sisk plea at the arrest day; Campbell sentencing at the release day; Gibson "again on" the release day) | 6 | 4 | FIXABLE (as B) | as B |
| E | Conduct or group-indictment sentence chosen instead of the charge (Hodges, Newman) | 4 | 2 | FIXABLE (as E) | as E |
| G′ | One prosecution labelled "two prosecutions, or two people of that name" (Sah, Jackson) | 4 | 2 | FIXABLE | `.chargedWith` disjoint-offence test: two quotes from the same verdict/plea are one prosecution |
| F | Plea-agreement recommendation reported as "another proceeding" (Torrez) | 2 | 0 | FIXABLE | `.sentenceImposed`: "recommends … be sentenced to" is not a sentence |
| J | Rules lead sentence cut at a decimal point ("ordered to pay $7." for $7.8 million) | 4 | 0 | FIXABLE | rules lead-sentence summariser / sentence splitter (do not split after "$<digits>.") |

## Comparison with ho14 categories A–G

| ho14 cat | ho14 wrong (rules/opus5) | ho15 wrong (rules/opus5) | status |
|---|---|---|---|
| A charge from a prior / other case or co-defendant clause | 8 / 0 | 0 / 0 | **Fixed for charge answers.** Recurred as PARTLY in timeline and sentenced answers (A′, 8 / 6): the rule did not reach the other step readers. |
| B date from the wrong event | 8 / 5 | 4 / 4 | **Recurred** in new forms: "announced today" beat "on Friday"; an offence day after "with possessing"; an intervening agent phrase defeated the month-only guard. The ho14 recommendation to add a cross-step order check was not implemented, which also let H through. |
| C paraphrase, so a dump of other cases | 1 / 1 | 3 / 0 | **Recurred on rules** (3, up from 1). The 78e6d00d fix covered one fallback; two other composers still dump unscoped headers. Fixed on opus5. |
| D participle plea missed | 2 / 2 missed | 0 / 0 | **Fixed.** No missed pleas. |
| E headline / non-charge sentence as the charge | partly 1 / 1 | 2 / 3 wrong, plus partly 4 / 2 | **Recurred and worse:** answers that name no offence. |
| F duplicate / "another proceeding" | partly 4 / 2 | partly 2 / 0 | Recurred (Torrez, rules). |
| G AI kept one of two prosecutions | partly 0 / 2 | 0 / 0 | Not seen. The inverse (G′, a false "two prosecutions") appears as partly. |
| H year-less date given the wrong year (NEW) | — | 4 / 4 | New category. |

## Result

- **rules:** adjudicated wrong 13 / 940 = **1.38 %**. Strict (incl. partly) 41 = 4.36 %. Missed 0. Causes: B 4, H 4, C 3, E 2.
- **opus5:** adjudicated wrong 11 / 940 = **1.17 %**. Strict 25 = 2.66 %. Missed 0. Causes: B 4, H 4, E 3.
- **Sensitivity.** If the answers that name no offence (E: Kevin Brown, Price p2) were scored PARTLY, as the ho14 headline case was, rules would be 11 = 1.17 % (still NO) and opus5 8 = 0.85 % (YES). The primary verdict below counts them as WRONG, because they do not state a charge at all.
- **Shared wrongs.** 8 of the 11 opus5 wrongs (B, H) are the same deterministic event-date output as rules. The AI does not touch dates or timelines on this path, so fixing B and H removes them from both paths at once.

The bar is not raised. No root cause is a limit of current technology.

**rules — Meets ≤1% wrong: NO** (1.38 %)

**opus5 — Meets ≤1% wrong: NO** (1.17 % primary measure; 2.66 % strict. Within the coverage stated in Method step 4.)
