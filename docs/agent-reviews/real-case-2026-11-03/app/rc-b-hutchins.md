# rc-b-hutchins — investigator memo (app-only)

Investigator: AGENT (Claude), 2026-11-03. Build c3e8c5b0, rules path (NOAI=1), 84 modules on.
Sources: only `briefs/rc-b-hutchins.md` and `runs/rc-b-hutchins/r1..r5/answers.md`.
Disclosure: I don't recognise this case from memory. The bench README's case table summarises it ("plea, 14 months"; Patricia 16 months; William 37 months). I read it before starting because I was told to read the README first. Below I report only what the app gave me. I did **not** get Patricia's or William's terms from the app.
Releases cited by the app:
- rel-01 2014-01-22 (William Hutchins)
- rel-02 2022-03-29 (indictment)
- rel-03 2024-09-12 (superseding indictment)
- rel-04 2025-03-19, rel-06 2025-06-26, rel-07 2025-10-07 (Patricia Hutchins)
- rel-05 2025-03-20 (plea)
- rel-08 2026-01-21 (sentencing)

## Conclusion (John L. Hutchins of Lewiston, NY)

1. **Charged.**
   - 2022-03-29: a federal grand jury in Buffalo indicted "John L. Hutchins, 68, of Lewiston, NY, and Roberto Soliman, 39, of Niagara Falls, NY, with conspiracy to commit wire fraud and bank fraud". The case concerned fraudulent loan applications under the EIDL and PPP programs, "more than $750,000", and AUSA Paul E. Bonanno was handling it (rel-02; r1 q01/q02, r2 q02).
   - 2024-09-12: a superseding indictment charged both with "conspiracy to commit wire fraud and bank fraud, bank fraud, and wire fraud", still "more than $750,000". It also said "Hutchins and Soliman applied for and received two Paycheck Protection Program loans totaling $115,978", and that "In November 2020, Hutchins is accused of making a false statemen[t]…", which the app truncated (rel-03; r5 q10, r3 q11, r4 q03).
   - Confidence: high.
2. **Co-defendant.** Roberto Soliman of Niagara Falls is named in both indictments and the sentencing (r2 q02). Confidence: high.
3. **Plea.** Per the release dated 2025-03-20, "John L. Hutchins, 71, of Lewiston, NY, pleaded guilty before Judge Meredith A. Vacca to conspiracy to commit wire fraud and bank fraud, which carry a maximum penalty of 30 years in prison and a $1,000,000 fine". The headline says "more than $1.8 million" (rel-05; r3 q02/q06). The plea date is the release date ("announced today"). Confidence: high.
4. **Sentence.** On 2026-01-21, Judge Meredith A. Vacca sentenced him: "Hutchins was sentenced to serve 14 months in prison, while Soliman was sentenced to serve 20 months." He was 72 (rel-08; r1 q08/q09, r2 q01). The release quotes an official: "the pair stole nearly $2 million from the program" (r4 q05). Confidence: high.
5. **Business.** He owned the Rapids Theatre, Niagara Falls. The entity "Rapids Theatre Niagara Falls, USA, Inc." appears in rel-05 (r1 q04). Confidence: high that the theatre is his; medium on the exact entity's role.
6. **Soliman's route to conviction.** The record shown to me says only "who were convicted of conspiracy to commit wire fraud and bank fraud" (rel-08). The app twice said Soliman pleaded guilty, quoting the headline about Hutchins (see Experience log). **I treat Soliman's plea or trial as not established.**
7. **Not obtained:** restitution and forfeiture (the app refused or answered with garbage), the investigating agencies, the EIDL loan amounts, and how the money was spent.

**Look-alikes (all different people; none of their facts belong to John L.):**
- **Patricia Hutchins, 53, of Brockport (Rochester office).**
  - Earlier: pleaded guilty to wire-fraud conspiracy (the "Kenny Chesney" impersonator matter), with restitution of $20,052 (fraudulent PPP loan) + $25,100 (elderly victim).
  - 2025-03-19: complaint for false statement and bank fraud.
  - 2025-06-26: pleaded guilty to making false statements.
  - 2025-10-07: "going to prison". The app would not give the term.
  - Sources: r1 q12, r2 q18, r4 q13, r4 q05 timeline.
- **William Hutchins, North Tonawanda.** 2014-01-22, sentenced "for Selling Cocaine and Setting a Car on Fire"; AUSA Timothy C. Lynch. The app would not give the term (r2 q10, r5 q02).

## Timeline

| date | event | source |
|---|---|---|
| 2014-01-22 | William Hutchins (North Tonawanda) sentenced — cocaine, car fire (distractor) | rel-01 |
| Nov 2020 | Hutchins accused of a false statement (text truncated) | rel-03 |
| 2022-03-29 | Indictment: Hutchins (68) + Soliman (39), conspiracy to commit wire fraud and bank fraud, EIDL/PPP, >$750k | rel-02 |
| 2024-09-12 | Superseding indictment: + bank fraud, wire fraud; two PPP loans $115,978; >$750k | rel-03 |
| 2025-03-19 | Patricia Hutchins charged again (distractor) | rel-04 |
| 2025-03-20 | Hutchins (71) pleads guilty before Judge Vacca; >$1.8M; max 30 yrs / $1M | rel-05 |
| 2025-06-26 / 10-07 | Patricia Hutchins pleads / sentenced (distractor) | rel-06/07 |
| 2026-01-21 | Hutchins (72) 14 months; Soliman (45) 20 months; Judge Vacca | rel-08 |

## Contradictions / discrepancies (the app's workflow flagged none: "contradictions found: 0")

- **Amount grows from $750k to $1.8M.** Both indictments say "more than $750,000". The plea and sentencing releases say "more than $1.8 million", and a quote says "nearly $2 million". The app did not flag or explain this. Its only "contradiction" output was trivial: "Multiple incidentOccurred events for the same subject: 'Federal Grand Jury Indicts…' on 2022-03-29 vs '…superseding indictment…' on 2024-09-12". The other was a cross-person false alarm: "'William Hutchins convicted on 2014-01-22' vs 'John L. Hutchins sentenced on 2026-01-21'".
- **Soliman's ages don't add up**, from the app's quoted passages: 39 on 2022-03-29, 40 on 2024-09-12, 45 on 2026-01-21. They can't all be right (39 in March 2022 implies at least 41 by September 2024). Hutchins's ages (68/70/71/72) are consistent. The app did not notice.
- **"Convicted" vs "pleaded guilty."** The sentencing release says both "were convicted". Only Hutchins's plea is documented in what I saw.

## Open questions

- Restitution and forfeiture for Hutchins: refused or garbage, asked 4 ways (r1 q11, r2 q09, r3 q05, r4 q06).
- Investigating agencies: the app returned the 2014 cocaine case's AUSA instead (r2 q11, r3 q07, r5 q07).
- EIDL amounts and the count of EIDL loans: refused or garbage (r4 q03/q04).
- Whether Soliman pleaded guilty or was tried: the app's "yes" is unreliable (wrong person).
- Patricia's and William's prison terms: "The documents don't give a count for this." These are distractors, so this doesn't affect the John L. conclusion.

## Round log

- **r1 (15 Qs):** charges, dates, 14-month and 20-month terms and the sentencing date were good; 7 answers were the garbage line "Hutchins: • Rapids Theatre Niagara Falls, USA, Inc. … Amount $1.80"; the plea answer was "Yes —" to an either/or question.
- **r2 (18 Qs):** Soliman confirmed as co-defendant; Judge Vacca appeared in the sentencing quote; AUSA Bonanno came from r1; **Soliman "Yes" pleaded (wrong person)**; prosecutor question → the 2014 cocaine AUSA; Patricia's restitution found.
- **r3 (17 Qs):** plea charge, Judge Vacca, and 30 yrs/$1M maximum found; two PPP loans $115,978 found; Soliman "pleaded guilty March 20, 2025" (wrong person); restitution and agencies failed.
- **r4 (14 Qs):** timeline per person, "nearly $2 million" quote; restitution refused; Patricia and William terms refused.
- **r5 (10 Qs):** superseding charges found; "What sentence did the Rapids Theatre owner receive?" refused ("don't state a sentence for Rapids Theatre"); Patricia/William terms unobtainable.

## Experience log

**Effort:** 5 rounds, 74 questions. About 20 gave a usable fact. About 30 returned the same garbage line. The core outcome (plea, judge, 14 months, date) came in r1, but confirming it and the co-defendant took 3 more rounds.

**Where it helped**
- **Same-surname separation.** Every John L. answer quoted a John L. passage. No Patricia or William fact was attached to him in Ask, and the r4 timeline kept "William Hutchins convicted", "Patricia Hutchins pleaded guilty" and "John L. Hutchins sentenced" as separate people.
- **Sentencing.** "John L. Hutchins was sentenced to 14 months in prison, while Soliman was sentenced to serve 20 months." This was exact and cited.
- **Two charging dates.** "John L. Hutchins was charged on March 29, 2022 and again on September 12, 2024 — the documents record more than one." This surfaced the superseding indictment unprompted.
- **Patricia's restitution.** It was found with a verbatim quote, which helped rule her out as the brief's person.

**Where it hurt or misled**
- **One garbage line for 30+ questions.** Questions on the judge, restitution, plea charge, investigating agency, maximum penalty, age, Patricia's sentence and William's sentence all returned exactly: "Hutchins: • Rapids Theatre Niagara Falls, USA, Inc. / --- / Also on file: Amount $1.80 · Status final · Role Director". This was not a refusal. "$1.80" is a mis-parse of "$1.8 million". Even "What was Patricia Hutchins of Brockport sentenced to in October 2025?" and "What did William Hutchins of North Tonawanda do…" got this John L. line.
- **Wrong person: Soliman's plea.**
  - "Did Roberto Soliman plead guilty or was he convicted at trial?" → "Yes — 'Rapids Theatre owner pleads guilty to defrauding COVID relief programs out of more than $1.8 million'"
  - "When did Roberto Soliman plead guilty?" → "The document dated March 20, 2025 reports that Roberto Soliman was pleaded guilty".
  - The headline is about Hutchins, the owner. A reader would wrongly record a plea for Soliman.
- **"No" built from garbage.**
  - "Was John L. Hutchins ordered to pay restitution?" → "No — the documents give hutchins: • Rapids Theatre Niagara Falls, USA, Inc." That is a confident-looking "No" with no basis.
  - "Is John L. Hutchins the same person as William Hutchins?" → "No — the documents give hutchins: • Rapids Theatre…" The answer is right, but by accident.
  - "Was Hutchins's plea entered on March 20, 2025?" → "No — …", which contradicts the app's own plea answer.
- **Other cases' facts.** "Who handled the case as Assistant U.S. Attorney?" and "Which agency's special agents investigated the Rapids Theatre case?" both returned "According to Assistant U.S. Attorney Timothy C. Lynch, who handled the case, between January 2009 and July 27, 2009, the defendant conspired with others to distribute cocaine…". That is the 2014 William Hutchins case, not refused and not flagged.
- **Misleading caveat on the first answer.** "The documents state more than one charge for John L. Hutchins (two prosecutions, or two people of that name)". This is one prosecution with a superseding indictment; the wording invites confusion with the look-alikes.
- **Sentence refused when phrased by role.** "What sentence did the Rapids Theatre owner receive?" → "The documents that name Rapids Theatre don't state a sentence for Rapids Theatre." The 14-month line is in the sentencing release headed "Rapids Theatre owner and co-defendant sentenced".
- **Findings report.**
  - It lists prosecutors and the judge as defendants: "On 2025-06-25 — Michael DiGiacomo pleaded guilty", "On 2025-10-06 — Michael DiGiacomo sentenced", "On 2026-01-20 — Judge Meredith A. Vacca sentenced", "On 2022-03-28 — Trini E. Ross charged".
  - It lists junk "findings": "Undated — fax: (716) 551-3051", "contact: Barbara Burns", "amount: $1.8 USD".
  - Every date is one day early (2026-01-20 for the 2026-01-21 sentencing, 2022-03-28 for the 2022-03-29 indictment).
  - Its only gap is about the distractor William ("no charging document on file"). It does not mention John L.'s missing restitution or the $750k→$1.8M jump.

**Would I trust it on a real case?** As a passage finder, yes, with every answer checked against its quote: the headline facts were right and same-surname separation mostly held. As an answerer, no. It produced a wrong-person "Yes" (Soliman's plea), confident "No"s built from a garbage line, another case's AUSA for "who handled the case", and a findings report naming the U.S. Attorney as a person who "pleaded guilty" and was "sentenced".
