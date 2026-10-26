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

### Claude-reworded questions (repaired scorer, 2026-10-26)

Each question rewritten two ways by Claude the way different investigators ask (names and quoted
subjects verbatim; Claude never sees the documents or the answers). "Rules" = Fully private;
"rules → Claude" = the question canonicalizer may ask the person's Claude key to map the wording onto
one of 29 canonical forms (only the question is sent, never a document).

| Set | Build | n | Rules only | Rules → Claude | Wrong (→ Claude) |
|---|---|---|---|---|---|
| NTSB conclusion withheld | ≈9553e814 | 720 | 88.8 % | 96.7 % | 1.9 % |
| Enron mailboxes (corrected count truth) | 36afa942 → d8672752 | 1,080 | 80.2 → 83.3 % | 85.8 → **88.3 %** | 9.4 → 7.9 % |
| Chronology (16 unsupported plea labels excluded) | ≈9553e814 → d8672752 | 1,486 | 49.9 → 69.1 % | 79.2 → **91.3 %** | 11.1 → 6.3 % |

The second number in each pair is **tuned**: the fixes between the two builds were read from these
sets' own failures. The honest figure is the held-out set below.

**Held-out (honest), 2026-10-26, build c581f8fb:** 60 new prosecutions never drawn before
(`--seed 4242`, skipping both earlier sets), each question newly reworded twice by Claude; nothing
was fixed from these cases before the run.

| Held-out chronology | n | Rules only | Rules → Claude | Wrong (→ Claude) |
|---|---|---|---|---|
| All questions | 898 | 65.0 % | **87.6 %** | **7.2 %** |
| When sentenced / charged / timeline / count / office / plea / never-happened | 60–120 each | — | 78–100 % | — |
| "What was X charged with?" | 82 | 22–44 % | 56–61 % | 35 % |
| "What sentence did X receive?" | 74 | 13.5 % | 73 % | 5 % |

**Second held-out set** (60 more new prosecutions, `--seed 5151`, newly reworded; build 7dee6891,
after the same-surname and headline-term fixes): rules → Claude **92.4 % right, 6.0 % wrong**
(n = 898; charge 75–77 %, sentence 84 %). **Rules only — the default mode (AI off) — 70.0 % right,
20.6 % wrong**: reworded sentence questions were not understood without a model (3–8 %). The
rules-only shapes were then extended from the tuned set (commit after 7dee6891); a third held-out set
is needed to measure that honestly.

**Third held-out set** (another 60 new prosecutions, `--seed 6161`, newly reworded; build e3859f63,
after the rules-only wording fixes, measured with nothing tuned on it): **rules only (the default
mode) 86.5 % right, 10.0 % wrong**; rules → Claude 90.2 % right, 7.5 % wrong (n = 888). Remaining
weak kinds in both modes: "what was X charged with" (40–70 %, partly the bench) and "when was X
charged" (59–71 %).

| Held-out set | Build | n | Rules only (default) | Rules → Claude |
|---|---|---|---|---|
| 1 (seed 4242) | c581f8fb | 898 | 65.0 % / 23.4 % wrong | 87.6 % / 7.2 % wrong |
| 2 (seed 5151) | 7dee6891 | 898 | 70.0 % / 20.6 % wrong | 92.4 % / 6.0 % wrong |
| 3 (seed 6161) | e3859f63 | 888 | **86.5 % / 10.0 % wrong** | **90.2 % / 7.5 % wrong** |

**Triage of the 111 held-out misses by Claude** (`judge.py`, reads the case documents; brief §17: an
LLM judge assists triage and is not the release oracle — a human must adjudicate a sample):
bench 28 (the app's answer is right or the label is wrong — 18 of them "charged with", where the
label is word overlap with any release and often picks a prior record), extraction 25 (12 of them
the sentence imposed — O-2), retrieval 22, attribution 13, over-refusal 11, composition 7,
understanding 3, **honesty 2** (the app stated something the documents do not support). If the 28
"bench" verdicts hold on human review, held-out correctness is about 90.7 %.

Against the brief's proposed bar (≥ 90 % answerable correctness, ≥ 99 % precision among answered
factual questions) this is **not** release-grade for the charge and sentence kinds; the other kinds
are close on correctness but not on precision. Claims must be restricted accordingly.

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

| 15 | Claude-reworded questions (O-10) were not understood by the rules: "Who's the sender listed on …", "To whom was … addressed", "the total count of press releases about X", "when X's sentencing took place", "the exact date X was sentenced", "emails that went from A to B" | courtesy wrappers stripped; the question canonicalizer maps a wording to one of 29 forms (on-device model, then the person's cloud key — never in Fully private); rules extended for each shape found | 36afa942, c20fd94e, a3566d85, 66da52c9, 26dea109 |
| 16 | O-3 counts over retrieved emails only | the ledger's participant index is the count's pool (every email in scope), read in full; a capped lookup says "at least N"; the index's display-name match counts when the header holds only an address | 36afa942, 3a2f9008, 1b8cb31e |
| 17 | O-5 record vs narrative day answered with one date | both days shown as a conflict | ae12c5f3 |
| 18 | O-6 no procedural gaps detected | a sentencing with no plea or verdict on file, or no charging document, is a gap (rule 11) | 765e7c4a |
| 19 | "Did X plead guilty?" answered "No" whenever X was convicted — but a conviction follows a plea as often as a trial | "No" only on a verdict at trial; a bare conviction is reported as such; a plea is never "not convicted" | be30350a |

## Open gaps (not yet closed)

| # | Gap | Measured | What would close it |
|---|---|---|---|
| O-1 | **"What was X charged with?"** — the offence is worded many ways; the quoted sentence is sometimes not the charging one | 70–73 % | an offence extractor (count + statute + description) and offence normalisation |
| O-2 | **Sentence terms** with unusual wording ("to serve 87 months", "time served", resentencing, two terms in one release) | 73–82 % | a sentence-term grammar; several sentences shown as a list |
| O-3 | Counts: closed by 16 above for email; "how many releases name X" still counts the documents retrieval found (stated as "of the documents found") | — | an exhaustive name lookup for documents, as for email |
| O-4 | **Which office**: Main-Justice releases with a U.S. Attorney's office as partner — the bench's metadata lists both, the app names one; some releases name no office in the text at all | 72–89 % | list every office the release credits |
| O-7 | **Pronouns** ("He was sentenced …") are not followed; only descriptive leads are | — | a bounded coreference pass |
| O-8 | **Email display names** (X-To/X-From) are not kept in the header block; the participant index carries them and now backs count/when answers, but subject questions read the header alone | — | keep display names in the header block |
| O-9 | A long or punctuated **subject** is sometimes not retrieved | ~1 % | exact-subject retrieval (FTS phrase lookup added 36afa942) |
| O-11 | Ambiguous **recipient names** ("All Houston" vs "All Enron Houston" lists) over- or under-count by one or two | ~30 % of remaining count misses | match a recipient by address first, display name second |

## Bench honesty notes

- The chronology truth accepts the release's day **or** a day the release states for that step
  ("on March 15, 2017, sentenced …", "yesterday"). The app often gives the stated day, which is the
  truer one.
- "What was X charged with?" is scored by word overlap with any release's wording of the offence
  (≥ 60 %); a correct answer in other words can still score wrong (O-1 is partly the bench).
- **Corrected 2026-10-26:** the Enron count truth counted only each message's first To recipient and
  counted two folder copies of one message twice. `enron.py` now counts any To recipient, one email per
  subject + date; `enron_recount.py` corrected the existing sets (31 rows). The app was not tuned to
  the old labels.
- **Corrected 2026-10-26:** the chronology plea truth expected "No" to "Did X plead guilty?" from any
  conviction. A conviction does not rule a plea out; the question is now asked only with trial
  wording, and `chronology_relabel.py` marks the 28 unsupported labels excluded — kept and counted,
  never scored.
- **Scorer repaired 2026-10-26 (brief §17):** a negated mention ("Alice did not send it") is not the
  answer, and retrieved snippets are not credited to the answer; only the visible body is scored.
  Re-scored fresh draws held: chronology 87.9 %, NTSB 98.3 %, Enron 95.7 %.
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
