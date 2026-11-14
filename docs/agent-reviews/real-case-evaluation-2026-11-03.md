# Real-case evaluation — "Does Investigations Made Easy make investigating real cases easier?"

**AGENT-run** (AI judge, no human review) · **Date:** 2026-11-03 · **App build:** `c3e8c5b0` (branch `investigations-next`), unsigned test host running the app's real pipeline (ingest → ledger → Ask; the case workflow opens each pack as an investigation and builds custody, contradictions, gaps and a findings report).

**Cases (n = 6, all real and closed):**
- `rc-a-upfront-fee`: DOJ New Jersey, 5 PDFs
- `rc-b-hutchins`: DOJ WDNY, 8 PDFs with same-surname look-alikes
- `rc-c-ntsb-moncks-corner`: NTSB record page, narrative PDF and analysis; the probable cause is withheld
- `rc-d-enron-watkins`: 60 EML files, 12 on the episode
- `rc-e-fda-bluebell`: 7 openFDA recall records in TXT
- `rc-f-logan-arson`: DOJ SDWV; scanned image-only PDF, DOCX, EML and PDF

**Material:** `~/CaseBench/realcase/` — the sealed keys `keys/<case>.json`, the app output `runs/<case>/r1..r5/answers.md`, the investigator memos `memos/app/`, and the baseline memos `memos/baseline/`.

**Method:**
1. The app's own answers in `answers.md` were scored fact by fact against each key. Every round was read, both the whole-archive Ask and the in-case answers.
2. Every wrong statement the app made without refusing was counted. Traps and must-not-conclude items were checked one by one. The workflow block (contradictions, gaps, findings) was checked against the key.
3. Each failure quoted in an investigator memo was checked against `answers.md`.
4. The baseline memos were scored the same way.
5. Per-case scoring was done by six AGENT sub-judges. I spot-checked their quotes against `answers.md`; every one checked matched verbatim. I confirmed three root causes in code, read-only.

**Arms:**
- **App arm:** one investigator agent per case. It could read only the brief and the app's answers, and asked up to 5 rounds of questions.
- **Baseline arm:** one agent per case that read the documents directly, with no app.

**Contamination statement.**
- `README.md` contains a table summarising each case's outcome: the sentences, the NTSB probable cause, the Watkins dates and the case-F discrepancies. Both arms were told to read it, and every agent disclosed that it had.
- I therefore do **not** credit either arm's final conclusions as independent discovery where the README supplied them.
- The app's **failures** are unaffected by the README: wrong answers, wrong people, garbled output, missed contradictions and report errors. They are the main evidence here.
- The scorecards score the **app's answers themselves**, not the memos.

**Limits:**
1. **Rules path only.** `NOAI=1`, the app's default; every round shows `AI model: none (rules path); modules on: 84`. The Opus 5 path was not evaluated.
2. **Harness, not GUI.** The GUI-only tools were not exercised by this harness: the ACH matrix, Watchlists screening, cross-case deconfliction, the chronology with verified marks, and timeline export. Nothing here speaks for or against them.
3. **n = 6, one investigator agent per arm per case.** There are no human investigators.
4. **Counting is not uniform across cases.** Sub-judges counted wrong statements slightly differently. Case D counts each wrong-message answer as distinct; case A merges repeats. Use the distinct counts to show direction, not as precise rates.
5. **Not comparable to the ho22 bench figure** ("0.00 % wrong" on templated prosecution questions). These are free-form investigator questions on unseen real packs.

---

## 1. Totals

| | key facts | found | found but wrong | missed | refused wrongly |
|---|---|---|---|---|---|
| **App answers** (answers.md) | 77 | 50 (many only partial) | 6 | 16 | 5 |
| **Baseline memo** | 77 | 76 | 0 | 1 (scanned PDF unreadable to it) | — |
| **App-arm memo (final report)** | 77 | 57 | 3 | 17 | — |

- **App wrong statements at normal confidence (not refused): 108 distinct**, several hundred instances counting repeats. Every one is duplicated between Ask and in-case.
- **Non-answers presented as answers:** about 199 distinct question-answers. Most are an off-target sentence labelled "(Quoted verbatim from the cited document; no model was consulted.)" at confidence 0.8.
- **Refusals:** about 36 wrongful against about 10 correct.
- **Workflow contradictions flagged: 0 in every round of every case.** Real contradictions in the keys: A, the transacting-in-proceeds inconsistency; F, three ($75k vs $50k, who spread the fuel, which camera). **0 of 4 caught.** The baseline also documented further real tensions in C (8) and D (2), and the app caught none of those either.
- **Effort:**
  - App arm: **30 rounds, 523 questions** (plus 3 smoke questions).
  - Baseline arm: read every document, about 70,000 words in total, of which case D's figure is triage of 60 messages with 25 read in full. That is about 2–2.5 hours of human-equivalent reading.
  - Per case, the app arm still recovered fewer facts after 74–99 questions than the baseline did from one read.

## 2. Per-case scorecards

### A — rc-a-upfront-fee (13 key facts; 5 rounds, 81 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 6 | 2 (#9 Mignott's term, #10 sentencing date) | 4 (#2 gold bonds, #3 $800,000, #4 added counts, #7 transacting) | 1 (#13 Douglas restitution) |
| Baseline | 13 | 0 | 0 | — |
| App memo | 9 | 1 (#10, "on 2023-06-23", inherited from the app) | 3 | — |

**App wrong statements, 7 distinct (16 instances):**
1. **Mignott's term.** r1 q12 and r2 q01, confidence 0.8: "Harold Mignott was sentenced to six years in prison. The document says: “Roy Johannes Gillar, 51, of Las Vegas, was sentenced to six years in prison; Harold Mignott, 60, of Voorhees, New Jersey, was sentenced to three years in prison.”" The quote the app cites contradicts its own answer.
2. **Wrong person.** r3 q01 "Who was sentenced to three years in prison?" was answered "…Judge Vazquez sentenced Douglas to three years of supervised release…", labelled "Quoted verbatim". The answer is Mignott.
3. **A conviction denied.** r4 q03 "Was Mignott convicted of conspiracy and wire fraud?" was answered "No — the documents give mignott: Eric Breslin Esq., Newark." That is his defence-counsel line, and the cited release says he was convicted.
4. **The judge as the person sentenced.** r5 q10: "Judge Vazquez was sentenced to three years of supervised release and ordered to pay restitution of $1 (June 23, 2023)…". The amount is also truncated.
5. **False "not stated".** r3 q16: "The release doesn't say which office announced it". Release-03 reads "U.S. Attorney Philip R. Sellinger announced today."
6. **Release date given as event date.** r1 q15: "October 24, 2022 — convicted"; the verdict was Oct. 21.
7. **Release date given as event date.** r1 q15: "June 23, 2023 — sentenced"; the sentences were imposed June 22.

**Non-answers and refusals:**
- 14 answers were a defence-counsel line, e.g. "What counts were Mignott and Gillar convicted of?" → "Mignott: Eric Breslin Esq., Newark."
- 18 answers were off-target "verbatim" sentences.
- 6 answers were garbled splices.
- 11 refusals were wrongful; 4 were correct, all about Adkins.

**Traps and must-not-conclude:**
- Avoided the Adkins outcome, consistently: "The documents that name James Adkins don't say whether James Adkins was convicted."
- Avoided the plea trap and the "Douglas sentenced in June" trap.
- **Fell in:** the transacting-in-proceeds inconsistency was never surfaced, and June 23 was given for June 22.
- **Partly fell in on amounts:** "$1 million" was offered as the amount Victim Company A transmitted.

**Workflow block (identical in r1–r5):**
- "contradictions found: 0" and "gaps found: 0". Adkins was charged and has no disposition, yet no gap was raised.
- The findings list the judge as a defendant: "On 2018-04-15 — John Michael Vazquez charged", "On 2022-10-23 — Judge John Michael Vazquez convicted".
- Defence counsel appear as findings: "Undated — gillar: Thomas Ashley Esq., Newark".
- "Roy Gillar" and "Roy Johannes Gillar" are split into two people.
- Every dated finding is the anchor date minus one day: 2018-04-15 for 04-16, 2022-10-20 for Oct 21, 2023-07-25 for 07-26.

**Memo claims checked:** all confirmed except "every dated finding is one day early". That is true of the anchor dates, but 2023-06-22 is correct by accident: release date minus one.

### B — rc-b-hutchins (10 key facts; 5 rounds, 74 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 5 (2 partial) | 2 (#7 Soliman's charges pending, #9 restitution) | 2 (#2 FBI false statement, #6 plea-stage totals) | 1 (#3 four EIDL loans) |
| Baseline | 10 | 0 | 0 | — |
| App memo | 6 (2 partial) | 0 | 4 | — |

**App wrong statements, 9 distinct (41 instances):**
1. **Must-not-conclude broken (Soliman).** r2 q03 "Did Roberto Soliman plead guilty or was he convicted at trial?" → "Yes — “Rapids Theatre owner pleads guilty…”". r3 q09: "The document dated March 20, 2025 reports that Roberto Soliman was pleaded guilty". That same document says "Charges remain pending against Roberto Soliman."
2. **Restitution denied.** r1 q11 and r3 q05: "No — the documents give hutchins: • Rapids Theatre Niagara Falls, USA, Inc." Release-08 orders full restitution.
3. **One-day trap.** r4 q14 "Was Hutchins's plea entered on March 20, 2025?" → "No — …". It cites Patricia Hutchins's March 19 release.
4. **Wrong case's prosecutor.** r3 q07 and r5 q07 give William Hutchins's 2014 cocaine prosecutor for John's case: "According to Assistant U.S. Attorney Timothy C. Lynch, who handled the case, … the defendant conspired with others to distribute cocaine…", labelled "(Quoted verbatim…)".
5. **Junk fields on 28 answers.** "Also on file: Amount $1.80 · Status final · Role Director". "$1.80" comes from "$1.8 million"; "Director" comes from an FBI official.
6. **One prosecution called two.** r1 q01: "(two prosecutions, or two people of that name)" for one prosecution with a superseding indictment.
7. **Misleading penalty.** r3 q06 gives the plea's statutory maximum ("$1,000,000 fine") as what the judge ordered.
8. **Two people treated as one.** r4 q05: "Multiple other events for the same subject: "William Hutchins convicted on 2014-01-22" vs "John L. Hutchins sentenced on 2026-01-21"".
9. **False contradiction.** r3 q04 treats the superseding indictment as conflicting with the original.

**Non-answers and refusals:**
- 41 non-answers. 27 of them are the line "Hutchins: • Rapids Theatre Niagara Falls, USA, Inc.", given even to questions about Patricia and William.
- 6 refusals, **all wrongful.** Examples: Patricia's 16 months, William's 37 months, "The documents don't give a count for this."

**Traps and must-not-conclude:**
- Never gave John 16 or 37 months, or the judges Geraci or Arcara. **Avoided.**
- Soliman's plea: **violated** (r2 q03, r3 q08, r3 q09).
- The 3/19 vs 3/20 one-day trap: **fell in.**
- William's facts in John's case: **partly fell in** (the Lynch answers).

**Workflow block (identical):**
- 0 contradictions.
- 1 gap, about the look-alike: "William Hutchins: no charging document on file".
- Officials listed as defendants:
  - "On 2022-03-28 — Trini E. Ross charged"
  - "On 2025-06-25 — Michael DiGiacomo pleaded guilty"
  - "On 2026-01-20 — Michael DiGiacomo convicted"
  - "On 2026-01-20 — Judge Meredith A. Vacca sentenced"
- Every person-event finding is the release date minus one. Headline findings are dated correctly.
- There is no "John L. Hutchins pleaded guilty" finding at all: release-05 ingested with **0 events**.
- Junk findings: "fax: (716) 551-3051", "amount: $1.8 USD", "role: Director".

**Memo claims checked:**
- Confirmed except two:
  - r2 q11 as a Lynch answer: **rejected**; it returned a headline.
  - "No Patricia or William fact was attached to him in Ask": **rejected**; see the Lynch answers and r4 q05.

### C — rc-c-ntsb-moncks-corner (13 key facts; 5 rounds, 99 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 8 (several partial) | 0 | 4 (#5 controller's expectation, #8 recovery from plan, #10 "immediately", #12 40 s / 300 kt) | 1 (#7 left turn crossed in front, "least conservative") |
| Baseline | 13 | 0 | 0 | — |
| App memo | 9 | 1 ("Status: pending", an app artefact; the record page has no Status line) | 4 | — |

**App wrong statements, 13 distinct (89 instances, 40 of them findings lines):**
1. **Wrong accident's date (San Diego, Aug 16, 2015).** "16 August 2015 — In November 2016, we issued safety recommendations…" (r1 Ask q01, 0.85).
2. **Fabricated yes.** "Yes — in November 2016, we issued safety recommendations … on 16 August 2015." This was the answer to "Was the F-16 pilot looking inside the cockpit…?" (r4 q18) and to r5 q13.
3. **F-16 values given as the Cessna's.** r3 q13 and r4 q17 ("What was the Cessna's altitude…") → "…the radar target of the F-16 was 1/2 nm northeast of the Cessna, at an altitude of 1,500 ft…". The Cessna was at 1,400 ft on a 110° track.
4. **F-16 pilot's hours given as the controller's experience.** r3 q15 → "His recent experience included 35 hours in the 90 days … all in the F-16."
5. **Generic guidance given as the controller's reason.** r4 q06 "Why did the controller not issue a traffic advisory earlier?" → generic AIM text: "Be aware that the controller may be occupied with higher priority duties…".
6. **Pre-accident alert given as a recommendation issued after it.** r3 q17: the May 2015 safety alert.
7. **Wrong document count.** "Not found in the 13 documents searched: identity." The case has 3 documents.
8. **Junk fields from prose.**
   - "Also on file: Status pending" (×27).
   - "employer: In Systems" and "employer: Active Traffic Systems".
   - "interceptthatcourseat1100: 56, one second before the collision…".
   - "On 2015-07-02 — At the time of the accident, the airframe had" (fragment).

**Non-answers and refusals:**
- 48 of 99 Ask answers were non-answers. For example, "Did the F-16 have a TCAS?" got a simulation sentence; the narrative says plainly "The airplane was not equipped with a TAS, TCAS, or ADS-B…".
- 8 wrongful refusals:
  - Clock times refused as "A when-question whose evidence states no date." The citations hold 1100:26 and 1100:33.
  - The analysis's conclusions refused with "None of the documents on file states the investigators' conclusion".
- 4 correct refusals.

**Traps and must-not-conclude:**
- **Avoided:**
  - No probable cause was invented.
  - The Cessna pilot was not faulted: "nor was he required to do so".
  - The USAF serial was handled correctly.
- **Fell in:** the San Diego date was carried into this case.
- Side effect: the only causal sentence the app surfaced faults the F-16 pilot. The controller-critical analysis (facts 7 and 8) never appeared, so the evidence the app offered was one-sided.

**Workflow block (identical):**
- 0 contradictions and 0 gaps.
- The baseline found 8 real tensions, all missed by the app:
  - "2 miles" vs 3.5 nm
  - "about 1101" vs 1100:57
  - witness "about 900 ft" vs radar ~1,500 ft
  - "neither … evasive maneuvers" vs "pull up"
- The findings consist mostly of the junk fields above.

**Memo claims checked:**
- Confirmed except two:
  - "every quote I checked in a second round was consistent": **partly rejected**; about 25 Ask and in-case answer bodies differ.
  - "The record page lists 'Status: pending'": **rejected.**

### D — rc-d-enron-watkins (15 key facts; 5 rounds, 95 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 9 (1 full, 8 partial) | 0 | 5 (#1 Aug 14 "unwind raptor" body, #2 Buy's reply, #5 Raptor = LJM "hiding losses", #10 Oct 24 to McMahon, #12 "what did you expect?") | 1 (#11 forwards to Lay) |
| Baseline | 15 (2 partial) | 0 | 0 | — |
| App memo | 10 (mostly partial) | 1 (says Buy's reply was the 15:27 "Wow…"; that is Watkins's own message) | 4 | — |

**App wrong statements, 48 distinct (95 instances, plus 25 wrong-dated findings lines):**
1. **Wrong owner of an address.**
   - "Mark Haedicke <mark.frevert@enron.com> — … appears in 4 emails (sent 0, received or copied 4)" (r3 q03).
   - "Andrew Fastow <andrew.wilson@enron.com>" (r3 q10).
   - "Jeff Mcmahon <jeff.donahue@enron.com>" (r3 q12).
2. **Messages misdated by years.**
   - A 29 Oct 2001 message shown as "May 24, 1996: MICHAEL BERRY campaign".
   - A 1 Oct 2001 message shown as "1 January 1999 — Credit Reserve - Talisman".
   - Messages of 8 Oct and 19 Nov 2001 shown as "29 November 1999 — EnronOnline…".
   - The findings report opens "On 1996-05-24 — Email correspondence…".
3. **Messages misdated by one day (UTC).**
   - "25 October 2001 — Your new CFO spot…", header Wed 24 Oct 17:09 PDT.
   - "12 November 2001 — Haina Note", header Sun 11 Nov 17:58 PST.
4. **34 wrong-message "verbatim" answers.** Examples:
   - "Who wrote the unsigned letter…" → "Thanks, Liz --- Kenneth.Lay@enron.com wrote:".
   - "What questions did Sherron Watkins ask Kenneth Lay?" → the WSJ reporter's "I have two additional quesitons I forgot to ask."
   - "When did Kenneth Lay learn…" opens with timothy.hubbard@, a look-alike. This partly breaks the must-not-conclude that Lay first learned in October.
   - "What did Sherron Watkins send to Rick Buy on August 14, 2001?" → "Fri, 2 Nov 2001 09:08:28 -0800 (PST)".

**Non-answers and refusals:**
- 23 distinct non-answers on Ask, plus 8 that occurred only in-case.
- 4 refusals, all wrongful. For example, "Which messages were forwarded to Kenneth Lay about the concerns?" got "The documents searched don't mention the messages."; the forward exists.

**Traps and must-not-conclude:**
- **Fell in:** the look-alike messages (portrac, Corp Dev, 130 Liberty; Hubbard and Carrington).
- **Avoided:** an exact date for the letter, and the "Walley" spelling.
- **Partly fell in:** the must-not-conclude items on Lay learning in October and on Hubbard and Carrington as whistle-blowers.

**Workflow block (identical):**
- 0 contradictions. The Fastow "leave of absence" vs "ousted" discrepancy is undetectable because quoted text is stripped at ingestion (see defect 9).
- "gaps found: 39", never listed.
- Findings misdated by years, with nonsense commitments ("A commitment was recorded to have good news."). The wording changes between identical runs, and the text is cut off after about 20 findings.
- **What worked:** the Aug 14 messages 048 and 056 were kept apart, and the profile "appears in 6 emails (sent 5, received or copied 1)" for Watkins was correct.

**Memo claims checked:**
- Confirmed except two memo errors, both **rejected**:
  - "Buy's reply 'RE: portrac' came at 15:27": the app showed Watkins→Buy.
  - "Watkins sent … 'CONFIDENTIAL NOTE'": the app showed l..carson as the sender.

### E — rc-e-fda-bluebell (12 key facts; 5 rounds, 84 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 11 | 1 (#8 lots and units: wrong rows) | 0 | 0 |
| Baseline | 12 | 0 | 0 | — |
| App memo | 12 | 0 | 0 | — |

The app memo found all facts mainly through about 30 event-ID questions such as "What is the termination date of recall event 70738?". It learned the event IDs from the **cited file names**, which carry the ID. That is a bench artefact a real user would not have.

**App wrong statements, 24 distinct (about 84 instances):**
1. **False conflicts pooled across separate events.**
   - "Your archive carries conflicting values for classification: • Class I • Class II • Class III … your sources disagree on classification".
   - The termination "conflict" in r1 q07 **omits** the true Nov 3, 2016.
   - The Jeni's initiation "conflict" (r1 q13) is built from Blue Bell dates and omits Apr 22, 2015.
   - "conflicting values for recalling firm: • Blue Bell Creameries, L.P. • Jeni's Splendid Ice Creams LLC".
2. **Wrong-event rows labelled verbatim at 0.8.**
   - The 2015 products question got "F-1407-2016 | BLUE BELL ICE CREAM Rocky Road pint | 23,973 pints".
   - "How many units of Blue Bell Country Cookie sandwiches…" got "All American Cup … 94,311 units". The real figure is 3,008,184.
   - The 2016 cookie dough question got a 2025 row.
3. **The 2015 "why" answered with the wrong reason.** "Reasonforrecall: Product may have been mispackaged and contain undeclared wheat and soy."
4. **"end" answered with initiation dates.** r5 q01.
5. **Day and month swapped.** "Date: 2020-10-05", from "Best By Date: 5/10/2020".
6. **A firm read as an employer.** "Employer: Splendid Ice Creams LLC".

**Non-answers and refusals:**
- 23 distinct non-answers; 14 of them were the 70738 header line.
- 1 wrongful refusal: "There is nothing in your archive about 'fda-recall-event-70738'". The in-case path answered the same question.

**Traps and must-not-conclude:**
- **Avoided:** deaths, charges, an FDA mandate, and an Aspen Hills link to the 2015 recall.
- **Partly fell in:** keeping Jeni's and 75254 separate, and keeping the four dates distinct. Both held when the question gave the event ID and failed on plain wording.

**Workflow block:**
- 0 contradictions, which is correct; the key has none. This is inconsistent with the Ask path's 11 false conflicts per run.
- 0 gaps.
- Findings: "0 dated and 66 undated finding(s)". Every line is a bare "Undated — field: value" with no event attached. Output is truncated mid-token, e.g. "Undated — eventid: 803". **r1 and r2 omit the Kansas reason entirely.** The subset and order change between runs.

**Memo claims checked:** all confirmed, except that the r5 q07 refusal is not "clear and well-reasoned": it is a wrongful refusal.

### F — rc-f-logan-arson (14 key facts; 5 rounds plus a smoke round, 90 + 3 questions)

| arm | found | wrong | missed | refused wrongly |
|---|---|---|---|---|
| App answers | 11 | 1 (#12 Williams 32 months: the app said 22) | 1 (#14 Workman) | 1 (#6 Williams named later; information) |
| Baseline | 13 | 0 | 1 (#1 indictment; **could not read the scanned PDF**) | — |
| App memo | 11 | 0 (left Williams "not established") | 3 | — |

**OCR worked.**
- All 5 documents ingested with no errors. The app's quotes from the image-only `release-01` match a Vision OCR of it word for word.
- The scanned PDF was the **only** route to the 36-count indictment and the $75,000 figure. The baseline arm could not read it.
- DOCX and quoted-printable EML were read correctly.

**App wrong statements, 7 distinct (20 instances):**
1. **Wrong person's sentence (Williams given Simon's).** r1 q15, r2 q10 and r3 q01, at 0.8: "Michael Williams was sentenced to 22 months in prison for destroying the digital video recorder … The document says: “Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams and was sentenced Thursday to a term of 22 months…”". The same error appears as "Yes —" in r5 q01.
2. **State court.** r4 q02 "Was Michael D. Williams sentenced in state court?" → "Yes — “Shawn C. Simon…”". The case was federal.
3. **Invented second plea.** r3 q04: "Guy R. Miller was pleaded guilty on November 6, 2013 and again on December 12, 2013". The source says "previously pleaded guilty last month".
4. **Invented second sentencing.** r3 q16: "Guy R. Miller was sentenced on May 28, 2014 and again on May 29, 2014".
5. **Wrong amount.** r1 q10 "How much did the insurance company pay?" → the $75,000 Thompson sentence. The insurer paid $1,010,000.
6. **Wrong date.** r4 q13 Thompson's plea hearing → "February 1, 2012."
7. **Right date, wrong evidence.** r3 q02: Williams's May 29 date is supported only by Simon's sentence.

**Non-answers and refusals:**
- 41 distinct non-answers.
- 6 wrongful refusals. One contradicts the app itself: r1 q12 quoted Thompson's five years, then r1 q13 said "The documents that name William Jamey Thompson don't state a sentence for William Jamey Thompson."
- 2 correct refusals: "don't record Michael Williams being pleaded guilty".

**Traps and must-not-conclude:**
- **Fell in:** "Thompson got $75k" was stated without the $50k figure; the workflow said "No conflicting accounts found in scope."
- **Fell in:** Williams's absence from the indictment.
- **Avoided:** the "faces a minimum" trap and the trial trap.
- **In the gaps only:** Miller / Miller Jr.; Williams / Michael D. Williams split into separate entities.

**Workflow block (identical):**
- **0 of 3 real contradictions** caught. The two fire-setter accounts are printed back to back in the findings with no link between them.
- The U.S. Attorney is listed as a defendant: "On 2013-09-02 — Booth Goodwin charged", "On 2014-05-29 — Booth Goodwin sentenced".
- Dates are one day early: "2013-12-11 — William Jamey Thompson pleaded guilty" for Dec 12; "2014-05-20" for May 21.
- False gaps: "Shawn C. Simon: no charging document on file" and "Guy R. Miller: no charging document on file". Both are in the indictment.
- "$50 USD", parsed from "$50k".

**Memo claims checked:** all confirmed, except "every finding date is one day early". That is true of the event findings; the Feb 1, 2012 and e-mail findings are dated correctly.

---

## 3. Comparison

| case | key facts | app found / wrong / missed / refused | app wrong stmts (distinct) | baseline found / wrong | app-arm effort | baseline effort |
|---|---|---|---|---|---|---|
| A | 13 | 6 / 2 / 4 / 1 | 7 | 13 / 0 | 5 rounds, 81 q | 5 docs, ~3,100 words, ~10–15 min |
| B | 10 | 5 / 2 / 2 / 1 | 9 | 10 / 0 | 5 rounds, 74 q | 8 docs, ~3,900 words, ~15 min |
| C | 13 | 8 / 0 / 4 / 1 | 13 | 13 / 0 | 5 rounds, 99 q | 3 docs, ~14,500 words, ~30–40 min |
| D | 15 | 9 / 0 / 5 / 1 | 48 | 15 / 0 | 5 rounds, 95 q | 60 msgs triaged (25 full), ~26,800 words, ~30–40 min |
| E | 12 | 11 / 1 / 0 / 0 | 24 | 12 / 0 | 5 rounds, 84 q | 7 records, ~19,700 words, ~15–20 min |
| F | 14 | 11 / 1 / 1 / 1 | 7 | 13 / 0 | 5 rounds + smoke, 93 q | 4 of 5 docs, ~2,400 words, ~20–25 min |
| **total** | **77** | **50 / 6 / 16 / 5** | **108** | **76 / 0** | **30 rounds, 523 q** | **~70k words, ~2–2.5 h** |

**Where the app genuinely saved work**

- **Format reading, including OCR of scanned PDFs (F).** This is the clearest win. The baseline could not read the image-only indictment. The app read it cleanly and surfaced the 36 counts, the four defendants and the $75,000. DOCX, quoted-printable EML, PDF, the NTSB coded record page and openFDA TXT all ingested with 0 errors.
- **Exact cited passages.** Every quote the sub-judges checked is verbatim from its source. That is what let investigators catch the app's own errors; for example, the Mignott "six years" answer quotes the "three years" sentence.
- **Verified refusals on absent outcomes:**
  - Adkins's outcome (A), refused consistently under four phrasings.
  - No NTSB probable cause (C).
  - No Williams plea (F).
  - No deaths or charges at Blue Bell (E).
- **Per-person history.**
  - A: "The case against Roy Johannes Gillar, in date order (6 steps from 4 documents)", with a quote for each step.
  - D: Watkins's e-mail profile, "appears in 6 emails (sent 5, received or copied 1)".
- **Same-surname separation held for the headline facts (B).** John L. Hutchins was never given Patricia's 16 or William's 37 months, or their judges.
- **Event-ID field answers (E).** "Termination date: November 3, 2016." Exact, when the investigator already knows the event ID.
- **Speed.** Answers take seconds, and custody hashing was correct in every case.

**Where it cost work or misled**

- **Wrong answers at normal confidence.** 108 distinct, in every case. Several are on the central question:
  - Mignott's prison term.
  - Williams's sentence.
  - Soliman's plea, a must-not-conclude.
  - Restitution denied with "No —".
  - The wrong e-mail address for Haedicke, Fastow and McMahon.
- **The verified label means nothing.** About half of all answers are a non-answer carrying "(Quoted verbatim from the cited document; no model was consulted.)" at confidence 0.8. That label is the app's trust signal, and it is attached equally to correct answers, off-target sentences, wrong people and wrong events. The investigator has to open the passage every time, which is reading the documents anyway, in fragments.
- **The workflow block never helped.**
  - Contradictions: 0 in 30 of 30 workflow runs, including F, a case built around three discrepancies, where it reported "No conflicting accounts found in scope." That is absence presented as verification.
  - Gaps: false (F), useless ("gaps found: 39", never listed), or off-target (B).
  - Findings reports: put prosecutors and judges in as defendants (A, B, F), shift dates by a day (A, B, F), misdate by years (D), and carry junk fields (B, C, E).
- **Phrasing sensitivity.** The same fact flips between answered, wrong and refused depending on wording ("Rapids Theatre owner", "how many", "before which judge", "end" vs "termination").
- **The Ask and in-case answers diverge** in C and D, about 25 bodies in C.
- **Net effort.** The app arm asked about 87 questions per case and reached 57 of 77 facts, 3 of them wrong. Even this was helped by the README. The baseline reached 76 of 77 with 0 wrong by reading about 12,000 words per case. On these six cases the app did not reduce the work. It moved the work from reading documents to cross-examining the app.

---

## 4. Defect list (prioritised)

Severity order: **wrong-at-confidence > misleading > unhelpful > cosmetic**. Components are marked *likely* unless verified in code.

### D1 — The answered value is not bound to the person asked (wrong person, wrong value) · **wrong-at-confidence**

- **Symptom:** a sentence that names several people is read as being about the person asked, and the first "sentenced to X" (or similar) in it is taken as that person's value.
- **Quotes:**
  - A: "Harold Mignott was sentenced to six years in prison. The document says: “Roy Johannes Gillar … six years …; Harold Mignott … three years in prison.”"
  - A: "Who was sentenced to three years in prison?" → "…sentenced Douglas to three years of supervised release…"
  - F: "Michael Williams was sentenced to 22 months in prison…", quoting "Shawn C. Simon … drove the getaway car for Miller and Williams and was sentenced Thursday to a term of 22 months".
  - B: "Roberto Soliman was pleaded guilty".
  - F: "Guy R. Miller was pleaded guilty on November 6, 2013 and again on December 12, 2013".
  - C: F-16 altitude given as the Cessna's.
- **Component (likely):** ProceedingAnswerer and the person-history step binding. The subject of the sentence clause is not matched to the named person, and prison terms are not told apart from supervised release. Some answers also have a document-level headline with no person attached.
- **A fix must:** bind each value to the grammatical subject of its own clause ("X … was sentenced to N; Y … was sentenced to M"). It must refuse when the asked person is not the subject. It must not treat "previously pleaded … last month" or "sentenced Thursday" from another person's clause as a new event for this person. The release that says "Charges remain pending against Roberto Soliman" must win over a headline about "the owner".

### D2 — The yes/no composer puts "Yes —" or "No —" in front of an unrelated fact · **wrong-at-confidence**

- **Quotes:**
  - A: "No — the documents give mignott: Eric Breslin Esq., Newark." (a conviction denied)
  - B: "No — the documents give hutchins: • Rapids Theatre Niagara Falls, USA, Inc." (restitution denied)
  - B: "Yes — “Rapids Theatre owner pleads guilty…”" (Soliman)
  - F: "Was Michael D. Williams sentenced in state court?" → "Yes — “Shawn C. Simon…”"
  - C: "Yes — in November 2016, we issued safety recommendations … on 16 August 2015." given to "Was the F-16 pilot looking inside the cockpit…?"
  - E: "No — the documents give voluntary: Firm initiated." (an either/or question)
- **Component (likely):** the yes/no answer builder on the fact-first path. It does not check that the supporting fact or passage is about the question's subject and predicate.
- **A fix must:** answer yes or no only when the evidence states the predicate for that subject. Otherwise refuse or say "not stated". Never answer "No" from an unrelated fact, and never answer an either/or question with yes or no.

### D3 — Off-target passages ship as "Quoted verbatim" at 0.8; there is no answers-the-question gate · **misleading** (wrong-at-confidence where the passage is about the wrong person or event)

- **Quotes:**
  - D: "What did Sherron Watkins send to Rick Buy on August 14, 2001?" → "Fri, 2 Nov 2001 09:08:28 -0800 (PST)".
  - D: "Who wrote the unsigned letter…" → "Thanks, Liz --- Kenneth.Lay@enron.com wrote:".
  - C: "Did the F-16 have a TCAS?" → a simulation sentence.
  - B: William's AUSA Lynch given for John's case.
  - E: the 2016 Rocky Road row given for the 2015 products.
  - Scale: 18 off-target answers in A, 48 of 99 in C, and so on. About 199 non-answers across the six cases.
- **Component (likely):** passage selection and the extractive composer (AnswerSynthesizer / PassageAnswerSelector). Lexical overlap wins. Nothing checks the subject, year, event or correspondents against the question, and the confidence (0.8) is fixed regardless of fit.
- **A fix must:**
  - Check that the chosen sentence contains what the question asks for: the slot type (a date for "when", a person for "who", a number for "how many"), the subject named, and the year or event named.
  - Refuse otherwise, with "not found" rather than a verbatim non-answer.
  - Make confidence reflect fit.
  - Use the "verbatim" label only to say that the words are the source's own, never to imply that they answer the question.

### D4 — Contradiction detection found nothing real in any of the six cases · **misleading** (absence presented as verification)

- **Quotes:**
  - "contradictions found: 0" and "No conflicting accounts found in scope." in all 30 workflow runs.
  - Missed in F: $75k vs $50k to Thompson, who spread the fuel, which camera filmed it.
  - Missed in A: Gillar AND Douglas convicted of transacting (release-03) vs Gillar only (release-04/05).
  - Missed in C: 8 numeric and time tensions.
  - Meanwhile the Ask path invents conflicts:
    - E: "conflicting values for classification: • Class I • Class II • Class III", pooled across 7 separate recalls.
    - B: original vs superseding indictment.
    - B: "same subject" William vs John Hutchins.
- **Component (likely):** ContradictionDetector, and the field-conflict composer on Ask. The detector compares only identical structured slots for one subject. It does not compare an amount paid to the same payee, the same role ("spread the gasoline") with a different actor, or a count present in one release and absent from the next. Separately, it has no notion of event identity or supersession.
- **A fix must:**
  - Flag the four keyed contradictions on these packs (A transacting; F payment, fuel, camera), showing both sources.
  - Never pool values from different events or people into a "conflict".
  - Treat a superseding charge as an update, not a conflict.
  - Say "contradiction check covers X kinds of claim" rather than imply none exist.

### D5 — The findings builder lists officials as defendants and promotes junk fields · **wrong-at-confidence** (in a report the user may hand on)

- **Quotes:**
  - A: "On 2018-04-15 — John Michael Vazquez charged", "On 2022-10-23 — Judge John Michael Vazquez convicted".
  - B: "On 2022-03-28 — Trini E. Ross charged", "On 2025-06-25 — Michael DiGiacomo pleaded guilty", "On 2026-01-20 — Judge Meredith A. Vacca sentenced".
  - F: "On 2013-09-02 — Booth Goodwin charged", "On 2014-05-29 — Booth Goodwin sentenced".
  - Junk fields:
    - A: "Undated — gillar: Thomas Ashley Esq., Newark".
    - B: "amount: $1.8 USD", "role: Director".
    - C: "employer: In Systems", "interceptthatcourseat1100: 56…".
    - E: "employer: Splendid Ice Creams LLC", "0 dated and 66 undated finding(s)", truncated at "Undated — eventid: 803".
  - B: no plea finding at all, because release-05 ingested with 0 events.
- **Component (likely):** event-participant extraction and the findings builder (InvestigationFindingsComposer and the claims behind it). Every person in a "charged" or "sentenced" sentence is tagged as the actor, including "U.S. Attorney … announced" and "before Judge …". The key:value extractor runs on prose. The report is truncated by a character budget and is not deterministic.
- **A fix must:**
  - Separate role classes: defendant vs prosecutor, judge, agent or counsel.
  - Never emit "<official> charged/sentenced".
  - Attach each structured record field to its event (E).
  - Keep only fields from real structured sources.
  - Produce a complete, deterministic report.

### D6 — Dates: findings one day early, event dates taken from the wrong sentence, release date used for event date · **wrong-at-confidence**

- **Quotes:**
  - One day early:
    - A: 2018-04-15 for 04-16; 2022-10-20 for Oct 21; 2023-07-25 for 07-26.
    - B: every person-event finding is the release date minus one.
    - F: "2013-12-11 — William Jamey Thompson pleaded guilty" for Dec 12; "2014-05-20" for May 21.
    - D: "25 October 2001 — Your new CFO spot…", header 24 Oct 17:09 PDT.
  - Wrong sentence or field:
    - C: "16 August 2015 — In November 2016, we issued…" (the San Diego accident's date).
    - D: "On 1996-05-24 — Email correspondence…" for a 29 Oct 2001 message.
    - D: "1 January 1999 — Credit Reserve - Talisman".
    - E: "Date: 2020-10-05" from "Best By Date: 5/10/2020".
  - Release date used for event date:
    - A: "October 24, 2022 — convicted" (verdict Oct 21).
    - A: "June 23, 2023 — sentenced" (imposed June 22).
- **Component:**
  - **Verified:** `Knowledge/History/HistoryNarrativeRenderer.datePhrase` formats with a UTC calendar (line 53), and `Export/ClaimSelectionService` also uses a UTC calendar. The host is `IST+0530`. A day anchor stored at local midnight therefore renders one day earlier. The upstream producer of the anchor is *likely* the event extractor, storing local midnight.
  - **Verified:** `EventAnswerComposer` formats e-mail dates in UTC, so Pacific evening e-mails move a day later.
  - *Likely:* the e-mail event date is taken from body or subject dates instead of the Date header.
  - *Likely:* the proceeding history uses the release date instead of the date stated in the text ("convicted on Oct. 21", "imposed the sentences on June 22").
- **A fix must:**
  - Store day-precision dates as calendar dates, not instants, and render them in the same calendar as they were parsed.
  - Show an e-mail in its sender's local day, or say which time zone is used.
  - Prefer the date stated in the text over the publication date.
  - Use the Date header for e-mail events.
  - Not attach a date from another sentence or another event.

### D7 — E-mail participants are resolved by first name only (wrong person) · **wrong-at-confidence**

- **Quotes (D):**
  - "Mark Haedicke <mark.frevert@enron.com> — … appears in 4 emails (sent 0, received or copied 4)"
  - "Andrew Fastow <andrew.wilson@enron.com>"
  - "Jeff Mcmahon <jeff.donahue@enron.com>"
- **Component (verified):** `App/AppState+SubjectFirst.swift:92` reads `let token = name.split(separator: " ").first…`, then queries the correspondence lookup by that token. The composer picks the most frequent address carrying the token ("mark" → mark.frevert). The display name falls back to the asked name, which hides the swap.
- **A fix must:** match on the full name, or the surname plus first name or initial, against the display name or local part. It must not show an address under a name it does not carry, and must refuse or ask the user to choose when the match is ambiguous.

### D8 — Prose turned into key:value "facts" that win the fact-first path · **misleading** (wrong-at-confidence when they feed D2)

- **Quotes:**
  - B: "Hutchins: • Rapids Theatre Niagara Falls, USA, Inc." answers 27 questions, including ones about Patricia and William.
  - B: "Also on file: Amount $1.80 · Status final · Role Director".
  - A: the defence-counsel line answers 14 questions ("Mignott: Eric Breslin Esq., Newark").
  - C: "Also on file: Status pending" ×27; the record page has no Status field.
  - F: "amount: $50 USD", from "$50k".
- **Component (likely):** the ingestion fact or record extractor ("label: value" on prose and bullet lists, surname as key), and the fact-first answerer, which short-circuits on a surname match with no check that the fact is relevant.
- **A fix must:**
  - Extract key:value only from real structured sources.
  - Parse amounts with their suffix (million, k).
  - Keep the fact-first path from answering unless the fact's predicate matches the question's.

### D9 — Quoted e-mail text is dropped at ingestion · **unhelpful** (it causes missed facts and wrongful refusals)

- **Symptom:** in D, Buy's 12:51 reply, the Oct 24 forward to Lay and McMahon's "what did you expect?" never surfaced. "Which messages were forwarded to Kenneth Lay about the concerns?" was refused. The Fastow discrepancy could not be detected.
- **Component (verified):** `Ingestion/Loaders/EmailLoader.swift` and `EmailStructuralParser` call `stripQuotedRegions`. Everything after "-----Original Message-----" is removed, so message 015 is indexed only as "Ken per my voice mail......thanks."
- **A fix must:** index the quoted and forwarded region as attributed content (who wrote it and when, per its inline header), so forwards are searchable without being taken for the forwarder's own words.

### D10 — Wrongful refusals from gates that are too broad · **unhelpful**

- **Quotes:**
  - C: clock times refused: "A when-question whose evidence states no date." (the citations hold 1100:33).
  - C: the analysis refused: "None of the documents on file states the investigators' conclusion" (the analysis document states conclusions).
  - B: "The documents don't give a count for this." (four, later five EIDL loans).
  - F: "The documents searched don't mention the role." and "don't mention the other crimes".
  - F: "The documents that name William Jamey Thompson don't state a sentence for William Jamey Thompson." right after quoting his five years.
  - E: "There is nothing in your archive about 'fda-recall-event-70738'".
  - In total about 36 wrongful refusals against about 10 correct.
- **Component (likely):** the when, conclusion, count and missing-slot gates in the answer pipeline. They work lexically on the top-ranked chunk, not on the retrieval set, and they ignore times of day and spelled-out numbers.
- **A fix must:** check the gate against the whole retrieved set. Accept times for "when" at minute precision, accept number words, and limit the conclusion gate to a probable-cause or official finding that really is absent.

### D11 — No event identity for same-template records · **misleading**

- **Symptom:** E's seven same-firm recalls are pooled. Plain-wording questions get other events' values, and "Also on file" lines come from other records. Facts were reachable only when the user already had the event ID, which the memo got from file names.
- **Component (likely):** entity and event resolution; the record ID (`Event ID: 70738`) is not used as the subject key.
- **A fix must:** key each structured record by its own ID. Resolve "the 2015 Listeria recall" to one event by year and reason, or list the candidates.

### D12 — Gaps: false, missed, or unlisted; aliases split · **misleading**

- **Quotes:**
  - F: "Shawn C. Simon: no charging document on file" and "Guy R. Miller: no charging document on file". Both are in the indictment, so these gaps are false.
  - A: no gap for Adkins, who was charged and has no disposition.
  - D: "gaps found: 39", never listed.
  - Aliases split: "Guy Miller" / "Guy R. Miller", "Michael Williams" / "Michael D. Williams", "Roy Gillar" / "Roy Johannes Gillar".
- **Component (likely):** the gap detector, fed by D5's participant extraction (charge events miss co-defendants), and alias merging that does not unify a middle name or initial.
- **A fix must:** raise "charged, no disposition on file" (Adkins), raise no gap for someone named in a charging document, merge middle-initial variants, and list every gap it counts.

### D13 — Garbled splices and wrong counts still ship · **cosmetic to misleading**

- **Quotes:**
  - A: "Caution: not found verbatim in the evidence: Nev However."
  - E: "…Product Products (recall number … Al The source says: Classification: Class I".
  - C: "Not found in the 13 documents searched" (the case has 3).
  - C and D: "the readings of these sources only partly agree" attached to concatenated fragments.
- **Component (likely):** the multi-document fallback composer.
- **A fix must:** refuse instead of splicing when no single passage answers, and count documents, not chunks.

---

## 5. Verdict

**No. On today's evidence the app does not make investigating these six real cases easier. On the rules path it made them harder and riskier.**

**What it does well, and genuinely:**
- It reads every format, including OCR of an image-only scanned PDF that the document-reading baseline could not open (F: the 36-count indictment and the $75,000).
- It quotes sources verbatim with a citation, so its errors can be caught.
- It refuses correctly on outcomes the record does not hold: Adkins, the NTSB probable cause, a Williams plea, deaths at Blue Bell.
- It builds per-person histories and correspondence profiles.
- It kept the same-surname Hutchinses apart on the headline facts.
- It answers exact structured fields when given a record ID.
- Custody hashing worked.

**What blocks the claim:**
1. **Wrong answers at normal confidence in every case.** 6 of 77 key facts were answered wrongly and 108 distinct wrong statements were made, several on the central question:
   - "Harold Mignott was sentenced to six years"
   - "Michael Williams was sentenced to 22 months"
   - "Roberto Soliman was pleaded guilty"
   - "No — the documents give mignott: Eric Breslin Esq."
   - "Mark Haedicke <mark.frevert@enron.com>"
2. **The trust label does not separate right from wrong.** About half of all answers are non-answers labelled "Quoted verbatim … no model was consulted" at 0.8, so every answer must be checked against its passage.
3. **The case workflow never found a real contradiction** in 30 of 30 runs, including the three in F, and it said "No conflicting accounts found in scope."
4. **The findings report needs correcting before anyone could use it.** It lists the prosecutor or judge as a defendant in 3 of 3 prosecutions, puts event dates a day early, misdates messages by years, and raises false gaps.
5. **Effort was not saved.** 523 questions over 30 rounds reached 57 of 77 facts, 3 of them wrong, and that was helped by the README. One read of about 70,000 words reached 76 of 77 with 0 wrong.

**What would have to be true to make the claim:**
- (a) On fresh real packs, wrong-at-confidence must be near zero for person, value and date. That requires D1, D2, D6 and D7 fixed, and D3 turning non-answers into refusals.
- (b) The workflow must surface the keyed contradictions (A transacting; F payment, fuel, camera) with both sources, and must not pool separate events (D4, D11).
- (c) The findings report must have correct roles and dates, so it can be handed on unedited (D5, D6, D12).
- (d) An app-only investigator must reach at least the baseline's facts with fewer documents' worth of reading.

This must be shown on a new set of real cases with an uncontaminated README, ideally with a human investigator and with the GUI tools (ACH, Watchlists, deconfliction, chronology, export) included. The Opus 5 path also needs evaluating separately; this run covers only the rules path.
