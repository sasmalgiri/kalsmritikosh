# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

Accuracy adjudication of the fresh held-out set **ho17-chron**, both answer paths. An AI agent did this work as an independent adjudicator, on the owner's written direction of 2026-11-01. It is not a human sign-off.

| | |
|---|---|
| Set | ho17-chron. FRESH: seed 20261104, 60 public DOJ prosecution cases, 926 questions (incl. paraphrases), skip-chron x1–x18, so 0 overlap with the 1,260 cases of earlier sets. Generated 2026-11-02 before any run |
| App commit | b1022f77 (includes the ho16 fixes B, K, E, A, T, C, F). Unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1 |
| Runs | opus5 2026-11-02T00:15:43Z–00:54:03Z (Claude Opus 5 hybrid, Claude calls confirmed); rules 00:54:03Z–00:56:20Z |
| Scorer sha256 (in MEASUREMENT-*.txt) | 060e98b9… — the same value as ho14–ho16, and still matching none of today's files (score.py 04a26faa…, common.py 7e055679…, ccsscore.py b5d79621…). Pin it before the result is frozen. |
| Automatic score | rules: right 98.3 %, wrong 1.5 % (11 wrong, 2 dump, 3 unsupported, 119 honest refusals). opus5: right 98.8 %, wrong 1.2 % (9 wrong, 2 unsupported, 120 honest refusals). Re-running the scorer's `classify` over the result files gives the same counts. |
| Release bar | ≤ 1 % wrong per path |

## Method

Same method and judgement rules as ho14–ho16 (`accuracy-adjudication-ho14.md`, `-ho15.md`, `-ho16.md`). Work files: `~/CaseBench/adjudication/ho17-work` (`flat.py`, `fam.py`, `verdict.py`, extracted texts under `text/`).

1. **Blind first.** I read all 27 scorer-flagged items (rules 16, opus5 11) on the blinded sheets and judged them against the case documents before opening the keys. After that I used the keys only to map items to cases and paths.
2. **Documents.** All 133 case documents were extracted: PDFKit for the 89 PDFs, `textutil` for doc/docx/rtf/html, and plain text as is. Two scanned PDFs (Lepsky ×2) were read with Apple Vision OCR. No byte-identical files (MD5), so the duplicate-file key defect does not occur in this set.
3. **Verdicts.** TRUE WRONG, SCORER ERROR, TRUTH-LABEL ERROR, PARTLY, AMBIGUOUS, FALSE CORRECT (as in ho14–ho16).
   - **PARTLY** = the main claim is true but incomplete; or a secondary element or row is misdated or mislabelled; or a row or second value belongs to another case or person. PARTLY is not counted in the primary measure. It is counted in the strict measure.
   - **"Charged with" naming no offence = WRONG** ("one count in a federal indictment", "a charge stemming from …", "indicted on federal charges in July", a quote cut before the asked person's offence). An offence named only vaguely, anaphorically, or as admitted conduct (Hodges ho15, Farnell ho16) = PARTLY.
   - **A dump containing other cases' text = WRONG.** **Another (prior or separate) case's charge or sentence given as this case's = WRONG** (ho14 A, ho16 A). The same given as a second value next to the right one = PARTLY (A′). Report-date-hedged rows that are otherwise true are minor and recorded CORRECT. "Who was convicted of …, was sentenced" rows dated on the sentencing day are recorded CORRECT, as in ho16 (Frey, Coia, Blumhagen …).
   - **AMBIGUOUS** = the documents do not settle it (here: one day). It is excluded from the primary measure and shown in a strict + ambiguous column.
4. **Search for false "correct" verdicts — a full check, not a sample.** I checked every answer in these families on both paths: *charge* (204), *sentenced* (240), *charged* (88), *timeline* (240) and *sentence* (148), and also every *plea* answer (212). I checked each stated day against the release date and against the "today / yesterday / weekday / on <date>" of its source sentence. I checked each timeline row for its date, label and order, and for whose event it is.
5. **The rest.** A seeded random sample of 40 (20 per path, seed 20261104) from the *count*, *office* and *absent* items that were scored correct or honest refusal. Outside that sample, undetected false corrects remain possible only in those three families.
6. **Counting.** Wrong % counts dumps and unsupported answers as wrong. There were no wrong refusals (missed items) on either path.

## Per-item table

Item IDs are the blinded-sheet IDs; "—" means the full scan found the item (it is not on the sheet). Every item not listed is CORRECT or HONEST REFUSAL, as the scorer said. Causes: see Root causes.

| item | path | case | question | family | scorer | adjudicated | judgement | cause | reason |
|---|---|---|---|---|---|---|---|---|---|
| — | rules | chron-AdanDiaz-0055 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E | "Diaz pleaded guilty to the indictment filed on September 25, 2012, and admitted that … he pointed a gun at the victim" - the plea object names no offence; only the admitted conduct is given (Hodges, ho15, PARTLY). The offence, assault with a dangerous weapon, is in the lead (opus5 gives it). See sensitivity. |
| — | rules | chron-AdanDiaz-0055 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E | "Diaz pleaded guilty to the indictment filed on September 25, 2012, and admitted that … he pointed a gun at the victim" - the plea object names no offence; only the admitted conduct is given (Hodges, ho15, PARTLY). The offence, assault with a dangerous weapon, is in the lead (opus5 gives it). See sensitivity. |
| — | rules | chron-AdanDiaz-0055 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Unhedged row "September 25, 2012 — pleaded guilty" quoting "pleaded guilty to the indictment filed on September 25, 2012" - the indictment date labelled as a plea (plea Feb. 27, 2013, also listed); as Gordon (ho16). |
| — | rules | chron-AdanDiaz-0055 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Unhedged row "September 25, 2012 — pleaded guilty" quoting "pleaded guilty to the indictment filed on September 25, 2012" - the indictment date labelled as a plea (plea Feb. 27, 2013, also listed); as Gordon (ho16). |
| A0083 | rules | chron-CleophatTanis-0024 | sentence~p1 | sentence | unsupported | **CORRECT** | TRUTH-LABEL ERROR | — | "sentenced … to one month in prison and seven months of home detention" (release-2 verbatim). Key terms are malformed ("1 months", "one months") and cannot match "one month". Minor: lead sentence cut ("Department."). |
| A0048 | rules | chron-CleophatTanis-0024 | sentence~p2 | sentence | unsupported | **CORRECT** | TRUTH-LABEL ERROR | — | "sentenced … to one month in prison and seven months of home detention" (release-2 verbatim). Key terms are malformed ("1 months", "one months") and cannot match "one month". Minor: lead sentence cut ("Department."). |
| — | rules | chron-DanielWhitman-0027 | charged~p1 | charged | correct | **PARTLY** | DEFECT | B′ | "charged on June 2, 2021 and again on October 7, 2022 (the day it was reported)": the second quote is "arrested and charged in January 2021" (month only, the Jan. 6, 2021 complaint) - dated with the report day; the Jan. 6, 2021 complaint day ("arrested today and charged", release-1) is not given. |
| — | rules | chron-DanielWhitman-0027 | charged~p2 | charged | correct | **PARTLY** | DEFECT | B′ | "charged on June 2, 2021 and again on October 7, 2022 (the day it was reported)": the second quote is "arrested and charged in January 2021" (month only, the Jan. 6, 2021 complaint) - dated with the report day; the Jan. 6, 2021 complaint day ("arrested today and charged", release-1) is not given. |
| — | rules | chron-DennisLeeRichardson-0025 | plea~p1 | plea | correct | **PARTLY** | DEFECT | A′ | "Yes" is right but the evidence is his 2014 STATE plea ("pleaded guilty on March 10, 2014 in Caddo Parish"); the federal plea (Dec. 11, 2018) is what opus5 quotes. |
| — | rules | chron-DennisLeeRichardson-0025 | plea~p2 | plea | correct | **PARTLY** | DEFECT | A′ | "Yes" is right but the evidence is his 2014 STATE plea ("pleaded guilty on March 10, 2014 in Caddo Parish"); the federal plea (Dec. 11, 2018) is what opus5 quotes. |
| — | rules | chron-FadelAlshalabi-0005 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E′ | "Alshalabi was also convicted of money laundering" - only the secondary count; the jury convicted him of conspiracy to violate and violations of the Anti-Kickback Statute (release-1 lead). |
| — | rules | chron-FadelAlshalabi-0005 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E′ | "Alshalabi was also convicted of money laundering" - only the secondary count; the jury convicted him of conspiracy to violate and violations of the Anti-Kickback Statute (release-1 lead). |
| — | rules | chron-FadelAlshalabi-0005 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "June 27, 2025 — pleaded guilty" from "Six co-defendants … previously pled guilty before trial" - Alshalabi was convicted at trial; the co-defendants' pleas are listed as his step. |
| — | rules | chron-FadelAlshalabi-0005 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "June 27, 2025 — pleaded guilty" from "Six co-defendants … previously pled guilty before trial" - Alshalabi was convicted at trial; the co-defendants' pleas are listed as his step. |
| — | rules | chron-JacobRNavarro-0012 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 17, 2013 — charged" quoting "In a related case, a federal grand jury … returned a superseding indictment charging Jacob Navarro's father, Tod S. Navarro … and Christopher B. Wilson" - another person's indictment listed as a step of this case. |
| — | rules | chron-JacobRNavarro-0012 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 17, 2013 — charged" quoting "In a related case, a federal grand jury … returned a superseding indictment charging Jacob Navarro's father, Tod S. Navarro … and Christopher B. Wilson" - another person's indictment listed as a step of this case. |
| — | rules | chron-JamesCunningham-0017 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "don't say when charged; arrested on June 9, 2017" - release-1 (June 9, 2017) says complaints "unsealed today" charge him, so the day is effectively stated. |
| — | rules | chron-JamesCunningham-0017 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "don't say when charged; arrested on June 9, 2017" - release-1 (June 9, 2017) says complaints "unsealed today" charge him, so the day is effectively stated. |
| — | rules | chron-JamesCunningham-0017 | sentenced~p1 | sentenced | correct | **AMBIGUOUS** | DEFECT? | B? | "sentenced on May 10, 2018" from "was sentenced in federal court …, United States Attorney … announced today" (release May 10). The earlier release says "Cunningham is scheduled to be sentenced on May 9, 2018", so the day may be May 9; the documents do not state it. Not counted in primary; counted in the strict+ambiguous column. |
| — | rules | chron-JamesCunningham-0017 | sentenced~p2 | sentenced | correct | **AMBIGUOUS** | DEFECT? | B? | "sentenced on May 10, 2018" from "was sentenced in federal court …, United States Attorney … announced today" (release May 10). The earlier release says "Cunningham is scheduled to be sentenced on May 9, 2018", so the day may be May 9; the documents do not state it. Not counted in primary; counted in the strict+ambiguous column. |
| A0050 | rules | chron-JamesDunham-0040 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "arrested on a federal criminal complaint on charges of mail fraud and wire fraud" (release-1 verbatim); key wants the plea count (wire fraud). |
| A0028 | rules | chron-JamesDunham-0040 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "arrested on a federal criminal complaint on charges of mail fraud and wire fraud" (release-1 verbatim); key wants the plea count (wire fraud). |
| — | rules | chron-JasonAnthonyBarrett-0007 | charge~p1 | charge | correct | **PARTLY** | DEFECT | G′ | Charge right (possession with intent to distribute 50 g+ methamphetamine …) but framed "two prosecutions, or two people of that name" beside a group-indictment sentence that names no offence; one prosecution. |
| — | rules | chron-JasonAnthonyBarrett-0007 | charge~p2 | charge | correct | **PARTLY** | DEFECT | G′ | Charge right (possession with intent to distribute 50 g+ methamphetamine …) but framed "two prosecutions, or two people of that name" beside a group-indictment sentence that names no offence; one prosecution. |
| A0055 | rules | chron-JasonAnthonyBarrett-0007 | plea~p1 | plea | wrong | **WRONG** | TRUE WRONG (dump) | C | "Is there any record of X pleading guilty?" not parsed (stepWords has no "pleading"). Answer is a run-on of release headers incl. OTHER cases (ATF Deville silencer case; W.D. Mo. Tammy Dickin) and no yes/no. p2 and opus5 answered Yes. |
| A0114 | rules | chron-JodiaCampbell-0019 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Quotes the July 9, 2014 indictment verbatim ("sex trafficking of a minor, transportation of a minor across state lines …"); key wants the later plea wording. Quote cut at "prostit…" but offences named. |
| A0031 | rules | chron-JodiaCampbell-0019 | charge~p2 | charge | wrong | **WRONG** | TRUE WRONG (dump) | C | "I need to know specifically what X was charged with." not parsed ("specifically" before "what"). Header run-on incl. OTHER cases (D. Idaho Naples Lacey Act; N.D. Ind. Gary crack complaint). p1 and opus5 quote the indictment. |
| A0112 | rules | chron-JustinThomasShipley-0054 | charge~p1 | charge | wrong | **PARTLY** | DEFECT | E′ | Quotes "The indictment further charged Wood and Shipley with using and carrying firearms in relation to a drug trafficking crime" - true but only the supplementary count; the methamphetamine conspiracy/distribution charges (release-1/2, opus5) are omitted. |
| A0086 | rules | chron-JustinThomasShipley-0054 | charge~p2 | charge | wrong | **PARTLY** | DEFECT | E′ | Quotes "The indictment further charged Wood and Shipley with using and carrying firearms in relation to a drug trafficking crime" - true but only the supplementary count; the methamphetamine conspiracy/distribution charges (release-1/2, opus5) are omitted. |
| — | rules | chron-KenwanieeVontorianTate-0008 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer: "Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor … from Minnesota to Las Vegas" - his PRIOR case. This case (W.D.N.C.): jury verdict for sex trafficking of a minor by fraud, force and coercion and sex trafficking of a minor while required to register as a sex offender (release-1 lead). Key accepts the prior-case sentence. |
| — | rules | chron-KenwanieeVontorianTate-0008 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer: "Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor … from Minnesota to Las Vegas" - his PRIOR case. This case (W.D.N.C.): jury verdict for sex trafficking of a minor by fraud, force and coercion and sex trafficking of a minor while required to register as a sex offender (release-1 lead). Key accepts the prior-case sentence. |
| A0033 | rules | chron-KraigAntonioDavis-0041 | absent~p2 | absent | unsupported | **WRONG** | TRUE WRONG (unsupported dump) | C | "I'm trying to find the date X was pardoned — can you confirm?" not parsed ("find" without "out"). Run-on of OTHER cases (Robbins securities fraud, a DEA quote) plus "The source says: Date: 2019" and "your sources disagree" — no record of a pardon exists; should refuse (opus5 refused). |
| A0016 | rules | chron-KraigAntonioDavis-0041 | sentenced~p2 | sentenced | dump | **WRONG** | TRUE WRONG (dump) | C | "Please pull the record showing when X was sentenced." not parsed ("pull" without "up"). Header run-on incl. OTHER cases (Blakeley E.D. Cal.; Peter Yang Fresno). opus5 answered from the May 29, 2013 release. |
| A0079 | rules | chron-LucasRussellVanwoert-0039 | charged~p2 | charged | wrong | **PARTLY** | DEFECT | C′ | "I need the charge date for X — when did that happen?" answered with the offence quote ("was charged today in a four-count indictment …", release dated Oct. 28, 2022) but no date is stated; p1 says "charged on October 28, 2022". Not false; the asked fact is only derivable from "today" + the cited file date. |
| — | rules | chron-NaderPourhassan-0034 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | F′ | Term right (30 months) but one sentence reported twice as two: "(January 23, 2026) and, in another proceeding, to 30 months … (January 26, 2026) — the documents record more than one sentence" (two releases of the same sentencing). |
| — | rules | chron-NaderPourhassan-0034 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | F′ | Term right (30 months) but one sentence reported twice as two: "(January 23, 2026) and, in another proceeding, to 30 months … (January 26, 2026) — the documents record more than one sentence" (two releases of the same sentencing). |
| A0052 | rules | chron-PabloLugoIII-0026 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Sept. 15, 2017 indictment "charging Pablo Lugo III … with distribution of fentanyl causing death" (release-1 verbatim); key wants the plea wording. |
| A0082 | rules | chron-PabloLugoIII-0026 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Sept. 15, 2017 indictment "charging Pablo Lugo III … with distribution of fentanyl causing death" (release-1 verbatim); key wants the plea wording. |
| A0002 | rules | chron-RaekwonMalikHarrod-0021 | office~p2 | office | dump | **WRONG** | TRUE WRONG (dump) | C | "I need to identify the office that prosecuted X — can you confirm that?" not parsed ("identify" is only in the can-you wrapper). Passage/header run-on incl. ANOTHER case (Heather Hare teacher quote) and "your sources disagree". p1 and opus5 name District of Columbia. |
| — | rules | chron-SherryTaggart-0050 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 2, 2016 — sentenced: El Dorado Hills Woman Sentenced to 3.5 Years …" - release-2 is co-conspirator Barbara Antonucci's sentencing; Taggart was sentenced Dec. 9, 2016 to two years (also listed). |
| — | rules | chron-SherryTaggart-0050 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 2, 2016 — sentenced: El Dorado Hills Woman Sentenced to 3.5 Years …" - release-2 is co-conspirator Barbara Antonucci's sentencing; Taggart was sentenced Dec. 9, 2016 to two years (also listed). |
| A0081 | rules | chron-TonyNewton-0044 | sentenced~p2 | sentenced | wrong | **WRONG** | TRUE WRONG | C | "Do you happen to know when X was sentenced?" not parsed ("happen to"). A date list of OTHER cases (Powell overdose death Feb. 23, 2019; Blakeley plea Oct. 5, 2021), citing their files. Newton: sentenced June 12, 2024 (p1, opus5). |
| — | rules | chron-VincenzoLomax-0016 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | A′ | Adds "in another proceeding, to two years in prison (January 19, 2018)" - the June 2015 Superior Court sentence, dated with the 2018 report day (as Gordon, ho16). |
| A0001 | rules | chron-VincenzoLomax-0016 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | A′ | Adds "in another proceeding, to two years in prison (January 19, 2018)" - the June 2015 Superior Court sentence, dated with the 2018 report day (as Gordon, ho16). |
| — | opus5 | chron-AdanDiaz-0055 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | B′ | Unhedged row "September 25, 2012 — pleaded guilty" quoting "pleaded guilty to the indictment filed on September 25, 2012" - the indictment date labelled as a plea (plea Feb. 27, 2013, also listed); as Gordon (ho16). |
| A0031 | opus5 | chron-AdanDiaz-0055 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | B′ | Unhedged row "September 25, 2012 — pleaded guilty" quoting "pleaded guilty to the indictment filed on September 25, 2012" - the indictment date labelled as a plea (plea Feb. 27, 2013, also listed); as Gordon (ho16). |
| — | opus5 | chron-CleophatTanis-0024 | charge~p1 | charge | correct | **CORRECT** | DEFECT (minor) | — | "Tanis pled guilty to one count of mail fraud in December 2020." - offence right; "2020" is the release's own typo (plea Dec. 16, 2019). |
| — | opus5 | chron-CleophatTanis-0024 | charge~p2 | charge | correct | **CORRECT** | DEFECT (minor) | — | "Tanis pled guilty to one count of mail fraud in December 2020." - offence right; "2020" is the release's own typo (plea Dec. 16, 2019). |
| A0080 | opus5 | chron-CleophatTanis-0024 | sentence~p1 | sentence | unsupported | **CORRECT** | TRUTH-LABEL ERROR | — | "sentenced … to one month in prison and seven months of home detention" (release-2 verbatim). Key terms are malformed ("1 months", "one months") and cannot match "one month". Minor: lead sentence cut ("Department."). |
| A0047 | opus5 | chron-CleophatTanis-0024 | sentence~p2 | sentence | unsupported | **CORRECT** | TRUTH-LABEL ERROR | — | "sentenced … to one month in prison and seven months of home detention" (release-2 verbatim). Key terms are malformed ("1 months", "one months") and cannot match "one month". Minor: lead sentence cut ("Department."). |
| A0054 | opus5 | chron-CoryHutcheson-0006 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "following his indictment on eleven felony counts of Identity Theft" (release-1 verbatim); key wants the plea wording (wire fraud and identity theft). |
| A0109 | opus5 | chron-CoryHutcheson-0006 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "following his indictment on eleven felony counts of Identity Theft" (release-1 verbatim); key wants the plea wording (wire fraud and identity theft). |
| — | opus5 | chron-DanielWhitman-0027 | charged~p1 | charged | correct | **PARTLY** | DEFECT | B′ | "charged on June 2, 2021 and again on October 7, 2022 (the day it was reported)": the second quote is "arrested and charged in January 2021" (month only, the Jan. 6, 2021 complaint) - dated with the report day; the Jan. 6, 2021 complaint day ("arrested today and charged", release-1) is not given. |
| — | opus5 | chron-DanielWhitman-0027 | charged~p2 | charged | correct | **PARTLY** | DEFECT | B′ | "charged on June 2, 2021 and again on October 7, 2022 (the day it was reported)": the second quote is "arrested and charged in January 2021" (month only, the Jan. 6, 2021 complaint) - dated with the report day; the Jan. 6, 2021 complaint day ("arrested today and charged", release-1) is not given. |
| — | opus5 | chron-FadelAlshalabi-0005 | charge~p1 | charge | correct | **PARTLY** | DEFECT | E′ | "Alshalabi was also convicted of money laundering" - only the secondary count; the jury convicted him of conspiracy to violate and violations of the Anti-Kickback Statute (release-1 lead). |
| — | opus5 | chron-FadelAlshalabi-0005 | charge~p2 | charge | correct | **PARTLY** | DEFECT | E′ | "Alshalabi was also convicted of money laundering" - only the secondary count; the jury convicted him of conspiracy to violate and violations of the Anti-Kickback Statute (release-1 lead). |
| — | opus5 | chron-FadelAlshalabi-0005 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "June 27, 2025 — pleaded guilty" from "Six co-defendants … previously pled guilty before trial" - Alshalabi was convicted at trial; the co-defendants' pleas are listed as his step. |
| — | opus5 | chron-FadelAlshalabi-0005 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "June 27, 2025 — pleaded guilty" from "Six co-defendants … previously pled guilty before trial" - Alshalabi was convicted at trial; the co-defendants' pleas are listed as his step. |
| — | opus5 | chron-JacobRNavarro-0012 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 17, 2013 — charged" quoting "In a related case, a federal grand jury … returned a superseding indictment charging Jacob Navarro's father, Tod S. Navarro … and Christopher B. Wilson" - another person's indictment listed as a step of this case. |
| — | opus5 | chron-JacobRNavarro-0012 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 17, 2013 — charged" quoting "In a related case, a federal grand jury … returned a superseding indictment charging Jacob Navarro's father, Tod S. Navarro … and Christopher B. Wilson" - another person's indictment listed as a step of this case. |
| — | opus5 | chron-JamesCunningham-0017 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | "don't say when charged; arrested on June 9, 2017" - release-1 (June 9, 2017) says complaints "unsealed today" charge him, so the day is effectively stated. |
| — | opus5 | chron-JamesCunningham-0017 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | "don't say when charged; arrested on June 9, 2017" - release-1 (June 9, 2017) says complaints "unsealed today" charge him, so the day is effectively stated. |
| — | opus5 | chron-JamesCunningham-0017 | sentenced~p1 | sentenced | correct | **AMBIGUOUS** | DEFECT? | B? | "sentenced on May 10, 2018" from "was sentenced in federal court …, United States Attorney … announced today" (release May 10). The earlier release says "Cunningham is scheduled to be sentenced on May 9, 2018", so the day may be May 9; the documents do not state it. Not counted in primary; counted in the strict+ambiguous column. |
| — | opus5 | chron-JamesCunningham-0017 | sentenced~p2 | sentenced | correct | **AMBIGUOUS** | DEFECT? | B? | "sentenced on May 10, 2018" from "was sentenced in federal court …, United States Attorney … announced today" (release May 10). The earlier release says "Cunningham is scheduled to be sentenced on May 9, 2018", so the day may be May 9; the documents do not state it. Not counted in primary; counted in the strict+ambiguous column. |
| A0049 | opus5 | chron-JamesDunham-0040 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | "arrested on a federal criminal complaint on charges of mail fraud and wire fraud" (release-1 verbatim); key wants the plea count (wire fraud). |
| A0025 | opus5 | chron-JamesDunham-0040 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | "arrested on a federal criminal complaint on charges of mail fraud and wire fraud" (release-1 verbatim); key wants the plea count (wire fraud). |
| A0028 | opus5 | chron-JodiaCampbell-0019 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Quotes the July 9, 2014 indictment verbatim (sex trafficking of a minor, transportation of a minor …); key wants the later plea wording. |
| A0007 | opus5 | chron-JodiaCampbell-0019 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Quotes the July 9, 2014 indictment verbatim (sex trafficking of a minor, transportation of a minor …); key wants the later plea wording. |
| — | opus5 | chron-KenwanieeVontorianTate-0008 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer: "Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor … from Minnesota to Las Vegas" - his PRIOR case. This case (W.D.N.C.): jury verdict for sex trafficking of a minor by fraud, force and coercion and sex trafficking of a minor while required to register as a sex offender (release-1 lead). Key accepts the prior-case sentence. |
| — | opus5 | chron-KenwanieeVontorianTate-0008 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer: "Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor … from Minnesota to Las Vegas" - his PRIOR case. This case (W.D.N.C.): jury verdict for sex trafficking of a minor by fraud, force and coercion and sex trafficking of a minor while required to register as a sex offender (release-1 lead). Key accepts the prior-case sentence. |
| A0076 | opus5 | chron-LucasRussellVanwoert-0039 | charged~p2 | charged | wrong | **PARTLY** | DEFECT | C′ | "I need the charge date for X — when did that happen?" answered with the offence quote ("was charged today in a four-count indictment …", release dated Oct. 28, 2022) but no date is stated; p1 says "charged on October 28, 2022". Not false; the asked fact is only derivable from "today" + the cited file date. |
| A0061 | opus5 | chron-PabloLugoIII-0026 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Sept. 15, 2017 indictment "charging Pablo Lugo III … with distribution of fentanyl causing death" (release-1 verbatim); key wants the plea wording. |
| A0079 | opus5 | chron-PabloLugoIII-0026 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Sept. 15, 2017 indictment "charging Pablo Lugo III … with distribution of fentanyl causing death" (release-1 verbatim); key wants the plea wording. |
| A0099 | opus5 | chron-SherryTaggart-0050 | timeline~p1 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 2, 2016 — sentenced: El Dorado Hills Woman Sentenced to 3.5 Years …" - release-2 is co-conspirator Barbara Antonucci's sentencing; Taggart was sentenced Dec. 9, 2016 to two years (also listed). |
| A0105 | opus5 | chron-SherryTaggart-0050 | timeline~p2 | timeline | correct | **PARTLY** | DEFECT | P | Row "December 2, 2016 — sentenced: El Dorado Hills Woman Sentenced to 3.5 Years …" - release-2 is co-conspirator Barbara Antonucci's sentencing; Taggart was sentenced Dec. 9, 2016 to two years (also listed). |

Further minor defects, recorded as CORRECT:
- Rules *sentence* lead sentences are cut mid-phrase ("by Chief.", "by.", "Department.", "money laund."), but the quote after them is complete (ho15 J class).
- "It gives no other day" where the source says only "last week" (Martinez-Barrera) or gives a month only (Newton "charged … in July 2022").
- Report-date-hedged rows for prior cases in timelines (Robbins 2011, Lomax 2015, Richardson 2014 state plea).
- Co-conspirator rows where the person also pleaded (Tanis/Rapp).
- "Who was convicted of …" rows dated on the sentencing day (Tyler, Campbell, Lugo).
- Office answers that name only the investigating component (ATF) when no U.S. Attorney's district is named in the documents (Hayes, Richardson).

## Random spot check (count / office / absent, 20 per path, seed 20261104)

**rules — 20 of 20 confirmed:** Shipley count~p2, Cunningham absent~p2 (refusal), Whitman absent~p1, Woolridge absent~p1, Segovia absent~p2, Taggart absent~p1, Headen absent~p1, Campbell office~p1, Tyler count~p2, Holland office~p2, Diaz absent~p1, Yang office~p2, Taggart office~p1, Pope count~p2, Harrison office~p1, Hutcheson count~p2, Vanwoert count~p2, Soto count~p2, Hayes office~p1 (ATF only; no district named in the documents — minor), Beasley office~p1.

**opus5 — 20 of 20 confirmed:** Harley count~p2, Edwards absent~p1, Yang absent~p1, Dunham count~p2, Witthar office~p1, Lepsky absent~p2, Tanis office~p1, Harley absent~p1, Tanis absent~p2, Cartwright count~p1, Lepsky office~p1, Whitman count~p2, Yang absent~p2, Segovia absent~p2, Segovia office~p1, Newton absent~p2, Segovia count~p1, Soto absent~p2, Powell office~p1, Beasley office~p2.

## Adjudicated totals

### rules
| family | n | correct | honest refusal | partly | ambiguous | missed | wrong | wrong % | strict % (wrong+partly) | strict + ambiguous % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 116 | 0 | 0 | 2 | 0 | 2 | 1.67 % | 1.67 % | 3.33 % |
| timeline | 120 | 112 | 0 | 8 | 0 | 0 | 0 | 0.00 % | 6.67 % | 6.67 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| office | 120 | 119 | 0 | 0 | 0 | 0 | 1 | 0.83 % | 0.83 % | 0.83 % |
| absent | 120 | 0 | 119 | 0 | 0 | 0 | 1 | 0.83 % | 0.83 % | 0.83 % |
| plea | 106 | 103 | 0 | 2 | 0 | 0 | 1 | 0.94 % | 2.83 % | 2.83 % |
| charge | 102 | 91 | 0 | 8 | 0 | 0 | 3 | 2.94 % | 10.78 % | 10.78 % |
| sentence | 74 | 70 | 0 | 4 | 0 | 0 | 0 | 0.00 % | 5.41 % | 5.41 % |
| charged | 44 | 41 | 0 | 3 | 0 | 0 | 0 | 0.00 % | 6.82 % | 6.82 % |
| ALL | 926 | 772 | 119 | 25 | 2 | 0 | 8 | 0.86 % | 3.56 % | 3.78 % |
### opus5
| family | n | correct | honest refusal | partly | ambiguous | missed | wrong | wrong % | strict % (wrong+partly) | strict + ambiguous % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 118 | 0 | 0 | 2 | 0 | 0 | 0.00 % | 0.00 % | 1.67 % |
| timeline | 120 | 112 | 0 | 8 | 0 | 0 | 0 | 0.00 % | 6.67 % | 6.67 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| office | 120 | 120 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| plea | 106 | 106 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| charge | 102 | 98 | 0 | 2 | 0 | 0 | 2 | 1.96 % | 3.92 % | 3.92 % |
| sentence | 74 | 74 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| charged | 44 | 41 | 0 | 3 | 0 | 0 | 0 | 0.00 % | 6.82 % | 6.82 % |
| ALL | 926 | 789 | 120 | 13 | 2 | 0 | 2 | 0.22 % | 1.62 % | 1.84 % |

- **rules:** n = 926. Correct 772, honest refusal 119, partly 25, ambiguous 2, missed 0, **wrong 8 = 0.86 %**. Strict (wrong + partly) 33 = **3.56 %**; strict + ambiguous 35 = 3.78 %.
- **opus5:** n = 926. Correct 789, honest refusal 120, partly 13, ambiguous 2, missed 0, **wrong 2 = 0.22 %**. Strict 15 = **1.62 %**; strict + ambiguous 17 = 1.84 %.

## The automatic score versus the adjudicated score

- **Scorer flags that were not real wrongs.**
  - rules: 7 of 16 flagged answers are acceptable. Lugo ×2, Dunham ×2 and Campbell p1 are scorer errors (they quote the indictment or complaint charge; the key wants the plea wording). Tanis sentence ×2 is a truth-label error (the key terms "1 months" / "one months" are malformed). Shipley ×2 and Vanwoert ×1 are PARTLY. The real wrongs are the 6 dumps (Barrett, Campbell p2, Harrod, Davis ×2, Newton).
  - opus5: 10 of 11 flagged answers are acceptable (Hutcheson, Campbell, Lugo and Dunham ×2 each, Tanis ×2), and 1 is PARTLY (Vanwoert p2). opus5 has **no** real wrong among its flags.
- **"Correct" scores that were really wrong:** rules 2 and opus5 2, the same item: Tate charge ×2. The key accepts the prior Minnesota conviction.
- **Net.** rules: automatic 16 wrong + dump + unsupported → adjudicated 8. opus5: automatic 11 → adjudicated 2.
- **Bench generator defects still present** (bench fixes, not app fixes):
  - `offence_sentences` keys want the plea wording and reject the indictment or complaint charge (Lugo, Dunham, Campbell, Hutcheson; the same as Conover and Waqas Ali in ho16).
  - The same keys accept a prior-case sentence (Tate) and secondary counts (Alshalabi "also convicted of money laundering").
  - Sentence-term keys are generated ungrammatically for "one month" ("1 months", "one months").
  - `stated_days` accepts the announcement day where the sentencing day is not stated (Cunningham).

  Re-label these before quoting ho17 figures as final.

## Root causes of the TRUE WRONG items

| cat | root cause | rules | opus5 | exact reproducing sentence(s) | fixable? | code area |
|---|---|---|---|---|---|---|
| C | **Paraphrase not parsed → header/passage run-on with OTHER cases' text (rules only; scope breach).** Six new wrapper/verb gaps. The opus5 path is clean because the Claude canonicaliser rewrites these questions. | 6 | 0 | "Is there any record of Jason Anthony Barrett pleading guilty?" · "I need to know specifically what Jodia Campbell was charged with." · "I need to identify the office that prosecuted Raekwon Malik Harrod — can you confirm that?" · "Please pull the record showing when Kraig Antonio Davis was sentenced." · "I'm trying to find the date Kraig Antonio Davis was pardoned — can you confirm?" · "Do you happen to know when Tony Newton was sentenced?" | **FIXABLE** | `Kalsmritikosh/Brain/ProceedingAnswerer.swift`. Fixes: `stepWords` (l.39–51) has no "pleading (guilty)"; the `.chargedWith` pattern (l.118) needs an adverb before "what" ("specifically/exactly/precisely what"); `unwrap` (l.81) needs "identify" after "i need to"/"to", "pull (the) record(s) showing", "trying to find" (without "out") and "do you happen to know". **Structural fix (recommended in ho14, ho15 and ho16, still missing):** the passage composer and `IncidentAnswerComposer.swift` (l.62, the Newton "documents date 8 incidents" list) must scope a person-naming question to that person's documents and never emit concatenated release headers. A missed parse would then fail as a refusal, not as a scope breach. |
| A | **Prior case's conviction given as this case's charge (recurred in a new wording, both paths).** "was also convicted previously" reverses the word order of `priorRecord` ("previously convicted"), carries no year for `oldConviction`, and "also" in mid-sentence escapes `supplementary` (anchored at sentence start). The AI path's verifier kept it. | 2 | 2 | Tate release-2: "Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor …" (this case: sex trafficking of a minor by fraud, force and coercion; W.D.N.C. jury, release-1) | **FIXABLE** | `ProceedingAnswerer.swift` `.chargedWith`. Fixes: `priorRecord` (l.221) should add "convicted previously" and "(also )?(previously )?convicted (previously )?in <other court/state>"; `supplementary` (l.451) should also match a mid-sentence "<Name> was also convicted / the indictment further charged" (this also fixes the PARTLY E′ items Shipley and Alshalabi); a jury-verdict lead ("a federal jury delivered a guilty verdict … against X … for <offence>") should count as an offence-stating candidate. Mirror in `VerifiedRecordExtractor.verify`. |

**No TRUE WRONG is a limit of current technology.** Both causes are deterministic rule gaps with exact reproducing sentences. For C, the same question on the other path, and the other paraphrase on the same path, already answers correctly. The bar is not raised.

### Partly-correct items (strict measure only)

| cat | cause | rules | opus5 | fixable? | area |
|---|---|---|---|---|---|
| P (new) | Another person's step listed as a row of this case's timeline: the father's indictment "In a related case" (Navarro), co-defendants' pleas for a defendant convicted at trial (Alshalabi), and a co-conspirator's sentencing headline (Taggart / Antonucci) | 6 | 6 | FIXABLE | timeline reader in `ProceedingAnswerer` `.timeline` + `ProceedingEventExtractor`. Rows should be dropped when the sentence's step subject is another named person ("In a related case", "co-defendants … pled", a headline whose lead names someone else) |
| B′ | Indictment date labelled as a plea ("pleaded guilty to the indictment filed on September 25, 2012", Diaz, as Gordon ho16); month-only "charged in January 2021" dated with the report day (Whitman, as Waqas Ali ho16) | 4 | 4 | FIXABLE (recurred) | step label from the verb nearest the date; month-only guard in `.when(.charged)` multi-value answers |
| E′ | Supplementary count chosen over the main charge ("The indictment further charged …", "Alshalabi was also convicted of money laundering") | 4 | 2 | FIXABLE | `supplementary` (l.451), as A |
| E | Plea to "the indictment" + admitted conduct, no offence named (Diaz) | 2 | 0 | FIXABLE | as ho16 E: prefer the lead that states the offence |
| A′ | Prior case as a second value or as the evidence: Lomax 2015 Superior Court sentence dated Jan. 19, 2018; Richardson "Yes" quoting his 2014 state plea | 4 | 0 | FIXABLE (recurred) | `.sentenceImposed` multi-value and `.whether(.pleaded)` quote choice: apply `otherCourt`/prior penalties |
| F′ (new) | One sentence reported as two proceedings (Pourhassan, two releases of the same sentencing) | 2 | 0 | FIXABLE | `.sentenceImposed`: same term + same judge/wording across releases = one sentence |
| G′ | One prosecution framed "two prosecutions, or two people of that name" (Barrett) | 2 | 0 | FIXABLE (recurred) | `.chargedWith` disjoint-offence test: a group-indictment sentence naming no offence must not create a second prosecution |
| C′ | "I need the charge date for X — when did that happen?" answered with the offence quote, no date (both paths) | 1 | 1 | FIXABLE | `ProceedingAnswerer.parse`/`QuestionCanonicalizer.normalize` route this wording to `.chargedWith` (the "The documents say:" composer, l.589) instead of `.when(.charged)`. Pin it with a unit test |

## Comparison with ho16 (fixes at b1022f77)

| cat | ho16 wrong (rules/opus5) | ho17 wrong (rules/opus5) | status |
|---|---|---|---|
| A other/prior case | 2 / 0 (A′ partly 6 / 2) | **2 / 2** (A′ partly 4 / 0) | **Recurred, now on both paths.** The ho16 "In a separate case" sentence fix held (no such error), but a prior conviction phrased "was also convicted previously in Minnesota federal court" was taken as the charge. |
| B announcement vs step day | 2 / 2 | 0 / 0 | **Fixed, held** ("sentenced yesterday" → June 10, McGhee; "sentenced Friday" → Jan. 23, Pourhassan). B′ partly recurred (Diaz label, Whitman month-only). |
| C paraphrase dump | 3 / 0 | **6 / 0** | **Recurred on rules, and worse** (six new wordings). The three ho16 wordings now parse (e.g. "Can you identify the office that prosecuted X?" ×3 correct). The structural scope fix is still missing. |
| E no-offence charge | 4 / 1 | 0 / 0 | **Fixed, held** (no "a charge stemming from" / "federal charges in July" type). Remaining only as PARTLY (Diaz conduct, supplementary counts). |
| K anonymous lead | 2 / 2 (+2 / 1 missed) | 0 / 0, 0 missed | **Fixed, held** ("A former postal worker … pleaded guilty today", "A Monmouth County … man was sentenced today", "A former Tyngsborough police officer …" all linked). |
| T quote truncation | 0 / 2 | 0 / 0 | **Fixed, held.** |
| F 'to be sentenced' | partly 6 / 2 | 0 / 0 | **Fixed, held** (Shipley "will be sentenced to eight years" not read as a sentencing). New F′ duplicate (partly). |
| G′ | partly 4 / 0 | partly 2 / 0 | Recurred as partly. |
| P another person's row (NEW) | — | partly 6 / 6 | New (partly only). |

## Result

- **rules:** adjudicated wrong 8 / 926 = **0.86 %** (strict 33 = 3.56 %; strict + ambiguous 3.78 %; missed 0). Causes: C 6, A 2.
- **opus5:** adjudicated wrong 2 / 926 = **0.22 %** (strict 15 = 1.62 %; strict + ambiguous 1.84 %; missed 0). Cause: A 2.
- **Sensitivity.**
  - The rules verdict is close to the bar. Scoring Diaz charge (plea "to the indictment" plus admitted conduct) WRONG instead of PARTLY, by the Kevin Brown (ho15) reading rather than the Hodges reading, gives rules 10 = **1.08 % (would not meet)**.
  - Scoring Vanwoert's date-less answer WRONG gives rules 9 = 0.97 % and opus5 3 = 0.32 %. Both changes together: rules 11 = 1.19 %.
  - Counting the ambiguous Cunningham day as wrong adds 2 to each path: rules 1.08 %, opus5 0.43 %.
  - The primary verdict keeps the precedent readings (Hodges: admitted conduct = PARTLY; ambiguous excluded).
- **Shared wrong.** Tate (A) is the same deterministic output on both paths and is all of opus5's wrongs. The six C dumps are rules-only. Fixing `unwrap`/`stepWords` and the prior-conviction penalty removes all eight. The scope guard on the composers is still owed so that the next unparsed wording refuses instead of leaking other cases.

The bar is not raised. No root cause is a limit of current technology.

**rules — Meets ≤1% wrong: YES** (0.86 % primary measure; narrow margin, see Sensitivity; NO on the strict measure at 3.56 %. Within the coverage stated in Method steps 4–5.)

**opus5 — Meets ≤1% wrong: YES** (0.22 % primary measure; NO on the strict measure at 1.62 %. Within the coverage stated in Method steps 4–5.)
