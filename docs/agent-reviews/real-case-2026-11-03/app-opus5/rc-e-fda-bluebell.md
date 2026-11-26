# rc-e-fda-bluebell — investigator memo (AGENT, app in Online mode / Opus 5)

Investigator: agent, working only through `round-opus5.sh` answers (5 rounds, 83 questions over the whole archive,
each also asked inside the case). Sources read: README-opus5.md, briefs/rc-e-fda-bluebell.md,
runs-opus5/rc-e-fda-bluebell/r1..r5/answers.md. Nothing else.

Recognition: I recognise the matter in general terms (Blue Bell's 2015 Listeria recall). Nothing below rests on that
memory. Every point is tied to an app answer.

## Conclusion

The archive holds seven separate FDA enforcement-report events. One is the 2015 Blue Bell Listeria recall. One is an
unrelated Listeria recall by a different maker (Jeni's). Five are later Blue Bell recalls, each for a different reason.
Only one of the later five is a Listeria recall again, and its cause was an ingredient from an outside supplier
(Aspen Hills, Inc.).

| # | Point | Rests on | Confidence |
|---|---|---|---|
| 1 | **Reason for the 2015 recall (event 70738):** "Five patients who were treated in a single hospital in Kansas were infected with one of four rare strains of Listeria monocytogenes." | r2 q01, cites fda-recall-event-70738 | High |
| 2 | **Who / what:** Blue Bell Creameries, L.P., 1101 S Blue Bell Rd, Brenham, TX. 286 product records. Voluntary, firm-initiated. | r1 q04, r2 q01/q03, r4 q12 | High |
| 3 | **Scope:** many lines, each marked "all lots within expiry" or "all lot codes within expiry". Examples: Country Cookie sandwich 3,008,184 units; No Sugar Added coated bars 5,232,756 units; a quart line 911,871 units; sherbet cups; Citrus Swirl cup 1,128 units; DZ strawberry frozen-yogurt cup 54,626 units; All American Cup 94,311 units; an institutional vanilla sandwich/mini-sandwich line 10,636,220 units. This strongly suggests the whole product line within expiry was recalled. The app never stated this, never gave a total, and never answered "all products?" directly. | r1 q01 passages, r3 q10 citation, r5 q07, r4 inside-case q03 | Medium (scope); total units unknown |
| 4 | **FDA classification:** Class I. | r3 q01 | High |
| 5 | **Dates:** initiated March 13, 2015; classified June 19, 2015; report date July 1, 2015; terminated November 3, 2016. Status: Terminated. | r2 q02/q03, r4 q12/q14 | High |
| 6 | **Distribution:** "AL, GA, LA, MS, NC, OK, TX". The app gave this at confidence 0.45, with mixed citations. Asked directly twice (r3 q07, r5 q01), it returned only the report header. | r4 q01 | Low |
| 7 | **Jeni's Splendid Ice Creams LLC (event 71170)** is a separate firm and a separate event. Columbus, OH. Started April 22, 2015. Reason: "Product may be contaminated with Listeria monocytogenes." Class I, classified September 9, 2015, terminated November 6, 2015. National distribution to 18 states. 134 product records: about 1,513,227 pint units and about 61,267 three-gallon buckets, lots distributed July 1, 2013 – April 22, 2015. Nothing in the answers links it to Blue Bell. | r2 q07, r3 q02/q09/q10, r4 q03/q11, r5 q02/q03 | High (facts); Medium ("not linked" is an absence) |
| 8 | **Later Blue Bell events: each is a separate problem.** | | |
| 8a | 74032, May 3, 2016. Rocky Road pint, 23,973 pints, lot 022918576. "mispackaged and contain undeclared wheat and soy". Class II, classified May 31, 2016, terminated February 14, 2017. | r1 q02, r2 q08, r3 q03, r4 q15; Class II from the report-header passage in r1 q01 | High |
| 8b | **75254, September 20, 2016. Listeria again, from an outside supplier:** "containing cookie dough supplied by Aspen Hills, Inc., due to the potential for them to contain Listeria monocytogenes". Four products: Chocolate Chip Cookie Dough, Cookie Two Step, Krazy Kookie Dough, Blue Monster. Class I, classified January 6, 2017, terminated July 18, 2017. Distributed to AL, FL, GA, KY, LA, MS, NC, SC, TN, VA. Quantities: not obtained. | r2 q09/q16, r3 q08, r5 q04; Class I from the header passage | High |
| 8c | 80360, June 21, 2018. Homemade Vanilla 3 oz cups, 24 per box, "Not Labeled For Retail Sale", 136 boxes, best-by 5/10/2020. Sold individually without a nutrition panel or ingredient statement, and milk not declared. Class III, classified July 9, 2018, terminated August 9, 2018. | r2 q10, r3 q04, r4 q02 (passage), r5 q05 | High |
| 8d | 84008, October 8, 2019. "Possible foreign material in product." Class II, classified October 29, 2019, terminated April 10, 2020. Product and quantity: not obtained. | r2 q11, r3 q05 | High (product unknown) |
| 8e | 97481, August 21, 2025. "undeclared almond, walnut, and pecan". Chocolate Chip Cookie Dough cartons "with a Moo-llennium Crunch lid", which reads as a lid mix-up. Class II, classified August 28, 2025, terminated December 10, 2025. Quantity: not obtained. | r2 q12, r3 q06, r5 q06/q09 | High (reason/dates); Medium (product, which the app returned for a different question) |
| 9 | **Responsible party other than Blue Bell:** Aspen Hills, Inc., as the cookie-dough supplier in 75254. The archive holds no recall by Aspen Hills itself. | r2 q09; r4 q17 (only Blue Bell and Jeni's appear as recalling firms) | High |

**What the records do not show.** As far as the app surfaced them, the records do not show:
- which plant or facility made the product, or any inspection finding (r5 q13 returned only the header);
- the contamination source in 2015;
- illnesses beyond the five Kansas patients, or any deaths;
- any illness tied to Jeni's (r5 q14 returned only the header);
- total 2015 units;
- quantities for 75254, 84008 and 97481;
- the 84008 product;
- how the distribution patterns "Texas and Louisiana" and "AL…TX" map to events, beyond the low-confidence 70738 reading.

## Timeline

- 2013-07-01 → 2015-04-22: Jeni's lots distributed (71170).
- 2015-03-13: Blue Bell recall 70738 begins (Listeria; five Kansas patients).
- 2015-04-22: Jeni's recall 71170 begins (Listeria).
- 2015-06-19: 70738 classified Class I. 2015-07-01: report date.
- 2015-09-09: 71170 classified Class I. 2015-11-06: 71170 terminated.
- 2016-05-03: 74032 (Rocky Road; wheat/soy). Classified 05-31 (Class II). Terminated 2017-02-14.
- 2016-09-20: 75254 (Aspen Hills cookie dough; Listeria). Classified 2017-01-06 (Class I). Terminated 2017-07-18.
- 2016-11-03: 70738 terminated.
- 2018-06-21: 80360 (unlabelled vanilla cups; milk). Classified 07-09 (Class III). Terminated 08-09.
- 2019-10-08: 84008 (foreign material). Classified 10-29 (Class II). Terminated 2020-04-10.
- 2025-08-21: 97481 (undeclared tree nuts). Classified 08-28 (Class II). Terminated 12-10.

## Contradictions between sources

- **No genuine contradictions found.** Each document is a different recall event, so differing dates, classes and
  reasons are expected.
- The app repeatedly printed false conflicts. It put values from different events side by side as if they were
  competing readings of one fact, for example: "Your archive carries conflicting values for classification: • Class I •
  Class II • Class III … Note: your sources disagree on classification". It did the same for the start date,
  termination date, reason, recalling firm and firm address. That is a false alarm on every one.
- The case workflow reported "contradictions found: 0; gaps found: 0". That is right in effect, but the Ask answers
  said the opposite.

## Open questions and why

- **Total 2015 units, and whether literally every product was recalled.** The app returns one product row at a time,
  or the header "286 product record(s)". There is no totals view.
- **Distribution for 70738.** Direct questions returned the header.
- **Products and quantities for 75254, 84008 and 97481.** Questions returned the header "4 product record(s)" /
  "1 product record(s)".
- **Plants, inspections, root cause.** Probably not in the records, but the app never said "not on file". It returned
  the header.

## Round log

- **r1 (16 q):** broad questions. Got the reason list (shuffled across events), a Class I/II/III "conflict", dates
  "in conflict", and the Aspen Hills reason inside a conflict list. Products were answered with the 2016 Rocky Road row.
  The supplier question was refused although Aspen Hills was in the archive.
- **r2 (17 q):** switched to per-event-ID questions. This unlocked a clean reason and dates per event.
- **r3 (18 q):** classification, distribution, Jeni's and products per event. Classification dates came back instead
  of classes for several events. Product questions returned headers.
- **r4 (17 q):** totals, scope, Jeni's, Class I list. Mixed. "Which recall events are Class I?" got the 3-value
  "conflict".
- **r5 (15 q):** start dates per event, products by reason, absence questions. Start dates were clean. Products by
  reason gave "Product type: Food."

## Experience log

**Where it helped**
- **Once I asked per event ID, the field lookups were precise and well cited.** Reason, classification date, report
  date and termination date for each event came back one-line clean at 0.8 (r2 q01–q12, r5 q03–q06). That gave me the
  per-event backbone of the case, about 30 facts, quickly.
- **The full verbatim reason strings were the key to the case.** The Aspen Hills sentence (r1 q10, r2 q09) is the
  "other responsible party". The Kansas-patients sentence (r2 q01) is the 2015 cause. The app quoted both exactly.
- **Some product rows carried quantity and lot codes verbatim.** Rocky Road 23,973 pints; 136 boxes best-by
  5/10/2020; Jeni's 1,513,227 pints.

**Where it slowed or misled me** (exact words)
- **False conflicts across separate events.** This happened in about 15 answers: "Your archive carries conflicting
  values for reason for recall: … Note: your sources disagree on reason for recall — all 4 values are shown above."
  (r1 q10, r1 q13, r2 q13, r2 q14, r5 q10). A beginner would think FDA records contradict each other. They do not.
- **A wrong answer, framed as a conflict.** "Which Blue Bell recall events were for Listeria monocytogenes?" got "Your
  archive carries conflicting values for event id: • 70738 • 74032 • 75254 • 80360" (r3 q17). 74032 is wheat/soy and
  80360 is a labelling/milk recall. Only 70738 and 75254 are Listeria.
- **Wrong scope.** "Which Blue Bell products were recalled?" and "Did the 2015 Blue Bell recall cover all of its
  products?" both got "F-1407-2016 | BLUE BELL ICE CREAM Rocky Road pint | 23,973 pints" (r1 q02/q03), a 2016 row,
  labelled "Quoted verbatim … no model was consulted" at 0.8. "Was the 2015 Blue Bell Listeria recall of all products
  within expiry?" got the same 2016 row (r3 q18).
- **Wrong refusal.** "Who was the supplier responsible for any later recall?" got "The documents searched don't mention
  the supplier responsible." (r1 q12). The Aspen Hills sentence is in the archive.
- **Header-only answers at 0.8.** For quantity, distribution, products, voluntary/mandated, plants, illness and lot
  codes, the app returned "The document states: “FDA Enforcement Report — recall event 70738 Blue Bell Creameries, L.P.
  — 286 product record(s)”" (r1 q04, r2 q04–q06, r3 q07/q11–q14, r4 q05–q08/q13, r5 q01/q13–q15). That is about 20
  answers that look sourced but answer nothing.
- **Wrong row for a quoted figure.** "Which Blue Bell product had 10,636,220 units recalled?" got the 2018 "136 boxes"
  row (r4 q04, r5 q08). "Total number of units recalled by Blue Bell in 2015" got the same 2018 row (r4 q02).
- **Wrong product, or no product.** "Quantity for the Blue Bell Chocolate Chip Cookie Dough recall in 2016" returned
  the 2025 "Moo-llennium Crunch lid" row (r5 q09). "What product had possible foreign material?" got "Product type:
  Food." (r5 q11). The same happened for the tree-nut question (r5 q12) and for plants (r1 q15).
- **Mis-extraction noise in every answer footer.** "Employer: Splendid Ice Creams LLC" (a firm parsed as an employer)
  and "Also on file: Date 05/10/2020" (the best-by date on the 2018 cup row) were attached to unrelated answers. I spent
  a question (r3 q16) finding out what 05/10/2020 was, and the app could not tell me.
- **The classification question got the classification date.** "What classification did recall event 74032 receive,
  and when was it classified?" got "Centerclassification date: May 31, 2016." with no class (r3 q03, q05, q06). I had
  to read the class from the header passage.
- **Inside the case, a wrong "absent" answer.** "None of the 7 document(s) searched carries a recall number. A recall
  number is not among the fields this archive's documents contain (nearest on file: account number)." (r5 q07, inside
  case). Recall numbers such as F-2445-2015 are everywhere.
- **The findings report was of no use.** It listed "66 finding(s)… 0 dated and 66 undated", made of key:value
  fragments ("Undated — eventid: 70738", "Undated — recallinitiationdate: April 22, 2015") not tied to events. It
  showed 0 gaps.

**The model's contribution.** "model calls" shows {'claude': 1} or {'claude': 2} on 68 of 83 whole-archive answers,
and none on all inside-case answers. Yet every run footer reads "AI model: none (rules path)". Every answer is in
rules-path form: verbatim quote "no model was consulted", field lookup, conflict list, or the "Extracted facts …
A supported narrative could not be generated within the current analysis budget" fallback (r1 q01, q11). I saw **no
answer whose text was composed by the model.** Only one visible effect: "_(answered as: …)_" rewording, seen in
rc-f. In practice the Opus 5 calls added nothing I could see. The model never turned the per-event rows into a summary
such as "seven events, two Listeria, one supplier-caused".

**Effort.** 5 rounds, 83 questions, about 1–2 minutes of app time per round. About 40 % of answers were usable as
asked. I had to translate every natural question into "recall event NNNNN + field" to get a clean answer, and assemble
the case table myself.

**Would I rely on it?** As a **field-lookup and verbatim-citation aid for structured records, yes**: once you know the
event IDs, reason, class, dates and distribution come back exactly. **Not** for:
- scoping questions ("all products?", totals);
- cross-event comparison: it calls separate events "conflicting";
- "which events share X": the answer was wrong;
- the findings report.

A beginner asking in plain words would have been told the FDA records contradict each other and that the 2015 recall
was a Rocky Road pint.
