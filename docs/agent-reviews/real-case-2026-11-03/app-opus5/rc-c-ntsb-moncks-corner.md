# rc-c-ntsb-moncks-corner — investigator memo (app, Online / Opus 5)

Investigator: AGENT, using the app only (runs-opus5/rc-c-ntsb-moncks-corner/r1–r5). 5 rounds, 80 questions.
Recognition note: I recognise this accident (2015 Moncks Corner F-16 / Cessna midair) from general
knowledge. Everything below rests only on what the app returned; where my memory might tempt me
past the evidence I say so.

## Conclusion

**What happened (record-stated, high confidence).**
- On July 7, 2015, about 1101 EDT, a Cessna 150M (N3601V) and a USAF F-16CM collided in midair near
  Moncks Corner, SC (case-scope r1 q01, factual-narrative.pdf: "On July 7, 2015, about 1101 eastern
  daylight time, a Cessna 150M, N3601V, and a Lockheed Martin F-16CM … collided in midair").
- Cessna: no flight plan, departed Berkeley County Airport (MKS) about 1057 for Grand Strand Airport,
  North Myrtle Beach (r2 q01). Not in contact with ATC, relying on see-and-avoid (r4 q09, analysis.txt:
  "Because the Cessna pilot was not in contact with ATC and was relying solely on the see-and-avoid
  concept…"). It had a mode C transponder and altitude encoder (r1 q11). The private pilot and passenger
  aboard died (r4 q01 passage; record page "2 fatal, 0 serious, 1 minor").
- F-16: IFR flight plan, radar vectors for a practice TACAN approach to runway 15 at Charleston (CHS);
  contacted CHS approach about 1052 (r1 q04); told to descend from 6,000 to 1,600 ft about 1055, 34 nm NE
  of CHS (r2 q10 passage). No TAS/TCAS/ADS-B display (r1 q17).
- ATC sequence (factual-narrative.pdf): conflict detected by the ARTS IIE at 1059:59; conflict alert
  displayed/aural at 1100:13 with 3.5 nm lateral, 400 ft vertical separation (case r1 q03; r3 q05).
  1100:16 traffic advisory "traffic 12 o'clock, 2 miles, opposite direction, 1,200 indicated, type
  unknown" (r2 q02); F-16 then wings-level, ~1,570 ft, track 252°, 253 kt groundspeed (r5 q07).
  1100:24 pilot "looking". 1100:26 "turn left heading 180 if you don't have that traffic in sight".
  1100:30 pilot "confirm 2 miles?" (r5 q03). 1100:33 "if you don't have that traffic in sight turn left
  heading 180 immediately"; over the next 18 s the F-16 track turned southerly (r2 q03). 1100:49 F-16
  in a 30° bank left turn; Cessna would have become more discernible low-right in the HUD (r1 q10).
  1100:56 (simulation) second aural "Traffic, 2 o'clock, same altitude, zero miles" one second before
  collision (case r1 q10). Witness estimate ~900 ft; F-16 struck the Cessna's left side (r1 q07).
- The controller later thought the Cessna had passed below the F-16 and that they were clear until its
  target disappeared and the F-16 pilot made a distress call (case r5 q11).

**Cause assessment (MY assessment, not a record statement; moderate-high confidence).**
No document on file states a probable cause, and the app said so consistently: "None of the documents
on file states the investigators' conclusion; they hold the factual record only." (r1 q15, r2 q16,
r5 q01). The app never claimed a document states the cause. From the analysis text it did surface:
1. Primary: the approach controller's late and inadequate conflict resolution — she assumed the Cessna
   would stay in the MKS pattern (r2 q14; r3 q11), so the advisory came only at 3.5 nm/400 ft, ~3 s
   after the conflict alert (r1 q09); she issued a *conditional* turn instead of an immediate one (r4
   q14: "The F-16 pilot's attempt to visually acquire the Cessna per the controller's conditional
   instruction likely resulted in a slight delay in his beginning the turn"); her expectation of a high
   performance turn "was not clearly communicated" (r4 q04); and the turn she chose crossed the Cessna's
   path (r2 q09: best course would have been to turn earlier "preferably in a direction that did not
   cross in front of the Cessna's path"). FAA 7110.65 2-1-2 gives first priority to separation and
   safety alerts (r5 q05).
2. Contributing: inherent limits of see-and-avoid — both aircraft were small, near-stationary targets on
   converging courses (r4 q01 passage; r1 q14 ATSB quote); the F-16 remained a small object at the
   Cessna's 9–10 o'clock until <5 s before impact (r3 q04); the Cessna may have been hidden by the HUD
   post during the turn (r3 q14).
3. Contributing: no in-cockpit traffic display on either aircraft; a display could have shown the
   Cessna ~15 nm / ~3 min before the collision (case r2 q18; r2 q12).
4. Contributing: the Cessna pilot was not talking to CHS approach (r4 q09).
These map closely onto what I remember of the official finding — I flag that recognition; the
assessment above is built from the analysis passages cited.

## Timeline (all 7 July 2015, EDT; factual-narrative.pdf unless noted)
- ~1052 F-16 contacts CHS approach, requests practice TACAN RWY 15.
- ~1055 F-16 descends 6,000 → 1,600 ft, 34 nm NE of CHS.
- ~1057 Cessna departs MKS VFR for North Myrtle Beach, no flight plan, not talking to ATC.
- 1059:59 ARTS IIE detects conflict. 1100:13 conflict alert shown/aural (3.5 nm, 400 ft).
- 1100:16 traffic advisory "12 o'clock, 2 miles…". 1100:24 "looking". 1100:26 conditional turn.
- 1100:30 "confirm 2 miles?". 1100:33 "…turn left heading 180 immediately". Turn develops over 18 s.
- 1100:49 F-16 in 30° bank. 1100:56 simulated "zero miles" alert. ~1101 collision, ~900 ft.
- Nov 2016 (analysis.txt): NTSB safety recommendations to FAA and contract-tower operators, and safety
  alert "Prevent Midair Collisions: Don't Depend on Vision Alone" (r3 q16; r1 q12 passage).

## Contradictions (and whether the app flagged them)
- Traffic position: controller said 2 miles; the F-16's radar detected a target 20 miles away, which
  led the pilot to query "confirm 2 miles?" (r1 q13, r5 q03). Not flagged by the app (contradictions
  found: 0) — it is a discrepancy in the event, not between sources, so arguably fine.
- Controller's belief that the Cessna would stay in the pattern vs. its actual climb above 1,000 ft
  (r4 q05) — not flagged.
- Controller's post-event belief "the Cessna had passed below him" vs. the collision — not flagged.
- No source-vs-source contradiction found by me; app also found 0.

## Open questions
- The F-16 pilot's escape (ejection) and injuries: the record page says 1 minor injury but the app never
  returned a passage about ejection (r4 q02, r5 q06 off-target). I believe from memory he ejected — NOT
  established from the app.
- Exact turn rate the F-16 used vs. what was needed: r4 q03, r5 q08 returned off-target passages.
- Controller's identity, experience and fighter-traffic training (r2 q13, r3 q15 off-target — the
  latter returned the F-16 pilot's hours).
- Cessna pilot's experience (r3 q07 off-target).
- Whether Cessna was squawking 1200 (r3 q05 off-target).

## Round log
- r1 (18 q): overview, both flights, ATC, cause/conclusion check. Good: equipment, altitude, TCAS,
  refusal of cause. Bad: q01 timeline led with an August 2015 record that is actually about Nov 2016;
  q05 "When did the controller issue a traffic advisory" refused as "no date".
- r2 (18 q): timestamped ATC exchanges. Very good on 1100:16 / 1100:33 / departure 1057 /
  postaccident interview / in-cockpit display.
- r3 (18 q): pilots, occupants, HUD, controller assumption. Mixed; many off-target answers.
- r4 (14 q, re-run with FORCE=1 after my wrapper timed out): conditional instruction, controller
  expectation, not-in-contact; good. Ejection/ turn rate failed.
- r5 (12 q): probable-cause re-check (refused correctly), 1100:26/1100:30 exchange, speed, duty
  priority. Good.

## Experience log
**Where it helped.**
- Verbatim, timestamped quotes once I named the time: "At 1100:16, the CHS approach controller issued a
  traffic advisory…" (r2 q02); "At 1100:26 … At 1100:30, the pilot asked, "confirm 2 miles?"" (r5 q03).
  Building the ATC timeline was fast once I knew the anchors.
- Honest on the missing finding: five times it said no document states the conclusion and never claimed
  one did. That is exactly right for this file.
- The analysis-level sentences that carry the cause were retrievable when asked in the document's own
  words (r4 q04, r4 q14, r2 q09).
- The case-scope run sometimes gave a *better* passage than the whole-archive run (r3 q01 case: the
  1100:16/1100:24 exchange vs whole-archive junk), which helped cross-check.

**Where it slowed or misled me (exact words).**
- Time-of-day questions refused as date questions: "The documents don't give a date for this." (r1 q05,
  r2 q07, r4 q12 — all three asked *when* in clock time; the passage it cited has the time).
- Confident off-target quotes at 0.8 labelled "Quoted verbatim": q08 "At what time did the collision
  occur?" → "Given the speed of the F-16, the Cessna pilot likely would not have had adequate time…"
  (r1); "Was the Cessna pilot in contact with air traffic control?" → the traffic-advisory sentence
  (r1 q06); "Did the F-16 pilot eject?" → "(The radar system did detect a target 20 miles away…" (r4
  q02); "What was the controller's training…" → the F-16 pilot's hours (r3 q15); "What was the Cessna
  pilot's flight experience?" → the controller's descent instruction (r3 q07).
- Garbled field extractions presented as answers: "Interceptthatcourseat1100: 56, one second before
  the collision, the F-16 would have received a second aural." (r3 q01, r3 q12, r4 q13, r5 q10);
  "Location: Moncks Corner, SC." as the answer to where the Cessna departed (r1 q02) and to what the
  pilot asked (r3 q02); "**Status:** pending / **Status:** filed" (r1 q03).
- Mis-dated timeline: "16 August 2015 — In November 2016, we issued safety recommendations…" (r1 q01)
  and the story view "Jul 2, 2015: At the time of the accident, the airframe had" — the 16 Aug date is
  a different accident mentioned in passing. The same broken 3-event "History of the user's archive"
  came back for occupants, heading and ejection questions with "(No reasoning provider available —
  chapters ship without LLM prose)" even though Online mode was on.
- Findings report: 15 "findings" that are fields like "status: pending", "employer: In Systems",
  "employer: Active Traffic Systems" and the same mis-dated items; 0 conflicts, 0 gaps.

**Model use.** Whole-archive answers: 73 of 80 recorded model calls (137 calls total), yet every
answer text is a verbatim quote, field extraction or "no model was consulted" label; the run footer
says "AI model: none (rules path)" every round, and the in-case answers record "model calls: none".
In practice no answer I read was composed by Opus 5. The model's contribution, if any, is invisible.

**Effort.** 5 rounds, ~25–30 min of waiting, ~40 % of answers usable on first try; most useful content
came from re-asking in the document's own vocabulary (timestamps, "conditional instruction",
"expectation of performance"). An investigator without a guess at those words would get much less.

**Would I rely on it?** As a quote-finder and timeline aid over a known file: yes, with every quote
checked against its question. Not for questions about people (experience, injuries), not for
"when" questions, and not its findings report or timeline view. It did not do any reasoning about
cause; I did that from passages.
