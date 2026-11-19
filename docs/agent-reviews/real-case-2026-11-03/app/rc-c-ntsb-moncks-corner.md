# rc-c-ntsb-moncks-corner — investigator memo (app-only)

Investigator: agent (Claude), working only through the app's `round.sh` answers (r1–r5, 99 questions).
Commit under test: c3e8c5b0, rules path (no model).

**Disclosure.** I recognise this accident in general terms (the 2015 Moncks Corner F-16/Cessna midair).
Also, the bench README, which I was allowed to read, summarises the sealed NTSB probable cause in its
case table ("approach controller's failure to resolve the conflict; see-and-avoid limits contributing").
That biased me toward the controller line of questioning. Below I keep what the app's documents state
apart from my own assessment. I treat the README hint as contamination, not evidence.

## Conclusion

**What the records state (app-cited):**

1. On July 7, 2015, about 1101 EDT, Cessna 150M N3601V and a USAF Lockheed Martin F-16CM collided in
   midair near Moncks Corner, SC. (r1 in-case q01, factual-narrative.pdf: "On July 7, 2015, about 1101
   eastern daylight time, a Cessna 150M, N3601V, and a Lockheed Martin F-16CM … collided in midair near
   Moncks Corner, South Carolina.") Weather VMC, 10 sm visibility, daylight (record-page, r1 q14). Injuries: 2 fatal, 1 minor.
   The private pilot and passenger of the Cessna died (r3 q12). The F-16 pilot ejected and "landed safely
   using a parachute and incurred minor injuries" (r3 q09/q10). Both aircraft were destroyed. — high confidence.
2. The F-16 was on an IFR flight plan. After departing SSC it flew two practice approaches at MYR, then
   contacted CHS approach about 1052 and asked for a practice TACAN approach to runway 15 (r2 q13; r4 q11).
   About 1055 it was told to descend from 6,000 to 1,600 ft, about 34 nm NE of CHS (r1 in-case q17). The
   controller gave it a 260° vector to intercept final, meant "to keep the F-16 south of, and to avoid
   overflying, MKS" (r4 q11). — high confidence.
3. The Cessna was not in contact with ATC "nor was he required to do so" (r3 q18). It had an operating
   Mode C transponder and an altitude encoder (r1 q15; analysis passage r2 q11), and no traffic display.
   It was in its "departure climb" when the conflict developed (r3 q04). — high confidence on the equipment.
   **The departure airport was never stated by the app** (asked 4 ways, see Open questions).
4. ATC sequence (factual narrative, verbatim times):
   - 1100:13: the conflict alert (CA) shows on the display and sounds, at 3.5 nm lateral and 400 ft vertical separation (r5 q06).
   - 1100:16: "traffic 12 o'clock, 2 miles, opposite direction, 1,200 [ft] indicated, type unknown" (r2 q01).
   - 1100:24: the F-16 pilot replies that he is "looking" (r2 q01).
   - 1100:26: "turn left heading 180 if you don't have that traffic in sight" (r2 q02 citation).
   - 1100:30: the pilot asks "confirm 2 miles?" (r5 q07). The F-16's own radar showed a target 20 miles away, which likely caused the question (r5 q08).
   - 1100:33: "if you don't have that traffic in sight turn left heading 180 immediately". Over the next 18 s the F-16's ground track turned south (r3 q05).
   - 1100:49: the F-16 is ½ nm NE of the Cessna at 1,500 ft, on track about 215°, banking left at 30° (r3 q13; r1 q12).
   - 1100:53: "traffic passing below you one thousand four hundred" (r4 q04 citation).
   - Collision about 1101. The exact second was never given; 1100:56 is "one second before the collision" in the TIS simulation (r1 in-case q12).
   — high confidence (each is a verbatim citation).
5. Analysis statements (analysis.txt / narrative):
   - The advisory came only when the airplanes were "within about 3.5 nm and 400 vertical ft", "about 3 seconds after the ATC radar CA alarmed" (r3 q01, r4 q12).
   - The controller did not climb the F-16 "because the altitude indicated for the Cessna's radar target was unconfirmed" (r4 q07).
   - A left turn kept the F-16 closer to its destination (r3 q03), and the flow of other traffic likely shaped her choice (r4 q09).
   - During the left turn, the Cessna target "rotated to the right side of the F-16's projected course, with its heading still projected to intercept that course" (r5 q03). It may have been hidden by the HUD post and was "not visible again until about 2 seconds before the collision" (r4 q01).
   - "The collision likely would have been avoided had the F-16 pilot initiated the left turn, as ATC instructed, when he realized that he did not have the traffic in sight." (r3 q06, r5 q11)
   - Both pilots "would have had difficulty detecting the other airplane" (r2 q18), and the Cessna pilot "likely would not have had adequate time" (r2 q17).
   - FAA Order 7110.65 makes separation and safety alerts first priority (r4 q19, r5 q15).
   - The safety recommendations of November 2016 refer to "the ATC errors in this midair collision" (r1 q13).

**My assessment (not stated as a finding in any document):**

- *Primary cause (moderate confidence):* the approach controller did not resolve a conflict she could
  see. Evidence:
  - The Cessna's Mode C target was on her display.
  - She vectored the F-16 at 1,600 ft into a climbing departure area.
  - She gave no advisory until the conflict alert, at 3.5 nm.
  - Her first avoidance instruction (1100:26) was conditional rather than a safety alert. "Immediately" came only at 1100:33.
  - The left turn she chose kept the Cessna's heading projected to intercept the F-16's course. The analysis attributes that choice to traffic flow and the unconfirmed Cessna altitude.
  - The recommendations' own words, "ATC errors in this midair collision", point the same way.
- *Contributing (moderate):*
  - The F-16 pilot was slow to turn. The conditional instruction came at 1100:26, but he queried the distance at 1100:30 because his radar showed a 20 nm target, and the turn developed only after 1100:33. The analysis says the collision "likely would have been avoided" had he turned at once.
  - The inherent limits of see-and-avoid: small, near-stationary targets and the HUD post obstruction.
  - Neither aircraft had a cockpit traffic display.
  - The Cessna pilot was legally not in contact with ATC.
- I would **not** put the cause on the Cessna pilot alone, or on the F-16 pilot alone. The analysis
  sentence on the F-16 pilot's turn is a counterfactual, not a cause finding.
- **No document states the probable cause.** Every time I asked, the app refused: "None of the documents
  on file states the investigators' conclusion; they hold the factual record only." (r2 q19, r3 q20,
  r5 q19/q20). The record page lists "Status: pending". The app never claimed a document states the cause. Good.

## Timeline (reconstructed)

| time (EDT) | event | source (app round/q) |
|---|---|---|
| before | F-16 departs SSC, flies 2 practice approaches at MYR | r2 q09 citation |
| ~1052 | F-16 contacts CHS approach, requests TACAN rwy 15 | r2 q13 |
| ~1055 | descend 6,000 → 1,600 ft, 34 nm NE of CHS; later 260° vector south of MKS | r1 q17, r4 q11 |
| — | Cessna departs (airport/time not obtained), climbing; no ATC contact | r3 q04, r3 q18 |
| 1100:13 | conflict alert, 3.5 nm / 400 ft | r5 q06 |
| 1100:16 | traffic advisory, 12 o'clock 2 miles 1,200 indicated | r2 q01 |
| 1100:24 | F-16: "looking" | r2 q01 |
| 1100:26 | "turn left heading 180 if you don't have that traffic in sight" | r2 q02 |
| 1100:30 | F-16: "confirm 2 miles?" | r5 q07 |
| 1100:33 | "…turn left heading 180 immediately"; turn develops over 18 s | r3 q05 |
| 1100:49 | F-16 ½ nm NE of Cessna, 1,500 ft, track 215°, 30° bank | r3 q13, r1 q12 |
| 1100:53 | "traffic passing below you one thousand four hundred" | r4 q04 |
| ~1101 | collision; Cessna occupants killed; F-16 flies ~2½ min, pilot ejects | r1 q01, r3 q10 |
| Nov 2016 | safety recommendations re "ATC errors in this midair collision" | r1 q13 |

## Contradictions / discrepancies

- The 1100:53 "passing below you one thousand four hundred" call, against the F-16 at 1,500 ft on radar
  (r4 q04 citation) and the TIS simulation's "100 ft below" at 1100:56. These are consistent with a near
  co-altitude collision, not a contradiction. The workflow found **0 contradictions and 0 gaps** in every round.
- One genuine tension the workflow did not flag. The analysis says the collision "likely would have been
  avoided had the F-16 pilot initiated the left turn", while the recommendations speak of "ATC errors". Two
  attributions of responsibility, and the workflow raised no conflict.
- The app itself introduced a discrepancy. Its timeline dates a record "16 August 2015" (the date of a
  *different*, San Diego collision mentioned in the text) and "Jul 2, 2015: At the time of the accident, the
  airframe had" (a truncated maintenance sentence). The findings report repeats both as dated findings.

## Open questions

- **Cessna departure airport and takeoff time.** Asked 4 ways (r1 q03, r2 q09, r3 q11, r4 q10, r5 q04/q05).
  The answers were "Location: Moncks Corner, SC." or unrelated quotes. MKS (which the F-16 was routed to
  avoid) is probably that airport, but the app never said so: "Not found in the 13 documents searched:
  definition." (r4 q11).
- Exact collision second and altitude. r1 in-case q11 only says they "were determined based on
  extrapolation", and r4 q16 was refused as a "conclusion".
- The "two-aircraft flight" asked to expedite descent to 3,000 ft (r3 q14, r4 q08). Its identity was never
  given; it may be other traffic the controller was working.
- Whether the analysis explicitly criticises the conditional phrasing or the choice of left turn. The app
  returned only adjacent passages (r4 q01–q03 gave the same HUD-post sentence three times).
- The controller's experience. r3 q15 returned the *F-16 pilot's* flight hours instead.

## Round log

- **r1 (19 q):** broad. Got the time, the aircraft, weather, the transponder, the ATSB see-and-avoid quote and the 1055 descent. Many answers were off-target (e.g. the "who was flying" question returned a briefing-guide sentence). The "probable cause" question returned an "Extracted facts / Missing evidence" scaffold with no claim.
- **r2 (20 q):** ATC exchanges. Got 1100:16/24/26/30/33, the conditional instruction, see-and-avoid difficulty and the TACAN request. The "when" questions were refused despite times in the citation. The "probable cause" question was refused correctly.
- **r3 (20 q):** controller options. Got the CA at 3.5 nm/400 ft, the advisory 3 s after the CA, ejection, occupants dead, no ATC contact required, 1100:49 geometry, and the "would have been avoided had the F-16 pilot…" sentence.
- **r4 (20 q):** turn choice and interview. Got the unconfirmed Cessna altitude as the reason not to climb, traffic flow, the 260° vector south of MKS, 1100:53, and the 7110.65 duty priority. "Yes — in November 2016…" was nonsense.
- **r5 (20 q):** precise times. Got the CA at 1100:13 and the Cessna heading still intercepting during the left turn. The departure airport was still missing, and the nonsense "Yes" repeated.

## Experience log

**Helped:**
- When the question used the document's own vocabulary ("conflict alert", "conditional instruction",
  "postaccident interview"), the app returned the exact verbatim sentence with its document. Timeline
  building from those quotes was fast, and every quote I checked in a second round was consistent.
- It never invented a probable cause. "None of the documents on file states the investigators'
  conclusion; they hold the factual record only." That is exactly right for a file held before the finding.
- Refusals were explicit and labelled, so I knew when to re-ask.

**Hurt / misled (exact app words):**
- **Wrong-passage answers delivered at confidence 0.8 as "Quoted verbatim".** Examples:
  - q02 r1 "who was flying them?" → "(The Shaw General Briefing Guide is a local USAF document …)".
  - r1 q10 "At what time did the collision occur?" → "Given the speed of the F-16, the Cessna pilot likely would not have had adequate time…".
  - r1 q16 "Did the F-16 have a [TCAS]?" → "Our in-cockpit traffic display simulation showed…".
  - r3 q15 controller experience → the F-16 pilot's hours.
  - r5 q17 altitude-readout accuracy → the avionics list.

  The verbatim label made a wrong passage look authoritative. Roughly 40 % of my questions got an off-target quote.
- **Times refused as dates.**
  - r2 q02 "When did the controller tell the F-16 pilot to turn left?" → refused "A when-question whose evidence states no date." / "The documents don't give a date for this." The cited passage says "At 1100:26…".
  - The same happened in r2 q04, r4 q04/q05 and r5 q01.
- **Over-broad "conclusion" refusals.**
  - r2 q06 "What did the analysis conclude about the controller's instruction to turn left?" → "None of the documents on file states the investigators' conclusion".
  - r4 q16 "When was the collision time determined to be?" got the same refusal.

  The analysis document *does* contain conclusions. Only the probable cause is withheld.
- **Confident wrong yes.** r4 q18 "Was the F-16 pilot looking inside the cockpit…?" and r5 q13 "Was the
  left-turn instruction issued as a safety alert…?" both got "Yes — in November 2016, we issued safety
  recommendations to the FAA and Midwest Air Traffic Control, Robinson Aviation, and… on 16 August 2015."
  That is a fabricated yes and a wrong date.
- **Junk timeline.** Every "what happened / what happened at 1100:54" question got "History of the user's
  archive … Aug 16, 2015: In November 2016, we issued safety recommendations…" and "Jul 2, 2015: At the
  time of the accident, the airframe had". The findings report surfaces junk claims as findings:
  "employer: In Systems", "employer: Active Traffic Systems", "interceptthatcourseat1100: 56, one second…".
- The workflow block added almost nothing: "contradictions found: 0; gaps found: 0" in every round, 15
  claims, mostly record-page fields.

**Effort:** 5 rounds, 99 questions. About 25 produced the usable facts above. I needed 3–4 rephrasings per
fact, mainly by copying vocabulary from earlier citations.

**Would I trust it on a real case?** As a verbatim-passage finder, yes, *if* I read every citation myself.
As an answerer, no. The "Quoted verbatim … confidence 0.8" framing is attached equally to right and wrong
passages, the "Yes — …" answers are wrong, and time questions are refused. An investigator who skimmed
answer bodies without checking citations would have been misled several times per round.
