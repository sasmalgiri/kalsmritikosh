# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

Accuracy adjudication of the held-out set **ho14-chron**, both answer paths. This was done by an AI agent acting as an independent adjudicator, on the owner's written direction of 2026-11-01. It replaces human adjudication only to the extent the owner has said so; it is not a human sign-off.

| | |
|---|---|
| Set | ho14-chron — FRESH: seed 20261101, 60 public DOJ prosecution cases, 914 questions (incl. paraphrases); skip-chron x1–x15, 0 overlap; generated 2026-11-01 before any run |
| App commit | 81cf335f (unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1) |
| Runs | opus5 2026-11-01T18:35:55Z–19:08:25Z; rules 19:08:25Z–19:11:14Z |
| Scorer sha256 (as recorded in MEASUREMENT-*.txt) | 060e98b92d814d24e759ac09e1e7dffcdac54c13d8a12b597c8c4e9c26df32f0 |
| Scorer files today | scripts/casebench/ccsscore.py b5d79621…, score.py 04a26faa…, common.py 7e055679… (last changed 24eb3ae7). None of these hashes, and not their concatenation, equals the recorded sha, so the recorded hash covers some other file set. This should be pinned before the result is frozen. |
| Automatic score | rules: right 98.2 %, wrong 1.4 % (13 wrong, 2 missed, 1 dump, 120 honest refusals); opus5: right 97.6 %, wrong 2.1 % (19 wrong, 2 missed, 1 dump) |
| Release bar | ≤ 1 % wrong per path |

## Method

1. **Blind first.** I read every scorer-flagged item (wrong / missed / dump) on the blinded sheets `~/CaseBench/adjudication/ho14-{rules,opus5}-sheet.csv` and judged it against the case documents before opening the keys. The keys were then used only to map items to cases and paths.
2. **Documents.** I extracted the text of all 127 case documents: PDFKit for text PDFs, `textutil` for doc/docx/rtf/html, plain text as is. The 4 scanned PDFs (Eaton ×2, Ross ×2) were read with Apple Vision OCR. Every verdict is checked against the document text, not against truth.jsonl.
3. **Verdict per item.** *TRUE WRONG* means the answer states something the documents contradict or do not support, or it gives no answer (a dump). *SCORER ERROR* means the answer is right and the scorer misread it. *TRUTH-LABEL ERROR* means the bench key itself is wrong per the documents. *AMBIGUOUS / PARTLY* means the main claim is true but incomplete, or a secondary element is misdated. Partly-correct items are shown separately and are **not** counted as wrong in the primary measure. A strict measure (wrong + partly) is also given.
4. **Searching for false "correct".** The required 40-item random spot check (20 per path, seed 20261102, drawn from the sheet's "correct" sample) found one false correct: Jay Neal's timeline. Because of that I widened the search: (a) all 216 *charge* answers were read against the documents; (b) every *sentenced*/*charged* answer was checked automatically (each stated date compared with the release dates and the quoted sentence, a "today"/"yesterday" date that does not match its release flagged), and every flag was read by hand; (c) every *timeline* step with an unhedged date was checked the same way; (d) *plea* "Yes" answers whose quote does not name the person were read. *Office*, *count*, *sentence* and *absent* answers were covered only by the spot check and the scorer. Undetected false corrects in those families, and in timeline steps that carry a hedge, cannot be ruled out.
5. **Wrong % counts dumps as wrong.** A dump answers nothing and here includes other cases' text. A missed item (a wrong refusal) is reported separately, matching the scorer.

## Per-item table

Item IDs (A####) are the blinded sheet IDs where the item was on the sheet. "—" means the item was not on the sheet and was found by the adjudicator's scan.

| item | path | case | question | family | scorer | adjudicated | judgement | cause | reason |
|---|---|---|---|---|---|---|---|---|---|
| A0092 | opus5 | chron-DarronDimitriRoss-0047 | sentenced~p1 | sentenced | dump | **WRONG** | TRUE WRONG | C | "Do we have a sentencing date for X?" not parsed; answer is a run-on dump of release headers incl. OTHER cases (Greensburg police chief 2025, Rhode Island heroin 2018). Correct: Oct. 24, 2022 (p2 got it). |
| — | opus5 | chron-JayNeal-0024 | sentenced~p2 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Same as rules: Oct. 20, 2015 is the drug sale, not the sentencing (opus5 p1 correctly said Oct. 18, 2018). |
| A0111 | opus5 | chron-JayNeal-0024 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | B | First step "October 20, 2015 - sentenced" (the drug-sale date) puts the sentencing 2.5 years before the April 13, 2018 plea. |
| — | opus5 | chron-JayNeal-0024 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | B | First step "October 20, 2015 - sentenced" (the drug-sale date) puts the sentencing 2.5 years before the April 13, 2018 plea. |
| — | opus5 | chron-ShaunMiller-0045 | charged~p1 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on August 18, 2016 and again on October 20, 2017": the quote itself says "indicted in April 2016 was arrested yesterday" - Aug. 18 is the arrest, Oct. 20, 2017 the sentencing release. |
| — | opus5 | chron-ShaunMiller-0045 | charged~p2 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on August 18, 2016 and again on October 20, 2017": the quote itself says "indicted in April 2016 was arrested yesterday" - Aug. 18 is the arrest, Oct. 20, 2017 the sentencing release. |
| A0086 | opus5 | chron-AdriaHarper-0032 | plea~p1 | plea | missed | **MISSED** | TRUE MISS | D | Refused; release-2: "Adria Harper ... was sentenced ... after pleading guilty to one count of conspiracy to traffic drugs". The charge answer quotes this very sentence. |
| A0121 | opus5 | chron-AdriaHarper-0032 | plea~p2 | plea | missed | **MISSED** | TRUE MISS | D | Refused; release-2: "Adria Harper ... was sentenced ... after pleading guilty to one count of conspiracy to traffic drugs". The charge answer quotes this very sentence. |
| A0083 | opus5 | chron-DarronDimitriRoss-0047 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | July 23, 2019 superseding indictment is right, but "it gives no other day" is untrue: release-1 names the Dec. 20, 2018 original indictment. |
| A0118 | opus5 | chron-DarronDimitriRoss-0047 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | July 23, 2019 superseding indictment is right, but "it gives no other day" is untrue: release-1 names the Dec. 20, 2018 original indictment. |
| A0058 | opus5 | chron-DonnaOsowittSteele-0019 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer "Steele pleaded guilty to wire fraud" names the charge; release-1: "pleaded guilty to wire fraud". Scorer demanded a longer phrase. |
| A0029 | opus5 | chron-DonnaOsowittSteele-0019 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer "Steele pleaded guilty to wire fraud" names the charge; release-1: "pleaded guilty to wire fraud". Scorer demanded a longer phrase. |
| A0032 | opus5 | chron-DouglasRoseth-0022 | charge~p1 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: plea to production of child pornography (release-1/2 say exactly this). Truth label is a quote fragment: "a sexual predator,” said U". |
| A0035 | opus5 | chron-DouglasRoseth-0022 | charge~p2 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: plea to production of child pornography (release-1/2 say exactly this). Truth label is a quote fragment: "a sexual predator,” said U". |
| A0064 | opus5 | chron-FirozPatel-0002 | charged~p1 | charged | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: indictment unsealed May 17, 2023 (stated in release-1). Key wants the release day 2023-05-31 or 2025-05-20 (not in any document). |
| A0097 | opus5 | chron-FirozPatel-0002 | charged~p2 | charged | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: indictment unsealed May 17, 2023 (stated in release-1). Key wants the release day 2023-05-31 or 2025-05-20 (not in any document). |
| A0089 | opus5 | chron-FirozPatel-0002 | charge~p1 | charge | wrong | **PARTLY** | TRUTH-LABEL ERROR | G | Answer gives the 2023 indictment (money laundering) - true and the subject of release-1; key accepts only the 2020 Payza plea. Two prosecutions exist; the rules path quotes both, the AI path kept one. |
| A0056 | opus5 | chron-FirozPatel-0002 | charge~p2 | charge | wrong | **PARTLY** | TRUTH-LABEL ERROR | G | Answer gives the 2023 indictment (money laundering) - true and the subject of release-1; key accepts only the 2020 Payza plea. Two prosecutions exist; the rules path quotes both, the AI path kept one. |
| A0012 | opus5 | chron-FirozPatel-0002 | timeline~p1 | timeline | wrong | **PARTLY** | TRUTH-LABEL ERROR | F | Key order inverted (2023 before 2020). Answer order right, but it omits the Sept. 17, 2024 obstruction plea ("Patel plead guilty on September 17, 2024") and repeats 2020 events under report dates. |
| A0005 | opus5 | chron-FirozPatel-0002 | timeline~p2 | timeline | wrong | **PARTLY** | TRUTH-LABEL ERROR | F | Key order inverted (2023 before 2020). Answer order right, but it omits the Sept. 17, 2024 obstruction plea ("Patel plead guilty on September 17, 2024") and repeats 2020 events under report dates. |
| A0026 | opus5 | chron-JeffSmith-0051 | count~p1 | count | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | release-1 and release-2 are byte-identical files (same MD5); answer says 2 distinct releases and discloses the 3rd file as an exact copy. Truth counts files. |
| A0098 | opus5 | chron-JeffSmith-0051 | count~p2 | count | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | release-1 and release-2 are byte-identical files (same MD5); answer says 2 distinct releases and discloses the 3rd file as an exact copy. Truth counts files. |
| A0007 | opus5 | chron-JoshuaStamps-0056 | timeline~p1 | timeline | wrong | **CORRECT** | SCORER ERROR | — | Order is right; answer dates the indictment Sept. 25, 2013 (the stated day) while the key wants 2008-06-02 (a co-defendant's gun purchase) or the release day 2013-09-27. |
| A0028 | opus5 | chron-JoshuaStamps-0056 | timeline~p2 | timeline | wrong | **CORRECT** | SCORER ERROR | — | Order is right; answer dates the indictment Sept. 25, 2013 (the stated day) while the key wants 2008-06-02 (a co-defendant's gun purchase) or the release day 2013-09-27. |
| A0073 | opus5 | chron-JustinKEaton-0050 | timeline~p1 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts 2015-11-23 before 2013-08-17 (release order, not event order). Answer is in true date order. Minor defect: "February 2012" state charge listed under the Nov. 23, 2015 report date (hedged "date of the report"). |
| A0055 | opus5 | chron-JustinKEaton-0050 | timeline~p2 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts 2015-11-23 before 2013-08-17 (release order, not event order). Answer is in true date order. Minor defect: "February 2012" state charge listed under the Nov. 23, 2015 report date (hedged "date of the report"). |
| — | opus5 | chron-ShaunMiller-0045 | timeline~p1 | timeline | correct | **PARTLY** | FALSE CORRECT (minor) | B | Row "August 18, 2016 - charged" uses the arrest day; the April 2016 indictment appears only under a report date. |
| — | opus5 | chron-ShaunMiller-0045 | timeline~p2 | timeline | correct | **PARTLY** | FALSE CORRECT (minor) | B | Row "August 18, 2016 - charged" uses the arrest day; the April 2016 indictment appears only under a report date. |
| A0061 | opus5 | chron-StephanByrd-0005 | charge~p1 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: convicted on three counts of bank robbery, firearm counts, felon in possession - exactly release-1. Key is a fragment about a co-defendant: "his role in the crime". |
| A0088 | opus5 | chron-StephanByrd-0005 | charge~p2 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: convicted on three counts of bank robbery, firearm counts, felon in possession - exactly release-1. Key is a fragment about a co-defendant: "his role in the crime". |
| A0084 | opus5 | chron-ZsaZsaBouvierCouch-0010 | charge~p2 | charge | wrong | **PARTLY** | AMBIGUOUS | E | Answer quotes the headline "Charged With Covid-19 Loan Fraud" - true but not the charges; same release states "charged with multiple counts of bank fraud, making false statements ..., and money laundering" (p1 got it). |
| A0052 | rules | chron-DarronDimitriRoss-0047 | sentenced~p1 | sentenced | dump | **WRONG** | TRUE WRONG | C | "Do we have a sentencing date for X?" not parsed; answer is a run-on dump of release headers incl. OTHER cases (Greensburg police chief 2025, Rhode Island heroin 2018). Correct: Oct. 24, 2022 (p2 got it). |
| — | rules | chron-JamesRobertUnderwood-0037 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer: "in 1999, Underwood was convicted in Georgia of rape" - a prior record; the case charge is failing to register as a sex offender (opus5 path got it). |
| — | rules | chron-JamesRobertUnderwood-0037 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer: "in 1999, Underwood was convicted in Georgia of rape" - a prior record; the case charge is failing to register as a sex offender (opus5 path got it). |
| A0032 | rules | chron-JayNeal-0024 | sentenced~p1 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on October 20, 2015"; release-2 (Oct. 18, 2018) says "announced today that Jay Neal ... was sentenced"; Oct. 20, 2015 is a heroin sale ("on October 20, 2015, Neal sold"). Key wrongly lists 2015-10-20. |
| — | rules | chron-JayNeal-0024 | sentenced~p2 | sentenced | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | Answer "sentenced on October 20, 2015"; release-2 (Oct. 18, 2018) says "announced today that Jay Neal ... was sentenced"; Oct. 20, 2015 is a heroin sale ("on October 20, 2015, Neal sold"). Key wrongly lists 2015-10-20. |
| A0068 | rules | chron-JayNeal-0024 | timeline~p1 | timeline | correct | **WRONG** | FALSE CORRECT | B | First step "October 20, 2015 - sentenced" (the drug-sale date) puts the sentencing 2.5 years before the April 13, 2018 plea. |
| — | rules | chron-JayNeal-0024 | timeline~p2 | timeline | correct | **WRONG** | FALSE CORRECT | B | First step "October 20, 2015 - sentenced" (the drug-sale date) puts the sentencing 2.5 years before the April 13, 2018 plea. |
| — | rules | chron-JustinKEaton-0050 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer gives the unrelated 2013 Clay County state case; the federal charge the releases are about is attempting to distribute child pornography (Dec. 16, 2014 indictment). |
| — | rules | chron-JustinKEaton-0050 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer gives the unrelated 2013 Clay County state case; the federal charge the releases are about is attempting to distribute child pornography (Dec. 16, 2014 indictment). |
| — | rules | chron-RogerEdwardPicard-0027 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer: "in 1983, Picard was convicted in Massachusetts of Rape of a Child" - a prior record; the charge is failing to register as a sex offender. |
| — | rules | chron-RogerEdwardPicard-0027 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT | A | Answer: "in 1983, Picard was convicted in Massachusetts of Rape of a Child" - a prior record; the charge is failing to register as a sex offender. |
| — | rules | chron-ShaunMiller-0045 | charged~p1 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on August 18, 2016 and again on October 20, 2017": the quote itself says "indicted in April 2016 was arrested yesterday" - Aug. 18 is the arrest, Oct. 20, 2017 the sentencing release. |
| — | rules | chron-ShaunMiller-0045 | charged~p2 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on August 18, 2016 and again on October 20, 2017": the quote itself says "indicted in April 2016 was arrested yesterday" - Aug. 18 is the arrest, Oct. 20, 2017 the sentencing release. |
| — | rules | chron-StephanByrd-0005 | charge~p1 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer quotes "Byrd entered the bank with Charles Sanders, who pleaded guilty previously to his role in the crime" - Sanders's plea, not Byrd's charges. Matched a garbage key. |
| — | rules | chron-StephanByrd-0005 | charge~p2 | charge | correct | **WRONG** | FALSE CORRECT (truth-label error) | A | Answer quotes "Byrd entered the bank with Charles Sanders, who pleaded guilty previously to his role in the crime" - Sanders's plea, not Byrd's charges. Matched a garbage key. |
| — | rules | chron-StephenDBagley-0039 | charged~p1 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on June 22, 2014 and again on July 8, 2015": June 22, 2014 is the carjacking ("stole a 2008 Nissan Altima at gunpoint on June 22, 2014"); one indictment, July 8, 2015. Splitter merged "Kansas City, Mo. Today's indictment ...". |
| — | rules | chron-StephenDBagley-0039 | charged~p2 | charged | correct | **WRONG** | FALSE CORRECT (truth-label error) | B | "charged on June 22, 2014 and again on July 8, 2015": June 22, 2014 is the carjacking ("stole a 2008 Nissan Altima at gunpoint on June 22, 2014"); one indictment, July 8, 2015. Splitter merged "Kansas City, Mo. Today's indictment ...". |
| A0083 | rules | chron-AdriaHarper-0032 | plea~p1 | plea | missed | **MISSED** | TRUE MISS | D | Refused; release-2: "Adria Harper ... was sentenced ... after pleading guilty to one count of conspiracy to traffic drugs". The charge answer quotes this very sentence. |
| A0080 | rules | chron-AdriaHarper-0032 | plea~p2 | plea | missed | **MISSED** | TRUE MISS | D | Refused; release-2: "Adria Harper ... was sentenced ... after pleading guilty to one count of conspiracy to traffic drugs". The charge answer quotes this very sentence. |
| — | rules | chron-DarronDimitriRoss-0047 | charged~p1 | charged | correct | **CORRECT** | DEFECT (minor) | — | July 23, 2019 superseding indictment is right, but "it gives no other day" is untrue: release-1 names the Dec. 20, 2018 original indictment. |
| — | rules | chron-DarronDimitriRoss-0047 | charged~p2 | charged | correct | **CORRECT** | DEFECT (minor) | — | July 23, 2019 superseding indictment is right, but "it gives no other day" is untrue: release-1 names the Dec. 20, 2018 original indictment. |
| A0002 | rules | chron-DonnaOsowittSteele-0019 | charge~p1 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer "Steele pleaded guilty to wire fraud" names the charge; release-1: "pleaded guilty to wire fraud". Scorer demanded a longer phrase. |
| A0084 | rules | chron-DonnaOsowittSteele-0019 | charge~p2 | charge | wrong | **CORRECT** | SCORER ERROR | — | Answer "Steele pleaded guilty to wire fraud" names the charge; release-1: "pleaded guilty to wire fraud". Scorer demanded a longer phrase. |
| A0050 | rules | chron-DouglasRoseth-0022 | charge~p1 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: plea to production of child pornography (release-1/2 say exactly this). Truth label is a quote fragment: "a sexual predator,” said U". |
| A0054 | rules | chron-DouglasRoseth-0022 | charge~p2 | charge | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Answer: plea to production of child pornography (release-1/2 say exactly this). Truth label is a quote fragment: "a sexual predator,” said U". |
| — | rules | chron-FirozPatel-0002 | charged~p1 | charged | correct | **PARTLY** | DEFECT | B | "charged on May 17, 2023 and again on May 31, 2023" - May 31 is the detention hearing after the same indictment, not a second charge. |
| — | rules | chron-FirozPatel-0002 | charged~p2 | charged | correct | **PARTLY** | DEFECT | B | "charged on May 17, 2023 and again on May 31, 2023" - May 31 is the detention hearing after the same indictment, not a second charge. |
| A0106 | rules | chron-FirozPatel-0002 | sentence~p1 | sentence | correct | **PARTLY** | DEFECT | F | Lists the 2020 36-month sentence twice, the second time as "another proceeding (February 6, 2025)". |
| — | rules | chron-FirozPatel-0002 | sentence~p2 | sentence | correct | **PARTLY** | DEFECT | F | Lists the 2020 36-month sentence twice, the second time as "another proceeding (February 6, 2025)". |
| A0057 | rules | chron-FirozPatel-0002 | timeline~p1 | timeline | wrong | **PARTLY** | TRUTH-LABEL ERROR | F | Key order inverted (2023 before 2020). Answer order right, but it omits the Sept. 17, 2024 obstruction plea ("Patel plead guilty on September 17, 2024") and repeats 2020 events under report dates. |
| A0115 | rules | chron-FirozPatel-0002 | timeline~p2 | timeline | wrong | **PARTLY** | TRUTH-LABEL ERROR | F | Key order inverted (2023 before 2020). Answer order right, but it omits the Sept. 17, 2024 obstruction plea ("Patel plead guilty on September 17, 2024") and repeats 2020 events under report dates. |
| A0034 | rules | chron-JeffSmith-0051 | count~p1 | count | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | release-1 and release-2 are byte-identical files (same MD5); answer says 2 distinct releases and discloses the 3rd file as an exact copy. Truth counts files. |
| A0082 | rules | chron-JeffSmith-0051 | count~p2 | count | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | release-1 and release-2 are byte-identical files (same MD5); answer says 2 distinct releases and discloses the 3rd file as an exact copy. Truth counts files. |
| A0113 | rules | chron-JoshuaStamps-0056 | timeline~p1 | timeline | wrong | **CORRECT** | SCORER ERROR | — | Order is right; answer dates the indictment Sept. 25, 2013 (the stated day) while the key wants 2008-06-02 (a co-defendant's gun purchase) or the release day 2013-09-27. |
| A0087 | rules | chron-JoshuaStamps-0056 | timeline~p2 | timeline | wrong | **CORRECT** | SCORER ERROR | — | Order is right; answer dates the indictment Sept. 25, 2013 (the stated day) while the key wants 2008-06-02 (a co-defendant's gun purchase) or the release day 2013-09-27. |
| A0028 | rules | chron-JustinKEaton-0050 | timeline~p1 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts 2015-11-23 before 2013-08-17 (release order, not event order). Answer is in true date order. Minor defect: "February 2012" state charge listed under the Nov. 23, 2015 report date (hedged "date of the report"). |
| A0016 | rules | chron-JustinKEaton-0050 | timeline~p2 | timeline | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | Key order puts 2015-11-23 before 2013-08-17 (release order, not event order). Answer is in true date order. Minor defect: "February 2012" state charge listed under the Nov. 23, 2015 report date (hedged "date of the report"). |
| — | rules | chron-ShaunMiller-0045 | timeline~p1 | timeline | correct | **PARTLY** | FALSE CORRECT (minor) | B | Row "August 18, 2016 - charged" uses the arrest day; the April 2016 indictment appears only under a report date. |
| — | rules | chron-ShaunMiller-0045 | timeline~p2 | timeline | correct | **PARTLY** | FALSE CORRECT (minor) | B | Row "August 18, 2016 - charged" uses the arrest day; the April 2016 indictment appears only under a report date. |
| A0011 | rules | chron-ZsaZsaBouvierCouch-0010 | charge~p2 | charge | wrong | **PARTLY** | AMBIGUOUS | E | Answer quotes the headline "Charged With Covid-19 Loan Fraud" - true but not the charges; same release states "charged with multiple counts of bank fraud, making false statements ..., and money laundering" (p1 got it). |

## Random spot check of scorer-"correct" items (20 per path)

**rules**: 18 correct, 1 partly, 1 false correct. A0007 JeffSmith plea~p1 → CORRECT; A0012 DianeJohnson timeline~p2 → CORRECT; A0020 TariqArrhamannMajid office~p2 → CORRECT; A0025 MichaelMiller charge~p1 → CORRECT; A0029 CoreyCrosby timeline~p1 → CORRECT; A0030 AlbertReda plea~p2 → CORRECT; A0031 SethJBlewitt timeline~p2 → CORRECT; A0064 BenjaminJamalWashington plea~p1 → CORRECT; A0068 JayNeal timeline~p1 → WRONG; A0070 JulioPabloChan count~p2 → CORRECT; A0071 MichaelMiller charge~p2 → CORRECT; A0081 ZsaZsaBouvierCouch timeline~p2 → CORRECT; A0092 JayNeal plea~p2 → CORRECT; A0098 JoshuaStamps count~p2 → CORRECT; A0099 JoshuaStamps plea~p2 → CORRECT; A0103 NomanSaleem sentenced~p1 → CORRECT; A0106 FirozPatel sentence~p1 → PARTLY; A0108 OmarBarrientos charge~p1 → CORRECT; A0110 DouglasRoseth office~p2 → CORRECT; A0111 OwenMay office~p1 → CORRECT

**opus5**: 20 correct, 0 partly, 0 false correct. A0001 SethJBlewitt sentenced~p2 → CORRECT; A0003 JoshuaStamps count~p1 → CORRECT; A0010 ShawnDenning office~p2 → CORRECT; A0011 JamieLynMusic timeline~p2 → CORRECT; A0013 NomanSaleem count~p1 → CORRECT; A0015 ErickPizarro plea~p1 → CORRECT; A0017 FirozPatel office~p1 → CORRECT; A0033 TrevorJRobinson count~p1 → CORRECT; A0057 DianeJohnson office~p2 → CORRECT; A0065 ZeviChaimMehlman timeline~p1 → CORRECT; A0078 SethJBlewitt office~p2 → CORRECT; A0080 TravisDevonWoods sentenced~p1 → CORRECT; A0093 OmarBarrientos plea~p2 → CORRECT; A0096 StevenLemieux plea~p2 → CORRECT; A0101 StephenDBagley charge~p2 → CORRECT; A0104 JoshuaStamps count~p2 → CORRECT; A0108 TimothyRyanWolfe plea~p1 → CORRECT; A0114 AshleyNicoleHaydt sentence~p1 → CORRECT; A0118 DarronDimitriRoss charged~p2 → CORRECT; A0120 JamesRobertUnderwood plea~p1 → CORRECT

## Adjudicated totals

### rules

n = 914. Adjudicated: correct 766, honest refusal 120, partly 9, missed 2, **wrong 17 = 1.86 %**. Right (correct + honest refusal) 96.9 %. Strict wrong (wrong + partly) 26 = 2.84 %.

| family | n | correct | honest refusal | partly | missed | wrong | wrong % |
|---|---|---|---|---|---|---|---|
| sentenced | 120 | 117 | 0 | 0 | 0 | 3 | 2.5 % |
| timeline | 120 | 114 | 0 | 4 | 0 | 2 | 1.7 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % |
| office | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0.0 % |
| plea | 110 | 108 | 0 | 0 | 2 | 0 | 0.0 % |
| charge | 108 | 99 | 0 | 1 | 0 | 8 | 7.4 % |
| sentence | 74 | 72 | 0 | 2 | 0 | 0 | 0.0 % |
| charged | 22 | 16 | 0 | 2 | 0 | 4 | 18.2 % |

### opus5

n = 914. Adjudicated: correct 779, honest refusal 120, partly 7, missed 2, **wrong 6 = 0.66 %**. Right (correct + honest refusal) 98.4 %. Strict wrong (wrong + partly) 13 = 1.42 %.

| family | n | correct | honest refusal | partly | missed | wrong | wrong % |
|---|---|---|---|---|---|---|---|
| sentenced | 120 | 118 | 0 | 0 | 0 | 2 | 1.7 % |
| timeline | 120 | 114 | 0 | 4 | 0 | 2 | 1.7 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % |
| office | 120 | 120 | 0 | 0 | 0 | 0 | 0.0 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0.0 % |
| plea | 110 | 108 | 0 | 0 | 2 | 0 | 0.0 % |
| charge | 108 | 105 | 0 | 3 | 0 | 0 | 0.0 % |
| sentence | 74 | 74 | 0 | 0 | 0 | 0 | 0.0 % |
| charged | 22 | 20 | 0 | 0 | 0 | 2 | 9.1 % |

## What went wrong with the automatic score

The two errors run in opposite directions, so the automatic score was off by a different amount for each path.

- **Scorer flags that were not real wrongs.** On rules, 12 of the 16 flagged items are acceptable answers: 4 are scorer errors and 8 are truth-label errors. On opus5 it is 16 of 22: 4 scorer errors and 12 truth-label errors. The causes:
  - Keys that are quote fragments rather than charges: Roseth "a sexual predator,” said U", Byrd "his role in the crime".
  - Timeline keys built in *release* order rather than event order: Patel, Eaton.
  - Release-day dates demanded where the documents state the actual day: Stamps 2013-09-25, Patel 2023-05-17.
  - A duplicate file counted as a separate release: Jeff Smith.
  - A date found in no document: Patel 2025-05-20.
- **"Correct" scores that were really wrong.** Some answers matched bad keys, or keys too loose to catch them. This added 16 wrongs on rules and 5 on opus5. The keys involved:
  - Jay Neal 2015-10-20 is a drug sale.
  - Bagley 2014-06-22 is the carjacking.
  - Shaun Miller 2016-08-18 is the arrest.
  - Byrd's key is a fragment about a co-defendant.
  - For Underwood, Picard and Eaton, the key also accepts the prior or unrelated case.
- **Bench generator fix (not an app fix):** `scripts/casebench/chronology.py`.
  - `stated_days` takes any date within 80 characters of the verb, which lets in offence, arrest and sale dates.
  - `offence_sentences` lets in quote fragments and co-defendant clauses.
  - Timeline `order_any` follows release order.
  - The key can contain a date that is in no document.
  - Byte-identical files are counted as separate releases.

  Re-label ho14 before any further number is quoted from it.

## Root causes of the TRUE WRONG items

| cat | root cause | rules | opus5 | example | fixable? | likely code area |
|---|---|---|---|---|---|---|
| A | **Charge read from the wrong sentence**: a prior conviction ("in 1999, Underwood was convicted in Georgia of rape"; "in 1983, Picard was convicted …"), an unrelated earlier state case (Eaton, Clay County 2013), or a co-defendant's clause ("with Charles Sanders, who pleaded guilty previously to his role in the crime") | 8 | 0 | Underwood charge~p1 | **FIXABLE**: the AI path already gets all four right, and the defect is a rule gap | `Kalsmritikosh/Brain/ProceedingAnswerer.swift` `.chargedWith` (lines ~408–530). `oldConviction` only matches "convicted in YEAR", not a leading "In 1999, X was convicted …". `otherSubject` treats "who" as a stop word, so ", who pleaded guilty" (a relative clause about another named person) is counted as the defendant's. There is no penalty for "in the … County case" / "state court" / a sentence year ≥ 2 years before the release. The two-prosecution rule (`offenceSet` disjoint) misses Eaton because both cases share "child pornography". |
| B | **Event date taken from the wrong event in the same text.** (1) "announced today that Jay Neal … was sentenced" ran on into "stated that on October 20, 2015, Neal sold …"; `stepDay` takes the explicit "on <date>" because "today" is not *attached* to the verb. (2) "…Kansas City, Mo. Today's indictment alleges that Bagley stole … on June 22, 2014" was split as one sentence ("Mo." read as an abbreviation), so the offence day became the charge day. (3) "indicted in April 2016 was arrested yesterday": a month-only date cannot be represented, so the charge took the arrest's "yesterday". | 8 | 5 | Jay Neal sentenced~p1: "sentenced on October 20, 2015" (really Oct. 18, 2018) | **FIXABLE** | `Kalsmritikosh/Knowledge/Events/ProceedingEventExtractor.swift`: `stepDay` (l.356): a "today"/"yesterday" that governs the clause ("announced today that …") should win over a date inside a later attribution or conduct clause ("stated that on …", "alleges that … stole … on"); `sentences(of:)`/`rawSentences` (l.416–486): do not merge across "<State abbrev>. <Capital>"; add month-precision days ("in April 2016") so another verb's day is not borrowed. Plus a cross-step check in `ProceedingAnswerer`: a sentencing day before that case's plea or conviction day (Jay Neal 2015 < 2018 plea) is impossible, so refuse it or fall back to the release day. |
| C | **Paraphrase not parsed, so a passage dump containing other cases' text.** "Do we have a sentencing date for X?" — `unwrap` strips "do we have", leaving "a sentencing date for X", but the when-pattern allows only "(the )?(word )?date for"; the article "a" breaks it. The generic fallback then concatenated release headers, including other cases (Greensburg 2025, Rhode Island 2018). The AI was not called (`aiCalls` {}). | 1 | 1 | Ross sentenced~p1 | **FIXABLE** | `ProceedingAnswerer.parse` (l.123): accept `^(?:a|an|the)\s+(?:\w+\s+)?(?:date|day)\s+(?:of|for)…`. Also the fallback dump: `Kalsmritikosh/Brain/DeterministicEvidenceFallback.swift`. A fallback that names a person must stay in that person's documents and must never emit concatenated headers (this was also a scope breach). |

No TRUE WRONG is a limit of current technology. All three causes are rule gaps in deterministic code. The AI path's own record (0 category-A errors) shows A is solvable, and B and C are parsing defects with exact sentences to reproduce them.

### Missed and partly-correct items (not counted as wrong)

| cat | cause | rules | opus5 | fixable? | area |
|---|---|---|---|---|---|
| D | **MISSED (wrong refusal)**: plea stated as a participle ("was sentenced … after pleading guilty to …"); the `.pleaded` step pattern lacks "pleading guilty" | 2 | 2 | FIXABLE | `ProceedingEventExtractor.swift` l.57 `Step.pleaded.pattern`; the charge reader already quotes this sentence |
| E | Headline chosen as the charge ("Charged With Covid-19 Loan Fraud") for one paraphrase ("actually charged with") | 1 | 1 | FIXABLE | `.chargedWith` scoring: a headline (`headline(of:)`) should lose to a body sentence that states the counts |
| F | Timeline/sentence completeness: Patel's Sept. 17, 2024 plea ("Patel plead guilty", typo) missed; the 2020 sentence repeated as "another proceeding" | 4 | 2 | FIXABLE | step pattern (accept "plead guilty" past-tense typo); `.sentenceImposed` de-duplication of the same sentence restated in a later release |
| B′ | Minor misdated row/second date (Shaun Miller timeline "Aug 18 — charged"; Patel "again on May 31") | 4 | 2 | FIXABLE (same as B) | as B |
| G | AI kept one of two prosecutions (Patel charge) where the rules path quoted both | 0 | 2 | FIXABLE | `Kalsmritikosh/Brain/VerifiedRecordExtractor.swift` `verify`: when the deterministic reader finds two disjoint prosecutions, keep both |

## Top 3 fixes most likely to bring both paths under 1 %

1. **Date attribution in `ProceedingEventExtractor.stepDay` and the sentence splitter, plus a step-order sanity check (category B).** This removes 8 rules / 5 opus5 wrongs, and it is the *only* remaining wrong class on opus5 apart from the single dump. Specifically: a clause-governing "today"/"yesterday" beats a date inside an attribution or conduct clause; no merging at "Mo. Today's"; month-precision dates; sentencing must not precede plea or conviction.
2. **Charge selection in `ProceedingAnswerer` `.chargedWith` (category A).** This removes 8 rules wrongs. Specifically: penalise "In <year>, X was convicted …" ≥ 2 years before the release; penalise a relative-clause subject (", who pleaded guilty") naming another person; penalise "in the <X> County case" / "state court"; treat the subject release's charge as primary.
3. **Parser article fix plus a scoped, non-dump fallback (category C), together with the `pleading guilty` step pattern (D).** This removes the dump on both paths and the 2 misses on each.

Expected after 1–3, if they generalise beyond these items: rules 17 → ~0–1 wrong, opus5 6 → ~0. Both paths would then also be under 1 % on the strict measure, once E/F/G (≤ 9 items) are addressed. Validate on a NEW fresh set (ho15), not on ho14, which has now been read.

## Result

- rules: adjudicated wrong 17 / 914 = **1.86 %** (strict, incl. partly: 26 = 2.84 %); missed 2. The automatic 1.4 % *understated* the error. Most of the gap is false corrects that matched bad keys.
- opus5: adjudicated wrong 6 / 914 = **0.66 %** (strict: 13 = 1.42 %); missed 2. The automatic 2.1 % *overstated* the error (12 truth-label + 4 scorer errors).

The bar is not raised. No root cause is a limit of current technology.

**rules — Meets ≤1% wrong: NO** (1.86 %)

**opus5 — Meets ≤1% wrong: YES** (0.66 % primary measure; NO on the strict measure at 1.42 %. This holds only within the coverage limits stated in Method step 4.)
