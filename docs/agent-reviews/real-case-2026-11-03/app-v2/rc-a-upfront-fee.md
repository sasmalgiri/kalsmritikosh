# rc-a-upfront-fee: investigator memo (app v2, Online mode, Opus 5)

Investigator: agent. I learned the case only from the app's answers in `runs-v2/rc-a-upfront-fee/r1..r3/answers.md`. I don't recognise this matter from memory.
**Important run condition:** only **r1** had the AI reader. In **r2 and r3 every cloud call failed** (`The provider returned HTTP 400: Your credit balance is too low to access the Anthropic API.`: answerComposer 30/30 failed in r2, and every reader in r3 as well). Those rounds are evidence-only (rules) answers. The round header still said `ok`.

## Conclusion

Four men were charged by complaint (release dated 19 Apr 2017), then indicted (Dec 2017), then superseded (16 Apr 2018). Three of them, **Mignott, Douglas and Gillar, were convicted by a jury on 21 Oct 2022 and sentenced in 2023**. For the fourth, **James Adkins, the record shows no outcome at all**.

| Person | Role in the record | Outcome | Source (app answer / passage) | Confidence |
|---|---|---|---|---|
| Harold Mignott, Voorhees NJ (54 in 2017) | Co-conspirator. With Adkins he induced "Individual Victim 3" to pay $90,000 for an SBLC | Convicted 21 Oct 2022 at a five-week jury trial before Judge John Michael Vazquez: wire fraud conspiracy + 4 counts wire fraud. Sentenced to **3 years in prison**, 3 years supervised release, restitution **$1.1 million**, forfeiture **$219,000** | release-03-2022-10-24 (r1 q09); release-04-2023-06-23 (r1 q10; r2 q01 "Mignott was sentenced to three years of supervised release and ordered to pay restitution of $1.1 million and forfeiture of $219,000.") | High |
| Roy Johannes Gillar, Las Vegas (44 in 2017) | Co-conspirator. Also charged with transacting in criminal proceeds | Convicted 21 Oct 2022 (same counts) plus 1 count transacting in criminal proceeds. Sentenced to **6 years in prison**, 3 years supervised release, restitution $1.1 million, forfeiture **$1 million** | release-04-2023-06-23 (r1 q05, q13) | High |
| Jerrid Douglas, Freehold NJ (43 in 2017) | Co-conspirator. With Adkins he defrauded "Victim Company B" of about $250,000 in 2015 | Convicted 21 Oct 2022 (same counts) plus 1 count transacting in criminal proceeds. Sentenced 26 Jul 2023 to **45 months in prison**, 3 years supervised release, restitution $1.1 million, forfeiture **$44,750** | release-05-2023-07-26 (r1 q12 in-case; r3 q01 "Judge Vazquez sentenced Douglas to three years of supervised release, restitution of $1.1 million, and forfeiture of $44,750.") | High |
| James Adkins, Hillside NJ (64 in 2017) | Charged in the complaint, the Dec 2017 indictment and the 2018 superseding indictment (3 counts of wire fraud added) | **Silent.** No plea, verdict, dismissal or sentence in any document. He is not named in the 2022 trial release. Releases from the trial onward speak of "Douglas, Gillar, and Mignott, along with a fourth conspirator" | release-02-2018-04-16 (r1 q01); r1 q11 refused: "The documents that name James Adkins don't say whether James Adkins pleaded guilty."; Gaps: "(missingOutcome) The outcome for James Adkins … is not in any document of this case." | High that the record is silent. Whether he is the "fourth conspirator" is **not established** |

**The scheme** (r1 q02/q06, release-03/04): March–June 2016. The defendants got the two owners of the victim company to sign a joint venture with their New Jersey shell company. They promised a standby letter of credit (SBLC) "backed by either €1 billion in cash or highly lucrative Mexican gold bonds". The company agreed to pay a $1 million "bank fee" and sent **$800,000**. No SBLC was ever provided, and the defendants "misappropriated the money for their personal use" (release-03, r3 q03). The 2018 superseding indictment added two more victims. Victim Company B lost about $250,000 in 2015 (Adkins, Douglas). Individual Victim 3 paid $90,000 (Adkins, Mignott; "financing for his pork business"). That makes "four victims of over $1 million" (release-02). The victim company is never named: it is "Victim Company A", and the records only say "the victim company". r1 q17 honestly could not confirm a name.

**Prosecution team:** AUSA Jason S. Gould (General Crimes Unit, 2017). AUSAs Gould and Joshua L. Haber represented the government later (release-04, r3 q08). U.S. Attorneys: Acting U.S. Attorney William E. Fitzpatrick (2017), Craig Carpenito (2018), Philip R. Sellinger (2022–23). Investigators: FBI Newark, under SAC Timothy Gallagher (arrests) and SAC James E. Dennehy (conviction and sentencing) (r1 q18). Magistrate judges at first appearance: Michael A. Hammer (Newark) and Nancy J. Koppe (Las Vegas, for Gillar).

## Timeline (from the app's answers)

- Mar–Jun 2016: scheme against Victim Company A (release-01, -03). In 2015, Adkins and Douglas defrauded Victim Company B of about $250,000 (release-02, via the contradiction block).
- 18 Apr 2017: Gillar arrested; appears before Magistrate Judge Koppe in Las Vegas (release-01: "arrested yesterday").
- 19 Apr 2017: complaint announced (1 count conspiracy to commit wire fraud each). Mignott, Adkins and Douglas arrested "this morning" and appear before Magistrate Judge Hammer (release-01, r1 q07).
- Dec 2017: indictment with 1 count conspiracy + 4 counts wire fraud; Douglas and Gillar also charged with 1 count transacting in criminal proceeds (release-02, r1 q01). No exact day given.
- 16 Apr 2018: superseding indictment adds 3 wire fraud counts against Adkins, 2 against Douglas and 1 against Mignott, plus new victims (release-02).
- 21 Oct 2022: Mignott, Douglas and Gillar convicted after a five-week jury trial (release-03).
- 22 Jun 2023: Judge Vazquez sentences Gillar and Mignott (release-04 text: "Judge Vazquez imposed the sentences on June 22, 2023"; the release is dated 23 Jun).
- 26 Jul 2023: Douglas sentenced (release-05).
- Adkins after Apr 2018: nothing.

## Contradictions

**Flagged by the app (r1, all three by the AI reading). None of them is a real contradiction:**
1. "Jerrid Douglas's alleged fraud involving Victim Company B: approximately $250,000 vs $1 million". One figure is the agreed fee ($1 million), the other is the loss (~$250,000). That is the same pattern as Victim Company A ($1 million agreed, $800,000 paid). **Misleading.**
2. "Million Advance Fee Scheme: $1 Million vs $800,000". The 2017 headline counts one victim. The 2018 headline counts four victims after the superseding indictment. This is the case growing, not two records disagreeing. **Misleading.**
3. "four victims vs two individual victims". Same reason: the complaint had two victims and the superseding indictment four. **Misleading.**
The app turned all three into Gaps that ask for "payment, bank or financial records behind both figures". That would send an investigator chasing a non-issue.

**Found by me:**
- Sentencing date for Gillar and Mignott: the text of release-04 says **22 Jun 2023**, but the app's chronology entry is "2023-06-23 — Roy Johannes Gillar sentenced" (the release date). Its own AI-read entry "2023-06-22 — Sentences imposed" sits next to it. The app did not flag the clash.
- Who was the "fourth conspirator"? The 2017 and 2018 releases name four defendants, Adkins included. From the 2022 trial onward the releases name three plus "a fourth conspirator". This is a gap, not a contradiction, and the app surfaced it only as Adkins's missing outcome.
- Restitution of $1.1 million matches $800,000 + ~$250,000 + $90,000 ≈ $1.14 million. **That is my inference.** The record never says how the $1.1 million was computed, or whether it is joint.
- Ages are consistent across releases (Mignott 54→55→60→60; Gillar 44→45→50→51; Douglas 43→44→49→49). The app correctly flagged nothing here.

## Open questions (record silent)
- Adkins: severed? pleaded? dismissed? died? Nothing on file.
- The exact day of the December 2017 indictment, and the counts in the final trial verdict compared with the superseding indictment's added counts. Douglas was convicted of "four counts of wire fraud", though the superseding indictment added 2 against him. Their disposition is not stated.
- The name of the victim company and the shell company, which are never given.
- Whether the $1.1 million restitution is joint and several.

## Round log
- **r1** (18 questions, AI reader working, 12 min): established nearly everything: charges, roles, trial, sentences for three men, Adkins's silence, the prosecution team, and Gillar's restitution and forfeiture. Restitution for Mignott and Douglas was NOT answered (q15 "could not confirm").
- **r2** (16 questions, **all AI calls failed: credit balance too low**): rules-only answers. Got Mignott's supervised release, restitution and forfeiture. Douglas's question returned Gillar's sentence (see failures).
- **r3** (10 questions, AI still failing; I phrased questions close to the likely release wording so the rules path could hit): got Douglas's supervised release, restitution and forfeiture, and the trial AUSAs.
- Total: 44 questions over 3 rounds. Roughly 2.5 h wall-clock, mostly waiting in the shared lock queue.

## Experience log

**Where it helped**
- The r1 AI answers were excellent: each claim came with a verbatim quote and the document, e.g. q01 assembled complaint → indictment → superseding counts per defendant from two releases in one answer. q07 correctly split the arrest days (Gillar "arrested yesterday", the other three "this morning"), and the proceeding timeline for Gillar (q13) put 7 steps in date order.
- It refused honestly on Adkins: "The documents that name James Adkins don't say whether James Adkins pleaded guilty." The Gaps block also raised "(missingOutcome) The outcome for James Adkins … is not in any document of this case". That is the single most important finding in this case, and the app gave it to me unprompted.
- The cast of characters sorted officials (judge, AUSAs, U.S. Attorneys, FBI SACs) from defendants correctly, which spared me reading every release for names.
- Offline (r2/r3), the rules path still returned verbatim, correctly attributed sentences when the question echoed the document's wording (r2 q01 Mignott, r3 q01 Douglas).

**Where it slowed or misled me (exact words)**
- **Findings report lists the judge as convicted:** "On 2022-10-21 — Judge John Michael Vazquez convicted". The same report treats one man as two people: "Roy Gillar charged" and "Roy Johannes Gillar convicted".
- **Wrong person, high confidence (r2 q02 and r3 q02, 0.8):** I asked for Douglas's restitution and forfeiture. The answer was "In addition to the prison terms, Judge Vazquez sentenced Gillar to three years of supervised release and ordered to pay restitution of $1.1 million and forfeiture of $1 million." Someone reading quickly would give Douglas a $1 million forfeiture; his real figure is $44,750.
- **False "no date" (r3 q09, 0.8):** "The documents don't give a date for this." But release-04 says "Judge Vazquez imposed the sentences on June 22, 2023" (r1 q14).
- **r1 q15 failed outright:** "Needs review — the AI reading could not confirm this … Your archive carries conflicting values for amount: • $1,000,000 • $250,000 • $800,000 • $90,000". None of those figures is restitution, yet restitution and forfeiture for all three men are in the releases.
- **Garbage offline answers:** r2 q16 "Which Assistant U.S. Attorneys tried the case?" returned a run-on mash of three passages plus "Caution: not found verbatim in the evidence: Specia Instead." r3 q03 did the same, with "Caution: not found verbatim in the evidence: The  As." r2 q04 ("Was James Adkins tried together…?") returned the 2017 complaint sentence, which is a non-answer. r2 q12 ("Who were the four victims?") returned a list of amounts.
- **The chronology draft** omits the 19 Apr 2017 complaint and arrests of Mignott, Adkins and Douglas, and the Dec 2017 indictment. It dates "charged" for all four men to 2018-04-16, the superseding indictment.
- **All three flagged contradictions are false** (see above).
- The round header said `ok` when every cloud call had failed. Each answer did say "(The AI reading could not be used — the AI reader did not answer. This is the evidence-only reading.)", which is honest but never says why. The reason (out of credit) appears only in the run footer.

**"Needs review" items: were they right?**
- r1 q04 (Douglas's role): the AI reading was correct and complete. The evidence-only side ("scheduled to be sentenced on July 26, 2023") does not disagree. **False alarm.**
- r1 q08 (indictment): the AI reading was correct. The evidence-only side was a jumbled passage mash. **False alarm.**
- r1 q14 (judge): the AI was correct (Vazquez; magistrates Hammer and Koppe). The evidence-only side was about the $1 million fee. **False alarm.**
- r1 q01 in-case: the AI was correct, and the evidence-only side (the Individual Victim 3 passage) is compatible. **False alarm.**
- r1 q15 and q17 ("could not confirm"): q17 was right, since the name is not in the record. q15 was wrong, since restitution and forfeiture are on file.
- Summary: 0 of 4 value conflicts were real, and 1 of 2 "could not confirm" was right.

**Would I rely on it?** With the AI reader on, yes: for a first pass on who / charged / convicted / sentenced, with quotes I can check, and for spotting a missing outcome (Adkins). Not for money questions (restitution and forfeiture needed person-specific, document-worded questions). Not for the contradictions list or the findings report, both of which contained clear errors. Without the AI reader (r2/r3), only as a phrase finder: it answers when you already know roughly what the sentence says, and it can confidently hand you another defendant's sentence.
