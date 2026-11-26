# rc-a-upfront-fee — investigator memo (app-only)

Investigator: AGENT (Claude), 2026-11-03. Build c3e8c5b0, rules path (NOAI=1), 84 modules on.
Sources: only `briefs/rc-a-upfront-fee.md` and `runs/rc-a-upfront-fee/r1..r5/answers.md`.
Disclosure: I don't recognise this case from memory. The bench README's case table summarises the outcome
("three convicted at trial and sentenced (6 yrs, 3 yrs, 45 months); the fourth's outcome is not on file"). I read it
before starting because I was told to read the README first. Every point below rests on an app answer or a passage the app cited, not on that table.
A "release" is one of the five USAO-NJ press releases the app cited (rel-01 2017-04-19, rel-02 2018-04-16, rel-03 2022-10-24, rel-04 2023-06-23, rel-05 2023-07-26).

## Conclusion

1. **Scheme.** From March to June 2016, Mignott, Adkins, Douglas and Gillar allegedly agreed to defraud "Victim Company A" of about $1 million. The pitch was a joint-venture agreement in which the company would pay $1 million as the "bank fee associated with the standby letter of credit". The company owners sent $800,000, received no SBLC "or anything of value", and the defendants "misappropriated the money for their personal use". Sources: rel-01, rel-02, rel-04, rel-05 cited passages (r1 q01/q09, r2 q14, r3 q12, r5 q07). Confidence: high.
2. **Charges developed.** 2017-04-19 criminal complaint: each man charged with one count of conspiracy to commit wire fraud (rel-01; r1 q02). 2018-04-16 superseding indictment: "indicted today on additional charges", now "four victims of over $1 million". The new victims were Victim Company B ($250,000 to Adkins and Douglas's shell company) and Individual Victim 3 ($90,000 to Adkins and Mignott, who were seeking financing for his pork business) (rel-02; r1 q15, r2 q11, r2 q13). Maximum penalty for each count is 20 years and $250,000 (r2 q16). Confidence: high.
3. **Arrests.** Mignott, Adkins and Douglas were arrested "this morning" (2017-04-19) and appeared before Magistrate Judge Michael A. Hammer in Newark (r2 q15). Gillar was arrested "yesterday" (2017-04-18) and appeared before Magistrate Judge Nancy J. Koppe in Las Vegas (r1 q15). Confidence: high.
4. **Trial.** Three men were convicted by a federal jury after a five-week trial before U.S. District Judge John Michael Vazquez (rel-03 headline, rel-05; r4 q05). Douglas was "convicted on Oct. 21, 2022, of wire fraud conspiracy and four counts of wire fraud" (rel-05; r1 q10). The app identifies the other two as Gillar and Mignott: its Gillar case history lists "convicted" on 2022-10-24, and rel-04 says Douglas "was also convicted". I could not get the counts of conviction for Mignott and Gillar. Confidence: high for the three convictions, medium for their exact counts and date.
5. **Sentences.**
   - **Roy Johannes Gillar, 51, of Las Vegas:** 6 years in prison, 3 years supervised release, $1.1M restitution and $1M forfeiture, on 2023-06-23 (rel-04; r1 q15, r3 q02, r5 q10). Confidence: high.
   - **Harold Mignott, 60, of Voorhees:** **3 years** in prison, 3 years supervised release, $1.1M restitution and $219,000 forfeiture, on 2023-06-23 (rel-04 verbatim passage cited in r1 q12; r3 q03). Confidence: high, read from the cited passage. **The app's own sentence said "six years", which is wrong (see Experience log).**
   - **Jerrid Douglas, 49, of Freehold:** 45 months in prison, 3 years supervised release, $1.1M restitution and $44,750 forfeiture, on 2023-07-26 (rel-05; r1 q14, r3 q01). Confidence: high.
   - **James Adkins, 64 (in 2017), of Hillside:** no plea, trial, verdict or sentence is on file. The app correctly refused four times ("The documents that name James Adkins don't state a sentence for James Adkins."). The 2022/2023 releases refer to "a fourth conspirator" without naming him (r3 q08, r4 q15). It is plausible, but not established, that this is Adkins. The record is silent on his outcome. Confidence: high that it's silent.
6. **People around the case.** FBI special agents under SAC Timothy Gallagher (Newark) investigated (r4 q14). The releases were announced by Acting U.S. Attorney Fitzpatrick (2017), Craig Carpenito (2018) and Philip R. Sellinger (2022–23). Defense counsel were Breslin (Mignott), Buchan (Adkins), Ashley (Gillar) and Corazza (Douglas), from the findings report. I could not get the trial AUSAs.

## Timeline

| date | event | source |
|---|---|---|
| Mar–Jun 2016 | conspiracy period; SBLC fee pitch; Victim Co. A sends $800k of $1M | rel-01/02/04/05 |
| 2017-04-18 | Gillar arrested, Las Vegas (Mag. J. Koppe) | rel-01 |
| 2017-04-19 | Mignott, Adkins, Douglas arrested, Newark (Mag. J. Hammer); complaint, 1 count conspiracy to commit wire fraud each | rel-01 |
| 2018-04-16 | superseding indictment, additional charges, 4 victims, >$1M | rel-02 |
| 2022-10-21 | jury verdict after 5-week trial (Judge Vazquez); Douglas: conspiracy + 4 counts wire fraud | rel-05 |
| 2022-10-24 | release: three men convicted | rel-03 |
| 2023-06-23 | Gillar 6 yrs; Mignott 3 yrs (+ SR, restitution, forfeiture) | rel-04 |
| 2023-07-26 | Douglas 45 months (+ SR, $1.1M, $44,750) | rel-05 |
| — | Adkins: nothing after 2018-04-16 | (silence) |

## Contradictions / discrepancies (none flagged by the app: "contradictions found: 0; gaps found: 0" in every round)

- **Loss and victim count shift between releases.** The 2017 headline says "$800,000" and "defrauding two individual victims out of approximately $8[00,000]". The 2017 complaint text in the same release says "Victim Company A … out of approximately $1 million". 2018 says "four victims of over $1 million". The 2022/23 releases say $800,000 of the $1 million was actually transmitted. This is reconcilable: $1M was the agreed fee and $800k was paid. But "two individual victims" against "Victim Company A" is an unexplained wording difference. I could not get the app to explain it. Asked twice (r4 q09, r5 q04/q05), it returned the Victim Company A sentence each time.
- **Four defendants charged, three tried and sentenced.** Adkins drops out of the record after 2018. The app's gap detector did **not** flag this ("No missing-evidence gaps found in scope."), even though it is the most important silence in the file.
- **Date shift in the findings report.** Every dated finding is one day early: "On 2017-04-17 — Roy Johannes Gillar arrested" (the text says arrested 04-18), "On 2018-04-15 … charged" (release 04-16), "On 2022-10-20 — Jerrid Douglas convicted" (Oct. 21), "On 2023-06-22", "On 2023-07-25". The r4 q10 timeline repeats it ("Apr 17, 2017", "Apr 15, 2018").

## Open questions

- Adkins's outcome: the record is silent (the app refused correctly).
- Counts of conviction for Mignott and Gillar: every phrasing returned a defense-counsel line or "don't give a count" (r2 q10, r3 q04/q05, r4 q02/q03/q04, r5 q03).
- Identity of the "fourth conspirator": the app only echoed the sentence (r3 q08, r4 q15).
- Trial AUSAs: the app returned garbled text (r2 q17, r3 q18).
- Total loss across all four victims: the app gave a list of amounts with no total (r2 q11).

## Round log

- **r1 (16 Qs):** charges, arrests and the Gillar history were good; all four "role" questions refused; Mignott's sentence was given as **six years** (wrong); the judge question was garbled.
- **r2 (20 Qs):** Gillar 6 yrs confirmed; Mignott still "six years"; $250k Victim Co. B, max penalty and Newark arrests found; many answers were defense-counsel lines; "When did the jury convict" was refused.
- **r3 (18 Qs):** Mignott and Douglas restitution/forfeiture found; "fourth conspirator" passage found; conviction counts failed; FBI refused, though the cited passage named the FBI.
- **r4 (16 Qs):** Oct 21, 2022 verdict date and five-week trial found; FBI/Gallagher found; "Harold Mignott was sentenced to how many years" refused; forfeiture questions refused; "What happened to the two individual victims" returned a timeline with the same sentence five times.
- **r5 (11 Qs):** Gillar's $1M forfeiture found, under a garbled answer; Mignott's prison term came back as a defense-counsel line; the defense-attorney question returned an unrelated sentence.

## Experience log

**Effort:** 5 rounds, 81 questions. About 25 gave a usable fact, about 15 were correct refusals or silences, and about 40 were garbled, off-target or wrong. Each round took under a minute.

**Where it helped**
- **Per-person case history.** "What happened to Roy Johannes Gillar?" returned "The case against Roy Johannes Gillar, in date order (6 steps from 4 documents)". It covered arrest, superseding indictment, conviction and sentence, each with a verbatim quote. This was the single most useful answer.
- **Honest refusals on Adkins.** "The documents that name James Adkins don't say whether James Adkins pleaded guilty." / "…was convicted." / "…don't state a sentence for James Adkins." These are correct and consistent across 4 phrasings, and they told me the record is silent.
- **Cited passages.** Every answer carries its passage, so I could catch errors myself. The Mignott error was only catchable because the quote was printed beside it.
- **Custody.** "custody entries: 5 (5 hashed)".

**Where it hurt or misled**
- **Wrong prison term for Mignott, asked twice.** The answer read: "Harold Mignott was sentenced to six years in prison. The document says: 'Roy Johannes Gillar, 51, of Las Vegas, was sentenced to six years in prison; Harold Mignott, 60, of Voorhees, New Jersey, was sentenced to three years in prison.'" It came back at confidence 0.8 with no caution, in r1 q12 and r2 q01, in both Ask and the case view. A third phrasing ("Harold Mignott was sentenced to how many years in prison?") was refused: "The documents don't give a count for this." A fourth ("Harold Mignott, 60, of Voorhees was sentenced to what prison term?") returned "Mignott: Eric Breslin Esq., Newark." An investigator who reads only the first line gets the wrong sentence.
- **Defense-counsel lines as answers.** Many questions were answered with the defense-counsel table line, for example "What did Jerrid Douglas do in the scheme?" → "Douglas: Joseph Corazza Esq., Sparta, New Jersey." The same happened for "What counts were Mignott and Gillar convicted of?", "What supervised release did Douglas get?" and "What did Adkins and Mignott promise Individual Victim 3?" → "Mignott: Eric Breslin Esq., Newark." These were not refusals, so they look like answers.
- **Wrong person for "three years".** "Who was sentenced to three years in prison?" returned Douglas's "three years of supervised release". The correct passage (Mignott, three years in prison) exists.
- **Refusals with the answer in hand.**
  - "When was the jury verdict?" → "None of the documents on file states the investigators' conclusion; they hold the factual record only." The verdict date (Oct. 21, 2022) is in rel-05.
  - "Which agencies are credited with the investigation?" → "The documents searched don't mention the agencies." The cited passage itself reads "credited special agents o[f the FBI]".
  - "What forfeiture was Gillar ordered to pay?" → "The documents searched don't mention the forfeiture." The figure is in rel-04, and the app itself quoted "forfeiture of $1 million" in r1 q15.
- **Garbled text.**
  - "Which judge presided over the case?" → five release headers spliced together, ending "Caution: not found verbatim in the evidence: Nev However."
  - "When were the defendants arrested?" → five headers spliced together at confidence 0.87.
  - "What sentence did Judge Vazquez impose on Douglas besides prison?" → "Judge Vazquez was sentenced to three years of supervised release and ordered to pay restitution of $1 …", which makes the judge the subject.
- **Findings report.** It lists the judge as a defendant: "On 2018-04-15 — John Michael Vazquez charged", "On 2022-10-23 — Judge John Michael Vazquez convicted". All dates are one day early. It reports "0 conflict(s) and 0 evidence gap(s)", missing Adkins's disappearance.
- **Off-target quotes.** "How did the defendants persuade Victim Company A to pay?" and "What misrepresentations did the defendants make…" both returned the sentence about the $1M fee agreement, not the misrepresentations.

**Would I trust it on a real case?** Only as a passage finder. I would read every cited passage and never the answer's first line. It got the per-person timeline and the "nothing on file" calls right. But it stated a wrong prison term for a named defendant at normal confidence, twice. It made the judge a defendant in the report, shifted every report date by a day, and missed the one real gap (Adkins).
