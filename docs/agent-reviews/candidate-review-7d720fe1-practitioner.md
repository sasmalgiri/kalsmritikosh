# AGENT REVIEW — practitioner (investigator), not a practitioner's sign-off (owner decision 2026-11-01)

- **Reviewer:** a Claude agent reading the product as a working investigator would: HR/compliance, fraud/SIU, a
  generalist investigator. The owner decided on 2026-11-01 that agents replace practitioner review for v1. No
  practitioner took part.
- **Date:** 2026-11-04
- **Candidate:** `7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0`
- **Baseline:** the three practitioner reviews (81cf335f), `candidate-re-review-f766b035.md`, the real-case evaluations
  (`real-case-evaluation-2026-11-03.md`, `-opus5-2026-11-03.md`, `real-case-old-six-ai-comparison-2026-11-04.md`,
  `real-case-v2-interim-2026-11-04.md`) and `docs/ACCURACY.md`.
- **Method:** I read the code and the help/listing text only (no build, no test run, no GUI). The case reader, the
  permission flow, offline search, the case analysis paths, the case erasure and the help registry were read at the
  candidate commit.

**Verdict: NOT APPROVED. There are two blocking findings, plus one shared with the user evaluation.**

## What an investigator must be told (whatever the verdict)

1. **Nothing on this candidate was tested on live data.** Testing was simulation only (owner decision 2026-11-04): a fake
   Anthropic API, a fake relay and in-process StoreKit. **The whole-case reader, the product's main new capability, has
   never been run on a real case** (`docs/RELEASE_CANDIDATE.md`, Accuracy).
2. **The last real-case figures belong to the code before it** (`14e0708b`, 5 cases, round 1, cases the fixes were tuned
   on). 44 % of answers were correct per question, 32 % partly correct and 9.9 % wrong. There were 2.5 wrong answers at
   normal confidence per 100 questions. Contradictions: 13 real, 9 false (`real-case-old-six-ai-comparison-2026-11-04.md` §1).
   That is far from the owner's own plan-A bar (≥ 90 % correct, ≤ 1 confident-wrong per 100).
3. **Check every statement against the quoted source.** The quote check proves that a quote is in the document, not that
   the statement is complete, current or about the right person.

The app says (2) and (3) correctly in the terms (§3), the answer footer and the FAQ. It never says (1) to the
investigator inside the app, and the listing promises more than (2) supports (see the accuracy record).

## Blocking

| # | Finding | Evidence |
|---|---|---|
| **PB1** | **"The case's documents don't say" is stated as a fact when it is only the verifier's result.** When the AI read the whole case but every statement it proposed failed the quote check, the app answers as a refusal (`refused: true`, `answerState: .notFound`): "The case's documents don't say. The AI read all N documents of this case and found no statement answering the question (k proposed statements did not check out …)". With an unmeasured reader and a verifier that drops statements on wording differences, this is an unsupported negative. In an investigation, "the record does not say X" is itself a finding: an alibi absent, a payment not documented. It is the mirror of the unsupported "Yes" the f766b035 re-review blocked. Reword to state only what is known, for example: "No statement that checks out against the documents was found. The AI proposed k that did not match their sources; the documents may still answer this — search or read them." Do not mark it as a not-found refusal when k > 0. | `Brain/CaseReader.swift:165-171, :188-195` |
| **PB2** | **Erasing a case does not erase what the AI was sent.** The full text of the case's documents stays in the "What was sent" log after "Erase case… / Also erase the documents only this case uses". An HR or compliance investigator erasing a closed matter, or honouring a data-subject request, would believe it gone. (Same defect as legal LB1.) | `OnlineCloudProvider.swift:591-605`; `SchemaMigrations.swift:7025-7041`; `CaseErasure.swift:163-166`; `CaseFileView.swift:507` |
| **PB3** (shared with user-evaluation UB1) | **An investigator who pays for an AI plan and follows the Help gets search results, not the reader.** AI answers also need "Use AI to write answers" (off by default) and the document-terms tick in Settings ▸ Online. Neither the Help topic, the listing nor the review notes say so. Ask then says only "No AI is set up". | `Routing/EvidenceOnlyRelease.swift:20-31`; `App/AppState+CaseReading.swift:41-42`; `UI/Help/HelpRegistry.swift` (`task-ai-included`); `Brain/OfflineSearchResults.swift:44` |

## Should-fix

| # | Finding | Evidence |
|---|---|---|
| PS1 | **The contradictions header claims too much.** It says "Statements in this case's documents that cannot both be true", but on the last real-case run 9 of 23 flagged pairs were not contradictions. Say "that may not both be true — check each pair". The empty state is already honest ("does not prove the documents agree"). | `UI/CaseContradictionsSection.swift:28`; comparison §1 |
| PS2 | **No in-app notice that the AI reader is unmeasured on this version.** The FAQ says "Accuracy has not been measured on this version" (`docs/index.html:485`), but the permission sheet and the answer footer do not. Add one line to the permission sheet: "Answers are checked against their quotes; this version's accuracy has not been measured — verify before relying." | `UI/CaseReadConsentSheet.swift:17-19`; `Core/LegalNotice.swift:24-25` |
| PS3 | **The cost per question is understated after an idle hour.** The sheet says "then about N per question while it stays open". The case cache lasts one hour, so the first question after an idle hour pays the first-read cost again (about 2× input on a 1-hour write). An investigator working a case across a day should be told. | `Routing/Providers/Online/CloudUsage.swift:78-88`; `CaseWholeReading.swift:62-63` (`questionTTL = .oneHour`) |
| PS4 | **The answer does not show which path produced it.** A too-large case falls back to passages with an honest note (good, `CaseReader.swift:198-202`), but on a whole-case answer the investigator cannot see whether every document was read or some were withheld. The sheet lists "Not sent", but the answer does not repeat it. Add "read N documents; M withheld (privileged …)" to the receipt. | `Personas/Investigator/InvestigationAnswerService.swift` (planAAnswer); `CaseReader.swift:177-186` |
| PS5 | **Contradiction, role and draft analyses spend the case permission without a prompt.** The analysis uses the stored permission "without asking" (good: one consent). But each analysis kind is a whole-case read that costs up to the first-read amount, and the analysis buttons show no estimate. Show the estimate on "Find contradictions" / "Draft with AI" when the plan meters it. | `CaseWholeReading.swift:153-183` |
| PS6 | **Stale help on what is read.** The Sources help says "DOC, XLS, PPT, MSG, PST, RAR, 7z are kept but not read", but the guide, the listing ("email (including PST)") and the capability matrix say MSG and PST are read. An investigator triaging an Outlook export will be confused. | `UI/Help/HelpRegistry.swift:150`; `UI/GuideContent.swift:136`; `CAPABILITY_MATRIX.md:59` |

## Fine (checked)

- **Quotes are checked.** A whole-case answer is shown only after `VerifiedAnswerComposer.decide` checks every statement
  against the case's passages and the named person. A failed reading falls back to search results with the reason, and a
  failed send is flagged, never silent (`InvestigationAnswerService.swift` planAAnswer; `CaseReader.swift:157-175`).
- **Consent once per case is real and pinned.** The permission is tied to a fingerprint of the exact document versions. A
  new, removed or re-versioned document asks again. The send boundary recomputes the fingerprint, so no caller can widen
  it (`CaseReadPermission.swift:30-41`; `OnlineCloudProvider.swift:447-451`). Privileged and restricted documents are
  listed as "Not sent" with the reason (`CaseReadConsentSheet.swift:36-41`). "Not now" sends nothing and says why
  ("You have not allowed the AI to read this case's documents, so these are search results").
- **Offline is honest.** With no AI, Ask returns "Search results for …" with the question's words highlighted and
  "Open source", and no rules-written prose (`OfflineSearchResults.swift:39-48`).
- **A too-large case is said so,** with tokens, limit and how many documents were read (`CaseReader.swift:198-202`).
- **Case tools from the earlier reviews are unchanged:** custody hashes, the append-only case log, a "verified" mark only a
  person sets, and drafts as cited proposals to accept or reject. A chronology entry from a passage is refused if its
  source is outside the case. The whole-case path did not alter them.
- **Exports** keep the report disclaimer (`LegalNotice.reportDisclaimer`) and the AI-assisted footer; rules-only answers
  are labelled "no AI involved" (`LegalNotice.swift:20-25`).
- **The listing and help do not claim to decide.** "It does not decide findings, guilt or outcomes — you do"
  (`APP_STORE_LISTING.md:76`); terms §3.

## Conditions to re-review

Fix PB1–PB3 on a new commit. Whatever the verdict, the three warnings at the top must reach the investigator: in the
listing (already, apart from the claims in the accuracy record), in the permission sheet (PS2) and in the Help.
