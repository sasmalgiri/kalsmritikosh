# rc-c-ntsb-moncks-corner — baseline memo (documents read directly, no app)

Sources: `record-page.txt` (RP), `factual-narrative.pdf` (FN, 20 pages, text PDF) and `analysis.txt` (AN).

Recognition / contamination note: I recognise this accident in general terms as the 2015 Moncks Corner F-16/Cessna midair. I have some memory that the NTSB's finding centred on the approach controller. The shared README.md also states the withheld probable cause in one line. **The assessment below is built only from FN and AN.** Readers should know that my assessment cannot be independent of that prior exposure.

## Conclusion (what happened)

| Point | Rests on (verbatim) | Confidence |
|---|---|---|
| Collision about 11:01 EDT, Jul 7, 2015, near Moncks Corner SC, between Cessna 150M N3601V and USAF F-16CM (96-0085). Both aircraft destroyed. | "On July 7, 2015, about 1101 eastern daylight time, a Cessna 150M, N3601V, and a Lockheed Martin F-16CM, operated by the US Air Force (USAF), collided in midair near Moncks Corner, South Carolina." (FN); RP: "damage DEST" for both | High |
| Cessna: private pilot and passenger killed | "The private pilot and passenger aboard the Cessna died, and the Cessna was destroyed during the collision." (FN); cause of death "blunt trauma" (FN) | High |
| F-16 pilot ejected with minor injuries; F-16 crashed about 6 nm south | "The damaged F-16 continued to fly for about 2 1/2 minutes, during which the pilot activated the airplane's ejection system. The F-16 pilot landed safely using a parachute and incurred minor injuries" (FN) | High |
| **F-16 flight:** single-ship operational check flight from Shaw AFB (departed about 1020), practice approaches at Myrtle Beach then Charleston (CHS); IFR flight plan, in contact with CHS approach | "the F-16 pilot was assigned as pilot-in-command for a single-ship, operational check flight to verify the completion of recent corrective maintenance." / "The F-16 was operating on an instrument flight rules (IFR) flight plan and had departed from Shaw Air Force Base (SSC), Sumter, South Carolina, about 1020." (FN) | High |
| **Cessna flight:** personal VFR flight from Berkeley County Airport (MKS) at about 1057 toward North Myrtle Beach; no flight plan; never contacted ATC and was not required to | "No flight plan was filed for the Cessna, which departed from Berkeley County Airport (MKS) … about 1057, and was destined for Grand Strand Airport" / "For the duration of the flight, the pilot of the Cessna did not contact any ATC facilities, nor was he required to do so." (FN) | High |
| Controller descended the F-16 to 1,600 ft (the minimum vectoring altitude) on a 260° vector | "About 1055, the controller instructed the F-16 pilot to descend from 6,000 ft to 1,600 ft." (FN) | High |
| Neither aircraft had TAS/TCAS/ADS-B. The F-16's radar was not designed to find slow, small aircraft. | "The airplane was not equipped with a TAS, TCAS, or ADS-B equipment or displays." (FN, for both aircraft) / "the radar unit was designed to acquire fast moving enemy aircraft (not slow-moving, small aircraft)." (FN) | High |
| VMC; sun glare ruled out | "Visual meteorological conditions prevailed" (FN); "Thus, sun glare was not a factor in this accident." (AN) | High |

### ATC exchange and timing (all from FN, "The Collision")
| Time (EDT) | Event |
|---|---|
| ~1052 | F-16 checks in with CHS approach, requests the TACAN runway 15 approach; vectored 260° |
| ~1055 | Descend 6,000 → 1,600 ft; F-16 about 34 nm NE of CHS |
| ~1057 | Cessna departs MKS runway 23 |
| 1057:41 | Cessna radar target (code 1200) appears at 200 ft |
| 1058:05–06 | (Simulation only) ADS-B display would first have shown each aircraft to the other at 15 nm |
| 1059:47 | (Simulation only) target would have become "filled" (within 6 nm, 600 ft) |
| 1059:59 | ARTS IIE detects the conflict |
| 1100:13 | Conflict alert displayed and aural alarm; 3.5 nm lateral and 400 ft vertical separation |
| 1100:16 | "traffic 12 o'clock, 2 miles, opposite direction, 1,200 [ft altitude] indicated, type unknown" (study: actual distance 3.25 nm) |
| 1100:24 | F-16: "looking" |
| 1100:26 | "turn left heading 180 if you don't have that traffic in sight" |
| 1100:30 | F-16: "confirm 2 miles?" |
| 1100:33 | "if you don't have that traffic in sight turn left heading 180 immediately". F-16 begins an autopilot standard-rate (30° bank) left turn. |
| 1100:35 | (Simulation only) aural traffic alert would have sounded in both aircraft |
| 1100:49 | F-16 is 1/2 nm NE of the Cessna at 1,500 ft, track 215°; Cessna at 1,400 ft, track 110° |
| 1100:53 | "traffic passing below you one thousand four hundred" |
| 1100:54 | Last Cessna radar return |
| 1100:56–57 | F-16 pilot sees the Cessna directly ahead (under 1 s before impact) and pulls full aft stick. Collision (1100:57 per the simulation). |
| 1101:19 | F-16 distress call |
| 1103:17 | F-16 radar contact lost at 300 ft near the crash site |

## Assessment of cause (my own, marked as such; the official finding is withheld)

**What the records state** (AN, verbatim):
- "the controller's instruction to the F-16 pilot to turn left required the F-16's path to cross in front of the Cessna. Although this decision was not contrary to FAA guidance for air traffic controllers, it was the least conservative decision, as it was most dependent on the F-16 pilot's timely action for its success."
- "Due to the closure rate, the close proximity of the two airplanes, and human cognitive limitations, the controller did not recover from her ineffective visual separation plan … The controller's best course of action would have been to instruct the F-16 pilot to turn before the airplanes came into close proximity with each other and preferably in a direction that did not cross in front of the Cessna's path."
- "The collision likely would have been avoided had the F-16 pilot initiated the left turn, as ATC instructed, when he realized that he did not have the traffic in sight."
- "it is clear that the term 'immediately' held different expectations for both parties."
- "both pilots would have had difficulty detecting the other airplane." / "the Cessna pilot likely would not have had adequate time to recognize and avoid the impending collision."
- "their presence in one or both cockpits might have changed the outcome of the event." (traffic-display technology)

**My assessment.**
- **Primary cause:** the CHS approach controller did not resolve a conflict she was responsible for. Confidence: moderate-high. The facts behind this:
  - She descended the IFR F-16 to the 1,600 ft minimum vectoring altitude across the departure path of a nontowered airport.
  - She saw the Cessna depart but assumed it would stay in the pattern.
  - She gave the first traffic call only at about 3.25 nm with a closure rate of about 300 kt, roughly 40 s before impact.
  - She then gave a *conditional* turn instruction ("if you don't have that traffic in sight") in a direction that took the F-16 across the Cessna's path.
  - She did not escalate to an unconditional safety alert or a climb. She said she did not recall the conflict alert at all.
  - The analysis itself calls the plan "ineffective" and the left turn "least conservative".
- **Contributing factors:**
  1. The F-16 pilot was slow to begin the turn (about 7 s). He tried to acquire the traffic first and asked "confirm two miles?" because his radar showed a target at 20 miles. He then flew a standard-rate autopilot turn, not the hard turn the controller expected from "immediately". The miscommunication about "immediately" is documented.
  2. Inherent see-and-avoid limits for both pilots. The study shows a small, near-stationary target, an obscuring HUD frame and canopy structure, and the F-16 visible to the Cessna pilot only out the left window. Neither aircraft had cockpit traffic-display or alerting technology.
  3. The Cessna pilot had no contact with ATC. This was legal, but it meant the controller had no verified altitude and route and the Cessna pilot had no ATC traffic information. He had a single radio, and the analysis says he likely would have called later.
  4. Siting/airspace: an IFR approach vector at minimum vectoring altitude near MKS, where the controller believed pattern traffic was rare and stayed below 1,000 ft.
- **Not factors** per the records: weather, sun glare, toxicology (the F-16 pilot was negative; the Cessna pilot's ethanol was consistent with postmortem production), ARTS equipment (CA "worked properly"), and qualification or currency of either pilot or the controller.

## Contradictions / discrepancies
1. **Traffic distance:** the controller called "2 miles"; the study puts the Cessna at 3.25 nm at 1100:16, and the CA fired at 3.5 nm (FN). The F-16 pilot's "confirm two miles?" reflects his radar target at 20 miles.
2. **Sighting distance and time:** AN says "within about 430 ft … about 1 second before"; the pilot's interview says "within 500 feet" and "less than 1 second"; the study says the Cessna "was not visible again until about 2 seconds before the collision".
3. **Collision altitude:** witness estimated "about 900 ft"; radar shows F-16 1,480–1,500 ft and Cessna 1,400–1,440 ft.
4. **Evasive action:** witness 1 says "neither airplane appeared to conduct any evasive maneuvers"; witness 2 says the F-16 "tried to 'pull up'". The pilot reports full aft stick.
5. **Conflict alert:** the system detected the conflict at 1059:59 but presented the alert only at 1100:13. The controller "did not recall seeing or hearing a CA", yet her advisory came 3 s after it.
6. **Collision time:** "about 1101" (FN header) vs 1100:57 (simulation).
7. **"About 40 seconds"** (AN) vs 1100:16 → 1100:57 = 41 s. Consistent.
8. **Document artefact:** the FN text repeats the whole Cessna/F-16 equipment section under "AIRPORT INFORMATION". The airport section itself (MKS) is missing.

## Open questions
- The Cessna pilot's lookout: AN says "Our investigation could not determine to what extent the Cessna pilot was actively conducting a visual scan".
- Whether the Cessna's lights or strobes were on ("could not be determined").
- Whether the F-16's IFF was set to civil modes (the pilot "could not recall").
- Why the CA appeared 14 s after detection.
- Controller workload (she was also sequencing a flight of two F-16s).
- The official NTSB probable-cause wording, which is withheld from this file.

## Effort log
- Documents: 3 of 3 read; about 14,500 words (record page ~60, analysis ~3,300, factual narrative ~11,200 including a duplicated section and long regulatory excerpts).
- Steps: extraction, then a full read of AN, then a full read of FN, then building the second-by-second timeline from FN's radar/voice times, then reconciling distances, altitudes and sighting times. About 5 steps, roughly 30–40 minutes of human-equivalent reading.
- Hard by reading alone:
  - The timing is scattered across "The Collision", "ATC Radar Equipment", the visibility study and the simulation sections. Simulated (hypothetical) times are mixed in with recorded times and must be kept apart.
  - Distances and altitudes differ by source (controller, radar, study, witness).
  - Separating the analysis's descriptive statements from causal judgement takes care.
- Unreadable: none. Figures (flight tracks, cockpit views) are referred to but their images are not in the text.
