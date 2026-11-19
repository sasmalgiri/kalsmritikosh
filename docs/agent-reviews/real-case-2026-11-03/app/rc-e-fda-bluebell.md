# rc-e-fda-bluebell — investigator memo (app-only)

Investigator: agent (Claude), working only through `round.sh` / `runs/rc-e-fda-bluebell/*/answers.md`.
Build: c3e8c5b0, rules path (no AI model), 84 modules on. Rounds r1–r5, 84 questions.
I have general background knowledge that Blue Bell had a 2015 Listeria recall; I did not use it as evidence.
Disclosure: the bench README's case table (which I was told to read) states the 2015 initiation and termination
dates and the separate later events. Every claim below rests on an app answer, not on the README.

## Conclusion

| # | Point | Rests on (round/question → cited document) | Confidence |
|---|---|---|---|
| 1 | **The 2015 recall is FDA recall event 70738.** Recalling firm Blue Bell Creameries, L.P., 1101 S Blue Bell Rd, Brenham, TX. 286 product records: every Blue Bell product type listed, e.g. Country Cookie sandwiches (3,008,184 units), no-sugar-added bars (5,232,756 units), quarts, sherbet cups, all "All lots within expiry". | r2 q08, r1 q01 key passages → fda-recall-event-70738-20150313.txt | High (286 records); product list only partly seen |
| 2 | **Reason:** "Five patients who were treated in a single hospital in Kansas were infected with one of four rare strains of Listeria monocytogenes." | r2 q01, r4 q15 → 70738 | High |
| 3 | **Classification:** Class I. Voluntary, firm initiated. First notice to customers: "Two or more of the following: Email, Fax, Letter, Press Release, Telephone, Visit". | r2 q02, r3 q03, r3 q02 → 70738 | High |
| 4 | **Dates:** initiated March 13, 2015; FDA (center) classification June 19, 2015; enforcement report July 1, 2015; status Terminated; terminated November 3, 2016. | r2 q03–q06, r4 q10 → 70738 | High |
| 5 | **Distribution for 70738: not established.** Asked 5 ways (r1 q08, r2 q07, r3 q01, r4 q16, r5 q07/q08); never answered for this event. | — | Open |
| 6 | **The later recalls are separate events.** Event IDs, dates and causes differ: <br>• **75254** (initiated Sept 20, 2016; Class I; classified Jan 6, 2017; terminated July 18, 2017; 10 SE states): Listeria risk in Chocolate Chip Cookie Dough, Cookie Two Step, Krazy Kookie Dough and Blue Monster, "containing cookie dough supplied by Aspen Hills, Inc." The responsible party other than Blue Bell is **Aspen Hills, Inc.** (supplier). <br>• **74032** (May 3, 2016; Class II; classified May 31, 2016; terminated Feb 14, 2017; TX & LA): Rocky Road pints (23,973) "may have been mispackaged and contain undeclared wheat and soy". <br>• **80360** (initiation June 21, 2018 per the file name and the pooled date list; Class III; classified July 9, 2018; terminated Aug 9, 2018; AL, GA, LA, MS, NC, OK, TX): 136 boxes of vanilla 3 oz cups not labeled for retail sale, so missing nutrition and ingredient panels and the milk allergen. <br>• **84008** (Oct 8, 2019; Class II; classified Oct 29, 2019 per the pooled list; terminated Apr 10, 2020; 9 SE states): "Possible foreign material in product." <br>• **97481** (Aug 21, 2025; Class II; classified Aug 28, 2025; terminated Dec 10, 2025; 16 states + PR): "undeclared almond, walnut, and pecan", Chocolate Chip Cookie Dough cartons with a "Moo-llennium Crunch lid". | r2 q10/q11, r3 q05–q07 (75254); r2 q13, r3 q08, r4 q01/q05/q08 (74032); r2 q14, r3 q09, r4 q02 (80360); r2 q15, r3 q10, r4 q03/q06 (84008); r2 q16, r3 q11, r4 q04/q07/q09, r5 q11 (97481) | High for causes and classes; medium for the two dates I only got from pooled lists / file names |
| 7 | **The look-alike: Jeni's Splendid Ice Creams LLC** (Columbus, OH), event 71170: a separate firm and event. Listeria ("Product may be contaminated with Listeria monocytogenes"), Class I, initiated April 22, 2015, terminated Nov 6, 2015, 134 product records, nationwide distribution (18 states listed). Not part of the Blue Bell recall. | r2 q17–q19, r3 q12/q13, r4 q17 → 71170 | High |
| 8 | Whether the 2016 Aspen Hills Listeria (75254) is connected to the 2015 Listeria (70738): the records only show two events with different causes as stated (Kansas patients vs supplier cookie dough). Nothing in the app's answers links them. I treat them as separate. | r2 q01 vs r2 q10; r3 q15 (app gave no answer) | Medium (records show no link; they don't prove there isn't one) |

## Timeline (reconstructed)

- 2015-03-13: Blue Bell initiates recall 70738 (Listeria; five Kansas hospital patients).
- 2015-04-22: Jeni's initiates its own Listeria recall 71170 (separate firm).
- 2015-06-19: FDA classifies 70738 Class I. 2015-07-01: report date.
- 2015-11-06: Jeni's 71170 terminated.
- 2016-05-03: 74032 Rocky Road mispackaging (wheat/soy), Class II on 2016-05-31; terminated 2017-02-14.
- 2016-09-20: 75254 Aspen Hills cookie dough Listeria, Class I on 2017-01-06; terminated 2017-07-18.
- 2016-11-03: 70738 terminated.
- 2018-06-21: 80360 unlabeled vanilla cups, Class III on 2018-07-09; terminated 2018-08-09.
- 2019-10-08: 84008 foreign material, Class II on 2019-10-29; terminated 2020-04-10.
- 2025-08-21: 97481 undeclared tree nuts, Class II on 2025-08-28; terminated 2025-12-10.

## Contradictions / discrepancies

- None between sources that I could find: each record is a separate event with its own values. Note that 75254's Listeria **is** a second Listeria recall. A careless reading would merge it into 2015; the records keep it separate, naming the Aspen Hills supplier.
- The **app** invented contradictions. Every non-event-specific question got "Your archive carries conflicting values for …" (r1 q04–q08, q13; r5 q01, q02, q04, q08, q12), e.g. "Note: your sources disagree on classification — all 3 values are shown above." These are values from different recalls, not disagreements. Meanwhile the workflow reported "contradictions found: 0; gaps found: 0".

## Open questions

- 70738 distribution pattern (never answered; see above), and the full 286-product list and total quantity (the app only quoted bits of the product table).
- Which products 84008 covered (r4 q12: header line only).
- What the records do **not** show: any FDA inspection finding, plant location or cause inside Blue Bell's plants; deaths; a link between the Kansas strains and a specific product; whether the 2016 Aspen Hills dough connects to 2015. Enforcement records hold none of this.

## Round log

- **r1** (18 q, plain wording): reason, products, scope, dates, class, distribution, later recalls, Jeni's, allergens. Nearly unusable: answers pooled all 7 events ("conflicting values") or quoted an unrelated product line. The findings list showed the raw values (Listeria, Aspen Hills, Nov 3, 2016) with no event attached.
- **r2** (19 q, by event ID): reason/class/dates/status per event. Breakthrough: 70738 reason (Kansas patients), Class I, Mar 13 2015, Jun 19 2015, Nov 3 2016; 75254 Aspen Hills; reasons for 74032/80360/84008/97481; Jeni's 71170 reason/class.
- **r3** (18 q): notification, voluntary, class per later event, 75254 dates/distribution, Jeni's dates, the "same problem?" traps. Classes found for all events; Jeni's initiated Apr 22 2015. The trap and plain "all products" questions failed.
- **r4** (17 q): distribution/dates/products for later events, Kansas hospital, Jeni's count. Distributions and dates found for 74032/80360/84008/97481; 70738 distribution still missing.
- **r5** (12 q, plain re-ask as a new user would): end/begin date, seriousness, Listeria events, Aspen Hills in 70738, distribution. Plain wording still failed ("When did the Blue Bell Listeria recall end?" → a list of initiation dates); 97481 product identified.

## Experience log

**Effort.** 5 rounds, 84 questions. About 30 of them (r2–r4, event-ID questions) produced almost all usable facts.

**Where the app made the work easier**
- Once I addressed records by event ID, answers were exact, short and attributed: "Reason for recall: Five patients who were treated in a single hospital in Kansas were infected with one of four rare strains of Listeria monocytogenes." / "Termination date: November 3, 2016." / "Classification: Class I." Each came with an "Also on file" line from the same record (e.g. "Report date July 1, 2015 · Recall initiation date March 13, 2015") that served as a free cross-check.
- It kept the Jeni's look-alike separate when asked by event, and its refusal on a bad reference was clear and well-reasoned (r5 q07: "This is a deliberate refusal, not a search that came back thin…", listing the references it does hold).
- Cited file names carry the event ID and initiation date, which is how I learned the IDs to ask with.

**Where it made the work harder or misled me** (exact words)
- **Pooling across events, labelled as a source conflict.** r1 q05 "What classification did FDA give the 2015 Blue Bell recall?" → "Your archive carries conflicting values for classification: • Class I • Class II • Class III … Note: your sources disagree on classification". Likewise initiation dates (r1 q04), termination dates (r1 q07: the four dates listed **omit** the true Nov 3, 2016), distribution (r1 q08). This misstates the record and hides the answer.
- **Wrong field.** r5 q01 "When did the Blue Bell Listeria recall end?" → "Your archive carries conflicting values for recall initiation date: • August 21, 2025 • June 21, 2018 • March 13, 2015 • May 3, 2016".
- **Wrong event, high confidence (0.8), verbatim label.** r1 q02 "What products did Blue Bell recall in 2015?" → "F-1407-2016 | BLUE BELL ICE CREAM Rocky Road pint | 23,973 pints" (a 2016 event); r1 q03 "How many products were covered by the 2015 Blue Bell recall?" → the 2018 vanilla cups line "136 boxes"; r1 q18 recall number → the 2016 Rocky Road number. Each with "(Quoted verbatim from the cited document; no model was consulted.)".
- **Header-line non-answers.** At least 14 answers were just "The document states: “FDA Enforcement Report — recall event 70738 Blue Bell Creameries, L.P. — 286 product record(s)”", for distribution, lots, supplier, foreign material, "Is Aspen Hills mentioned in recall event 70738?" (r5 q06) and "Is the Listeria in recall event 75254 the same problem…?" (r3 q15). r1 q12 "Which cookie dough supplier…" and r2 q12 returned the 70738 header although the Aspen Hills sentence was in the ledger.
- **r1 q01 / q10 / r3 q16** ("Why did Blue Bell … recall … in 2015?") gave "Extracted facts" mixing firms and years ("Employer: Splendid Ice Creams LLC", "Reasonforrecall: Product may have been mispackaged and contain undeclared wheat and soy.") and then "A supported narrative could not be generated within the current analysis budget." The single most important question in the brief got no answer in plain wording, three times.
- r5 q09 "How many units of Blue Bell Country Cookie sandwiches were recalled?" → "All American Cup … | 94,311 units" (wrong product; the Country Cookie figure 3,008,184 had appeared in r1).
- **Findings report:** "66 finding(s) are supported … 0 dated and 66 undated finding(s)", a flat list like "Undated — classification: Class III" / "Undated — terminationdate: November 3, 2016" with no event attached, truncated at "Undated — eventid: 803", and in a different order and subset between r1 and r2 on identical documents. Not usable as a case report; "0 evidence gap(s)" despite the missing distribution.

**Would I trust it on a real case?** Not unsupervised. The facts I report are correct as far as the quotes show, but I only got them by learning the event IDs from file names and asking one field per event per question, which a real user starting from the brief would not know to do. With plain questions the app's main failure is to merge separate recalls and present them as a source conflict. An investigator who believed that would report a recall "classified Class I, II and III" with a wrong end date.
