# rc-f-logan-arson — investigator memo (app-only)

Investigator: agent (Claude), working only through `round.sh` / `runs/rc-f-logan-arson/*/answers.md`.
Build: c3e8c5b0, rules path (no AI model), 84 modules on. Rounds: smoke (pre-existing, 3 q) + r1–r5 (90 questions).
I did not recognise this case from memory. Disclosure: the bench README's case table (which I was told to read)
summarises the outcome: sentence range, "$75k vs $50k", "who spread the fuel", "which camera". So I knew
what kinds of disagreement to look for before I started. Every claim below rests on an app answer, not on the README.

## Conclusion

| # | Point | Rests on (round/question → cited document) | Confidence |
|---|---|---|---|
| 1 | **Glick planned it.** James Gregory Glick (44, Logan) arranged the burning of the office building at 111 Stratton Street, Logan, to collect insurance. He bought the building in January 2012 for $50,000, across the street from his own restaurant, the 317 Steakhouse. | r1 q02 → release-01 ("in November 2011, Glick allegedly arranged to have an office building … burned to collect more than $1 million"); r5 q09/q10/q14 → release-04/-05 ("In January 2012, Glick purchased … for $50,000, across the street from the restaurant he owned and operated, the 317 Steakhouse") | High |
| 2 | **Thompson got the insurance.** William Jamey Thompson (44–45, Chapmanville), an independent insurance agent, was paid by Glick to get a fraudulently inflated $1 million policy from General Star Indemnity Company. He was also charged with filing the false property-loss claim. | r1 q10 → release-01; r2 q02 → release-02; r4 q07 → release-01 | High (role); amount disputed, see Contradictions |
| 3 | **Miller organised the fire.** Guy R. Miller Jr. (40, Logan) organised the fire on Feb 1, 2012, while Glick was out of town. He recruited Shawn C. Simon (41, Charleston) and Michael D. Williams (44, Logan). | r1 q08 → release-04 ("Miller … enlisted the assistance of Shawn C. Simon … and Michael D. Williams … to help torch the building"); the "While Glick was out of town … Miller orchestrated the burning of the structure with Williams and Simon" fragment appears in spliced answers r1 q18, r3 q11, r4 q16 | High (Miller's role); medium on "out of town" (only seen inside spliced fragments, never as a clean quote) |
| 4 | **Who set it (latest account):** Williams spread about 15 gallons of gasoline on the first floor and lit it. Simon drove the getaway car and then destroyed the digital video recorder of the neighbouring 317 Steakhouse (obstruction). | r2 q14, r4 q15 → release-05; r2 q13/q15 → release-05; r3 q05 → release-03 ("Mr. Simon previously pleaded guilty in November to obstruction of justice for his role in destroying a security camera that captured the arsonists fleeing the scene") | Medium: the sources disagree (see Contradictions) |
| 5 | **Money.** General Star paid Glick $1,010,000 in May 2012 "without sufficient evidence of the arson", and Glick shared it with co-conspirators. In June 2013, IRS-CI and the West Virginia State Police seized the remaining $450,000. Restitution: $1,010,000 to General Star, plus $3,900 that Glick and Thompson must pay the City of Logan. Glick also made more than nine transactions over $10,000 at Logan Bank & Trust, and a fragment shows he "structured more than $170,000". | r3 q08, r4 q05, r5 q06, r4 q12 → release-04; r3 q09 → release-03; $170,000 only in spliced fragments (r2 q19, r5 q13) | High; $170,000 medium |
| 6 | **Charges.** On Sept 3, 2013 a 36-count indictment was unsealed against Glick, Miller, Simon and Thompson. Williams is not named in it. The May 2014 release says the conspirators were "indicted in late August 2013". | r1 q01 → release-01; r4 q11 → release-04 | High |
| 7 | **Pleas.** Glick and Miller pleaded guilty Nov 6, 2013: Glick also to unlawful monetary transactions and structuring, Miller also to an oxycodone conspiracy. Simon pleaded in November 2013 (obstruction). Thompson pleaded Dec 12, 2013 (conspiracy to commit mail and wire fraud, aiding and abetting arson) before Judge Thomas E. Johnston. | r3 q06, r2 q18 → release-02; r3 q05, r2 q06 → release-03 | High (Glick, Miller, Thompson); medium (Simon: month only) |
| 8 | **Sentences.** Glick: 7 years 3 months. Thompson: 5 years (both sentenced May 21, 2014). Miller: 6 years 3 months (Wednesday, May 28, 2014). Simon: 22 months (Thursday, May 29, 2014). **Williams: not established.** The app never produced his own sentence. | r1 q12 → release-04; r2 q12; r1 q14 → release-05; r2 q11, r3 q17 → release-05 | High for four; Williams unresolved |
| 9 | Prosecution: U.S. Attorney Booth Goodwin; AUSA Thomas Ryan in charge. | r2 q12, r3 q19 → release-04/-05 | High |

## Timeline (reconstructed)

- Nov 2011: Glick arranges to have the building burned (indictment wording, release-01).
- Jan 2012: Glick buys 111 Stratton Street for $50,000 (release-04/-05).
- Feb 1, 2012, early hours: building burned. Miller, with Simon and Williams; the 317 Steakhouse's Main Street security cameras capture Miller, Simon and Williams fleeing (r4 q08 → release-05).
- After the fire: Simon destroys the 317 Steakhouse's DVR.
- May 2012: General Star pays Glick $1,010,000.
- June 2013: IRS-CI and WVSP seize the remaining $450,000.
- Late Aug 2013: indictment returned. Sept 3, 2013: 36-count indictment unsealed against four (Glick, Miller, Simon, Thompson).
- Nov 6, 2013: Glick and Miller plead guilty. Thompson and Simon plea hearings set for Nov 7, 2013 (r3 q14 → release-02). Glick's sentencing set for Feb 19, 2014 (r4 q04 → release-02).
- Nov 2013: Simon pleads guilty (obstruction).
- Dec 12, 2013: Thompson pleads guilty (release-03, an e-mail forwarding the DOJ release).
- May 21, 2014: Glick (7 y 3 m) and Thompson (5 y) sentenced, plus restitution.
- May 28, 2014: Miller sentenced (6 y 3 m). May 29, 2014: Simon sentenced (22 months). Williams was due to be sentenced May 29 (r4 q01 → release-04, "Williams and Simon will be sentenced on May 29, 2014"); outcome not surfaced.

## Contradictions / discrepancies between sources

1. **Thompson's payment: $75,000 vs $50,000.** The indictment release (release-01) says "approximately $75,000" (r1 q10); the plea release (release-02) says "approximately $50,000" (r2 q02). **The app did not flag this.** I found it only because I asked "Did Glick pay Thompson $50,000?". The case workflow reported "contradictions found: 0" and "No conflicting accounts found in scope." in every round.
2. **Who spread the gasoline.**
   - release-02: "Guy Miller, Shawn C. Simon, 41, of Charleston and another associate worked together to set the fire by spreading gasoline throughout the main floor." (r1 q04)
   - The timeline/findings: "Simon, 41, of Charleston and Michael Williams, 44, of Logan, worked together to set the fire to the building by spreading gasoline throughout the main floor."
   - release-05: Williams spread ~15 gallons and lit it; Simon "drove the getaway car" (r2 q13/q14).

   The app listed both of the first two accounts as separate dated "findings" on 2012-02-01 but did **not** flag them as conflicting.
3. **What was destroyed:** "a security camera that captured the arsonists fleeing the scene" (release-03) vs "the digital video recorder from the neighboring restaurant, the 317 Steakhouse" (release-05). Release-05 also says the restaurant's "Main Street side security cameras … captured Miller, Simon and Williams fleeing". These are compatible (camera footage on a DVR) but described differently. Not flagged.
4. **Planning before ownership:** "in November 2011, Glick allegedly arranged to have [the building] burned" (release-01) vs "In January 2012, Glick purchased" it (release-04/-05). Possibly planned before buying; worth noting. Not flagged.
5. **Indictment date:** "late August 2013" (release-04) vs unsealed Sept 3, 2013 (release-01). Consistent (returned, then unsealed). The app's own findings date the charge "2013-09-02", one day before the release.
6. **Schedules that slipped:** Thompson's plea hearing was set for Nov 7, 2013, but he pleaded Dec 12, 2013. Glick's sentencing was set for Feb 19, 2014, but happened May 21, 2014. Not contradictions, just schedule changes. Not flagged (and not expected to be).

## Open questions

- **Michael D. Williams: charge, plea and sentence.** Asked 9 different ways (r1 q08/q15, r2 q08/q09/q10, r3 q01–q03, r4 q01/q02, r5 q01–q04). Every sentence question got Simon's sentence sentence back; plea/charge questions were refused. The May 30, 2014 release headline mentions "25 Years Of Pr[ison]", but the app never quoted the Williams sentence. Unresolved: the app could not surface it.
- How much Miller (and the others) received from the $1,010,000. Asked 3 times (r1 q11, r2 q04, r3 q10, r4 q06); never answered.
- Which court or agency the "Joint Federal and State Investigation" headline refers to (r4 q03 answered with the IRS/WVSP seizure).
- Total of 36 counts and how they split by defendant; the indictment's text beyond the press release.
- The exact $170,000 structuring passage: only seen cut off ("structured more than $170,000 in monies from accounts at LB&T durin…").

## Round log

- **smoke** (3 q, pre-existing): who was charged / Glick's sentence / fire date. Glick 7 y 3 m found; "who was charged" was a spliced dump.
- **r1** (20 q): roles, sentences, insurer, camera, cover-up. Found the four-person indictment, Glick's plan, $75k to Thompson, General Star, Miller 6 y 3 m, Simon 22 m. Thompson role/sentence refused; Williams's sentence answered with Simon's.
- **r2** (20 q): payments, pleas, Williams, getaway, gasoline, DVR, AUSA. Found the $50k vs $75k discrepancy, Thompson's plea (Dec 12, 2013), Williams spreading gasoline, Simon getaway/DVR, Miller's oxycodone plea.
- **r3** (20 q): plea dates, insurance payout, structuring, judge, AUSA, restitution. Found $1,010,000 payout, Glick/Miller Nov 6 pleas, Simon's November obstruction plea, AUSA Thomas Ryan, restitution fragment. Two double-date errors for Miller.
- **r4** (16 q): Williams again, state prosecution, shares, camera, indictment date, restitution. Found $1,010,000 + $3,900 restitution, $450,000 seized, cameras captured the three fleeing, "indicted in late August 2013", "Williams and Simon will be sentenced on May 29, 2014". Williams still unresolved.
- **r5** (14 q): Williams four more ways, Miller's sentence, seizure, structuring, Glick's whereabouts, counts, US Attorney. Found Glick bought the building for $50,000 and owned the 317 Steakhouse. Williams still unresolved; several answers off-topic.

## Experience log

**Effort.** 6 runs (smoke + 5 rounds), 93 questions. Each round took under a minute of compute; queue wait was a few minutes behind other investigators. Roughly 40–50 % of answers were usable as is; the rest were off-topic quotes, spliced dumps or wrong-person answers.

**Where the app made the work easier**
- When it hit, it hit cleanly: one verbatim sentence, one named document, e.g. r3 q08 "Without sufficient evidence of the arson, General Star paid Glick the $1,010,000 insurance policy proceeds in May 2012…". Every good answer could be traced to a document by file name.
- It worked out sentencing days from relative wording, correctly: "William Jamey Thompson was sentenced on May 21, 2014 (the release is dated May 22, 2014)" from "sentenced in federal court yesterday"; Miller on Wednesday May 28, Simon on Thursday May 29.
- It read the scanned image-only PDF (release-01) and the DOCX/EML without OCR errors.
- Asking a yes/no question with a specific figure ("Did Glick pay Thompson $50,000?") retrieved the second document's figure, which exposed the discrepancy.

**Where it made the work harder or misled me** (exact words)
- **Wrong-person sentence, repeated, at normal confidence (0.8).** r1 q15, r2 q10, r3 q01: "Michael D. Williams was sentenced to 22 months in prison for destroying the digital video recorder from the neighboring restaurant, the 317 Steakhouse, operated by co." The quoted sentence is about **Simon** ("Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams and was sentenced Thursday to a term of 22 months…"). r5 q01 even answered "Yes — " to "was sentenced to how many years?". r4 q02 "Was Michael D. Williams sentenced in state court?" → "Yes — “Shawn C. Simon … was sentenced Thursday…”". On a real case this would put the wrong sentence in a report.
- **Contradictions not detected.** Every round: "contradictions found: 0" / "No conflicting accounts found in scope." despite $75,000 vs $50,000 and three versions of who spread the gasoline. The findings list even prints two conflicting fire-setter findings back to back without linking them.
- **Self-contradiction across questions.** r1 q12 quoted "William Jamey Thompson … was sentenced to five years in prison", but r1 q13 refused: "The documents that name William Jamey Thompson don't state a sentence for William Jamey Thompson."
- **Invented second events.** r3 q04: "Guy R. Miller was pleaded guilty on November 6, 2013 and again on December 12, 2013 … the documents record more than one", from a Dec 12 sentence saying he "previously pleaded guilty last month". r3 q16: "Guy R. Miller was sentenced on May 28, 2014 and again on May 29, 2014", the second date coming from Simon's sentence sentence.
- **Wrong figure for the question asked.** r1 q10 "How much did the insurance company pay?" answered with the $75,000 paid **to Thompson**. r5 q14 "Who orchestrated the burning?" → "In January of 2012, Glick bought the commercial building for $50,000."
- **Off-topic default quote.** At least 10 answers returned the indictment headline sentence for unrelated questions (r2 q01 "How much did Glick pay … Thompson?", r2 q04, r2 q05, r3 q07, r3 q10, r5 q05, r5 q08), presented as "The document states: …" with "(Quoted verbatim from the cited document; no model was consulted.)". The verbatim label makes an irrelevant answer look verified.
- **Spliced dumps.** r1 q18, r2 q16, r3 q11, r4 q16, r5 q13: headlines and fragments run together ("…Results in 25 Years Of Pr While Glick was out of town…"). These carried a "Caution: not found verbatim in the evidence: …" line, which is honest but leaves nothing usable.
- **Wrong refusals.** r1 q06 "What role did William Jamey Thompson play?" → "The documents searched don't mention the role." r1 q09 the same for Simon. r2 q17 "What other crimes did Glick commit besides the arson?" → "The documents searched don't mention the other crimes." (structuring and unlawful monetary transactions are in release-02/-03). r2 q07 refused a plea date that r3 q04/q05 later answered.
- **Findings report errors.** "On 2013-09-02 — Booth Goodwin charged" and "On 2014-05-29 — Booth Goodwin sentenced": Booth Goodwin is the U.S. Attorney. Every finding date is one day early versus the releases ("2013-12-11 — William Jamey Thompson pleaded guilty" vs Ask's "December 12, 2013"; "2014-05-20" vs Ask's "May 21, 2014"). False gaps: "Shawn C. Simon: no charging document on file" and "Guy R. Miller: no charging document on file", though the Sept 2013 indictment names both. "Michael D. Williams: sentenced, with no plea or verdict on file" assumes a sentence the app never produced. Undated amount findings "$50 USD", "$10,000 USD", "status: filed" have no context. The executive summary says "14 finding(s) are supported by the sources".
- r5 q12 (original sentencing date) produced a "History of the user's archive" block instead of the Feb 19, 2014 date it had quoted in r4 q04.

**Would I trust it on a real case?** As a search tool that shows me a sentence and its document, partly yes, because I can check the quote myself. As an answerer, no. It gave a wrong-person sentence five times at confidence 0.8. It reported zero contradictions on a file whose central facts disagree. Its findings report names the prosecutor as a defendant. Every answer needs reading against the quoted sentence, and every "no contradictions" needs ignoring.
