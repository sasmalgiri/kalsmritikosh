# rc-c-ntsb-moncks-corner — investigator memo (app v2, Online mode, claude-opus-5)

Investigator: agent (Claude), working only through the app. Rounds: r1 (16 questions), r2 (18 questions).
Sources read: README-v2.md, the brief, runs-v2/rc-c-ntsb-moncks-corner/r1/answers.md and r2/answers.md.

**Recognition disclosure.** I recognise this accident from memory (2015 Moncks Corner Cessna 150 / F-16
midair). I remember the NTSB's final probable cause roughly. That memory is not evidence. Everything below
rests on the app's answers, and I note where my assessment happens to match what I remember.

**Run-quality warning.** In r2 the Anthropic account ran out of credit partway through. The case
workflow (contradictions, drafts, roles) failed on every call ("The provider returned HTTP 400: Your credit
balance is too low to access the Anthropic API…"). In-case answers q09–q18 fell back to the rules-only
reading. r2's whole-archive answers all had model calls and are usable. The r2 in-case fallback answers are
assessed in the Experience log below.

## Conclusion

**What happened (stated in the records, high confidence).**
- A civil Cessna 150M (N3601V) took off VFR from Berkeley County Airport (MKS), a nontowered field, about
  1057 for Grand Strand (North Myrtle Beach). No flight plan was filed. The pilot never contacted ATC and did
  not have to (r1 q01: factual-narrative.pdf "For the duration of the flight, the pilot of the Cessna did
  not contact any ATC facilities, nor was he required to do so."; analysis.txt "had not requested traffic
  advisory (flight-following) services"). Its mode C transponder worked and it showed on CHS radar as a 1200
  code (r1 q09).
- A USAF F-16CM was flying IFR on a single-ship operational check flight from Shaw AFB, doing practice
  approaches. CHS approach radar-vectored it to the TACAN runway 15 approach: heading 260, descending to
  1,600 ft (r1 q02, factual-narrative.pdf).
- At 1100:13 the conflict alert sounded (3.5 nm lateral, 400 ft vertical). About 3 s later the controller
  gave a traffic advisory with aircraft type "unknown" (r1 q04, factual-narrative.pdf + analysis.txt). At
  1100:26 she told the pilot to "turn left heading 180 if you don't have that traffic in sight" (r2 q03). The
  pilot asked "confirm two miles?" (r2 q04, analysis.txt). At 1100:33 she said "…turn left heading 180
  immediately" (r2 q05). The pilot turned on autopilot at 30° bank and standard rate (3°/s) so that he could
  keep looking outside (r2 q05, factual-narrative.pdf). The left turn "pointed his aircraft toward the
  Cessna" and "required the F-16's path to cross in front of the Cessna" (r2 q06, analysis.txt).
- The F-16 pilot saw the Cessna only at about 430 ft, about 1 s before impact (r1 q06, analysis.txt). The
  collision happened about 1101 EDT (r1 q08). The F-16 pilot ejected and had minor injuries (r2 q02,
  factual-narrative.pdf). The findings report gives "injuries: 2 fatal, 0 serious, 1 minor" from
  record-page.txt. The app never answered the occupants question directly (see the Experience log).

**Assessment of cause (my assessment, built on the analysis.txt statements the app quoted). Confidence: high
on the factors, moderate on how they rank.**
1. *Primary: ATC did not give an effective, timely resolution once the conflict was known.* The controller
   made the turn conditional ("if you don't have that traffic in sight"). She chose a left turn that crossed
   the Cessna's path. She went 7 s before saying "immediately" (r1 q05). She never said she expected a
   high-performance turn: she believed "fighters could turn on a dime", but "this expectation of performance
   was not clearly communicated" (r2 q08). She did not climb the F-16 because the Cessna's altitude was
   unconfirmed (r1 q05). analysis.txt says her "best course of action would have been to instruct the F-16
   pilot to turn before the airplanes came into close proximity … preferably in a direction that did not
   cross in front of the Cessna's path" (r2 q10). It also says she "did not recover from her ineffective
   visual separation plan … and switch to an alternative method of separation" (r1 q14). She had assumed the
   Cessna would stay in the MKS pattern below 1,000 ft (r2 q09).
2. *Contributing: see-and-avoid has inherent limits.* "Given the physiological limitations of vision, both
   pilots would have had difficulty detecting the other airplane." The F-16 would have stayed "a relatively
   small and slow-moving object" out the Cessna's left window until less than 5 s before impact (r1 q07,
   q14, q16). The closure rate was about 300 kt (r1 q16).
3. *Contributing: the F-16 pilot was slow to start the turn and turned at standard rate.* His attempt to
   find the traffic visually "likely resulted in a slight delay in his beginning the turn", and "the
   collision likely would have been avoided had the F-16 pilot initiated the left turn, as ATC instructed"
   (r1 q14, analysis.txt). He was also confused about range: his radar showed a target 20 miles away (r2 q04).
4. *Contributing: neither cockpit had traffic alerting.* Neither aircraft had any cockpit traffic display or
   alert. The F-16's tactical radar could not reliably detect a small slow aircraft (r1 q10). An in-cockpit
   display "could have helped" (r2 q16).
5. *Not factors:* weather (VMC, 10 sm, scattered clouds at 2,600 ft, r1 q13) and sun glare ("sun glare was
   not a factor", r1 q14). The Cessna pilot's failure to call ATC was legal ("nor was he required to do so").
   It is context, not a fault.

This matches what I remember of the NTSB's final finding: the controller's failure to give an appropriate
resolution, plus the inherent limitations of see-and-avoid. That match is a recognition note, not a source.

**Did the app ever claim a document states the probable cause?** No. Asked "Does any document state the
probable cause of the accident?", the app answered "Needs review — the AI reading could not confirm this.
The AI reader found no passage stating it…", in both the archive and the case (r1 q15). Asked "who or what
was responsible", it gave analytic statements from analysis.txt and did not present them as a probable cause
(r2 q18). That is correct behaviour. The fallback "evidence-only reading" under r1 q15 was a meaningless
stitched excerpt (Garmin TIS guidance + pilot hours), but it did not claim a cause.

## Timeline (all from app answers; EDT, July 7, 2015)
| time | event | source (app answer) |
|---|---|---|
| ~1020 | F-16 departs Shaw AFB, IFR; two practice approaches at MYR | r1 q02, factual-narrative.pdf |
| ~1052 | F-16 calls CHS approach, asks for TACAN rwy 15; given heading 260 | r1 q02/q03 |
| ~1055 | F-16 cleared down from 6,000 to 1,600 ft; MKS weather calm, 10 sm | r1 q02, q13 |
| ~1057 | Cessna departs MKS rwy 23, VFR, no flight plan | r1 q01 |
| 1057:41 | Cessna target (code 1200) appears at 200 ft | r1 q09 |
| 1059:59 | ARTS IIE detects the conflict | r1 q09, factual-narrative.pdf |
| 1100:13 | Conflict alert displayed and sounds (3.5 nm / 400 ft) | r1 q04 |
| 1100:16 | Traffic advisory, type "unknown"; F-16 wings level at ~1,570 ft, track 252°, 253 kt | r1 q04; case q02 |
| 1100:24 | F-16: "looking" | r2 q03 |
| 1100:26 | "turn left heading 180 if you don't have that traffic in sight"; F-16: "confirm two miles?" | r2 q03/q04 |
| 1100:33 | "…turn left heading 180 immediately"; F-16 starts banking (autopilot, 30°, 3°/s) | r2 q05 |
| 1100:49 | F-16 ½ nm NE of Cessna at 1,500 ft, track 215°; Cessna at 1,400 ft | r1 q08 |
| 1100:54 | Last Cessna radar return | r1 q08 |
| 1100:56 | Aircraft 260 ft apart (visibility study) | case r1 q07 |
| ~1101 | Collision; F-16 pilot sees the Cessna about 1 s before | r1 q06, q08 |
| ~1101–1103 | Damaged F-16 flies about 2½ min; pilot ejects; radar lost at 1103:17 | r2 q02 |
| Nov 2016 | Safety recommendations to FAA and contract-tower operators; safety alert "Don't Depend on Vision Alone" | r2 q14 |

## Contradictions
- **The app found none** (r1: "0 by rules, 0 by the AI reading (2 AI pairs dropped…)"; r2: every
  contradiction call failed for lack of credit).
- The one lead it raised and dropped was traffic alerts increasing search effectiveness "by a factor of eight"
  versus "a factor of two", dropped with the reason "passage not sent". I followed it up (r2 q15). The AI
  confirmed only "a factor of eight". The "factor of two" sentence never appeared in full in any answer.
  **Unresolved.** The two figures may come from different studies. It does not matter for the cause.
- 1059:59 (ARTS detected the conflict) versus 1100:13 (alert presented and sounded). I read this as
  detection versus display, not a contradiction. The app never explained the 14 s gap.
- The record page shows "status: pending", "status: filed" and "status: published" (findings report)
  without explanation. When asked about the status, the app gave "Needs review" and no answer (r2 q17).

## Open questions
- Who the occupants were and how many died. The only source is the findings line "2 fatal, 0 serious,
  1 minor". The question failed twice.
- The full "factor of two" passage.
- The controller's workload and other traffic at the time. The draft gap list names this, and I did not ask.
- The NTSB's actual probable-cause statement is not in the archive, as the brief says.

## Round log
- **r1 (16 Qs):** flights, ATC exchanges, timing, visibility, equipment, factors, whether any document
  states the probable cause. 15/16 answered well. The occupants question failed. 3 "Needs review" items.
  Workflow: 0 contradictions, drafts with 3 chronology items.
- **r2 (18 Qs):** occupants/ejection, exact transmissions, the turn, "immediately", controller
  expectations, what she should have done, experience of the pilot and controller, 7110.65,
  recommendations, the factor-of-eight lead, the record-page status, responsibility. All 18 archive answers
  used the model and were mostly excellent. Credit ran out during the case pass, so the workflow and in-case
  q09–q18 were rules-only.

## Experience log

**Helped**
1. *Verified, quote-backed answers on a technical narrative.* Almost every archive answer was right,
   specific, and carried verbatim quotes with the document name. Examples: the exact transmissions at
   1100:24, 1100:26 and 1100:33, and the autopilot "30º of bank and standard rate". I could build the
   minute-by-minute timeline in two rounds without reading the PDF.
2. *Analytic statements were found and attributed.* Questions such as "what should the controller have
   done" (r2 q10) and "what did 'immediately' mean to each side" (r2 q08) brought back the analysis.txt
   reasoning precisely. That is the core of a cause assessment.
3. *It was honest about the probable cause.* It never invented one. It said "the AI reading could not
   confirm this" (r1 q15), and it answered "who was responsible" with attributed analysis, not a verdict
   (r2 q18).
4. Notes such as "1 statement the AI proposed did not check out and is not shown" showed the checking at
   work.

**Slowed or misled**
1. *The occupants question failed in both rounds and both modes.* It produced an unrelated archive "History"
   page at confidence 0.2: "History of the user's archive … (No reasoning provider available — chapters ship
   without LLM prose) … Jul 2, 2015: At the time of the accident, the airframe had". Two problems: a
   reasoning provider *was* available, and the history page is misdated ("Aug 16, 2015: In November 2016, we
   issued safety recommendations…").
2. *The rules fallback looks confident but answers the wrong question.* When credit ran out (r2 in-case),
   answers came back at **confidence 0.8** with quotes unrelated to the question:
   - "How experienced was the Cessna pilot…?" → "Shortly after, she asked the two-aircraft flight to
     expedite its descent to 3,000 ft…"
   - "How experienced was the CHS approach controller?" → "…the F-16 pilot contacted the approach controller
     at CHS about 1052…"
   - "What does the analysis say the controller should have done…?" → the conflict-alert trigger sentence.
   The label "(The AI reading could not be used … This is the evidence-only reading.)" is truthful, but 0.8
   confidence on an off-topic quote is misleading. A user without the archive answer would be misled.
3. *Many "Needs review" flags were false conflicts.* A "Needs review — the AI reading and the evidence-only
   reading give different values" flag appeared when the evidence-only reading was simply a different,
   consistent or irrelevant passage:
   - case r1 q01: evidence-only "Aircraft2: Lockheed-Martin F-16CM, registration 96-0085…" for a question
     about the Cessna.
   - case r1 q09: the transponder question.
   - r1 q14: contributing factors.
   - r2 q13: 7110.65, where the evidence-only reading was a subset of the AI reading.
   - r2 q14: recommendations, where evidence-only gave a May 2015 alert.
   - r2 q15.
   In every case the AI reading was right. I count 0 of 6 "Needs review" flags that marked a real
   disagreement. The 4 "could not confirm" flags (r1 q12, q15; r2 q07, q17) were right to withhold, although
   q12 and q17 were answerable in principle.
4. *Drafts were weak on this case.* The chronology had 3 items: two irrelevant checkride dates and the
   collision. It missed the whole 1052–1101 sequence. The cast of characters had no people (no pilots, no
   controller) and was full of non-entities: "Avoid Concept", "Pilots' Role", "Lockheed Martin F-",
   "Controller Glossary". One gap ("The qualifications, medical status and experience of the Cessna pilot")
   was presented as missing, but the factual narrative has it (r2 q11).
5. *The findings report was noisy.* It had "Undated — employer: In Systems" and "On 2015-07-02 — At the
   time of the accident, the airframe had" (truncated, wrong date). It dated the November 2016
   recommendations "On 2015-08-16".
6. The archive answer said the advisory came "about 40 seconds before" the collision. Combined with 1100:16,
   that puts the collision near 1100:56. That is consistent, but the app never stated an exact collision
   second.

**Effort:** 2 rounds, 34 questions, about 20 minutes of round time plus queue waits. The answers were
high-signal, and reading them took less effort than reading the 37-chunk PDF.

**Would I rely on it?** Yes, for building a factual timeline and pulling the investigators' own analytic
statements with citations (Online mode, with the model working). No for the drafts, cast list or findings
report on a technical file. No for the rules-only fallback. Treat any answer marked "the AI reading could
not be used" as unreliable whatever its confidence.
