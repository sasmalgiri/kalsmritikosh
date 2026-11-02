# AGENT ADJUDICATION — not human adjudicators (owner direction 2026-11-01)

# Why the wrong rate does not stay under 1 % — root cause across ho14–ho20

This document answers the owner's question: what is actually wrong, after seven fresh held-out sets and six rounds of fixes? An AI agent wrote it, acting as the independent adjudicator. It is not a human finding.

Sources:
- the seven adjudications `accuracy-adjudication-ho14.md` … `-ho20.md`;
- the code at f766b035 (`Kalsmritikosh/Brain/ProceedingAnswerer.swift`, `Kalsmritikosh/Knowledge/Events/ProceedingEventExtractor.swift`, `Kalsmritikosh/Brain/VerifiedRecordExtractor.swift`, `Kalsmritikosh/Brain/MasterBrain.swift` l.2119–2203);
- the git history of those files between 81cf335f (ho14) and f766b035 (ho20);
- the ho20 result files.

## 1. The measurements

There are 60 fresh DOJ cases per round, with no overlap between rounds (6,528 questions per path in total). All figures are the adjudicated values.

| set | commit | n | rules wrong % | rules strict % | rules missed | opus5 wrong % | opus5 strict % | opus5 missed | rules causes (wrong items) | opus5 causes |
|---|---|---|---|---|---|---|---|---|---|---|
| ho14 | 81cf335f | 914 | **1.86** | 2.84 | 2 | 0.66 | 1.42 | 2 | A 8, B 8, C 1 | B 5, C 1 |
| ho15 | 78e6d00d | 940 | **1.38** | 4.36 | 0 | **1.17** | 2.66 | 0 | B 4, H 4, C 3, E 2 | B 4, H 4, E 3 |
| ho16 | f0bb8bfd | 946 | **1.37** | 4.76 | 2 | 0.74 | 2.01 | 1 | E 4, C 3, K 2, B 2, A 2 | K 2, T 2, B 2, E 1 |
| ho17 | b1022f77 | 926 | 0.86 | 3.56 | 0 | 0.22 | 1.62 | 0 | C 6, A 2 | A 2 |
| ho18 | 2e70e537 | 942 | **2.23** | 6.05 | 2 | **1.59** | 3.93 | 2 | P 9, H 4, A 2, B 2, O 2, C 2 | P 4, H 4, A 2, B 2, O 2, C 1 |
| ho19 | 6a029132 | 924 | 0.22 | 4.33 | 6 | 0.22 | 3.57 | 6 | C 2 | C 2 |
| ho20 | f766b035 | 936 | 0.75 | 5.24 | 4 | 0.21 | 4.27 | 4 | P 2, B 2, A 2, C 1 | P 2 |
| **pooled** | — | 6,528 | **1.24** (81) | — | 16 | **0.69** (45) | — | 15 | | |

**How the rate behaves.**
- The rules path exceeded 1 % in 4 of 7 rounds, and opus5 in 2 of 7.
- Neither path exceeded 3 % in any round, on the primary measure or with misses counted as wrong (the worst is 2.44 %, rules ho18).
- The rate does not trend down. rules runs 1.86 → 1.38 → 1.37 → 0.86 → 2.23 → 0.22 → 0.75. The highest value came in round 5, after four rounds of fixes.

**What the pooled rate means.** Answers come in paraphrase pairs, so the effective sample is about half of n. On that basis the pooled rates carry approximate 95 % intervals of 0.86–1.62 % (rules) and 0.41–0.97 % (opus5). The single-round spread (0.22–2.23 %) is about what that rate predicts once errors cluster by case. A single round under 1 % — ho17, ho19 and ho20 on rules — is therefore not evidence that the underlying rate is under 1 %. The best forecast for the next fresh set is about 1.2 % (rules) and about 0.7 % (opus5): both under 3 %, only opus5 under 1 %.

**Caveat on the strict measure.** It is not comparable across rounds. The full scan widened from ho18 on (every family), so more PARTLY items were found. That is why strict % rises while wrong % does not.

## 2. (a) The same few semantic failures, in new wording each round

Every wrong item in the seven rounds answers one of four questions wrongly, plus question parsing and the office reader:

| class | the question the reader got wrong | letters used in the rounds | rules wrongs (7 rounds) | opus5 wrongs |
|---|---|---|---|---|
| **WHO** | whose step is it / whose case is it (co-defendant, relative, namesake, conspirators, a prior or separate case, an anonymous lead, a pronoun) | A, P, K, T | **29** | **14** |
| **WHEN** | which date belongs to the step (announcement day, offence day, a relative clause's day, a year-less day, a weekday) | B, H | **26** | **21** |
| **WHAT** | what offence was charged (no offence named, conduct only, a supplementary count) | E | 6 | 4 |
| **QUESTION** | what is being asked (a paraphrase the parser misreads) | C | 18 | 4 |
| office | which office prosecuted | O | 2 | 2 |
| **total** | | | **81** | **45** |

WHO and WHEN together are 55 of 81 rules wrongs (68 %) and 35 of 45 opus5 wrongs (78 %). The misses are the same classes seen from the other side (a step not attributed to the person): D, K, N, R and W in ho14–ho20, 16 rules and 15 opus5 in total.

**After ho16, no round found a new class.** Every round found new WORDINGS of classes already known:

| round | how the adjudication described the wrongs |
|---|---|
| ho15 | B "recurred in new forms"; H new; E new; C "new wordings" |
| ho16 | E "recurred in new forms"; C "new wordings"; K new; B and A "recurred" |
| ho17 | C "six new wrapper/verb gaps"; A "recurred in a new wording" |
| ho18 | P "grown from partly to wrong"; H, A recurred; B "new form"; O new; C new wording |
| ho19 | C "two new forms" (canonicaliser rewrite, possessive) |
| ho20 | P new form (a namesake sharing a compound surname); B new form ("sentenced Friday, April 3, 2015, … following his conviction on December 11, 2014"); A new form (a supervised-release revocation); C new wording ("on what date were charges filed") |

**The code shows the chase.** Between ho14 (81cf335f) and ho20 (f766b035), `ProceedingAnswerer.swift` grew 581 → 703 lines and `ProceedingEventExtractor.swift` 507 → 617. The regular-expression call sites in the two files went 57 → 89 (+56 %), and code comments citing a held-out round or adjudication went 31 → 67. Each round's fixes removed that round's wordings: ho19's six misses and two wrongs did not recur in ho20. They did not lower the next fresh round's rate, because the next round brings different wordings of the same four relations.

The step attribution is a fixed set of surface tests:
- a 60-character window after the verb (`findings` l.195);
- "the one capitalised word before the surname" (`namesSomeoneElse` l.339);
- a document-wide count of introductions to decide whether "He" can be linked (l.146);
- a list of relationship words (l.188–193).

The date is a fixed list of forms (`stepDay`). The question type is a cascade of anchored patterns (`parse` l.88–168).

English has an open-ended number of ways to say "the brother, Noel Lomas Murillo, was sentenced", "He pleaded guilty in September", "was sentenced Friday, April 3, 2015, following his conviction on December 11, 2014" or "on what date were charges filed". Each test is right for the wordings it was written from, and silently wrong for the next one.

**This is the structural cause of the long tail.** The fixes are correct and they hold — no regression from the ho19 fixes was found in ho20. But they can only be written after a failure is seen, so a fresh set keeps producing new failures at roughly the same rate.

## 3. (b) Why the Opus 5 path inherits the rules path's wrongs

`MasterBrain.swift` l.2119–2203 and `VerifiedRecordExtractor.swift` give the answer path with AI on:

1. **The rules parser decides first, and Claude is confined to its decision.** `ProceedingAnswerer.parse(intent.rawQuestion)` (l.2119) decides whether this is a proceeding question, whose, and which ask (`.when(step)`, `.chargedWith`, …).
   - The cloud reader is called with that `parsed` value, and `verify` checks the reply against `parsed.ask` (the `switch parsed.ask` branch).
   - A misparse therefore cannot be corrected by Claude. "On what date were charges filed against Burton" became a charge question, and the cloud answer was verified as a charge quote (ho20). The same happened with "the charge date for Kimbrew" (ho19).
   - The question canonicaliser (l.1695–1700) is asked only when no rule understands the wording. A wording the rules misunderstand is never sent to it (Adkins, ho19: no Claude call).
2. **Timeline, office and count never go to the cloud.** `VerifiedRecordExtractor.handles` (l.32) returns true only for `.when`, `.sentenceImposed`, `.chargedWith` and `.whether`. Every timeline, office or count answer on the opus5 path is the rules answer: 360 of 936 answers in ho20 made no Claude call.
   - ho20: both opus5 wrongs (the Murillo timeline) and 22 timeline PARTLYs per path are rules answers.
   - ho18: both O wrongs and the count wrong are rules answers.
3. **When the cloud reply does not verify, the rules answer ships unchanged, with no comparison.** At l.2190–2194, `if let verified = … { return verified }`; otherwise `ProceedingAnswerer.answer(…)`.
   - A cloud proposal that names a different date, person or offence is thrown away. It is not used as a signal that the rules answer may be wrong.
   - ho18: "the eight wrong sentenced answers and the four wrong charged answers are the deterministic record answer, kept by the Claude path (each records one Claude call)".
   - ho20: all four misses and the Murillo *sentenced* p1 PARTLY made a Claude call, and the rules answer shipped.
4. **The verifier accepts only the forms the rules already read, so it rejects the cloud exactly where the rules fail.**
   - **Dates.** `verify` accepts a stated full date, a month-day, "today" or "yesterday" (l.140–151). It does not accept a weekday ("on Wednesday", the ho19 Craig form). It tests "today" BEFORE "yesterday" (l.144), so a correct cloud answer to "announced today that X was sentenced yesterday" (the ho16 B form) fails verification.
   - **Charges.** The charge test (l.168) lacks "sentenced … for <offence>" and "pleaded guilty … for <offence>" (ho20 Ramdihall, Freddie Lewis).
   - **Person.** The person test reuses `namesSomeoneElse` (l.131), so a cloud quote of the namesake Noel Lomas Murillo's step would also pass as Abel's.
   - **Context.** The cloud reads only the first 7,000 characters of at most 8 documents (l.84–86); the rules read 40,000 characters of up to 80.
5. **When the cloud does verify, it usually fixes the rules answer.** In ho20, on the 456 paired items of the cloud-handled date, plea, charge and sentence families:
   - The two paths' VALUES disagree on 28. The rules value is wrong or partly wrong on 9 of these (4 wrong, 5 partly) and the cloud value on 1. The other 18 differ but are both acceptable.
   - The paths agree on 428. Those include the shared misparse (Burton), 7 shared PARTLYs and the 4 shared misses.
   - Mabie (the conviction date given as the sentencing date) and Hicks (an earlier case's revocation term) are rules wrongs that the opus5 path got right.

**In short:** with AI on, the rules still decide the question, still answer timelines, offices and counts, and still win whenever the AI's reading is rejected. The AI's answer is checked with the same narrow patterns. So the AI only helps where the rules were already nearly right, and the rules' long tail passes straight through.

## 4. (c) Bench-key error versus app error

| set | rules automatic wrong (incl. dump/unsupported) | rules adjudicated wrong | opus5 automatic | opus5 adjudicated |
|---|---|---|---|---|
| ho14 | 14 | 17 | 20 | 6 |
| ho15 | 16 | 13 | 15 | 11 |
| ho16 | 16 | 13 | 14 | 7 |
| ho17 | 16 | 8 | 11 | 2 |
| ho18 | 24 | 21 | 21 | 15 |
| ho19 | 21 | 2 | 14 | 2 |
| ho20 | 16 | 7 | 14 | 2 |
| total | 123 | 81 | 109 | 45 |

- **The automatic scorer is wrong in both directions, and by more than the app.** In ho20 (rules), 9 of 16 scorer "wrongs" are right answers (key or scorer error), 4 are only PARTLY, and 4 of the 7 real wrongs were scored correct, because the key accepted the conviction date and the earlier case's term. The key/scorer mislabelled about 17 of 936 items (1.8 %), more than the app's own 0.75 %. In ho19 only 2 of 21 rules "wrongs" were real.
- **The residual app error is real, not a bench artefact.** Every adjudicated wrong was checked against the documents and reproduced with the shipped code. Key errors do not explain the app's 0.2–2.2 %. They mask it, sometimes adding and sometimes hiding errors.
- **The automatic score cannot measure a 1 % bar.** The key defects recur every round:
  - `offence_sentences` rejects correctly quoted complaints, pleas and headlines;
  - `stated_days` uses the release day instead of a stated weekday;
  - `order_any` follows release order;
  - `count` counts duplicate files;
  - `dates` accepts conviction dates as sentencing dates.
  Until the generator is fixed, only an adjudicated figure is meaningful at the 1 % level. At 3 % the automatic score is coarse but usable as an upper bound: it has overstated the adjudicated wrong rate in 6 of 7 rounds.

## 5. (d) What would actually move the curve

The rate is set by how often a fresh document says WHO/WHEN/WHAT in a wording the patterns have not seen. Adding more patterns lowers the rate on the sets already read, not on the next one. Changes that move the curve make the system fail closed on an unseen wording, instead of answering from the pattern that happened to match. In order of effect:

### Change 1 (top recommendation): two independent readers, and disagreement means "needs review"

This applies to every proceeding ask when AI is on.
- **Cloud for every ask.** The verified cloud reader answers EVERY proceeding ask, including timeline (as step/date/quote rows, each verified), office and count. It also classifies the question itself from the raw wording, independently of `ProceedingAnswerer.parse`.
- **The rules become the cross-check.** Compare VALUES, not text: date sets with the hedged report dates set aside, the term, the offence tokens, yes/no, the office set and the row set.
  - If the two agree, ship.
  - If they disagree, or the cloud proposal fails verification while the rules give a different value, or the two parse the question differently, show "needs review". Both readings are shown with their quotes; neither is stated as the answer.
  - Never fall silently back to the rules answer when the cloud read something else.
- **Fix the verifier's blind spots:** weekdays, "yesterday" before "today", "… for <offence>", the 7,000-character cap.

Estimated effect from the observed items:
- **ho20, cloud-handled families.** All 4 rules wrongs and 9 of 10 value disagreements would be reviewed or resolved correctly (the cloud was right in 9 of 10). The cost is about 28 / 456 = 6 % of those asks marked "needs review" with today's crude value comparison. With proper normalisation (most of the 18 both-acceptable disagreements are the same date or term, worded differently) this would fall to about 2–3 % of proceeding asks, roughly 1.5–2 % of all questions.
- **ho20 opus5.** The 2 timeline wrongs would go to the cloud reader. The cloud's own verified *sentenced* p2 answer for Murillo already gives only Abel's date, so the disagreement would catch them: 2 → 0.
- **ho14–ho20 opus5, 45 wrongs.** At least 5 are families the cloud never sees (ho18 O 2 and C 1, ho20 P 2). At least 15 are rules answers shipped after a Claude call or a misparse (ho18 12, ho19 2, ho14 C 1). About 6–8 are verified cloud errors (ho15/ho16 E, ho16 T, ho17 A). Under Change 1, the first two groups become "agree → ship" or "disagree → review". Only errors that BOTH readers make the same way survive (ho17 A 2 is the documented case).
- **Expected opus5 wrong rate:** about 0.1–0.3 % per fresh set (from 0.69 % pooled), with about 2 % of questions shown as needs review. This is the only change that targets all four semantic classes at once.

### Change 2: one person-attribution module shared by every reader

Today the extractor, `.chargedWith`, `.sentenceImposed`, the office reader and the cloud verifier each re-implement "is this sentence about the asked person" (a 60-character window, one word before the surname, an introductions count, relationship word lists). One module would:
- resolve each step's subject to a full name span (all given-name and surname tokens);
- resolve a pronoun to its nearest antecedent;
- resolve a descriptive lead to the one introduced defendant;
- parse a defendant list as a list;
- recognise a prior or separate proceeding (revocation, "in a separate case", decade-old years).

Every reader would call it. Estimated effect: the WHO class is 29 of 81 rules wrongs and 14 of 45 opus5 wrongs. It also covers the R, K and L misses and partlys (ho20: Patel, Dunnigan, Kamara, Murillo, Hicks). It is still a deterministic module, so it narrows the WHO tail rather than closing it. It matters most for the AI-off path, which has no second reader.

### Change 3: consistency checks that downgrade instead of answering (both paths, no AI needed)

- A timeline whose rows would be an impossible order for one case (a plea or conviction after the same case's sentencing; two sentencings without "in another proceeding") goes to needs review.
- A step dated with a date that the same sentence attaches to another step ("following his conviction on …") goes to needs review.
- Two terms in one release, one of them a revocation, are not given as the case's single sentence.

In ho20 these catch 6 of the 7 rules wrongs (Murillo ×2, Mabie ×2, Hicks ×2) and about 10 timeline PARTLYs (Louis, Burton, Melvin Smith, Lewis Johnson, Mabie). Expected rules-path effect: about 1.24 % → about 0.5–0.8 %, at a small needs-review cost. This is the cheapest way to keep the AI-off path under 1 % on a fresh set, but it is probabilistic: a check written from today's errors shares the blind spots of the patterns.

### Change 4 (measurement): fix the bench generator's key defects (section 4) before using the automatic score near the 1 % bar

## 6. Is any of this a limit of current technology?

**No, for the errors themselves.** In 7 rounds, every adjudicated wrong and miss concerns a fact the document states in plain text. Each was reproduced as a deterministic rule gap, and the opus5 path's verified Claude reading got the hard ones right whenever it was allowed to answer (ho14 A, ho16 A, ho20 Mabie and Hicks).

**What is a limit is the METHOD.** Hand-written patterns cannot enumerate the ways English expresses whose step, which case, which date and what offence. That is why the rate oscillates around 1–2 % on the rules path instead of converging. Reading these relations is what current language models do well. Verifying their quotes deterministically against the document, which the app already does, controls their main risk.

**The one genuine limit is the AI-off path.** With no second reader, it can be pushed down by Changes 2 and 3 but cannot be expected to stay under 1 % on every fresh set. Under the owner's 3 % bar (2026-11-02) it has stayed under on every set, and it is forecast to stay under.

## 7. Plain-words summary

- **The structural root cause.** The app decides whose step, which case, which date and what offence by matching wording against rules written after earlier failures. Every fresh set says those four things in some new way, so a few new failures always appear.
- **Why AI on does not escape it.** The rules pick the question type first, the AI is not used at all for timelines, offices and counts, and the AI's answer is accepted only if it passes checks built from the same rules. When it is rejected, the rules' answer is shown without any comparison.
- **The fix that moves the curve.** Let the AI read every proceeding question independently, keep the rules as a cross-check, and show "needs review" when they disagree, instead of trusting either one. Back it with one shared person-attribution check and timeline sanity checks for the AI-off path.
- **Expected effect.** On the observed items: opus5 about 0.7 % → about 0.1–0.3 %, with about 2 % of questions marked needs review; rules about 1.2 % → about 0.5–0.8 %.
- **Against the bars.** Both paths already meet ≤ 3 % on every fresh set. Only opus5 meets ≤ 1 % reliably.
