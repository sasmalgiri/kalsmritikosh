# AGENT REVIEW — not a human practitioner review (owner direction 2026-11-01)

- **Reviewer:** Claude agent (practitioner reviewer)
- **Date:** 2026-11-01
- **Commit:** 81cf335f (branch `investigations-next`)
- **Personas:** SIU / insurance fraud investigator · Journalist · Researcher / historian
- **Scope:** read-only review of code, contracts, field specs, executors and acceptance tests. No build, no test run,
  and no UI was driven in this pass. Paths are relative to the repo root; line numbers are at 81cf335f.

## Method

1. Read the job contracts (`Kalsmritikosh/Personas/JobContracts.swift`, `docs/JOB_CONTRACTS.md`), the measured outcome
   matrix (`docs/JOB_OUTCOME_MATRIX.md`), the routing (`JobExecutorKind.assignments`, `JobExecutors.swift:23-67`), the
   contract fields and completion rules (`JobFields.swift`), and every executor the three personas route to
   (`JobExecutors.swift`, `JobFamilyExecutors.swift`, `JobDeliverableExecutors.swift`).
2. Read the persona studios that make the named work products: SIU referral (`Investigate/SIUReferral.swift`,
   `UI/SIUStudioView.swift`), fact-check memo and right of reply (`Investigate/FactCheckMemo.swift`,
   `UI/JournalistStudioView.swift`), and the studio prefill (`Investigate/StudioCasePrefill.swift`).
3. Followed the evidence each executor gets (`App/AppState.swift:2670-2704`, `Investigate/StudioDraft.swift`).
4. For the journalist standard, traced protected-source handling through every export and cloud route I could find:
   `ProtectedIdentities`, `OnlineCloudProvider.send`, `StudioStorage`, `exportJobResult`, `CaseOutputService`, plus a
   grep of every `NSSavePanel` / `fileExporter` in `Kalsmritikosh/UI`. I checked the results against
   `docs/OUTPUT_ROUTES_INVENTORY.md`.
5. Read the scenario checks in `KalsmritikoshTests/JobAcceptanceScenarioTests.swift:155-335`, `FactCheckMemoTests.swift`,
   `SIUReferralTests.swift` and the test names in `JobDeliverableTests.swift`, to see which contract acceptance
   statements are actually tested.
6. Judged each item against the field standard named in the brief. Classes: **BLOCKER** means a practitioner could be
   misled or harmed, so it must be fixed before release. **SHOULD-FIX** means the gap is acceptable only if the
   limitation is stated. **NOTE** is an observation, including things that hold.

## Cross-persona finding (applies to all three)

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Evidence assembly | Names, amounts and stated dates are read from **at most 60 documents per case**. The 60 are chosen by UUID order, which is arbitrary. Nothing in any result says so. Every document is still listed, because texts are fetched for all of them. A document past the cap is therefore reported as "no date stated", "citation metadata incomplete" or "uncorroborated" even when it states those things. A person named only there gets no interview row, no EUO question and **no "Reply opportunity" row** before publication. Events are also capped at 400 with no notice. | BLOCKER | `Investigate/StudioDraft.swift:324` (`objectIDs.sorted(by: uuidString).prefix(60)`), `:394` (`limit: 400`); `App/AppState.swift:2673-2676` (all documents' texts fetched); consumers `JobFamilyExecutors.swift:141-146`, `:162`, `:226`, `:342-359`, `:524-527`; `JobDeliverableExecutors.swift:634-651` |

## SIU / insurance fraud investigator

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Referral: contrary facts | The contract for `siu.referral-report` says "The referral includes contrary facts and only data authorised for the recipient". The referral model has no contrary-facts or innocent-explanation element: a red flag is only `indicatorID` + `note`. The rendered report lists indicators with no innocent explanation beside them. The worksheet's innocent explanations (`siu.red-flags`) are not carried into the referral, because prefill copies claim fields and chronology only. An external referral (DOI / NICB / law enforcement) can therefore be approved and exported without any exculpatory fact. Nothing selects data by recipient. No test covers either half of this acceptance statement. | BLOCKER | `JobContracts.swift:147`; `Investigate/SIUReferral.swift:21-28`, `:138-149`, `:204-213`; `Investigate/StudioCasePrefill.swift:115-155`; `KalsmritikoshTests/SIUReferralTests.swift` (4 tests, none on contrary facts or recipient) |
| Referral: approval needs a red flag | Approval needs every stage complete (`completionFraction >= 1`), and the Red-flags stage needs at least one flag. A file opened for audit or quality review with no indicator cannot get an approved report unless an indicator is entered. That works against the contract line "a legitimate claim closes with no red flag required". | SHOULD-FIX | `Investigate/SIUReferral.swift:141`; `UI/StudioStorage.swift:409` |
| Indicator taxonomy | The 14 indicator categories carry no paired innocent explanation. Some of them, such as "Hard to reach / cell-only", "Unusual … fluency with claim terminology" and "Financial distress", are socio-economic proxies. A senior SIU reviewer would want these qualified or tied to documented criteria. The discipline line ("never, on their own, proof of fraud") is shown. | SHOULD-FIX | `Personas/SIU/SIUFraudIndicator.swift:43-46`, `:63-64`, `:33-34` |
| Red-flag worksheet (`siu.red-flags`) | Holds: the "Innocent explanation" field is required on every accepted row. A legitimate claim completes with every row rejected, since rejected rows count as decided. Conflicting values are kept, not averaged. Limitation: the rows are the generic fact–evidence matrix ("label: value"), not indicators, and the indicator taxonomy is not offered in this job. The investigator types each indicator. | NOTE | `JobFields.swift:113`; `JobExecutors.swift:43`; `JobFamilyExecutors.swift:265-306`; `Personas/JobResult.swift:220-233`; `JobAcceptanceScenarioTests.swift:198-201` |
| EUO prep (`siu.euo-prep`) | Holds: every question is written against one cited passage. Disputed points show both sources. An accepted question with no source is refused at completion. Unanswered questions are "never an admission". | NOTE | `JobDeliverableExecutors.swift:632-673`; `JobFields.swift:271-274`; `JobAcceptanceScenarioTests.swift:288-294` |
| Statement comparison (`siu.statements`) | The contract says "Two accounts of the loss are compared". The job gets generic contradiction rows. The point-by-point statement executor serves only `hr.statements`. The outcome matrix records this job as "not verified". | SHOULD-FIX | `JobExecutors.swift:46`; `docs/JOB_OUTCOME_MATRIX.md:137` |
| Claim intake (`siu.claim-intake`) | The contract says "Claimed, estimated, reserved and paid amounts are recorded separately". The job is generic caseIntake, recorded "not verified". The referral holds a single `claimedAmount`. | SHOULD-FIX | `JobContracts.swift:135`; `docs/JOB_OUTCOME_MATRIX.md:130`; `Investigate/SIUReferral.swift:91` |
| Loss chronology (`siu.loss-chronology`) | This is the generic chronology. Inception and loss dates appear only if the extracted events carry them. The scenario checks rows titled "Policy inception" and "Loss reported" in a fixture. Disputed dates are detected only for identical event titles. | NOTE | `JobExecutors.swift:26`, `:158-172`; `JobAcceptanceScenarioTests.swift:162-164` |
| Prior claims (`siu.prior-claims`) | Holds: an accepted row with no source is refused. Limitation: every case document becomes a row (generic catalogue), and the person rejects those that are not prior claims. The policy "prior claims are context, not proof" does not appear in the result's limitations. | NOTE | `JobFields.swift:69-70`, `:237-240`; `JobExecutors.swift:32`; `JobFamilyExecutors.swift:174-185` |
| Causation and closure | Holds: every causal sentence is a "hypothesis — not a finding". The referral disposition needs the acknowledgement that indicators are not proof, and external referral needs good faith. Return to claims is offered as "suspicion not substantiated". The tool draws no fraud conclusion. | NOTE | `JobFamilyExecutors.swift:369-391`; `Investigate/SIUReferral.swift:61-74`, `:144-149` |

**SIU counts:** 1 BLOCKER (plus the cross-persona one), 4 SHOULD-FIX, 5 NOTE.

**Verdict: REJECT.** An external fraud referral can be approved and exported with no contrary facts or innocent explanations, against its own contract. Together with the silent 60-document cap, this has to be fixed before an SIU relies on the referral.

## Journalist

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Right of reply: verified adverse claims | A claim needs a reply only if it is marked adverse. When the mark is unset, it needs one only if the claim is short of verified. The UI toggle "Adverse to someone" therefore starts **off** for a Verified claim. The test says outright: "A fully-verified story needs no reply entries". The rendered memo prints "No reply entries — no claim short of verified". Right-of-reply practice applies to serious allegations whether or not they are verified, and the most damaging verified allegation is the one that most needs a reply. The memo's reply stage completes with none. | BLOCKER | `Investigate/FactCheckMemo.swift:44-45`, `:118-119`, `:216`; `UI/JournalistStudioView.swift:249`; `KalsmritikoshTests/FactCheckMemoTests.swift:19-26` |
| Protected source: export routes not scrubbed | The `jrn.source-vault` contract says "A protected source's name never appears in exports or AI payloads". Several reachable file exports write case text with no `ProtectedIdentities.scrub`: **Transcripts › Export quotes** (Markdown with a *Speaker* column and `authorOrSender`), the **Ask answer receipt** (a JSON file of the answer and cited snippets), the **Issue chronology** export (cited statement of facts), and **Case story** export. None of these is listed in `docs/OUTPUT_ROUTES_INVENTORY.md`, which says it lists "Every route by which case content can leave the app". Only the Ask *copy* route is recorded as a gap (route 20). | BLOCKER | `UI/TranscriptsView.swift:317-359`; `UI/AskView.swift:839-849`; `UI/IssueChronologyView.swift:110-116`; `UI/CaseStoryView.swift:106-114`; reachable via `UI/RootView.swift:277`, `:1461`, `:1476` and `UI/ToolSheet.swift:90`; `docs/OUTPUT_ROUTES_INVENTORY.md:5`, `:43`, `:58`; compare the scrubbed paths `App/AppState+Erasure.swift:287-292`, `UI/StudioStorage.swift:364-371` |
| Protected source: Source-map "Protection" does nothing | The source map has a field "Protection: none / confidential source". The protected-identity register reads only `jrn.source-vault` rows with `protected = yes` and an identity, so marking a source "confidential source" in the source map protects nothing: no masking, no scrub. The result does not tell the journalist this. The field records a document, not a person, so no identity is captured either. | BLOCKER | `JobFields.swift:97-100`; `Personas/JobResult.swift:362-368`; `JobDeliverableExecutors.swift:847-858` |
| Protected source: cloud sends | Holds for text: protected names are masked in every online send, whatever the masking setting. A name that survives masking stops the send. The register is re-read after consent, and an unreadable register fails closed. Limitation: page images (scan rescue) and recordings (A11 transcription) cannot be masked. The consent preview says so, but a recording of a confidential-source interview can still be sent. The recording is chosen from disk and does not pass through `CloudSourceGate`. | SHOULD-FIX | `Routing/Providers/Online/OnlineCloudProvider.swift:183-218`, `:233-234`, `:255-267`; `App/Online/OnlineTools.swift:95-113` |
| Publication gate (`jrn.publication`) | Holds: clearing is refused while any "Reply opportunity" row is not accepted, and a rejected row counts as open. Limitation: reply rows are created only for entities labelled `person`, so an organisation that is the subject of an adverse claim gets none. Accepting the row is an attestation and is not linked to the reply log in the fact-check memo. | SHOULD-FIX | `JobFamilyExecutors.swift:521-534`; `JobFields.swift:256-261`; `JobAcceptanceScenarioTests.swift:226`, `:440-443` |
| Independence (`jrn.claim-board`, `jrn.fact-verification`) | The contract says "Copied reporting does not count as independent corroboration" and "A fact with one copied source stays unverified". In the memo, corroboration is free text and the status is free choice. Nothing links the claim to the source-map families, so a claim supported only by one wire story repeated twice can be marked Verified. The source map itself holds: nothing is called independent, and a lineage decision needs its rationale. | SHOULD-FIX | `Investigate/FactCheckMemo.swift:32-46`; `JobContracts.swift:152`, `:159`; `JobDeliverableExecutors.swift:723-818`; `JobFields.swift:279-282` |
| Quote accuracy (`jrn.quote-book`) | There is no field spec, so the contract's "timecode" and "verification" columns do not exist in the result. Every attributed sentence is flagged "verbatim", including lines from an AI transcript of a recording, which is marked only by its header and file name. A corrected value keeps its original (frozen `sourced` values, and a change needs a note), which holds. | SHOULD-FIX | `JobFields.swift:51-181` (no `jrn.quote-book` entry); `JobExecutors.swift:78`; `JobFamilyExecutors.swift:315-336` (`:327`); `App/Online/OnlineTools.swift:34`, `:118`; `Personas/JobResult.swift:86-90`, `:228-231` |
| Transcript corrections | In the Transcripts tool, renaming a speaker overwrites `transcript_segments.speaker` in place and keeps no log of the earlier label. That contradicts "A speaker correction never rewrites the original silently". The `jrn.transcript` job result itself keeps a correction log. Its speaker prefill carries the raw text "Speaker: X (basis)". | SHOULD-FIX | `Storage/Repositories/TranscriptRepository.swift:103-115`; `UI/TranscriptsView.swift:305-314`; `JobFields.swift:120-121`, `:197`; `JobFamilyExecutors.swift:324` |
| Tick-tock (`jrn.chronology`) | The contract says "Conflicting times are shown with both sources". Conflicts are detected only when the event title is identical and the day differs. Times of day are never compared. | SHOULD-FIX | `JobExecutors.swift:158-172`; `JobContracts.swift:158` |
| Source protection: aliases | Every name form of a protected source (surname alone, e-mail address, phone) has to be typed into the vault ";"-separated. Only the forms entered are masked or scrubbed. | NOTE | `JobDeliverableExecutors.swift:849-865`; `JobFields.swift:64-68` |
| Corrections | Holds: post-publication corrections and correction actions are append-only registers. An ineffective action reopens. | NOTE | `JobFields.swift:54-59`; `Personas/JobResult.swift:250-260` |

**Journalist counts:** 3 BLOCKER (plus the cross-persona one), 6 SHOULD-FIX, 2 NOTE.

**Verdict: REJECT.** Confidential-source protection, the journalist's highest-harm duty, has unscrubbed export routes and a "Protection" control that protects nothing, and the right-of-reply gate lets a verified adverse claim through without a reply.

## Researcher / historian

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Bibliography date (`res.bibliography`) | The required "Date" field is typed `.date`, which accepts only a real calendar day (yyyy-mm-dd). A source dated "1771", "c. 1850", a range or "n.d." cannot be accepted without inventing a month and day. The alternative is rejecting the row, which drops the source from the bibliography. The invented day is then exported as if it were the source's date. This contradicts "uncertain dates kept as ranges". | BLOCKER | `JobFields.swift:79-80`, `:322`, `:329-337`; `Personas/JobResult.swift:225-227` |
| Catalogue and finding aid dates | The contract says "An item with an uncertain date shows the uncertainty". Stated dates are kept only when they parse as a full ISO date. The catalogue then prints the day and ignores precision. A year-only or ranged date is therefore not shown as such, and the item reads "no date stated". The scenario checks only the "no date stated" flag. | SHOULD-FIX | `Investigate/StudioDraft.swift:311-315`, `:356-359`; `JobFamilyExecutors.swift:141-151`; `JobAcceptanceScenarioTests.swift:167-169` |
| Citation completeness | The contract says "A citation missing a date or locator is flagged; citation style stated". There is no locator field (page, folio, box) and no citation-style field. The flag fires only for a missing name or day. The Author prefill copies the row detail ("Dates: …; X; Amounts: …"), and because that value is frozen as sourced, correcting it needs a reason note. | SHOULD-FIX | `JobFields.swift:79-80`, `:197`; `JobFamilyExecutors.swift:149-163`; `JobContracts.swift:185` |
| AI-derived texts as sources | AI translations (A5) and AI transcriptions (scan rescue, A11) are ingested as ordinary documents, marked only by a header and file name. In the annotated edition every passage of such a document is flagged "source text — verbatim", and transcription rows treat it as an "original". Holds: the translation never replaces the original, and its header names the original. | SHOULD-FIX | `JobDeliverableExecutors.swift:951-962`, `:870-884`; `App/Online/AIAssist.swift:148-157`, `:230-237`; `App/Online/ScanRescue.swift:82` |
| Source criticism (`res.source-criticism`) | The contract says "A statement and its interpretation are kept apart". The job is the generic reliability executor (corroboration counts) with origin, authorship, bias and reliability fields. Nothing separates statement from interpretation, and the scenario checks only "not assessed". | SHOULD-FIX | `JobExecutors.swift:40-41`; `JobFamilyExecutors.swift:204-238`; `JobFields.swift:96`; `JobAcceptanceScenarioTests.swift:193-196` |
| Interpretation, prosopography, authority control | These are generic kind rows, recorded "not verified". The `res.interpretation` contract says "Opposing accounts are both kept". | SHOULD-FIX | `docs/JOB_OUTCOME_MATRIX.md:47`, `:52`, `:53` |
| Chronology (`res.chronology`) | Holds: an event dated to a year, decade or span keeps its range in the flag, Period and Dated fields. It is never narrowed. Limitation: rows built from *stated dates* (not events) carry no precision. | NOTE | `JobDeliverableExecutors.swift:363-385`; `Investigate/StudioDraft.swift:185-198`; `JobAcceptanceScenarioTests.swift:259-263` |
| Competing accounts (`res.alternative`) | Holds: each disputed value is an account with its supporting and contrary sources, neither is preferred, and stated causes are added as accounts. | NOTE | `JobDeliverableExecutors.swift:899-943`; `JobAcceptanceScenarioTests.swift:315-319` |
| Editions and translations (`res.edition`, `res.transcription`) | Holds: passages are verbatim with their exact version and hash. An annotation must sit on a cited passage. A translation is refused without its transcription and original. Limitation: the edition lists at most 150 passages per document and 600 in all. This is stated. | NOTE | `JobDeliverableExecutors.swift:949-972`; `JobFields.swift:287-301` |

**Researcher counts:** 1 BLOCKER (plus the cross-persona one), 5 SHOULD-FIX, 3 NOTE.

**Verdict: REJECT.** A historian cannot complete a bibliography of undated or year-dated sources without fabricating day-precise dates, and the silent 60-document cap mislabels larger corpora as undated or incomplete. Once those two are fixed, the chronology, alternative-accounts and edition work products would support ACCEPT WITH LIMITATIONS.

## Status of the previous agent pass (`docs/PRACTITIONER_REVIEW_AGENT.md`)

| Persona | Previous item | Status now | Evidence |
|---|---|---|---|
| SIU | "Open: none beyond the general ones" | **Superseded.** New findings above: referral contrary facts (BLOCKER), red flag required for approval, taxonomy, statements/intake not verified | see SIU table |
| Journalist | "Open: 'one family' is textual; syndicated rewrites with changed wording are not caught" | **Partly closed.** Near-identical wording (content-word overlap ≥ 0.6) is now grouped as a possible rewrite, and boilerplate is excluded. Heavier rewrites are still not caught, which is stated in the limitation. Lineage is the journalist's decision and needs a rationale. | `JobDeliverableExecutors.swift:723-818`; `JobFields.swift:279-282`; `JobDeliverableTests.swift:317` |
| Journalist | (claimed hold) "a protected source's identity is scrubbed and verified in exports" | **Not accurate as stated.** It holds for job-result, studio and case-output exports and for text cloud sends. It does not hold for Transcripts quotes, the Ask receipt, Issue chronology or Case story exports. | see Journalist BLOCKER rows |
| Researcher | "Open: periods are the historian's to name; the executor only prefills ranges" | **Stated boundary.** The Period field is prefilled with the range and the next action is "Name the periods". | `JobDeliverableExecutors.swift:376`, `:384` |
| All | "Open: exports were not exercised through the UI (system save panel)" | **Still open.** It is recorded in the candidate packet. Not verified in this pass. | `docs/RELEASE_CANDIDATE.md:87` |
| All | "Open: the practitioner evaluation (five users …)" | **Still open.** It needs people, and this agent review does not replace it. | — |
| All | Ask copy-answer not scrubbed (route 20, recorded gap) | **Still open.** The decision is still pending. | `docs/OUTPUT_ROUTES_INVENTORY.md:58-60`; `docs/RELEASE_CANDIDATE.md:89` |

## Not verified in this pass

- Runtime behaviour: no build, no test run, no UI journey. Every finding is from reading the code at 81cf335f.
- Whether `normalizedValue` for a year-only date can parse in `statedDay`, i.e. whether a year-only date is dropped or narrowed to a day. Either way the uncertainty is not shown.
- The systematic-review studio (`res.protocol`, `res.screening`, `res.extraction`; PRISMA and GRADE). I read only its routing and its test name, `PersonaDeliverables2Tests`.
- Whether the four unscrubbed export views can show text from cases whose vault has protected names. I traced the paths, not data.
