# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

This adjudicates the fresh held-out set **ho22-chron** on the **Opus 5 (Online) path**, re-run r2, for commit e49783fd. An AI agent (Claude) did the work as an independent adjudicator on the owner's written direction of 2026-11-01. It is not a human sign-off. Four helper agents did the full blind scan of all 928 answers (Method step 4). The adjudicator checked every finding they reported that was not CORRECT, their borderline calls, and a seeded sample of 20 of their CORRECT verdicts against the documents before using any of it. The rules path of ho22 is adjudicated separately, by another adjudicator; it is not covered here.

| | |
|---|---|
| Set | ho22-chron. FRESH: seed 20261109, 60 public DOJ prosecution cases never used before, 928 questions (including paraphrases), skip-chron x1–x23, so 0 overlap with earlier sets. Generated 2026-11-03 before any run. |
| App commit | e49783fd. Unsigned host, FULL=1 ASK_EVERY=1 WORKFLOW_EVERY=0, workers=1. |
| Path | opus5: Online mode with a bench key. Claude's reading is shown only if it verifies against the documents. |
| Run | **r2**, 2026-11-03T08:10:46Z–08:45:29Z, **ocr-failures: 0**. The first opus5 run (`results-opus5`, sheet/key `ho22-opus5-*`) is INVALID: 7 OCR failures while another app was using Vision. It is not used here. |
| Inputs (sha256) | sheet `ho22r2-opus5-sheet.csv` 5bbe4d50f90eae041c34961fdefa0250f2c0196b06b2d330ec9c5f10d59124d0 · key `ho22r2-opus5-key.csv` 73a92eabe309e62aafc687e1b60d0397e66d55065d29d5c222fd532998e29b08 · results-opus5-r2: shard-00000 916eb0bb75a62debba08efe328e09ca0c0ae925555c1e3641ff9882f50ab6cb5, -00001 83c323364842a78056e2dabd154f4594e7eec44506f951dc10d2e90b57aeced9, -00002 c923d6926ca82bdb3e20856370c19f1cedbe29400ea0d2c04395bd50f6b5961f, -00003 f3461a8f582405bf370bc9511f674d9ab02f54b66565f33a015d13154931371a, -00004 36f64207a1ccbbbc353dda9daba5b53a8f249eb25019d12653507221e5f2c4bc, -00005 54453f3bba84ddd9a567536c4956904cbe8fb307074b6e4f34310fbd4e834d2a · score-opus5-r2.txt 9cef8771541371cd2c321f36c1acca78dbc488e03cc73e050f3b4ed5633aa440 · MEASUREMENT-opus5-r2.txt 6310f6b39c519be20d418add72e4a5d0086a4a0e9088ba4e4ef2b46667d07c26 |
| Scorer sha256 (in MEASUREMENT) | 060e98b9…, the same value as ho14–ho20. It still matches none of today's scorer files. Pin it before the result is frozen. |
| Automatic score | right 97.0 %, **wrong 2.2 %**: 20 wrong, 8 missed, 120 honest refusals, 780 correct. |
| Release bar | **≤ 3 % wrong per path (owner decision 2026-11-02).** The earlier ≤ 1 % figure is also given. |

## Method

The method and judgement rules are the same as ho20 (`accuracy-adjudication-ho20.md`). The rules are written out in `RULES.md` in the work folder.

**Work files.** They are in `~/CaseBench/adjudication/ho22-opus5-work`:
- `extract.sh` / `ext.swift`: PDFKit text with **no OCR**, plus `textutil`.
- `findsrc.py`: source release text from `~/CaseBench/raw/doj`.
- `flat.py`, `dump.py` (`dump/<case>.txt`, every answer per case, with no scorer class or key), `g.py`, `cmp.py` (opus5 against the rules run).
- `scan-aa…ad.jsonl`: the helpers' blind per-item verdicts.
- `verdict22.py`: overrides and causes; it produces the table below. `final.json` holds the final verdicts.
- `sheet.py`: writes the adjudicated CSV and the sample estimate.

1. **Blind first.** I judged the 28 scorer-flagged items on the sheet against the documents before reading the key's expected values. The helpers judged all 928 answers blind, from per-case dumps that carry no scorer class and no key. After that, the key was used only to map sheet items to cases and to name key defects.
2. **Documents.** There are 136 case documents. 72 PDFs have a text layer and were read with PDFKit; doc/docx/html/rtf were read with `textutil`; the 14 .txt files were read as they are.
   - 9 PDFs are scanned with no text layer (Murillo Prijic ×2, John Thompson ×2, Payne ×3, Coley ×2). **No OCR was run.** Each was read from its source release in `raw/doj`, matched by title and printed date (all 9 found).
   - Two pairs of files are byte-identical: Kelly release-2 and release-3, and Murillo's two scans (byte-identical only as empty text layers; their source releases differ).
3. **Verdicts.** CORRECT, HONEST REFUSAL, PARTLY, MISSED (a wrong refusal) and WRONG, with the ho20 judgement rules unchanged:
   - Another person's or case's step as an extra row is PARTLY; given alone it is WRONG.
   - A timeline is WRONG only when its order is impossible.
   - "It gives no other day" is a minor CORRECT when only "today" or a month exists, and PARTLY when another day is stated.
   - A hedged "(date of the report)" row that is otherwise true is a minor CORRECT (ho20 Aiello).
   - An appearance or arraignment day given as the charge day, with the charge day unstated, is PARTLY (ho20 Burton opus5 p1).
   - "Charged with" naming no offence is WRONG.
   - A spurious second office is PARTLY.
   - MISSED is reported separately.
4. **Full check, not a sample.** Every one of the 928 answers was judged: every stated day against the release date and its source sentence's today/yesterday/weekday/"on <date>", every timeline row (date, label, order, completeness, whose step), every count against distinct releases, and every office against the releases. Machine re-checks were run over the CORRECT verdicts:
   - count: answer = distinct releases naming the person, 0 exceptions;
   - office: district named but not answered, 2 hits, both courts, not prosecutors (Ellis, Bowman: prosecuted by the Criminal Division's Public Integrity Section);
   - "no other day" answers with a stated weekday, yesterday or "on <date>" near the step: 8 hits, all another person's or another step's day.
5. **Spot check of the helpers.** I drew a seeded sample (seed 20261109) of 20 of the 100 unflagged sheet items and re-judged them myself: **20 of 20 confirmed.** They were Michalewski absent p1, Washington charge p2, Lesser timeline p2, Oliver office p2, Shomo charged p1, Fernandez charge p2, Lance Roark sentenced p1, Clawson office p2, Carthens sentence p1, Singletary count p1, Abbott charge p2, Silber count p2, Yahaira Diaz timeline p2, Jordan timeline p1, Carthens office p1, Repella office p2, Yahaira Diaz office p2, Lance Roark plea p2, Coley count p2 and Michelle Smith absent p2.
6. **Overrides of the helpers.** There were 3 cases, 6 items, all made to follow ho20 precedent:
   - McCasland timeline ×2, PARTLY → CORRECT: a hedged plea row, and no plea day is given.
   - Singletary timeline ×2, PARTLY → CORRECT: hedged duplicate rows beside the right ones.
   - Tavor Tom *charged* ×2, WRONG → PARTLY: the appearance day as the charge day (the Burton convention). It is listed under Sensitivity.
7. **Counting.** No dumps or unsupported answers were found. There were no AMBIGUOUS items; the borderline calls are listed under Sensitivity.

**The estimate formula.** The sheet holds every scorer-flagged item (F = 28) plus a uniform seeded random sample of s = 100 of the U = 900 unflagged items (`adjudication_pack.py`: `rng.sample(rest, 100)`, seed 20261028; uniform, not weighted). The sample estimate is

  est. wrong = W_F + (w_s / s) × U, and est. % = est. wrong / 928.

On this sheet:
- wrong: 0 + 0/100 × 900 = 0, so **0.00 %**;
- wrong + missed: 8 + 0/100 × 900 = 8, so 0.86 %;
- wrong + partly: 6 + 3/100 × 900 = 33, so 3.56 %.

**The sample estimate misses both real wrongs.** The two WRONG items (Hoffman *charge* p1/p2) were scored correct and were not drawn. The full check (step 4) finds them, so the **primary figures below come from the full check of all 928 answers**, as in ho20. The sample estimate is reported only for comparison.

## Per-item table (every item that is not CORRECT / HONEST REFUSAL, plus every scorer flag)

Sheet IDs are given where the item is on the sheet; "—" means the item was found by the full check. "rules-identical" means the opus5 answer body is byte-identical to the rules run's answer for the same item at the same commit.

| item | case | question | scorer | adjudicated | judgement | cause | Claude call / inherited | decisive passage (release's printed date) |
|---|---|---|---|---|---|---|---|---|
| — / — | chron-JohnPHoffman-0039 | charge p1, p2 | correct | **WRONG** | FALSE CORRECT (names no offence) | E | claude:1; rules-identical (inherited) | The answer is only "John P. Hoffman, 54, … pleaded guilty to two counts before United States District Judge David S. Cercone." The offence is stated in the descriptive lead: "A resident of Conneaut Lake, Pennsylvania, pleaded guilty in federal court to charges of violating federal laws relating to the sexual exploitation of children" and "Hoffman possessed and distributed computer images depicting minors engaging in sexually explicit conduct" (July 5, 2017). |
| A0089, A0056, A0061, A0090 | chron-ArturoCarlosMurilloPriji-0008 | charge p2, plea p1, p2, sentenced p1 | missed | **MISSED** | TRUE MISS | X (new) | no Claude call (the refusal runs first); rules-identical | The answer is "No readable document in your archive names Arturo Carlos Murillo…": the asked name without "Prijic". False: "Arturo Carlos Murillo Prijic, 58, of Bolivia, pleaded guilty on Oct. 20, 2022, to one count of conspiracy to commit money laundering" and "The former Bolivian Minister of Government was sentenced today to 70 months in prison" (Jan. 4, 2023). charge p1 and sentenced p2 kept the full name and were answered correctly. |
| A0064, A0125 | chron-CharlesAllenRoark-0000 | sentence p1, p2 | missed | **MISSED** | TRUE MISS | S (term not read) | claude:1, nothing verified; rules-identical | "Charles Allen Roark, 38, of Jefferson City, was sentenced by U.S. District Judge Stephen R. Bough to 12 years in federal prison without parole – 10 years, which is the statutory maximum penalty for the offense, plus a consecutive sentence of two years for his supervised release revocation …" (Nov. 9, 2016). |
| A0022, A0027 | chron-PhilipGPayne-0051 | sentence p1, p2 | missed | **MISSED** | TRUE MISS | K | claude:1, nothing verified; rules-identical | Descriptive lead: "The former Operations Manager of Midamar Corporation … was sentenced yesterday to serve a three year term of probation." The named sentence is "Philip G. Payne, 50, of Ryan, Iowa, received the sentence after having pleaded guilty on January 5, 2015 …" (Oct. 2, 2015, source release text). |
| A0084, A0008 | chron-ChristopherScottFry-0053 | charge p1, p2 | wrong | **PARTLY** | DEFECT | E′ | claude:1; rules-identical | Headline only: "Jerseyville Man Charged With Conspiracy to Distribute Methamphetamine". The second count is missing: "has indicted Christopher Scott Fry … with conspiracy to distribute methamphetamine and possession of a firearm while being a user of a controlled substance" (Nov. 17, 2017). |
| A0123, A0093 | chron-RobertoMontesVillalpando-0029 | charge p1, p2 | wrong | **PARTLY** | DEFECT | G′/E′ | claude:1; rules-identical | The answer reads "two prosecutions, or two people of that name". Its first quote is cut before the offence ("pleaded guilty before U.S. District Judge Lawrence …") and its second inside it ("convicted of conspiring to harbor aliens f…"). The indictment: "…charging Roberto Montes-Villalpando … with conspiracy to commit forced labor, forced labor, conspiracy to harbor aliens for financial gain, …" (June 12, 2020). |
| — | chron-NequanCarthens-0012 | charge p1, p2 | correct | **PARTLY** | DEFECT | E | claude:1; rules-identical | Conduct only: "has pleaded guilty to opening fire last year with a handgun … and killing a woman". The offence is named in "Carthens pleaded guilty on Oct. 15, 2021, … to voluntary manslaughter while armed." (Oct. 18, 2021). |
| — | chron-TavorTom-0017 | charged p1, p2 | correct | **PARTLY** | DEFECT (sensitivity: WRONG) | B′ | claude:1; **verified cloud answer** (text differs from rules, same date) | "charged on July 12, 2019" is the appearance day: "Tavor Tom … appeared in federal court today on a criminal complaint charging him with murder in Indian Country." / "The FBI arrested Tom on July 5, 2019." (July 12, 2019). The complaint's day is not stated. |
| — | chron-JohnBlakeTinkle-0041 | charged p1, p2 | correct | **PARTLY** | DEFECT | B′ | claude:1; rules-identical | The answer gives "dated August 4, 2015 … it gives no other day". Untrue: "A federal grand jury returned the 13-count indictment under seal on July 21, 2015, which was unsealed today upon Tinkle's arrest." (Aug. 4, 2015). |
| — | chron-NequanCarthens-0012 | sentenced p1, p2 | correct | **PARTLY** | DEFECT | B′ | claude:1; rules-identical | The answer gives "Jan. 10, 2022 … no other day". The release says "The Honorable Danya A. Dayson accepted the plea and sentenced the defendant accordingly on Jan. 7, 2022." (Jan. 10, 2022). |
| — | chron-PhilipGPayne-0051 | sentenced p1, p2 | correct | **PARTLY** | DEFECT | B′ | claude:1; rules-identical | The answer gives "Oct. 2, 2015 … no other day". The release says "was sentenced yesterday to serve a three year term of probation" (Oct. 2, 2015), which is Oct. 1. |
| — | chron-ThomasHanes-0021 | sentenced p1, p2 | correct | **PARTLY** | DEFECT | B′ | claude:1; rules-identical | The answer gives "Feb. 24, 2017 … no other day". The release says "a Youngsville man was sentenced Thursday to more than 18 years in prison" (Fri. Feb. 24, 2017), which is Feb. 23. |
| — | chron-JohnPHoffman-0039 | office p1, p2 (A0020 = p1) | correct | **PARTLY** | DEFECT | O′ | no call | Western District of Pennsylvania is right. The Criminal Division comes from the Project Safe Childhood boilerplate: "Led by the United States Attorneys' Offices and the Criminal Division's Child Exploitation and Obscenity Section" (2017). |
| — | chron-MichaelJRolfe-0005 | office p1, p2 | correct | **PARTLY** | DEFECT | O′ | no call | WDNY plus the same PSC boilerplate (Sept. 24, 2013). |
| — | chron-ThomasHanes-0021 | office p1, p2 | correct | **PARTLY** | DEFECT | O′ | no call | WDLA plus the PSC boilerplate "Led by U.S. Attorneys' Offices and the Criminal Division's Child Exploitation and Obscenity Section" (Nov. 29, 2016). |
| — | chron-LanceDouglasRoark-0056 | office p1, p2 | correct | **PARTLY** | DEFECT | O′ | no call | FBI alone would be a minor CORRECT, since no district is named ("U.S. Attorney Clint Johnson", Tulsa). The Criminal Division comes from the PSC sentence (May 16, 2024). |
| — | chron-FranciscoGabrielDiaz-0042 | office p1, p2 | correct | **PARTLY** | DEFECT | O′ (new form) | no call | District of Massachusetts is right. "The Justice Department's Criminal Division" is the USAO's own unit: "Assistant U.S. Attorney Benjamin A. Saltzman of Rollins' Criminal Division" (Dec. 19, 2022). |
| — | chron-JorgeLuisSanchezLopez-0028 | office p1, p2 | correct | **PARTLY** | DEFECT | O′ (new form) | no call | The same form: "Assistant U.S. Attorney Eric Rosen of Lelling's Criminal Division prosecuted the cases" (Jan. 10, 2018). |
| A0035, A0087 | chron-JorgeLuisSanchezLopez-0028 | timeline p1, p2 | wrong | **PARTLY** | DEFECT | D | no call | The rows use only release-2. The plea is a hedged Jan. 10, 2018 row whose quote says "In September 2017, Sanchez-Lopez pleaded guilty". Two steps are missing: "agreed to plead guilty today" (Sept. 6, 2017) and "In June 2016, the 10 defendants were charged". The order is possible. |
| — | chron-EricClawson-0055 | timeline p1, p2 | correct | **PARTLY** | DEFECT | P | no call | Row "March 15, 2010 — pleaded guilty" is a co-defendant's: "A second defendant and associate of Clawson, Joe Grivette, … previously pleaded guilty on March 15, 2010, to a related charge of misprision of a felony." (Mar. 24, 2010). Clawson's own rows (jury conviction Mar. 24, sentencing Sept. 9, 2010) are right. |
| — | chron-FranciscoGabrielDiaz-0042 | timeline p1, p2 | correct | **PARTLY** | DEFECT (sensitivity: WRONG) | A | no call | Rows labelled "convicted" quote the headlines "Convicted Felon Charged with Drug and Firearms Offenses" (Dec. 17, 2021) and "Convicted Felon Indicted …" (Dec. 19, 2022), both before the July 10, 2024 plea. "Diaz was charged by criminal complaint in December 2021" is repeated at later report dates. |
| — | chron-KelvontaeRashadWallace-0034 | timeline p1, p2 | correct | **PARTLY** | DEFECT (sensitivity: WRONG) | A | no call | The indictment "A federal grand jury indicted a convicted felon …" (June 4, 2024) is labelled "convicted". The prior state case "Wallace was convicted in the Circuit Court of Talladega County, in July 2022" appears as a June 4, 2024 "convicted" row. There is no charge row. |
| A0021 (p2) | chron-VictorLColey-0049 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | Hedged "arrested" rows on Feb. 24 and Apr. 27, 2015, sorted after the conviction and the sentencing. The releases say "the shootings took place at 1:10 p.m. on Nov. 6, 2013 … Coley was arrested minutes later". |
| A0003 (p2) | chron-JustinCoreyThurston-0054 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | Plea row "May 1, 2015 (date of the report)". The release says "entered a conditional guilty plea on Thursday" (Fri. May 1, 2015), and the Aug. 6, 2015 release says "the April 30, 2015, guilty plea". |
| — | chron-JohnBlakeTinkle-0041 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The indictment row is dated Aug. 4, 2015, but the indictment was "returned … under seal on July 21, 2015". An extra plea row is dated Apr. 20, 2017; the plea itself "pleaded guilty Sept. 29, 2016" is also listed. |
| — | chron-JamieMelo-0004 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The indictment row is dated Oct. 26, 2017, but "A Captain with the Bristol County Sheriff's Office was indicted yesterday by a federal grand jury" (Oct. 26, 2017) gives Oct. 25. The August 2017 arrest/complaint rows are repeated at Oct. 26. |
| — | chron-KoryMammen-0033 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | Beside the right Jan. 4 plea and Apr. 25, 2022 sentencing rows, extra hedged rows are dated Jan. 5 and Apr. 27, 2022. The releases state "pled guilty January 4, 2022" and "sentenced on April 25, 2022". |
| — | chron-LindaFernandez-0010 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The plea rows are dated Jan. 30 and May 9, 2023 "(date of the report)". The release says "pled guilty January 26, 2023" (Jan. 30, 2023). The May 9 plea row follows the sentencing. |
| — | chron-MichelleSmith-0015 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | Rows labelled "charged" quote "At the time of the offenses charged in the indictment, Smith was employed by Wells …", which reports no step. "Smith was charged in Feb. 2014" is dated at the report days and sorted after the Apr. 23, 2015 plea. |
| — | chron-NequanCarthens-0012 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The sentencing row is "Jan. 10, 2022 (date of the report)" instead of "on Jan. 7, 2022". There is an extra hedged plea row on Oct. 18, 2021; the release says "pleaded guilty on Oct. 15, 2021". |
| — | chron-PhilipGPayne-0051 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The sentencing row is Oct. 2, 2015 (date of the report), but "sentenced yesterday" gives Oct. 1. |
| — | chron-ThomasHanes-0021 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The plea row is Nov. 29, 2016 (date of the report), but "According to the November 7, 2016 guilty plea" (Feb. 24, 2017). The sentencing is Feb. 24 instead of "sentenced Thursday" (Feb. 23). |
| — | chron-TavorTom-0017 | timeline p1, p2 | correct | **PARTLY** | DEFECT | B′ | no call | The "charged" row is July 12, 2019, the appearance day, as for *charged* above. |
| — | chron-JoshuaMarkDavis-0025 | timeline p1, p2 | correct | **PARTLY** | DEFECT | D | no call | The indictment is missing: "In May of 2022, a federal grand jury indicted Davis on the charge" (Mar. 19, 2026). |
| A0007, A0028 | chron-CarterReese-0050 | charge p1, p2 | wrong | **CORRECT** | SCORER ERROR | — | claude:1 | "…entered a plea of guilty today … to one count of wire fraud and one count of mail fraud" names the offences. The key wants "those offenses earlier this month". |
| A0081, A0069 | chron-EricClawson-0055 | charge p1, p2 | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | claude:1 | "a federal jury convicted Clawson of the federal hate crime charge" (Mar. 24, 2010). The key wants the co-defendant Grivette's "misprision of a felony" or the unrelated mail-fraud count. |
| A0029, A0032 | chron-MichelleSmith-0015 | charge p1, p2 | wrong | **CORRECT** | SCORER ERROR | — | claude:1 | "Smith was charged in Feb. 2014 in an indictment that included 14 counts of wire fraud and four counts of aggravated identity theft." The key wants the plea wording. |
| A0085, A0058 | chron-EugeneAKelly-0011 | count p1, p2 | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | no call | "2 … 1 further file is an exact copy of one of these and is counted once." release-2 and release-3 are byte-identical (MD5 f41ef461…). The key says 3. |
| A0012, A0005 | chron-GlennDuffieShriver-0003 | office p1, p2 | wrong | **CORRECT** | SCORER ERROR | — | no call | EDVA and NSD both prosecute: "…of the U.S. Attorney's Office for the Eastern District of Virginia and Trial Attorney Brandon L. Van Grack of the Counterespionage Section in the National Security Division are prosecuting the case" (Oct. 22, 2010). The key lists NSD only. |
| A0026, A0100 | chron-MarciaAbbott-0048 | sentence p1, p2 | wrong | **CORRECT** | SCORER ERROR | — | claude:1 | "Gregory Abbott … and Marcia Abbott … were each sentenced today … to one month in prison, one year of supervised release, … 250 hours of community service and to each pay a fine of $45,000." (Oct. 8, 2019). The key's strings ("1 months", "one months", "8 months" = the government's recommendation) do not match "one month". The answer's paraphrase is cut at "a fine of." but the quote is complete (minor). |
| A0073, A0055 | chron-NarsanLingala-0047 | sentence p1, p2 | wrong | **CORRECT** | TRUTH-LABEL ERROR | — | claude:1 | "An Indiana man was sentenced today to 222 months in prison …" (May 10, 2022, the Lingala release). The key's "63 months" is the conspirator's: "Sandya Reddy … was sentenced on Aug. 10, 2020, to 63 months in prison." |

**Further minor defects, recorded as CORRECT (ho20 conventions):**
- **Hedged "(date of the report)" rows that are otherwise true**, including a plea row listed after the sentencing when the documents give no plea day or only a month: the McCasland, Singletary, Reese, Shomo, Bowers, Fry, Gutierrez, Kelly, Repella, Ellis, Favors and Lingala timelines.
- **"It gives no other day" where only "today" exists:** the Roark, Lance Roark, Murillo Prijic p2 and Chey Johnson *sentenced* answers, and the Roark, Payne and Melo (complaint) *charged* answers.
- **Office: the investigating component alone, with no district named:** FBI for Reese and Tom, DEA for Chey Johnson, ATF for Wallace.
- **Murillo Prijic absent p2:** the refusal is right, but the reason it gives ("No readable document … names Arturo Carlos Murillo") is false, from the same cause X.
- **Sentence paraphrases cut off mid-phrase**, with the full quote beside them: Abbott, Carthens, Coley and Fry.

## Adjudicated totals (opus5, r2, full check of all 928)

| family | n | correct | honest refusal | partly | missed | wrong | wrong % | wrong+missed % | wrong+partly % | wrong+partly+missed % |
|---|---|---|---|---|---|---|---|---|---|---|
| sentenced | 120 | 113 | 0 | 6 | 1 | 0 | 0.00 % | 0.83 % | 5.00 % | 5.83 % |
| timeline | 120 | 88 | 0 | 32 | 0 | 0 | 0.00 % | 0.00 % | 26.67 % | 26.67 % |
| count | 120 | 120 | 0 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % | 0.00 % |
| office | 120 | 108 | 0 | 12 | 0 | 0 | 0.00 % | 0.00 % | 10.00 % | 10.00 % |
| absent | 120 | 0 | 120 | 0 | 0 | 0 | 0.00 % | 0.00 % | 0.00 % | 0.00 % |
| plea | 98 | 96 | 0 | 0 | 2 | 0 | 0.00 % | 2.04 % | 0.00 % | 2.04 % |
| charge | 110 | 101 | 0 | 6 | 1 | 2 | 1.82 % | 2.73 % | 7.27 % | 8.18 % |
| sentence | 82 | 78 | 0 | 0 | 4 | 0 | 0.00 % | **4.88 %** | 0.00 % | 4.88 % |
| charged | 38 | 34 | 0 | 4 | 0 | 0 | 0.00 % | 0.00 % | 10.53 % | 10.53 % |
| **ALL** | **928** | 738 | 120 | 60 | 8 | 2 | **0.22 %** | **1.08 %** | **6.68 %** | 7.54 % |

- **Primary wrong: 2 / 928 = 0.22 %.**
- **Wrong + missed: 10 = 1.08 %.**
- **Wrong + partly (strict): 62 = 6.68 %.** Strict + missed: 70 = 7.54 %.
- **Families above 3 %:**
  - primary wrong %: none (the highest is charge, 1.82 %);
  - wrong + missed: **sentence 4.88 %** (Roark ×2, Payne ×2);
  - wrong + partly: timeline 26.67 %, charged 10.53 %, office 10.00 %, charge 7.27 %, sentenced 5.00 %.
- **The sheet-sample estimate** (formula above): wrong 0.00 %, wrong + missed 0.86 %, wrong + partly 3.56 %. It undercounts, because both real wrongs were scored correct and not drawn.

## The automatic score versus the adjudicated score

- **Scorer flags (28).**
  - Of the 20 "wrong": 14 are CORRECT and 6 are PARTLY; **none is a real wrong**.
    - Scorer errors: Reese charge ×2, Michelle Smith charge ×2, Shriver office ×2, Abbott sentence ×2.
    - Truth-label errors: Clawson charge ×2, Kelly count ×2, Lingala sentence ×2.
    - PARTLY: Fry charge ×2, Montes-Villalpando charge ×2, Sanchez-Lopez timeline ×2.
  - All 8 "missed" are real misses.
- **"Correct" scores that were really wrong.** 2 FALSE CORRECT WRONG items (Hoffman charge ×2): the key accepts a quote that names no offence. A further 54 scored-correct items are PARTLY.
- **Net.** Automatic: 20 wrong + 8 missed (2.2 % wrong). Adjudicated: 2 wrong + 8 missed (0.22 % wrong). Neither real wrong is among the scorer's 20.
- **Key defects** (bench fixes, not app fixes). Re-label these before quoting ho22 figures as final.
  - `count` counts byte-identical files (Kelly).
  - `office` lists one of two prosecuting offices (Shriver).
  - `sentence` takes a conspirator's term (Lingala, Reddy's 63 months) and matches "one months" rather than "one month" (Abbott).
  - `offence_sentences` takes the co-defendant's or an unrelated count (Clawson) and rejects correctly quoted pleas or indictments (Reese, Michelle Smith).
  - `offence_sentences` also accepts a quote naming no offence (Hoffman).
  - `dates` accepts the report day where another day is stated (Carthens, Payne, Hanes *sentenced*; Tinkle *charged*) and the appearance day as the charge day (Tom).
  - `order_any` requires 2017-09-06 for Sanchez-Lopez, which is an agreement to plead, with the plea deferred.

## Did the online path inherit the rules answer?

**Yes, for every wrong and every miss.** This is visible from the result files:
- **aiCalls.** 563 of 928 answers record `{'claude': 1}`; 365 record none. The 365 are all 360 timeline, office and count answers, which never call Claude, plus 5 Murillo Prijic refusals: the absent-person refusal (dabb91f1) runs before the online extraction.
- **Comparison with the rules run (`cmp.py`).** The rules run of ho22 is at the same commit e49783fd. Of the 563 Claude-call answers, 272 are byte-identical to the rules answer for the same item, so the rules answer shipped. 291 differ, which is the verified cloud reading.
- **Both WRONG items (Hoffman charge)** record a Claude call and are byte-identical to the rules answer. Nothing verified, so the rules quote shipped.
- **All 8 MISSED** are byte-identical to the rules answer. Murillo Prijic ×4 made no Claude call. Roark ×2 and Payne ×2 made a call, nothing verified, and the rules refusal shipped.
- **58 of the 60 PARTLY** are byte-identical to the rules answer: all 44 timeline and office items, plus the charge, *charged* and *sentenced* PARTLYs with a call. Only **Tavor Tom *charged* ×2** is a verified cloud answer, and it gives the same day as the rules (July 12, 2019).

So in ho22 the online path added no error of its own beyond the rules', and fixed none of the rules' wrong, missed or PARTLY items either.

## Root causes of the WRONG items and misses

| cat | root cause | items | decisive passage | fixable? | area |
|---|---|---|---|---|---|
| E | **The offence is not named.** The charge reader takes a plea sentence whose object is "two counts" (it matches `\bcounts?\b` / "pleaded guilty … to") as stating the offence. The offence stands only in the descriptive lead, "charges of violating federal laws relating to the sexual exploitation of children". The cloud reading did not verify, so the rules quote shipped. | Hoffman charge ×2: **2 WRONG** | "John P. Hoffman, 54, … pleaded guilty to two counts before United States District Judge David S. Cercone." (July 5, 2017) | FIXABLE | `ProceedingAnswerer` `.chargedWith` `statesOffence`/`offenceWords`: require an offence word in the object ("two counts" alone is not an offence), and read "charges of …" in a descriptive lead. |
| X (NEW) | **The person is refused as absent although the documents name them.** The refusal names "Arturo Carlos Murillo", the asked name without "Prijic", so the asked name was cut short for these paraphrases. The dabb91f1 full-name rule ("a name followed by a further capitalised surname is a different person") then treats every "Arturo Carlos Murillo Prijic" as someone else. This mechanism is inferred from the refusal text and the dabb91f1 description; it was not reproduced in a harness (none was built: this round ran no code). It is a regression introduced by the ho21 fix. | Murillo Prijic charge p2, plea ×2, sentenced p1: **4 MISSED** (+ absent p2 refused for the wrong reason) | "Arturo Carlos Murillo Prijic, 58, of Bolivia, pleaded guilty on Oct. 20, 2022 …" (Jan. 4, 2023) | FIXABLE | `ProceedingAnswerer.parse` name span (keep the 4th name token) and `ProceedingAnswerer.anySourceNames` / `ProceedingEventExtractor.mentionsFully`: a name continued by further tokens of the *asked* name is the person, not a different person. |
| S | **The term is not read.** The term sentence names the person but holds "12 years … without parole – 10 years, which is the statutory maximum penalty … plus … two years for his supervised release revocation". No term detail was extracted, and the cloud reading did not verify. Inferred, not reproduced. | Roark sentence ×2: **2 MISSED** | (Nov. 9, 2016, quoted above) | FIXABLE | the `ProceedingEventExtractor` term reader and the `VerifiedRecordExtractor` sentence check: accept "N years in federal prison without parole", and keep a total term beside a "statutory maximum" aside. |
| K | **Descriptive lead.** "The former Operations Manager of Midamar … was sentenced yesterday to serve a three year term of probation"; the sentence naming Payne says only "received the sentence". The ho19 K fix covers announcer and judge leads, not this "The former <title> of <company>" lead. | Payne sentence ×2: **2 MISSED** (+ the B′ *sentenced*/timeline PARTLYs) | (Oct. 2, 2015) | FIXABLE | the descriptive-lead → named-defendant link in `ProceedingEventExtractor.findings`. |

**No WRONG item and no miss is a limit of current technology.** Each concerns a fact the documents state in plain text, and each traces to a deterministic rule gap: the offence test, name parsing with the full-name gate, the term reader, and the descriptive lead. The online path's verified reading was rejected or not attempted on every one.

### Partly-correct items (strict measure only)

| cat | cause | items | fixable? | area |
|---|---|---|---|---|
| B′ | A stated day not used: "yesterday", a weekday ("sentenced Thursday", "plea on Thursday"), "on Jan. 7, 2022", "on July 21, 2015", "January 26, 2023", "the November 7, 2016 guilty plea", "minutes later" after a dated shooting; or an appearance day used as the charge day (Tom) | 32 (Carthens, Payne, Hanes *sentenced* 6; Tinkle and Tom *charged* 4; 11 timelines × 2 = 22) | FIXABLE (recurring every round) | `stepDay`, weekday resolution, the verifier date forms |
| O′ | A spurious second office: PSC boilerplate (Hoffman, Rolfe, Hanes, Lance Roark); **new form**: the USAO's own "Criminal Division" unit ("Saltzman of Rollins' Criminal Division", "Rosen of Lelling's Criminal Division") read as the Justice Department's | 12 | FIXABLE (recurred from ho19/ho20) | `IssuingOfficeGate` / `offices(in:)` |
| A | Prior-record wording read as a step: the headline "Convicted Felon Charged/Indicted" labelled "convicted"; a prior state conviction as this case's "convicted" row | 4 (Diaz, Wallace timelines) | FIXABLE | apply `priorRecord` to step labelling |
| P | A co-defendant's plea as the person's row (Grivette) | 2 (Clawson timeline) | FIXABLE (recurred) | person attribution ("A second defendant …, Joe Grivette, … pleaded guilty") |
| D | A month-dated or group step missing ("In May of 2022, a federal grand jury indicted Davis"; "In June 2016, the 10 defendants were charged"; the "agreed to plead guilty today" release unused) | 4 (Davis, Sanchez-Lopez timelines) | FIXABLE | the step reader for month-only and group steps |
| E / E′ / G′ | The offence by conduct only (Carthens); a headline with one of two counts (Fry); quotes cut before or inside the offence and framed as "two prosecutions" (Montes-Villalpando) | 6 | FIXABLE (recurred) | `.chargedWith`, the quote truncation, the G′ same-case test |

## Comparison with ho20 (opus5)

| | ho20 opus5 (f766b035) | ho22 opus5 r2 (e49783fd) |
|---|---|---|
| wrong | 2 / 936 = 0.21 % (P, the rules timeline) | 2 / 928 = 0.22 % (E, the rules charge quote) |
| missed | 4 (R, W/S) | 8 (X new ×4, S ×2, K ×2) |
| wrong + missed | 0.64 % | 1.08 % |
| strict (wrong + partly) | 4.27 % | 6.68 % (timeline PARTLY 32 vs 22) |

- **New cause class: X.** A person is refused as absent because the asked name is cut short and the ho21 full-name gate (dabb91f1) rejects the full name. It is the first miss caused by a fix.
- **New form of O′:** the USAO's own "Criminal Division".
- The other classes (E, K, B′, A, P, O′) are known classes in new wordings.

## Sensitivity

- **Tom *charged* ×2 WRONG** instead of PARTLY (the appearance day stated as the charge day, unhedged): 4 = 0.43 %.
- **Montes-Villalpando charge ×2 WRONG** instead of PARTLY (the first quote names no offence): +2.
- **Diaz and Wallace timelines ×2 each WRONG** instead of PARTLY ("convicted" rows before the plea): +4.
- **All of the above together:** 10 = **1.08 %**. With the misses counted as wrong: 18 = **1.94 %**.
- **McCasland and Singletary timelines PARTLY** instead of CORRECT: strict +4 only.

**≤ 3 % holds in every combination.** The highest is 1.94 %.

## Result

**opus5 (ho22-chron, r2, e49783fd): adjudicated wrong 2 / 928 = 0.22 %.**
- Wrong + missed 1.08 %; wrong + partly 6.68 %; strict + missed 7.54 %.
- Cause of the wrongs: E 2 (a rules answer inherited after a Claude call).
- Misses: X (new) 4, S 2, K 2.

**Meets ≤ 3 % (owner bar 2026-11-02): YES.** 0.22 % primary; 1.08 % with misses; 1.94 % in the harshest sensitivity combination. No family exceeds 3 % on the primary measure. The sentence family exceeds 3 % with misses counted (4.88 %). The strict measure (6.68 %) does not meet 3 %, mainly from timeline PARTLYs (32) and office PARTLYs (12).

**Meets ≤ 1 % (earlier bar): YES on the primary measure** (0.22 %). **NO with misses counted as wrong** (1.08 %), and NO on the strict measure. These figures hold within the coverage stated in Method steps 4–5: a full check of every answer, a 20-item spot check of the helpers with 20/20 confirmed, and no OCR, with the scanned releases read from their source text.
