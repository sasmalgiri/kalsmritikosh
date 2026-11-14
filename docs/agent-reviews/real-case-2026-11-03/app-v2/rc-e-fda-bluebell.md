# rc-e-fda-bluebell — investigator memo (app v2, Online mode, claude-opus-5)

I worked this case only through the app.

**Memory disclosure.** I recognise the 2015 Blue Bell Listeria matter in general terms. Nothing below relies on that memory. Where my memory would fill a gap, such as an "all products" recall or plant names, I say the app's record is silent.

**Round caveat.** Only r1 ran with the AI reader working. In r2 and r3 every cloud call failed with "The provider returned HTTP 400: Your credit balance is too low to access the Anthropic API." Those two rounds are evidence-only (rules) answers.

## Conclusion

| Point | Rests on | Confidence |
|---|---|---|
| **Reason (2015).** Listeria monocytogenes. The 2015 Blue Bell event is FDA recall event 70738. Its stated reason: "Five patients who were treated in a single hospital in Kansas were infected with one of four rare strains of Listeria monocytogenes." | r1 q15; r2 q01, q08; r3 q01 (fda-recall-event-70738-20150313.txt) | High |
| **Who / what.** Recalling firm Blue Bell Creameries, L.P., 1101 S Blue Bell Rd, Brenham, TX. Event 70738 covers **286 product records** (F-2445-2015 onward). Examples: Country Cookie sandwich 3,008,184 units, Great Divide Bar 2,116,608, Sour Pop Green Apple 3,551,724, a quart item 911,871, sherbet cups, Blue Bell Scoops (bulk). Code information reads "All lots within expiry". | r1 q02, q01/q03 passages (70738) | High for the listed items |
| **Share of the product line.** The app never said whether 70738 was all of Blue Bell's products. Asked directly in r2 (q04) and r3 (q02), the rules path only repeated "286 product record(s)". The record as surfaced shows 286 product records and "All lots within expiry". An explicit "all products" statement was never shown. | r1 q02; r2 q04; r3 q02 | Medium (scope wide; "entire line" not shown) |
| **Total quantity of 70738.** Not answered. r1 q03 said "The documents searched don't say … (8 proposed statements did not check out)". r2 q07 only gave the header. | — | Record silent via the app |
| **FDA classification.** 70738 is **Class I**, "Voluntary: Firm initiated". Initial notification was "Two or more of the following: Email, Fax, Letter, Press Release, Telephone, Visit". | r2 q02, q15, q16 (70738) | High |
| **Key dates of 70738.** Initiated **March 13, 2015**. Center classification **June 19, 2015**. Report **July 1, 2015**. Terminated **November 3, 2016**. | r1 draft chronology items 1, 3, 4, 12 and gap 11, quoting "Recall initiation date: March 13, 2015 Center classification date: June 19, 2015 Report date: July 1, 2015 Termination date: November 3, 2016" | High |
| **Distribution / plants for 70738.** Not surfaced. r2 q05, q06 and r3 q03, q04 returned only the header or an irrelevant "Product type: Food". | — | Record silent via the app |
| **Other maker, same pathogen, separate event.** Jeni's Splendid Ice Creams LLC (Columbus, OH), event 71170, 134 product records. Reason: "Product may be contaminated with Listeria monocytogenes". **Class I**. Initiated Apr 22, 2015, classified Sep 9, 2015, terminated Nov 6, 2015. Distribution "National: AZ, CA, CO, … WA & WI". Quantities: ~1,513,227 pint units, ~61,267 three-gallon units, ~236,267 regular sandwiches, ~16,814 mini sandwiches; "All lots distributed were between July 1, 2013 and April 22, 2015". | r1 q11, q09 (in-case) and passages; r2 q10 (71170) | High |
| **Later Blue Bell recalls are separate events.** 74032, initiated May 3, 2016, Class II: "mispackaged and contain undeclared wheat and soy" (Rocky Road pints, 23,973; Texas and Louisiana). **75254**, initiated Sep 20, 2016, Class I, classified Jan 6, 2017, terminated Jul 18, 2017: cookie-dough products "containing cookie dough supplied by **Aspen Hills, Inc.**, due to the potential for them to contain Listeria monocytogenes" (Chocolate Chip Cookie Dough 4,288,629; Cookie Two Step 1,531,902; Blue Monster 8,909; Krazy Kookie Dough 3,699; AL, FL, GA, KY, LA, MS, NC, SC, TN, VA). 80360, Jun 21, 2018, Class III: labelling, undeclared milk (136 boxes). 84008, Oct 8, 2019, Class II: "Possible foreign material" (Butter Crunch, 1,626 units, "produced 8/26/19 in Sylacauga, AL"). 97481, Aug 21, 2025: undeclared almond, walnut, pecan (16,532 half gallons, Moo-llennium Crunch lid). | r1 q10, q04, q03 (in-case), q02, q09 (in-case); draft item 21 | High |
| **Same problem?** Only 75254 (2016) shares the pathogen, and its stated source is a supplier's ingredient, Aspen Hills cookie dough. The 2015 reason is the Kansas patient cluster, and no supplier is named there. The other later recalls are allergen, labelling and foreign-material events. The record does not say whether the 2016 Listeria is linked to the 2015 strains. | r1 q10; r3 q07 | High that these are separate events; linkage silent |

**Responsible party other than Blue Bell:** Aspen Hills, Inc., as cookie-dough supplier in the 2016 event 75254. Jeni's is a separate recalling firm, not a party to Blue Bell's problem.

## Timeline
- 2015-03-13: 70738 initiated (Listeria, Kansas hospital cluster)
- 2015-04-22: Jeni's 71170 initiated (Listeria)
- 2015-06-19: 70738 classified (Class I). 2015-07-01: reported.
- 2015-09-09: 71170 classified. 2015-11-06: 71170 terminated.
- 2016-05-03: 74032 initiated (wheat/soy). Classified 05-31, terminated 2017-02-14.
- 2016-09-20: 75254 initiated (Aspen Hills cookie dough, Listeria)
- 2016-11-03: 70738 terminated
- 2017-01-06: 75254 classified. 2017-07-18: terminated.
- 2018-06-21 → 07-09 → 08-09: 80360 (labelling/milk)
- 2019-10-08 → 10-29 → 2020-04-10: 84008 (foreign material, Sylacauga AL lot)
- 2025-08-21 → 08-28 → 12-10: 97481 (tree nuts)

## Contradictions
- **App-flagged (r1: 3, all AI).** "Count — Blue Bell Creameries: 286 vs 1", "4 vs 286", "4 vs 1". **All false positives.** These are product-record counts of different recall events, not two accounts of one fact. The gap list then turned them into leads: "The documents disagree … records: The charging document or the underlying list both counts rely on". The phrase "charging document" makes no sense for FDA recalls.
- **Found by me.** No real contradiction between records. r1 also contradicted itself: its gap list says "The recall classification (class) assigned on the center classification dates is not recorded" (gap 5, 70738) and "The reason or basis for any of the listed recalls is not stated" (gap 4). Yet r2 read both straight from the same document ("Classification: Class I"; "Reason for recall: Five patients…").

## Open questions (silent via the app)
- Whether 70738 covered Blue Bell's entire product line. Its total units, distribution pattern, and which plants made the products.
- How the Kansas cluster was linked to Blue Bell (sampling, testing) beyond the reason line.
- Whether the 2016 Aspen Hills Listeria relates to the 2015 strains.
- What the 2019 foreign material was. r3 q08: "The documents searched don't mention the foreign material."

## Round log
- **r1** (15 q; AI on; 22 min): good on reasons for later recalls, Jeni's, Aspen Hills, quantities, the discovery line. Missed or skewed every "the Blue Bell recall" question, which was answered from the wrong event. Contradictions 3 (all false), gaps 15, chronology 29 items (good).
- **r2** (16 q; **cloud failed, credit too low**): the rules path gave 70738 Class I, voluntary and notification method. Everything else echoed the document header.
- **r3** (8 q; **cloud failed again**): only the reason line and the multi-record reasons table were useful.
- INVALID/OCR: none.

## Experience log

**Helped**
- r1 q10 ("later ice cream recalls … for what reason?") gave all five later Blue Bell events with dates and reasons in one checked answer. That settled the "same problem or separate" question, including **Aspen Hills** as the outside party.
- The r1 draft chronology (29 items, each quoting "Recall initiation date / Center classification date / Termination date") was the most useful artefact. It is where I got 70738's dates, which the Ask answers never gave.
- r1 q15 "How was the problem discovered?" gave the Kansas hospital cluster line with its quote.
- r3 q07's rules table ("The reason for recall differs by record — each record states its own (these are separate records, not a disagreement between sources)") is a good, honest framing. It answered the wrong question (I asked about Jeni's), but it is useful.

**Slowed or misled**
- **The main 2015 question was refused.** r1 q01 "Why was Blue Bell ice cream recalled in 2015?" got "The documents searched don't say. The AI reader found no passage stating the answer among the 5 passages it read." It failed both in the archive and in the case, while the reason line exists in 70738 (q15 found it).
- **"The Blue Bell recall" was resolved to the wrong event.** "When did the Blue Bell recall start?" → "That recall was initiated on May 3, 2016" (74032). "When was … classified?" → "July 9, 2018" (80360). "When was … terminated?" → "August 9, 2018" (80360). "How did the FDA classify the Blue Bell recall?" listed 75254/74032/80360 and **omitted 70738**. None of these said it had picked one of several events. An investigator could easily report the wrong dates.
- Gap list errors: "The recall classification (class) assigned … is not recorded" and "The reason or basis for any of the listed recalls is not stated". Both are false.
- Three false "Count" contradictions (286 vs 1 etc.), with a lead to obtain "The charging document".
- "Needs review" items (r1 q08, q09, q13, q14). q08 and q09: the evidence-only side listed recalling firms or distribution per event, while the AI said "could not confirm". Half-right: the per-record distribution list was useful, but nothing for 70738. q13 "Is the later recall the same problem?": the evidence-only side quoted just the 70738 header, so no use. q14: AI recall numbers versus a header, a false disagreement. None of these flagged a real conflict.
- q12 "Was any recall caused by an ingredient supplied by another company?" answered only "That recall was a Class I recall initiated on September 20, 2016". It dropped the supplier name that q10 had found.
- Rules-only mode (r2/r3) answered at 0.8 confidence with the document header ("FDA Enforcement Report — recall event 70738 … 286 product record(s)") for at least 10 different questions: distribution, plants, quantity, code info, supplier. Other misses:
  - "Who supplied the cookie dough…" → a Rocky Road lot line
  - "same Listeria problem?" → a 2025 Moo-llennium carton line
  - "Which plant…" → "Product type: Food."
  - "Was recall event 70738 voluntary or mandated?" → "No — the documents give voluntary: Firm initiated."
- In r2 the findings summary said "0 unresolved conflict(s) and 0 evidence gap(s)". This came only because every contradiction call failed; the summary itself didn't say the check never ran (only the contradictions block did). Findings include junk like "employer: Splendid Ice Creams LLC" and "date: 2020-10-05". The cast of characters is all non-people: "Enforcement Report", "Press Release", "Blue Bell Rd", "Code Date".

**Effort.** 3 rounds, 39 questions. About 2 hours of wall time (queue waits ~45 min before r1, 22/13/13 min runs) and about 30 minutes of reading. Rephrasing by event id ("recall event 70738") was needed to get anything about the actual 2015 event.

**Would I rely on it?** Partly. It is good for the list of all events with reasons and dates (r1 q10, the chronology draft) and for spotting the third-party supplier. I would not rely on it for "the recall" questions on a multi-event archive: it silently picks a different event. I would not trust its gap list or count contradictions. In rules-only mode it is not usable for this structured-record case beyond single-field lookups (reason, classification).
