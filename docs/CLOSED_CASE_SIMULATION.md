# Closed-case simulation — can the app work a real, solved case?

Owner request 2026-10-26: "in the whole world there are many successful closed cases; we need to
simulate them with our app so we know if our app is capable or not. If you find any gap, fix it and
make it a list."

The earlier case benches asked one question of one document. An investigation is different: the
answer is spread over several documents, the archive holds other cases too, and the tool must not
"solve" anything the record does not state. Three simulations were built from real, finished cases.
Every expected answer comes from the records themselves; nothing was written by hand.

| Simulation | Real source | Cases | What it checks |
|---|---|---|---|
| **Chronology** — one defendant across a prosecution | U.S. Justice Department releases (public domain), 9,126 finished prosecutions followed across ≥2 releases ending in a sentence; 200 sampled | 200 (10 per shard: every shard is an archive of 10 unrelated prosecutions) | when was X charged / sentenced, the sentence, did X plead guilty, the timeline in order, how many releases name X, what X was charged with, which office prosecuted, and a pardon no record mentions (must be refused); every case also worked as an opened investigation |
| **Conclusion withheld** — before the final report | NTSB aviation database (public domain): factual record + narrative + analysis, **probable-cause finding removed** | 150 | the facts (date, place, aircraft, deaths) must be found; "what was the probable cause" / "what did the NTSB conclude caused it" must be answered "no document states it" — never a narrative sentence passed off as the finding |
| **Who knew what, when** — a corporate-fraud mailbox | Enron email dataset (released by FERC during its investigation), real messages kept byte for byte | 100 mailboxes × ~40 messages | who sent the email "…", when, to whom, what it said; how many emails A sent B; an email to a person who never appears (must be refused) |

Generators: `scripts/casebench/chronology.py`, `scripts/casebench/ntsb_hidden.py`,
`scripts/casebench/enron.py`. Scorer: `scripts/casebench/score.py` (types `order_any`, `dates`,
`overlap_any` added for these). Runs: Fully private (rules only, no model), the strictest setting.

## Results

"Right" = correct, or an honest refusal where the documents do not hold the answer. "Wrong" includes
answers that state something the documents do not support.

| Simulation | First run | After fixes (tuned on these cases) | Fresh draw, never seen (honest) | Wrong (fresh) |
|---|---|---|---|---|
| Chronology — 200 prosecutions; fresh: 100 others | **7.6 %** | **89.3 %** archive-wide · 90.3 % inside the opened case | **87.9 %** · 89.1 % in case | 7.2 % |
| Conclusion withheld — 150 NTSB; fresh: 60 others | **64.6 %** — "what did the NTSB conclude" answered with a narrative sentence **16 of 16 times** | **98.7 %** | **98.6 %** | 0.8 % |
| Enron mailboxes — 100; fresh: 40 others | **6.8 %** | **93.7 %** | **95.2 %** | 2.2 % |

The fresh draws (`--seed 777 --skip-keys …`) use the same question wordings on cases the fixes were
never read from; the scores held, so the fixes were not fitted to the first cases. Builds: tuned
chronology a0866664, conclusion-withheld cb83f72d, Enron a0866664; fresh draws 9b1914bb.

## Gaps found and fixed

| # | Gap (what the simulation showed) | Fix | Commit |
|---|---|---|---|
| 1 | Questions about a **person** — "When was X sentenced?", "Did X plead guilty?", "What sentence did X get?" — came back as a pasted release (0–2 % right) | `ProceedingEventExtractor` reads the steps of a proceeding (charged, arrested, arraigned, pleaded, convicted, acquitted, sentenced, pardoned, released) for a named person, dated as the document dates them; `ProceedingAnswerer` answers when / whether / the sentence / the timeline / how many documents, each step quoted and cited; steps with a day become ledger events | 41db7d56 |
| 2 | "The timeline of the case against X" became a **history of the whole archive** | person timelines go to the proceeding answer, in date order, from every document that names the person | 52d18977 |
| 3 | A **step no document records** ("When was X pardoned?") was answered with some date | "The documents that name X don't record X being pardoned." | 41db7d56 |
| 4 | **PDF line wraps** split a sentence ("Reginald Bennett, 41, of / Cedar Grove … was sentenced") | sentences rejoin wrapped lines; Title Case headlines stay their own line | 52d18977, fd6d0dd3 |
| 5 | A step stated only in the **headline** ("Man Arrested for …") was missed | the headline's step is reported on the document's printed date, said as such | 52d18977 |
| 6 | "Today"/"yesterday" were not dates | resolved against the date the document prints at its head — never the file date | 41db7d56 |
| 7 | Only the question's own retrieval was read — the **other documents of the case** were missed | a second retrieval on the person's name, same access scope | 52d18977 |
| 8 | **Aliases** ("Christi Romano, aka Christi Machala"), **middle initials** ("Nathaniel E. Robinson"), **hyphenated names** ("Garcia-Zamora"), **descriptive leads** ("A Florida man was sentenced …") lost the person | each handled | 41db7d56 … cbd8f58f |
| 9 | A step was given to the **wrong person** ("… was sentenced, announced U.S. Attorney Peter F. Neronha") | a step belongs to the person named before it or right after it | cbd8f58f |
| 10 | "Which office prosecuted X?" was not an office question; the District of the Virgin Islands was cut to "Virgin" | office gate covers it; two-word territories | 41db7d56, 52d18977 |
| 11 | **Conclusion withheld**: "What did the NTSB conclude caused it?" quoted the narrative as the finding (16/16) | `ConclusionGate`: a conclusion only from text labeled as one (probable cause, finding, determination, verdict); otherwise "None of the documents on file states the investigators' conclusion" | cb83f72d |
| 12 | The record's own **"Date:" / "Injuries: 4 fatal"** lines were not used — a passage, or the date of another event ("An FAA publication dated …") came back | `RecordLineGate` answers from the named record's labeled line | cb83f72d |
| 13 | **"Who sent the email …?"** was read as the email-ADDRESS field and answered with every address on file; "When was the email sent?" said no date was given | `EmailHeaderAnswerer` reads the message's own headers (From / To / Date / body), RE:/FW: is the same subject, copies in several mailboxes are one email; "the email …" no longer means the address field | a0866664 |
| 14 | "When did A email B?" for an organisation or address sender went to a passage | any sender parses; a sender none of the emails found shows is said so | 9b1914bb |

## Open gaps (not yet closed)

| # | Gap | Measured | What would close it |
|---|---|---|---|
| O-1 | **"What was X charged with?"** — the offence is worded many ways; the quoted sentence is sometimes not the charging one | 70–73 % | an offence extractor (count + statute + description) and offence normalisation |
| O-2 | **Sentence terms** with unusual wording ("to serve 87 months", "time served", resentencing, two terms in one release) | 73–82 % | a sentence-term grammar; several sentences shown as a list |
| O-3 | **Counts across a large archive** ("How many emails did A send to B?") are counted over the emails *retrieved*, not every email in scope; undercounts | 54–55 % (Enron) | a scoped ledger query over the email headers (participants table), not retrieval |
| O-4 | **Which office**: Main-Justice releases with a U.S. Attorney's office as partner — the bench's metadata lists both, the app names one; some releases name no office in the text at all | 72–89 % | list every office the release credits |
| O-5 | **Date conflicts** between a record page and the narrative (UTC vs local day) are answered with one date, not shown as a conflict | 6 % of NTSB date answers | surface both, as the conflict rule requires |
| O-6 | **Gap analysis** in the opened case found 0 gaps across 200 prosecutions (a case with a charge and a sentence but no plea or verdict release is a real gap) | 0 / 200 | procedural-gap rules for proceedings |
| O-7 | **Pronouns** ("He was sentenced …") are not followed; only descriptive leads are | — | a bounded coreference pass |
| O-8 | **Email display names** (X-To/X-From) are not kept by the email loader, so name questions rely on address spellings | — | keep display names in the header block |
| O-9 | A long or punctuated **subject** ("CA RTO News --Prediction-- …") is sometimes not retrieved, and the answer cites another case | ~1 % | exact-subject retrieval |
| O-10 | These simulations ran **Fully private**. The on-device model and Claude interpreter steps were not run on them | — | rerun in Gated and Online modes |

## Bench honesty notes

- The chronology truth accepts the release's day **or** a day the release states for that step
  ("on March 15, 2017, sentenced …", "yesterday"). The app often gives the stated day, which is the
  truer one.
- "What was X charged with?" is scored by word overlap with any release's wording of the offence
  (≥ 60 %); a correct answer in other words can still score wrong (O-1 is partly the bench).
- The Enron count question counts only each message's first recipient; the app counts any
  recipient, so a few "wrong" counts are the bench's.
- The fixes were made by reading the first sets' failures, so the "after fixes" column is tuned.
  The "fresh draw" column is the honest figure: new cases, never read while fixing.
- Fresh draws reuse the question wordings; new wordings were tested separately (held-out wording
  sets 4 and 5, 2026-10-25).

## How to rerun

```
python3 scripts/casebench/chronology.py --raw ~/CaseBench/raw --out ~/CaseBench/ccs/cases --render build/casebench-render --cases 200
python3 scripts/casebench/ntsb_hidden.py ~/CaseBench/raw/avall.mdb --out ~/CaseBench/ccs-ntsb/cases --cases 150
python3 scripts/casebench/enron.py --maildir ~/CaseBench/raw/enron/maildir --out ~/CaseBench/ccs-enron/cases --cases 100
TEST_RUNNER_CASEBENCH_FULL=1 TEST_RUNNER_CASEBENCH_ASK_EVERY=1 DD=build/dd6 scripts/casebench/run.sh <cases> <results> 3 1
```
