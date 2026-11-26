# rc2-k-fda-sabra — investigator memo (app-v2)

**The run's main condition: the Opus 5 cloud readers never ran.** In every round (r1–r4), every cloud call failed with
"The provider returned HTTP 400: Your credit balance is too low to access the Anthropic API. Please go to Plans &
Billing to upgrade or purchase credits." (r1 Run line: answerComposer 26 calls (26 failed), contradictionReader 6
(6 failed), draftReader 1 (1 failed), questionInterpreter 14 (14 failed), questionRewriter 12 (12 failed), roleReader 1
(1 failed); r2–r4 were the same). Every answer ends "(The AI reading could not be used — the AI reader did not
answer. This is the evidence-only reading.)" and shows "model calls: none". So this memo measures the **rules /
evidence-only path running in Online mode with a dead key**, not Opus 5. The app said honestly that the AI was not
used. It did not tell the user in the answer itself that the cause was billing; that appears only in the workflow's
"failed calls" lines.

Recognition: I have a general memory of a 2015 Sabra hummus Listeria recall. I did not use it. Every point below rests
only on the app's answers.

## Conclusion (from the app's answers)

| Point | Finding | App answer / citation | Confidence |
|---|---|---|---|
| Firm | Sabra Dipping Company, LLC, 15900 Sabra Way, Colonial Heights, VA 23834-5935 (event 70934) | r1 q01 table "Event id 70934: Sabra Dipping Company, LLC"; r1 q03 / q14 passage [fda-recall-event-70934-20150407.txt] | High |
| Which recall | Event ID 70934. It is the only 2015 record (initiated April 7, 2015) | r2 q05 "Recall initiation date: April 7, 2015." [70934] | High |
| How found | "Michigan Dept. of Agriculture collected a sample of Sabra Hummus that came up positive for L. Monocytogenes. Baltimore District is working with VDACS to investigate." | r1 q08 / r1 q03 [70934] | High (verbatim) |
| Classification | Class I | r1 q04 "Classification: Class I." cited passage [70934] "Class I"; center classification date April 28, 2015 (r2 q06) | High |
| Distribution | "The product was distributed nationwide." | r2 q09 [70934] | High |
| Begin / end | Initiated April 7, 2015; classified April 28, 2015; reported May 6, 2015; terminated August 26, 2015; status Terminated | r2 q05, q06, q07, q13; r4 q10 [70934] | High |
| Voluntary? | "Voluntary: Firm initiated" | r2 q11 [70934] (the answer was worded oddly: "No — the documents give voluntary: Firm initiated") | High |
| Notification | "Two or more of the following: Email, Fax, Letter, Press Release, Telephone, Visit" | r4 q09 [70934] (r3 q06 gave the same value but cited all 5 documents) | Medium-high |
| Products / quantity | **Not established.** The app said only that the record holds "5 product record(s)". It never showed the 70934 product table: no product names, sizes, quantities, recall numbers or codes, across 8 differently worded questions | r1 q02, r2 q01–q04, q11, r3 q02–q05, r4 q02–q04, q11 | — (gap) |
| Recall number | Not established. The app said "None of the 5 document(s) searched carries a recall number … (nearest on file: account number)". This is false: the cited passages show recall numbers in other records (F-2295-2014, F-0386-2021) | r1 q07, r2 q03 | — |
| Illnesses | Silent. The app never addressed the question; it only quoted the header line | r1 q09, r2 q10 | Silent (app gave no answer) |
| Product type | Food | r2 q12 | High |

Keeping it separate from the other recalls. The archive holds 5 records (r1 q01, q06, q08):
- 68614 Hot Mama's Foods (Lansal, Inc.), Wheeling IL: initiated May 15, 2014; about 14,860 lb of hummus and dips (Archer Farms brand); Listeria; US nationwide; terminated May 17, 2016; Class I (r4 q07).
- 75765 Sabra, South Chesterfield VA: initiated November 18, 2016; 20 product records; Listeria; "Thru out the US and three foreign countries"; terminated February 17, 2017; Class I (r4 q05).
- 75787 LSG Sky Chefs, Coraopolis PA: initiated November 20, 2016; 389 sandwiches. The firm was notified on 11/20/16 that Sabra Red Pepper Hummus had been recalled for Listeria, and that hummus was an ingredient in a 7-11 sandwich. This is downstream of a Sabra recall (most likely 75765, by date, but the app did not link them). Distribution OH, PA, NY, WV; terminated July 14, 2017; Class I.
- 87614 Sabra: initiated March 26, 2021; Salmonella; Classic Hummus 10 oz; 2,160 cases, 16,200 lb; terminated May 27, 2021; Class I (r4 q06).

## Timeline (event 70934)
- 2015-04-07: recall initiated (r2 q05)
- 2015-04-28: center classification, Class I (r2 q06, r1 q04)
- 2015-05-06: enforcement report date (r2 q07)
- 2015-08-26: terminated (r2 q13)
- The date the Michigan sample was collected is not given by the app.

## Contradictions
- App flagged: none. Contradiction check "0 by rules, 0 by the AI reading", with 6 failed AI calls.
- I found: no genuine contradictions. Sabra's address is Colonial Heights in 70934 and South Chesterfield in 75765/87614 (same street and ZIP; r1 q14). The app listed this as "The address is ambiguous across the evidence". It is a record-level difference, not a dispute, and the app could not explain it (r2 q14 returned only the header). The app correctly framed the cross-record differences as "separate records, not a disagreement between sources" (r1 q01/q05/q06/q08). That was right and useful.

## Open questions
1. What products, sizes and quantity were in event 70934's five product records, and what were the recall numbers and codes? The app never surfaced them.
2. Illnesses: the record as surfaced is silent.
3. When and where the Michigan sample was collected; what VDACS found.
4. Whether LSG Sky Chefs 75787 traces to Sabra 75765.

## Round log
- r1 (14 Qs): broad. Firm, Class I, the Michigan finding, nationwide, termination and the record-by-record tables came out. Products, quantity, recall number and illnesses failed. All cloud calls failed (credit balance).
- r2 (14 Qs): pinned to "event 70934". Initiation, classification, report and termination dates, voluntary status, distribution and type all came out cleanly. Products, quantity and codes still returned only the header.
- r3 (13 Qs): product-name wording. This misled me: "How many cases of Sabra hummus were recalled in April 2015?" was answered with the 2021 Salmonella record ("2160 cases, 16,200 lbs", [87614]) at confidence 0.8.
- r4 (12 Qs): per-event classification (all Class I), notification, status. The product table was still unreachable. "Colonial Heights Sabra recall record" was answered from 87614.
- Stopped at 4 rounds: four rounds of rewording did not reach the 70934 product table, and the cloud path was dead.

## Experience log

**Where it helped**
1. Event-pinned field questions were exact and fast. "Recall initiation date: April 7, 2015." / "Termination date: August 26, 2015." / "Classification: Class I." Each came from the right record at about 1 s.
2. The record-by-record tables kept the five recalls apart without merging them, with this framing: "each record states its own (these are separate records, not a disagreement between sources)". That is exactly what the brief asked for. It gave me the archive's shape in one question.
3. Honest about the AI: every answer says "the AI reading was not used", and the workflow lists each failed call with the provider's reason.

**Where it slowed or misled me**
1. Wrong record, stated confidently. Asked about April 2015, it answered from the 2021 Salmonella recall: "The document states: “Expiration date 4/26/21 | 2160 cases, 16,200 lbs | 300067.”" (r3 q03, confidence 0.8). Asked about "the Colonial Heights Sabra recall record", it answered from 87614 (South Chesterfield): "F-0386-2021 | Sabra Dipping Co, Classic Hummus ,10oz." (r4 q03). "What hummus sizes … recalled by Sabra in 2015?" was answered from Hot Mama's 2014 record (r4 q04). A careless investigator would report the wrong quantity.
2. Header-line non-answers at confidence 0.8. Eight different product, quantity, illness and code questions got "The document states: “FDA Enforcement Report — recall event 70934 Sabra Dipping Company, LLC — 5 product record(s)”" with no sign that it did not answer the question. The confidence of 0.8 is wrong for a non-answer.
3. A false absence claim. "None of the 5 document(s) searched carries a recall number. A recall number is not among the fields this archive's documents contain" (r1 q07). Yet its own cited passage shows "Products (recall number | product description | quantity | code information): F-2295-2014".
- Others: q13 "voluntary … how communicated" was answered with "Best By: 1119, 1120, 1121. | 389 sandwiches" (LSG). Garbled stitched answers, flagged by the app itself as "Caution: not found verbatim in the evidence: Prod The, Pr The." q14 inside the case answered with LSG's address. The findings report is 55 "Undated — fieldname: value" lines with no record attribution (for example "Undated — terminationdate: May 17, 2016"), so it is unusable without the tables. Drafts produced no chronology and a cast that is all non-persons ("Enforcement Report", "Press Release", "Sabra Way").

**"Needs review" items:** none were raised. With the AI dead, no cross-check could run. The "ambiguous address" flag was a reasonable heads-up but not a real conflict.

**Effort:** 4 rounds, 53 questions, about 1.5 h of queue waiting. My own work was mostly rewording questions to get past header-line answers.

**Would I rely on it?** As an aid, for field lookups pinned to an event ID and for the "differs by record" overview: yes. Those were correct and cited. For quantities, product lists or anything not pinned to a record: no. It answered from the wrong recall with high confidence, and it could not reach the key product table at all. Every number must be checked against the record ID shown in the citation.
