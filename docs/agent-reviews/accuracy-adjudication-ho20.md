# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

This adjudicates the fresh held-out set **ho20-chron** on both answer paths, for the release candidate f766b035. An AI agent did the work as an independent adjudicator, on the owner's written direction of 2026-11-01. It is not a human sign-off. Two helper agents did the full scans of the timeline, sentenced, plea, sentence, office and count answers and drew the random sample (Method steps 4–5). Every finding they reported was spot-checked against the documents before it was used.

| | |
|---|---|
| Set | ho20-chron. FRESH: seed 20261107, 60 public DOJ prosecution cases, 936 questions (including paraphrases), skip-chron x1–x21, so 0 overlap with the 1,440 cases of earlier sets. Generated 2026-11-02 before any run. |
| App commit | f766b035, the RELEASE CANDIDATE (includes the ho19 fixes C, K, N and O′). Unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1. |
| Runs | opus5 2026-11-02T05:19:44Z–05:52:36Z: Claude Opus 5 hybrid; 576 of 936 answers record a Claude call, all in the sentenced, absent, plea, charge, sentence and charged families. Timeline, office and count questions never call Claude. rules 05:52:36Z–05:54:50Z, 0 Claude calls. |
| Scorer sha256 (in MEASUREMENT-*.txt) | 060e98b9…, the same value as ho14–ho19. It still matches none of today's files (ccsscore.py b5d79621…, score.py 04a26faa…, common.py 7e055679…). Pin it before the result is frozen. |
| Automatic score | rules: right 97.9 %, wrong 1.7 % (16 wrong, 4 missed, 120 honest refusals; 7 of the wrongs are timelines). opus5: right 98.1 %, wrong 1.5 % (14 wrong, 4 missed, 120 honest refusals). Re-running the scorer's `classify` over the result files (`flat.py`) gives the same counts. |
| Release bars | ≤ 1 % wrong per path (bar until 2026-11-02). **≤ 3 % wrong per path (owner decision 2026-11-02, to be declared publicly).** Both bars are reported. |

## Method

The method and judgement rules are the same as in ho14–ho19 (`accuracy-adjudication-ho14.md` … `-ho19.md`).

**Work files.** They are in `~/CaseBench/adjudication/ho20-work`:
- `flat.py`, `fam.py`, `g.py`, `show.py`, `hx.py`, and `verdict20.py`, which holds every verdict and produces the tables below.
- The helper scans `scan-*.txt` and `scan2-*`.
- The harness `/tmp/ho20h`. It compiles the unmodified `ProceedingAnswerer.swift` of f766b035, plus `ProceedingEventExtractor.swift` and `IssuingOfficeGate.swift` with only their unused ledger/announcer functions removed, against small stubs. The build needs `-enable-bare-slash-regex`. The binary is `h`.

The harness reproduced every root cause below on the release texts and the question wordings.

1. **Blind first.** I read all 38 scorer-flagged items (20 rules, 18 opus5) with their questions and answers. I judged them against the case documents before reading the keys' expected values. After that, the keys were used only to map items to cases and to name key defects.
2. **Documents.** All 137 case documents were extracted: PDFKit for the 74 PDFs, `textutil` for docx, html and rtf, and plain text as it is (11 .txt). Four scanned pages were read with Apple Vision OCR (Aiello, Bennett). Durante's two 2013-05-22 releases are byte-identical (MD5 227d142d…).
3. **Verdicts.** The verdicts are TRUE WRONG, SCORER ERROR, TRUTH-LABEL ERROR, PARTLY, AMBIGUOUS, MISSED and FALSE CORRECT. The judgement rules are unchanged:
   - **PARTLY** means the main claim is true but incomplete. It also covers a secondary element or row that is misdated or mislabelled, and a row or second value that belongs to another case or person. PARTLY is not counted in the primary measure. It is counted in the strict measure.
   - **"Charged with" naming no offence is WRONG.** An offence named only vaguely, by reference back ("the federal charge") or by its conduct is PARTLY.
   - **Another (prior, separate or co-defendant's) case's or person's step given as this person's is WRONG.** The same step given as a second value, or as an extra row next to the right one, is PARTLY.
   - **A timeline is WRONG** when its rows put the case in an impossible order. A misdated, mislabelled, extra or missing row with the order still possible is PARTLY.
   - **A non-answer** (a question answered with a sentence that does not answer it) is WRONG.
   - **Office.** The investigating or issuing component alone is a minor CORRECT when the documents name no prosecuting district, and WRONG when they do. A right office plus a spurious second office is PARTLY.
   - **"It gives no other day."** This is a minor CORRECT where the release's own "today" is the only day, or only a month is given. It is PARTLY where the release states another day for the step ("yesterday", "on Thursday", "on July 21").
   - **Minor defects recorded CORRECT:** rows hedged "(date of the report)" that are otherwise true; "who was convicted of …, was sentenced" rows dated on the sentencing day; hedged prior-case rows.
   - **MISSED** (a wrong refusal) is reported separately (ho14/ho16 convention), with a strict + missed column.
4. **Search for false "correct" verdicts.** This was a full check, not a sample: every answer on both paths in *charge* (212), *charged* (72), *sentenced* (240), *sentence* (168), *plea* (220) and *timeline* (240).
   - Each stated day was checked against the release date and against the "today / yesterday / weekday / on <date>" of its source sentence.
   - Each timeline row was checked for date, label, order, completeness and whose event it is.
   - Every *count* answer (240) was checked against the number of distinct releases, and every *office* answer (240) against the releases.
5. **The rest.** I drew a seeded random sample of 40 from the *count*, *office* and *absent* items scored correct or honest refusal: 20 rules items (seed 20261107) and 20 opus5 items (seed 20261108, because 20261107 overlapped the rules draw).
6. **Counting.** Wrong % counts dumps and unsupported answers as wrong when they are wrong; there were none. There were no AMBIGUOUS items; the borderline calls are listed under Sensitivity.

## Per-item table

Item IDs are the blinded-sheet IDs. "—" means the item is not on the sheet and was found by the full scan. Every item not listed is CORRECT or HONEST REFUSAL, as the scorer said. Quotes carry the printed date of their release. For the causes, see Root causes.

| item | path | case | question | scorer | adjudicated | judgement | cause | reason |
|---|---|---|---|---|---|---|---|---|
| A0081, A0053 | rules | chron-AbelLomasMurillo-0033 | timeline~p1, ~p2 | wrong | **WRONG** | TRUE WRONG | P | Rows "September 28, 2021 — pleaded guilty: “Noel Lomas Murillo, 33, pleaded guilty …”" and "April 27, 2022 — sentenced: “Noel Lomas Murillo, 34, was sentenced to 60 months …”" (a co-defendant who shares the asked man's two surnames) follow Abel's own "April 15, 2019 — pleaded guilty" and "September 10, 2019 — sentenced". This is an impossible order for one case (a plea after the sentencing). |
| A0080, A0052 | opus5 | chron-AbelLomasMurillo-0033 | timeline~p1, ~p2 | wrong | **WRONG** | TRUE WRONG | P | The same rules answer (timelines never call Claude). |
| — | rules | chron-WilliamJMabie-0021 | sentenced~p1, ~p2 | correct | **WRONG** | FALSE CORRECT | B | "William J. Mabie was sentenced on December 11, 2014 and again on April 6, 2015 (the day it was reported)". The source: "… William J. Mabie, 56, of Festus, Missouri, was sentenced Friday, April 3, 2015, in federal district court in East St. Louis, following his conviction on December 11, 2014, …" (Apr. 6, 2015). Dec. 11, 2014 is the conviction date. The sentencing day, April 3, is not given. The key accepts 2014-12-11 (key defect). opus5 is right ("sentenced on April 3, 2015", a verified Claude extraction). |
| — | rules | chron-JoshuaStevenHicks-0047 | sentence~p1, ~p2 | correct | **WRONG** | FALSE CORRECT | A | "Joshua Steven Hicks was sentenced to one year in prison for violating the terms of his supervised release", from "On September 12, 2024, Hicks was sentenced to one year in prison for violating the terms of his supervised release" (background in both releases: the revocation in his earlier case). This case's sentence is missing: "Joshua Steven Hicks, 43, of Charleston, was sentenced today to three years and one month in prison …" (Jan. 20, 2026). The key accepts "1 year". opus5 is right. |
| A0028 | rules | chron-MichaelScottBurton-0037 | charged~p2 | wrong | **WRONG** | TRUE WRONG (non-answer) | C | "I need to confirm — on what date were charges filed against Michael Scott Burton?" is parsed as `.chargedWith` (harness). The answer is the sentencing sentence "…was sentenced to 96 months in federal prison yesterday after he pleaded guilty to charges of …" (Aug. 2, 2019), with no charge date. p1 dates it. |
| A0028 | opus5 | chron-MichaelScottBurton-0037 | charged~p2 | wrong | **PARTLY** | DEFECT | C | The same misparse. The cloud extraction, verified as a *charge* quote, gives "…were arraigned on Tuesday, June 26, after a federal grand jury returned an indictment charging them with conspira…" (June 28, 2018). It states no charge date, but the quote carries the only day the documents give (sensitivity: WRONG). |
| A0058, A0118 | rules | chron-SurajPatel-0006 | plea~p1, ~p2 | missed | **MISSED** | TRUE MISS | R | "don't say whether Suraj Patel pleaded guilty". False: "Patel was sentenced to serve one day in prison … He pleaded guilty in September 2016 to mail fraud and money laundering." (Nov. 20, 2017). |
| A0057, A0116 | opus5 | chron-SurajPatel-0006 | plea~p1, ~p2 | missed | **MISSED** | TRUE MISS | R | As rules. A Claude call was made; nothing verified, so the rules refusal shipped. |
| A0055, A0084 | rules | chron-GyadeenPRamdihall-0031 | charge~p1, ~p2 | missed | **MISSED** | TRUE MISS | W/S | "don't state what … was charged with". False: "Jervis A. Hillaire, 25, … and Gyadeen P. Ramdihall, 27, of Rosedale, New York, pleaded guilty in U.S. District Court to conspiracy to commit access device fraud." (Jan. 29, 2015) and "…Gyadeen P. Ramdihall, 28, of Bronx, New York, was sentenced today … for conspiracy to commit access device fraud." (July 15, 2015). |
| A0054, A0083 | opus5 | chron-GyadeenPRamdihall-0031 | charge~p1, ~p2 | missed | **MISSED** | TRUE MISS | W/S | As rules. A Claude call was made; nothing verified. |
| A0011, A0002 | both | chron-PethrodDunnigan-0011 | timeline~p1, ~p2 | wrong | **PARTLY** | DEFECT | L | The rows (Dec. 11, 2015 complaint and arrest, Feb. 9, 2018 plea, June 7, 2018 sentencing) are right and in order. The indictment "a federal grand jury has returned and indictment charging Jose Manuel Lua-Guizar, 25, Max Riestra, 40, both of Mexico, and Pethrod Dunnigan, 37, …" (Jan. 14, 2016) and the superseding indictment (Mar. 25, 2016) are missing: the name stands more than 60 characters after the verb, inside a defendant list. |
| A0088, A0070 / A0087, A0069 | both | chron-JoshuaStevenHicks-0047 | timeline~p1, ~p2 | wrong | **PARTLY** | DEFECT (key order wrong too) | A | Rows: "September 12, 2024 — sentenced" (the supervised-release revocation in his earlier case, unlabelled), "September 15, 2025 — pleaded guilty", "January 20, 2026 — sentenced". The extra row is another proceeding's; the case's own rows are right. The key `order_any` puts 2024-09-12 after the 2025 plea, which is impossible (key defect). Sensitivity: WRONG. |
| A0120 / A0118 | both | chron-DerekRand-0049 | timeline~p1 | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | "August 29, 2019 — pleaded guilty" is right: "pleaded guilty in federal court on Thursday" (Fri. Aug. 30, 2019 → Aug. 29) and "Rand previously pleaded guilty on August 29, 2019." (Dec. 16, 2019). The key wants the release day 2019-08-30. |
| A0085, A0051 / A0084, A0050 | both | chron-MichaelDurante-0020 | count~p1, ~p2 | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | "2 of the documents found name Michael Durante … 1 further file is an exact copy of one of these and is counted once." release-1 and release-2 are byte-identical (MD5 227d142d…), so there are 2 distinct releases. The key says 3. |
| A0083, A0116 / A0082, A0114 | both | chron-ZacharyAdamChesser-0041 | office~p1, ~p2 | wrong | **CORRECT** | SCORER ERROR | — | "National Security Division and the U.S. Attorney's Office for the Eastern District of Virginia". Both prosecute: "Assistant U.S. Attorneys … of the U.S. Attorney’s Office for the Eastern District of Virginia and Trial Attorney John T. Gibbs of the Counterterrorism Section in the National Security Division are prosecuting the case." (Oct. 20, 2010). The key lists NSD only. |
| A0016, A0034 | rules | chron-JasonRayGrubb-0040 | charge~p1, ~p2 | wrong | **CORRECT** | SCORER ERROR | — | "entered his guilty plea in federal court to failing to pay employment taxes" (Feb. 3, 2016) names the offence. The key wants "a federal tax crime …" / "collect, account for, and pay". |
| A0025, A0094 | rules | chron-StaffredKaiBegay-0059 | charge~p1, ~p2 | wrong | **CORRECT** | SCORER ERROR | — | "Begay was arrested on Aug. 12, 2014, on a criminal complaint charging him with child abuse." (Dec. 15, 2014): the complaint's offence. The key wants the plea wording. |
| A0016, A0034 | opus5 | chron-JamesStrahlerII-0038 | charge~p1, ~p2 | wrong | **CORRECT** | SCORER ERROR | — | "Specifically, Strahler pleaded guilty today to cyberstalking, producing obscene visual representations of child sexual abuse and publication of digital forgeries." (Apr. 7, 2026), the counts verbatim. The key wants the lead's "cybercrimes that included …". |
| — | rules | chron-AbelLomasMurillo-0033 | sentenced~p1, ~p2 | correct | **PARTLY** | DEFECT | P | "sentenced on September 10, 2019 and again on April 27, 2022": the second date is Noel Lomas Murillo's ("Noel Lomas Murillo, 34, was sentenced to 60 months"). |
| — | opus5 | chron-AbelLomasMurillo-0033 | sentenced~p1 | correct | **PARTLY** | DEFECT | P | The same rules answer. The Claude call made for this paraphrase did not verify, so the rules answer stood. p2 (verified extraction) is right. |
| — | rules | chron-AbelLomasMurillo-0033 | sentence~p1, ~p2 | correct | **PARTLY** | DEFECT | P | "235 months … and, in another proceeding, to 60 months in federal prison and three years’ supervised release (April 27, 2022)": Noel's term. opus5 is right (235 months only). |
| — | rules | chron-JoshuaStevenHicks-0047 | sentenced~p1, ~p2 | correct | **PARTLY** | DEFECT | A | "sentenced on September 12, 2024 and again on January 20, 2026": the first is the revocation in his earlier case, not labelled as another proceeding. opus5 is right (Jan. 20, 2026). |
| — | both | chron-WilliamJMabie-0021 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B | Row "December 11, 2014 — sentenced" (the conviction day, as above) beside the right "December 11, 2014 — convicted" and a hedged "April 6, 2015 (date of the report) — sentenced". Misdated row, order possible (sensitivity: WRONG). |
| — | both | chron-KevensLouis-0057 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | Row "June 27, 2019 (date of the report) — charged" from "Louis and his co-conspirators … were charged with conspiracy to commit wire fraud on April 9, 2019." The stated day is ignored, so the charge sorts after the plea. |
| — | both | chron-MichaelScottBurton-0037 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | Row "August 1, 2019 … — pleaded guilty" from "was sentenced to 96 months … yesterday after he pleaded guilty to charges of …" (Aug. 2, 2019): the sentencing's "yesterday" is given to the earlier plea. There is also a row labelled "sentenced" on a quote that reports no step. |
| — | both | chron-MelvinSmith-0000 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | Row "January 11, 2017 — pleaded guilty" from "Smith pled guilty in November 2016 to three counts of robbery and was sentenced today …" (Jan. 11, 2017). The right Nov. 1, 2016 plea row is also listed. |
| — | both | chron-JustinKrantz-0001 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | H | Row "May 4, 2016 — charged" from "Krantz arrested in Nov. 2016, on an indictment charging him with being a felon in possession of a firearm and ammunition on May 4, 2016, in San Juan County" (Apr. 11, 2017): the offence date. |
| — | both | chron-LewisJohnson-0010 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | Unhedged plea rows "December 30, 2015" and "January 4, 2016" from "announced today, that Lewis Johnson … pled guilty in federal court" (Dec. 30, 2015, and a reissue). The later release says "Johnson pled guilty on December 29, 2015." (also listed). |
| — | both | chron-GebahKamara-0007 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | L | The indictment is missing: "The indictment charges Ahmed Kamara, 38, and Ibrahim Kamara, 48, … Gebah Kamara, 46, of Sharon Hill, PA, and Dauda Koroma …" (June 12, 2014). Two namesakes stand before the verb and Gebah is more than 60 characters after it. |
| — | both | chron-GebahKamara-0007 | charged~p1, ~p2 | correct | **PARTLY** | DEFECT | L | "The documents don't say when Gebah Kamara was charged; they report … arrested on June 12, 2014" is untrue, because the indictment unsealed "today" (June 12, 2014) names him. The day given is the same, so the answer is not WRONG. |
| — | both | chron-SurajPatel-0006 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | R | The September 2016 plea ("He pleaded guilty in September 2016 …") is missing (cause R). |
| — | both | chron-CarlinJerridMontgomery-0042 | timeline~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | "July 6, 2018 (date of the report) — pleaded guilty" while the release says "an Abbeville man pleaded guilty Monday" (Fri. July 6, 2018 → July 2). |
| — | both | chron-HovikDagesian-0022 | charged~p1, ~p2 | correct | **PARTLY** | DEFECT | B′ | "dated January 29, 2021 … it gives no other day". Untrue: "According to an affidavit filed with the complaint on Thursday" (Fri. Jan. 29, 2021 → Jan. 28). |
| — | opus5 | chron-MichaelScottBurton-0037 | charged~p1 | correct | **PARTLY** | DEFECT | B′ | "Michael Scott Burton was charged on June 26, 2018", from "…were arraigned on Tuesday, June 26, after a federal grand jury returned an indictment …". June 26 is the arraignment day; the indictment's day is not stated. The key accepts. |
| — | rules | chron-JamesStrahlerII-0038 | charge~p1, ~p2 | correct | **PARTLY** | DEFECT | G′ | "two prosecutions, or two people of that name": the lead's "cybercrimes that included …" and "Strahler pleaded guilty in April to cyberstalking, …" are one plea. |
| — | both | chron-FreddieLewis-0055 | charge~p1, ~p2 | correct | **PARTLY** | DEFECT | E/S | "Lewis previously pleaded guilty to the federal charge on April 16, 2019." (July 24, 2019) names the charge only by reference back. The offence is stated as "pleaded guilty before U.S. District Judge Dee D. Drell for possession of a firearm by a convicted felon" (Apr. 16, 2019) and "sentenced … for possession of a firearm by a convicted felon", both "… for <offence>" forms the charge reader does not accept. |
| — | opus5 | chron-AndrewCClayton-0029 | charge~p2 | correct | **PARTLY** | DEFECT | E′ | The cloud quote gives only the supplementary count, "Clayton is also charged with enticing a minor …". The main counts (production of child pornography) are left out; the rules and opus5 p1 quote both. |
| — | both | chron-JeraldKicinski-0027 | office~p1, ~p2 | correct | **PARTLY** | DEFECT | O′ | "Western District of New York; the Justice Department's Criminal Division". The second office comes from the Project Safe Childhood boilerplate "Led by United States Attorneys' Offices and the Criminal Division's Child Exploitation and Obscenity Section" (2013-05-22; the 2014 copy reads "Attorneys= Offices"). |
| — | both | chron-BrianZenszer-0054 | office~p1, ~p2 | correct | **PARTLY** | DEFECT | O′ | "FBI; the Justice Department's Criminal Division". The FBI heading alone would be a minor CORRECT (no district named); the Criminal Division comes from the same Project Safe Childhood boilerplate. |
| — | both | chron-MichaelScottBurton-0037 | office~p1, ~p2 | correct | **PARTLY** | DEFECT | O′ | "Northern District of Florida; the Justice Department (… Criminal Division)". The second office comes from the national take-down paragraph "Today's enforcement actions were led and coordinated by the Criminal Division, Fraud Section's Health Care Fraud Unit" (June 28, 2018). The case is "prosecuted by Assistant United States Attorney Tiffany H. Eggers". |

**Further minor defects, recorded as CORRECT:**
- **"It gives no other day" where only the release's "today" or a month exists.** The *sentenced* answers for Gilbert, Durante (descriptive lead "was sentenced today"), Clayton, Grubb, Montgomery and Kenon. The *charged* answers for Aiello and Kenon ("unsealed today"), McCoy ("indicted … last month") and Patel. Clayton *charged* ("returned by a federal grand jury", with no day). Burton rules *charged* p1, where the release gives only the arraignment day.
- **Stewart *charged*.** The Feb. 20, 2015 complaint is right. The later indictment ("Stewart was subsequently indicted on the same charge on March 10, 2015") is not listed: the step pattern needs "was indicted" with no adverb in between.
- **Dunnigan *charged*.** It gives the Dec. 11, 2015 complaint only, not the two indictments (cause L).
- **Lewis Johnson *sentenced*.** "sentenced on April 1, 2016" comes from "announced today, that Lewis Johnson … was sentenced". No other day is stated; it should be hedged as the release date.
- **Aiello timeline.** A hedged "(date of the report)" plea row ("In October 2025, Aiello pleaded guilty") is listed after the Jan. 23, 2026 sentencing.
- **Kenon timeline.** No plea row; the plea ("after previously pleading guilty") is undated and is quoted in the sentencing row.
- **Office.** ATF alone for Montgomery and Freddie Lewis is a minor CORRECT, because the releases name "United States Attorney David C. Joseph" but no district.

## Random spot check (count / office / absent)

**rules: 20 of 20 confirmed.** Martin absent~p2, Louis count~p1, Jalen Thomas absent~p1, Strahler count~p1, Stewart absent~p2, Young absent~p1, Leroy Jones office~p2, McCoy absent~p2, Mabie count~p1, George office~p2, Begay office~p1, Patel count~p1, Martin count~p2, Anglin office~p2, Young absent~p2, George count~p2, Heyde office~p2, Patel office~p1, Shariff Britton office~p1, Aiello absent~p2.

**opus5: 20 of 20 confirmed.** McMahon count~p2, Strahler absent~p1, Gilbert count~p1, Faro absent~p1, Murillo count~p2, Hicks absent~p2, Krantz count~p2, Hicks office~p1, Louis absent~p2, Crosby office~p2, Patel absent~p2, Eloff count~p2, Melvin Smith count~p1, Jalen Thomas count~p2, Louis absent~p1, Heyde absent~p1, Grubb count~p2, Kamara count~p1, Dagesian absent~p1, Begay office~p2.

The full office check (step 4) found the three spurious-second-office cases (Kicinski, Zenszer, Burton).

## Adjudicated totals

### rules
| family | n | correct | honest refusal | partly | ambiguous | missed | wrong | wrong % | strict % (wrong+partly) | strict + missed % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 114 | 0 | 4 | 0 | 0 | 2 | 1.67 % | 5.00 % | 5.00 % |
| timeline | 120 | 96 | 0 | 22 | 0 | 0 | 2 | 1.67 % | 20.00 % | 20.00 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| office | 120 | 114 | 0 | 6 | 0 | 0 | 0 | 0.00 % | 5.00 % | 5.00 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| plea | 110 | 108 | 0 | 0 | 0 | 2 | 0 | 0.00 % | 0.00 % | 1.82 % |
| charge | 106 | 100 | 0 | 4 | 0 | 2 | 0 | 0.00 % | 3.77 % | 5.66 % |
| sentence | 84 | 80 | 0 | 2 | 0 | 0 | 2 | 2.38 % | 4.76 % | 4.76 % |
| charged | 36 | 31 | 0 | 4 | 0 | 0 | 1 | 2.78 % | 13.89 % | 13.89 % |
| ALL | 936 | 763 | 120 | 42 | 0 | 4 | 7 | **0.75 %** | 5.24 % | 5.66 % |

### opus5
| family | n | correct | honest refusal | partly | ambiguous | missed | wrong | wrong % | strict % (wrong+partly) | strict + missed % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 119 | 0 | 1 | 0 | 0 | 0 | 0.00 % | 0.83 % | 0.83 % |
| timeline | 120 | 96 | 0 | 22 | 0 | 0 | 2 | 1.67 % | 20.00 % | 20.00 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| office | 120 | 114 | 0 | 6 | 0 | 0 | 0 | 0.00 % | 5.00 % | 5.00 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| plea | 110 | 108 | 0 | 0 | 0 | 2 | 0 | 0.00 % | 0.00 % | 1.82 % |
| charge | 106 | 101 | 0 | 3 | 0 | 2 | 0 | 0.00 % | 2.83 % | 4.72 % |
| sentence | 84 | 84 | 0 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % |
| charged | 36 | 30 | 0 | 6 | 0 | 0 | 0 | 0.00 % | 16.67 % | 16.67 % |
| ALL | 936 | 772 | 120 | 38 | 0 | 4 | 2 | **0.21 %** | 4.27 % | 4.70 % |

- **rules:** n = 936. Correct 763, honest refusal 120, partly 42, missed 4, **wrong 7 = 0.75 %**. Strict (wrong + partly) 49 = **5.24 %**; strict + missed 53 = 5.66 %. Wrong + missed 11 = 1.18 %.
- **opus5:** n = 936. Correct 772, honest refusal 120, partly 38, missed 4, **wrong 2 = 0.21 %**. Strict 40 = **4.27 %**; strict + missed 44 = 4.70 %. Wrong + missed 6 = 0.64 %.

## The automatic score versus the adjudicated score

**Scorer flags that were not real wrongs.**
- **rules:** of 20 flagged items:
  - 9 are acceptable: Durante count ×2 and Rand timeline p1 are truth-label errors; Chesser office ×2, Grubb charge ×2 and Begay charge ×2 are scorer errors.
  - 4 are PARTLY: the Dunnigan and Hicks timelines ×2 each.
  - 4 are real misses: Patel plea and Ramdihall charge ×2 each.
  - 3 are real wrongs: the Murillo timeline ×2 and Burton *charged* p2.
- **opus5:** of 18 flagged items:
  - 7 are acceptable: Durante ×2, Rand p1, Chesser ×2 and Strahler charge ×2.
  - 5 are PARTLY: the Dunnigan and Hicks timelines and Burton *charged* p2.
  - 4 are misses and 2 are wrongs (the Murillo timeline).

**"Correct" scores that were really wrong.**
- rules: 4 FALSE CORRECT WRONG items (Mabie *sentenced* ×2, Hicks *sentence* ×2). The keys accept the conviction date and the earlier case's term.
- opus5: none.
- Scored correct but PARTLY: rules 38, opus5 33.

**Net.**
- rules: automatic 16 wrong + 4 missed; adjudicated 7 wrong + 4 missed. Only 3 of the 7 real wrongs were among the scorer's 16.
- opus5: automatic 14 + 4; adjudicated 2 + 4.

**Bench generator defects** (bench fixes, not app fixes). Re-label these before quoting ho20 figures as final.
- `count` keys count byte-identical duplicate files (Durante).
- `stated_days` / `order_any` keys use the release day where the release states a weekday (Rand "on Thursday"). They also put a prior-case step in release order (Hicks 2024 after 2025).
- `dates` keys accept a conviction date as the sentencing (Mabie 2014-12-11). `sentence` keys accept an earlier case's revocation term (Hicks "1 year").
- `offence_sentences` keys want one release's wording and reject a correctly quoted complaint, plea or count list (Grubb, Begay, Strahler).
- `office` keys list one of two prosecuting offices (Chesser).

## Root causes of the TRUE WRONG items (and of the misses)

| cat | root cause | rules | opus5 | exact reproducing sentence(s) / question (release's printed date) | fixable? | code area |
|---|---|---|---|---|---|---|
| P | **A namesake who shares the asked person's compound surname read as the person (new form of P).** `namesSomeoneElse` looks only at the ONE capitalised word before the surname. In "Noel Lomas Murillo" that word is "Lomas", which is one of the asked tokens ("abel lomas murillo"), so it returns false and Noel's plea and sentencing become Abel's. Harness: `findings(…"Abel Lomas Murillo")` on release-2/3 returns "pleaded – Noel Lomas Murillo, 33, pleaded guilty …" and "sentenced – Noel Lomas Murillo, 34, was sentenced …". The same helper guards `.chargedWith` and `VerifiedRecordExtractor.verify` (l.131), so a cloud quote of Noel's step would pass too. | 2 wrong (+4 partly) | 2 wrong (+1 partly) | "Noel Lomas Murillo, 33, pleaded guilty to conspiring to possess with intent to distribute and distribute methamphetamine." (Sept. 28, 2021) · "Noel Lomas Murillo, 34, was sentenced to 60 months in federal prison …" (Apr. 27, 2022) | **FIXABLE** | `ProceedingEventExtractor.namesSomeoneElse` l.333–357: compare the WHOLE name span before the surname (all capitalised tokens back to the sentence/list boundary) with the asked tokens; any given name not among them means someone else. Timeline order check (`answer` `.timeline` l.673): a plea or conviction dated after the same case's sentencing should mean "needs review". |
| B | **The step's own date written without "on" ("sentenced Friday, April 3, 2015,") loses to a later date in the sentence (new form of B).** `stepDay` does not read "<weekday>, <Month d, yyyy>" right after the verb and takes "following his conviction on December 11, 2014". Harness: release-2 gives `sentenced 2014-12-11`. | 2 wrong (+2 partly) | 0 (+2 partly; the sentenced answer is the verified Claude extraction) | "… William J. Mabie, 56, of Festus, Missouri, was sentenced Friday, April 3, 2015, in federal district court in East St. Louis, following his conviction on December 11, 2014, on three counts of Mailing Threatening Communications." (Apr. 6, 2015) | **FIXABLE** | `ProceedingEventExtractor.stepDay` (called l.221): accept `(?:on\s+)?(?:Monday…Sunday),?\s+<full date>` right after the verb, before any later date. Treat "following his conviction on <date>" as the conviction's date (`belongs`). |
| A | **A supervised-release revocation in an earlier case read as this case's sentence (new form of A).** "for violating the terms of his supervised release" is not in `separateCase` / `priorRecord`. In `.sentenceImposed` the second, real term in the SAME release is dropped by `t.0 != hit.0` (l.484), because both sentences are in release-2 and the dated 2024 sentence sorts first. | 2 wrong (+4 partly) | 0 (+2 partly; timeline only) | "On September 12, 2024, Hicks was sentenced to one year in prison for violating the terms of his supervised release." (Sept. 15, 2025 and Jan. 20, 2026) | **FIXABLE** | `ProceedingAnswerer.separateCase` / `priorRecord` (l.282): add supervised-release/probation revocation wording. `.sentenceImposed` l.483–486: compare terms, not documents. |
| C | **A when-question parsed as a charge question (recurred: a new wording of ho17 C′ and ho19 C1).** The ho19 guard `charges?\b(?!\s+(?:date\|day)\b)` covers "the charge date". Here "date" comes BEFORE "charges", and the last-resort pattern l.134 `\bwhat\b[^?]{0,40}\b(?:charges?…)\b[^?]{0,20}\b(?:against\|faced\|filed)\b` matches "what date were charges filed against". Harness: `parse("On what date were charges filed against Michael Scott Burton?")` → `.chargedWith`; "What date was … charged?" → `.when(.charged)`. On the opus5 path the cloud reader inherits `parsed.ask` and is verified as a charge quote. | 1 | 0 wrong (1 partly) | Q: "I need to confirm — on what date were charges filed against Michael Scott Burton?" | **FIXABLE** | `ProceedingAnswerer.parse` l.124/l.134: a question that contains "what date / when / which day" asks when, whatever follows. |
| R (missed) | **A pronoun subject not linked when the release introduces a second person (new).** The "He/She … pleaded" lead (l.146–152) is used only when `introductions <= 1`. Release-2 introduces "Suraj Patel, 38," and the co-defendant "Rudy Rampertab, 46,", so "He pleaded guilty in September 2016 …" (the sentence after "Patel was sentenced …") is dropped. | 2 missed (+2 partly) | 2 missed (+2 partly) | "Patel was sentenced to serve one day in prison, followed by six months of home confinement … He pleaded guilty in September 2016 to mail fraud and money laundering." (Nov. 20, 2017) | **FIXABLE** | `ProceedingEventExtractor.findings` l.146–152: resolve "He/She" to the subject of the previous sentence when that sentence names the asked person (nearest-antecedent), not by a document-wide count. |
| W/S (missed) | **A sentence broken by blank lines, and "sentenced … for <offence>" not read as stating the offence (new).** release-1 is hard-wrapped plain text with a blank line between every line. `rawSentences` (l.548) ends a paragraph at every blank line, so the plea sentence is cut into "…announced that Jervis" / "A. Hillaire, … Gyadeen P. Ramdihall, 27, of Rosedale, New York," / "pleaded guilty in U.S. District Court to conspiracy to commit access device fraud." In release-2 the offence is stated only as "was sentenced … for conspiracy to commit access device fraud", and neither `statesOffence` (l.508) nor the verifier's charge test (`VerifiedRecordExtractor` l.168) accepts "sentenced … for". The cloud call was made; nothing verified. | 2 missed | 2 missed | (Jan. 29, 2015, blank-line wrapped) · "… Gyadeen P. Ramdihall, 28, of Bronx, New York, was sentenced today in U.S. District Court by Judge D. Brock Hornby to 10 months in prison and three years of supervised release for conspiracy to commit access device fraud." (July 15, 2015) | **FIXABLE** | `rawSentences` l.546–571: join a "paragraph" that ends without terminal punctuation to the next. `statesOffence` and `VerifiedRecordExtractor` l.168: accept `\b(?:sentenced\|pleaded guilty)\b[^.]{0,200}\bfor\s+<offence word>`. The same gap gives the Freddie Lewis PARTLY. |

**No TRUE WRONG and no miss is a limit of current technology.** Every cause is a deterministic rule gap in question parsing, attribution or record reading. Each was reproduced on the exact text with the shipped code. The documents state the right answer in plain text, and on 4 of the 7 rules wrongs the opus5 path's verified Claude reading gave it. The bar is not raised.

**Note on the opus5 path.**
- Both opus5 wrongs are the deterministic timeline: timelines never call Claude.
- All four opus5 misses made a Claude call. Nothing verified, so the rules refusal shipped.
- The one opus5 PARTLY on a cloud-handled family that the rules got right (Clayton charge p2) is a verified cloud quote of a supplementary count.

### Partly-correct items (strict measure only)

| cat | cause | rules | opus5 | fixable? | area |
|---|---|---|---|---|---|
| B′ | Stated day not used, or given to another step: the sentencing's "today"/"yesterday" given to an earlier plea (Melvin Smith, Burton); "announced today that X pled guilty" taken as the plea day (Lewis Johnson); an explicit "on April 9, 2019" in the row ignored (Louis); a weekday ("pleaded guilty Monday", "complaint on Thursday") not read (Montgomery, Dagesian); the arraignment day given as the charge day (Burton opus5) | 12 | 13 | FIXABLE (recurring every round) | `stepDay`: bind a relative day to the clause of its own verb; resolve weekdays everywhere; a participle/second verb ("pled guilty in November 2016 … and was sentenced today") keeps its own date |
| L | Defendant-list attribution: the person named more than 60 characters after "indictment charging …" (Dunnigan) or after two namesakes (Kamara), so the indictment is missing | 6 | 6 | FIXABLE | `findings` l.195: read a defendant list after the step verb as a list (the person is in it), not a 60-character window |
| A / P / B (secondary) | The Hicks, Murillo and Mabie items above | 14 | 5 | FIXABLE | as A, P, B |
| O′ | A spurious second office from Project Safe Childhood boilerplate (Kicinski, including the "Attorneys= Offices" mojibake; Zenszer) or a national take-down paragraph (Burton) | 6 | 6 | FIXABLE (recurred from ho19) | `IssuingOfficeGate` / `offices(in:)`: ignore the PSC sentence in any encoding, and "enforcement actions were led and coordinated by" |
| R | Patel timeline without the "He pleaded" plea | 2 | 2 | FIXABLE | as R |
| H | Offence date as the charge row (Krantz "… charging him with being a felon in possession … on May 4, 2016") | 2 | 2 | FIXABLE (recurred from ho15/ho18 H) | `stepDay.belongs`: a date after the offence description belongs to the offence |
| E/S, E′, G′ | Charge only "the federal charge" (Freddie Lewis); a supplementary count alone (Clayton opus5); one plea framed as "two prosecutions" (Strahler rules) | 4 | 3 | FIXABLE (recurred) | `.chargedWith` (accept "… for <offence>"); `VerifiedRecordExtractor` should apply the `supplementary` rule; G′ same-plea test |

## Comparison with ho19 (fixes at f766b035)

| cat | ho19 wrong (rules/opus5) | ho20 wrong | status |
|---|---|---|---|
| C parse | 2 / 2 | 1 / 0 (+1 partly) | **Recurred in a new wording** ("on what date were charges filed"). The ho19 "charge date" and possessive fixes held; no possessive question failed. |
| K anonymous / judge lead | 0 wrong; 4 / 4 missed | 0 / 0, no K miss | **Held.** No descriptive or judge lead was misattributed in the full scan. |
| N noun charge | 2 / 2 missed | 0 | **Held** (no such wording this round). |
| O′ "now with" office | partly 2 / 2 | 0 | **Held.** The O′ class recurred through other boilerplate (Kicinski, Zenszer, Burton). |
| P another person's step | 0 / 0 | **2 / 2** (+partly) | **Recurred in a new form** (namesake sharing a compound surname). |
| A prior record | 0 / 0 | **2 / 0** | **Recurred in a new form** (supervised-release revocation). |
| B step-day binding | 0 / 0 | **2 / 0** | **Recurred in a new form** (weekday + date without "on"). |
| R pronoun (NEW), W/S wrapped text / "sentenced for" (NEW) | — | 0 wrong; 4 / 4 missed | New. |

**Regressions from the ho19 fixes: none found.** No ho19 change (C guard, possessive name, abbreviation leads, judge lead, "announced the Indictment of", "now with" office) caused a wrong answer, a miss or a PARTLY. Every ho20 cause traces to rules unchanged by f766b035: `namesSomeoneElse`, `stepDay`, `separateCase`, the `introductions <= 1` pronoun rule, `rawSentences` and `statesOffence`.

## Result

**rules:** adjudicated wrong 7 / 936 = **0.75 %**.
- Strict 49 = 5.24 %; strict + missed 5.66 %; missed 4; wrong + missed 1.18 %.
- Causes: P 2, B 2, A 2, C 1.

**opus5:** adjudicated wrong 2 / 936 = **0.21 %**.
- Strict 40 = 4.27 %; strict + missed 4.70 %; missed 4; wrong + missed 0.64 %.
- Cause: P 2 (the rules timeline).

**Sensitivity.**
- **Misses counted as wrong:** rules 11 = **1.18 %** (fails ≤ 1 %); opus5 6 = 0.64 %.
- **Hicks and Mabie timelines WRONG instead of PARTLY** (a sentencing row before the plea / on the conviction day): rules 11 = 1.18 % (fails ≤ 1 %); opus5 6 = 0.64 %.
- **Burton opus5 *charged* p2 WRONG instead of PARTLY:** opus5 0.32 %.
- **All of the above together:** rules 15 = **1.60 %** (fails ≤ 1 %, meets ≤ 3 %); opus5 11 = 1.18 % (fails ≤ 1 %, meets ≤ 3 %).
- **≤ 3 % holds in every combination on both paths.** The strict measure exceeds 3 % on both paths (5.24 % / 4.27 %), mainly from timeline PARTLYs (22 per path).

**The rules margin under 1 % is narrow.** It depends on judging the Hicks and Mabie timelines PARTLY and on not counting misses.

The bar is not raised. No root cause is a limit of current technology.

**rules — Meets ≤1%: YES** (0.75 % primary measure; narrow; NO with misses as wrong (1.18 %) and NO on the strict measure (5.24 %). Within the coverage stated in Method steps 4–5.)
**rules — Meets ≤3% (owner bar 2026-11-02): YES** (0.75 % primary; 1.18 % with misses; 1.60 % in the harshest sensitivity combination. The strict measure, 5.24 %, does not meet 3 %.)

**opus5 — Meets ≤1%: YES** (0.21 % primary measure; 0.64 % with misses as wrong; NO on the strict measure (4.27 %). Within the coverage stated in Method steps 4–5.)
**opus5 — Meets ≤3% (owner bar 2026-11-02): YES** (0.21 % primary; 0.64 % with misses; 1.18 % in the harshest sensitivity combination. The strict measure, 4.27 %, does not meet 3 %.)
