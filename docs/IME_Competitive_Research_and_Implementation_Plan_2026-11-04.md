# Investigations Made Easy: competitive research and implementation plan

**Research date:** 4 November 2026  
**Product:** Investigations Made Easy, formerly Kalsmritikosh  
**Purpose:** Make a human investigator's work measurably easier, while preserving their judgement and the evidence record.  
**Code reference:** `sasmalgiri/kalsmritikosh`, `investigations-next`, `d0d6638a77383832f025a189e6dfd5e96ccd0299`.

## 1. Decision

The strongest opportunity is to shorten the journey from a mixed collection of documents to a checked, reusable finding and a usable report. The investigator should spend less time locating passages, reopening documents, dismissing bad suggestions, re-entering decisions and repairing exports.

IME already has substantial infrastructure for that journey. Its immediate competitive weakness is the reliability and continuity of the complete workflow. Several concrete source-level issues also need correction before making strong claims about what the AI read or what the case does not contain.

The recommended product promise is:

> Bring the case records together, see what has and has not been read, check each proposed finding beside its sources, and carry your decisions into a report without repeating the work.

This is a proposed positioning statement, not a verified performance claim. A timed human comparison must establish the advantage. Completing this plan also does not replace the existing release, distribution and security gates.

## 2. Research boundaries and evidence quality

This is a targeted qualitative review of the nine products discussed previously: Casefleet, CaseMap+ AI, Case IQ, Everlaw, DEVONthink, Gemini Notebook/NotebookLM, Hunchly, Maltego and i2 Analyst's Notebook. It uses published user reviews, product/community forums, practitioner assessments and vendor documentation. It is not an exhaustive reading of every review or a representative sentiment survey.

Individual review text was preferred over review sites' AI-generated summaries. Repeated themes below are priorities for IME, not measured percentages of customers. Seller-invited and incentivized reviews occur in the material and can introduce selection bias. Some Capterra evidence was available through indexed review excerpts when direct page retrieval failed. Syndicated reviews and replies were not treated as independent users.

Dates matter. Some complaints concern a previous version, a beta or a subsequently fixed incident. Those establish useful failure scenarios; they do not establish that a current competitor still has the defect. Public evidence for i2 and some Hunchly complaints was particularly sparse.

For IME, the remote branch was checked and a source snapshot was inspected at the revision above. The review concentrated on case reading, coverage, review decisions, handoffs, reports, requests, help, cost controls and committed measurements. It was not a line-by-line audit of the entire repository. No new Mac UI run, distribution-signed test or live model benchmark was performed for this report. Earlier committed measurements are identified as historical, with their own limitations.

## 3. What people value and what frustrates them

| Product | Positive signals in the material reviewed | Friction reported, with qualification | Consequence for IME |
|---|---|---|---|
| **Casefleet** | Turning documents into linked facts and timelines; reusing reviewed material in reports; approachable organization and helpful support. | Some reviewers wanted stronger OCR/transcription and support across time zones. Older reports of awkward functionality are not proof of current defects. [R1–R2] | Make passage capture, fact review and report reuse one continuous action. Provide useful recovery guidance without waiting for support. |
| **CaseMap+ AI** | Structured facts linked to evidence and case organization. | Specific 2025 cloud-transition reviews describe unreliable source links, disrupted PDF/Bates workflows, repeated metadata edits and losing position when returning to a document. Older desktop reviews must be separated from the current cloud product. [R3–R4] | Stable passage links, preserved place and efficient review matter more than the existence of a feature on a checklist. |
| **Case IQ** | Centralized case history, phases, deadlines, adaptable workflows and reporting. | Reviews describe too many clicks, scattered information, repeated lookup, reporting/setup complexity and occasional upload sluggishness. Other users praise setup and reporting, so the experience is not uniform. [R5] | Keep one case context, show the next actionable task and provide useful defaults with minimal configuration. |
| **Everlaw** | Search, document review, support and handling substantial review work. | Some reviewers report a learning curve, friction in bulk/editing operations and AI coding that needs improvement. Several also describe the interface as intuitive. [R6] | Preserve a fast expert path while giving beginners a short route to their first checked output. Test bulk operations and correction effort. |
| **DEVONthink** | A mature document workspace, organization, search and continued development. | Community discussions raise complexity, update-pricing expectations and whether AI features match users' workflows. Some comments concerned DT4 beta; later releases added capabilities. [R7–R9] | Explain the commercial model clearly and make AI useful inside an investigation task rather than requiring users to assemble the workflow. |
| **Gemini Notebook / NotebookLM** | Convenient source-grounded exploration and accessible summaries or study materials. | Hands-on assessments and forum reports describe shallow or incorrect synthesis, attribution/coverage problems and OCR-related concerns. A February 2026 grounding incident was reported fixed by users shortly afterward. [R10–R12] | Show exactly which material was available to an answer and distinguish a supported quotation from a verified conclusion. |
| **Hunchly** | Capturing and organizing web evidence while the investigator browses, reducing manual collection work. | Practitioner guidance and support material identify capture compatibility and learning limits; one user report describes difficulty with video comments. These are not measured failure rates. [R13–R15] | Make collection failures visible and preserve capture context. Support useful handoffs before building a separate web-collection product. |
| **Maltego** | Visual relationship exploration and pivots across data sources. | Some users find it expensive or excessive for small jobs; setup and credit availability can interrupt work. Vendor documentation confirms exhausted search credits can block searches. [R16–R18] | Use graphs only where they answer a case question. Make cost, dependencies and incomplete results understandable before work begins. |
| **i2 Analyst's Notebook** | Practitioner discussion values link analysis for investigative and financial work. | The available direct complaint evidence is too thin to name a current dominant complaint. An older novice discussion describes difficult import preparation; current documentation shows explicit import mapping and reusable specifications. [R19–R21] | Good import mapping and understandable links are valuable. Do not claim current superiority over i2 without a matched task test. |

The most useful cross-product lessons are:

1. **Review once, use repeatedly.** A source passage should support a finding, chronology item and report without three independent review exercises.
2. **Keep the investigator's place.** Search filters, the selected document, scroll location and the active case should survive navigation.
3. **Make evidence checking cheap.** A citation should open the right passage with enough surrounding context to challenge the answer.
4. **Give incomplete work an honest state and a remedy.** Unreadable files, provider failures, missing records and unsupported conclusions are different situations.
5. **Make the final deliverable practical.** Users value outputs they can edit, hand over and reopen without repairing links or reconstructing the reasoning.
6. **Make the cost and learning effort predictable.** Useful defaults, visible limits and recovery instructions reduce the burden around the investigation itself.

These are a synthesis of the reviewed material, not a claim that every product or every user experiences every problem.

## 4. What the current IME source establishes

Source links in this section are pinned to the inspected revision. Paths are relative to the repository; implementers should re-check a newer head before editing.

| Finding | Evidence and classification | Required response |
|---|---|---|
| **Quoted material can disappear from the AI payload.** | **Confirmed source behavior.** `Brain/CaseReader.swift`, `collapseQuoted`, replaces runs of two or more `>` lines with a marker. It does not establish that the earlier message is present elsewhere. This affects the prepared reading payload; it does not prove originals are deleted. | Preserve such text by default. Compress only with an explicit mapping to an accessible surviving copy. |
| **Content deduplication loses occurrence context in the reader.** | **Confirmed representation gap.** `CaseReader.prepare` deduplicates normalized text. `App/AppState+CaseReading.swift` chooses one source-version ID when an object has several. The reader document has one filename/version, rather than all relevant occurrences. | Separate content reuse from acquisition, sender/recipient, source-version and occurrence provenance. |
| **Coverage exists but is not connected to the whole-case answer contract.** | **Confirmed wiring gap in the inspected source.** `CaseCoverageManifestBuilder` and its output type appear in definitions, with no production builder caller found. Coverage repositories and scope resolution do have other uses. The reading loader skips absent/empty text. | Feed authorized case coverage into preparation, consent, answer receipts, review and exports. Account for unreadable/container items too. |
| **An answer that fails verification can become an absence claim.** | **Confirmed source behavior.** `CaseReader.verdict` handles `.notStated` and reports dropped proposed claims; `notStated` still says the case's documents do not say. Its receipt describes all prepared documents as the whole case. | Separate no supported passage found from failed verification and incomplete coverage. Describe actual transmitted scope. |
| **The case contradiction screen has a review detour.** | **Confirmed UI structure; time cost unmeasured.** `UI/CaseContradictionsSection.swift` shows both sides and saved decisions but keeps confirm/dismiss in the separate contradiction/gap desk. | Add review controls in place using the existing review service and repository. |
| **Requests are structured too lightly for collection follow-through.** | **Confirmed data-model limit.** `EvidenceRequest` has description, hypothesis, status, actor and revisions. It lacks explicit custodian, due date, requested period, partial receipt and delivered source references. Fulfilment changes status. | Extend the existing request model and task engine; do not create another unrelated request list. |
| **Help exists, but some instructions no longer match the product.** | **Confirmed copy drift; complete UI effect unmeasured.** Home says users need their own key and preview every send. Current code supports AI plans and stored case permission. The tutorial routes through several separate areas and assumes an older Ask experience. | Reconcile live commercial/privacy behavior and teach the same case workflow that users actually run. |
| **Handoffs and export rechecks are already implemented.** | **Existing strength.** `Personas/JobResultHandoff.swift` reloads authoritative rows and checks revisions, digests and citations. `Investigate/CaseFile/CaseOutputService.swift` reauthorizes at release and supports atomic write/readback/logging. | Preserve these controls. Improve continuity and usability rather than replacing the authority with a second system. |
| **Review storage, safe bulk review and next-step logic exist.** | **Existing strength.** `InvestigationDeskReviewRepository`, `JobResultTable` and `CaseNextSteps` provide useful foundations. | Connect them to a consistent case workspace. Do not claim these capabilities are absent. |
| **Cost controls and shared case prefixes exist.** | **Existing strength with verification work remaining.** `AICredits`, `AIPricing`, `CaseWholeReading` and provider wiring implement limits, estimates and a reusable prefix. Async batch submission remains a TODO. | Measure cost and recovery at case level; defer a batch subsystem until a measured bottleneck justifies it. |
| **Current comparative usability is not established.** | **Evidence gap.** Historical agent evaluations and narrow synthetic performance runs are not a timed human comparison of this head. | Run the protocol in section 8 and publish failures, correction time and costs as well as successes. |

One smaller robustness issue belongs in the same maintenance pass: `CloudReaders.isEmpty` does not include `roleReader`, `draftReader` or `caseReader`. This is not a proven live failure because readers may currently be installed together. Add a targeted test for each capability being installed alone and make the capability check complete.

### Existing evidence must not be misrepresented

The committed 4 November comparison, `docs/agent-reviews/real-case-old-six-ai-comparison-2026-11-04.md`, explicitly uses AI judges and older revisions. In one older arm, all 17 “different values” alerts were classified as false alarms. Later filters and the current whole-case path were not measured there. This is a reason to measure review burden now, not a current-head error rate.

`docs/SUPPORT_ENVELOPE.md` measures generated text on an M4 MacBook Air with 16 GB RAM. Its 4,000-document collection totals only 1.1 MB. It is useful engineering evidence, but does not establish responsiveness for thousands of scanned PDFs, attachment-heavy mail or current Online AI work.

The current source also contains genuine improvements that older assessments missed. Repeating an old gap after it has been fixed wastes implementation time and makes the plan less trustworthy.

## 5. Implementation contract

Preserve the current accepted product scope: single-user Mac investigation assistance, English v1, nine personas and existing advertised jobs. Preserve the current accepted AI plans, Anthropic answering policy, relay behavior, privacy controls and territorial availability. Reconcile superseded text against the most recent accepted decisions; do not resurrect an old provider list, old pricing or the previous per-send-consent policy.

Use one case ID, one source/version authority, one existing evidence vocabulary and one export authorization path. Schema additions must be additive and migrated through the ledger. UI preferences may remain preferences; case evidence and decisions remain in the ledger. Treat source content as data, including during parsing, model use and export.

The following packages are ordered by dependency. They are implementation instructions and proposed acceptance criteria, not claims that the criteria have already passed.

### P0-A — Faithful intake and a coverage record for every answer

**Goal:** The investigator can see what the answer could examine, and no sole surviving evidence disappears during preparation.

**Start in:** `Brain/CaseReader.swift`; `App/AppState+CaseReading.swift`; `Personas/Investigator/CaseWholeReading.swift`; `Ingestion/Coverage/CaseCoverageTypes.swift`, `CaseCoverageManifestBuilder.swift`, `CaseCoverageRepository.swift` and `CaseCoverageScopeResolver.swift`.

**Implement:**

1. Preserve quoted blocks unless an equivalent surviving span is positively identified in an authorized source. Keep a mapping from any compacted passage to every retained original span. Compression must not remove the only usable account or change attribution.
2. Represent canonical content separately from occurrences. A repeated body can share reading/storage work while each acquisition, message header, recipient set, timestamp, source version and container relationship remains available to the investigator. A forwarded copy is not automatically an independent corroborating source.
3. Build an authorized case coverage snapshot from the existing coverage infrastructure. Record source occurrences, canonical content, parsing/OCR state, partially read pages, containers and members, exclusions and retry remedies.
4. Attach a request-specific reading record: input revision, authorized scope, actual material supplied, transformations, selected-passage versus full-cleared-text mode and completion/failure state. A model request being sent does not prove every passage received equal attention.
5. Reconcile counts at case intake, before AI reading, after reading and at export. The existing consent sheet already lists loaded denied documents; extend it to represent unreadable or otherwise unrepresented material rather than replacing it.
6. Preserve source permissions. Local coverage can explain an authorized user's exclusions; forbidden content or confidential metadata must not enter the model request or an unauthorized export.

**Acceptance:** A quoted email whose original is absent remains answerable; identical bodies with different recipients retain both occurrences; a password-protected attachment, failed OCR page and unsupported container member remain visible; restrictive scope changes cannot reuse broader content. A count-based fixture reconciles exactly across intake, reading and report. Restore and reingestion preserve links and scope.

**Metric:** Zero silent omissions in the controlled fixture suite; complete accounting of submitted material. This is a test invariant, not a guarantee about every future input.

### P0-B — Honest answer states and useful uncertainty

**Goal:** The app helps the investigator decide the next step instead of turning technical failure into an investigative conclusion.

**Start in:** `CaseReader`, `CaseWholeReading`, the existing verified-answer composer/types, `InvestigationAnswerService` and their current presentation surfaces.

**Implement:**

1. Give supported answers, no supporting passage found, incomplete reading, failed verification, blocked sending and provider failure distinct machine-readable outcomes.
2. If every proposed claim fails verification, show that failure and the remedy. Do not describe it as proof the case contains no answer.
3. Phrase negative search outcomes within their limits: “No supporting passage was found in the 32 readable, permitted documents examined.” Expose the unresolved items and search scope. Avoid a claim of exhaustive absence based on one model response.
4. Keep a source's assertion distinct from the investigator's finding. A quote can accurately reproduce an allegation that is false or contested. Show the source, speaker, event/date role and conflicting material where available.
5. Keep useful suggestions available as clearly labelled leads, interview questions or hypotheses. They may reference supporting material but cannot silently become documentary facts or approved findings.
6. Record source/result revisions. Changed sources invalidate affected verification or approval as appropriate, while preserving the earlier decision history.

**Acceptance:** Force malformed output, unsupported numbers, swapped people, partial reading, missing files, declined permission and a provider timeout. Each produces the correct state and an actionable next step. A valid quote with an unsupported interpretation is not promoted. Repeat with AI off and with the currently supported Online route, keeping their different behaviors explicit.

### P0-C — Reduce false alerts and review each issue in place

**Goal:** Every review prompt earns the investigator's attention.

**Start in:** `UI/CaseContradictionsSection.swift`, `InvestigationContradictionGapService`, `InvestigationDeskReviewRepository`, the contradiction finder and existing evidence-target checks.

**Implement:**

1. Match the subject, event, proposition, time period, unit/currency and procedural status before suggesting a contradiction. Distinguish an updated estimate, a different transaction, a new legal stage and a true conflicting account.
2. Present both exact passages with context and a short explanation of the apparent conflict. Explain uncertainty without an unsupported confidence percentage.
3. Add Confirm, Dismiss and Defer in the case screen, calling the existing service. Record reasons such as different event, different person, changed estimate, transcription error or insufficient context.
4. Preserve decisions using stable item identity and relevant source revisions. Unchanged reruns must not restore dismissed alerts. New evidence can reopen an issue with a visible explanation.
5. Route corrections to the relevant dependency: corrected identity affects entity-dependent results; a dismissal of a conflict does not erase either source. Do not overwrite original text or silently train a shared model on case decisions.
6. Rank the review queue by materiality and evidential support. Separate a question worth exploring from a statement that two records conflict.

**Acceptance:** Include namesakes, two different bank transactions, gross versus net, allegation versus conviction, scheduled versus actual dates and amended plans. True material conflicts must still surface. Dismiss, restart, rerun, revise one source and verify precisely which decisions persist or reopen.

**Measures:** Alert precision, known-conflict recall, minutes spent on unhelpful alerts and repeated prompts per unchanged case. Historical benchmarks are development tests, not a fresh holdout.

### P1-A — One persistent case workspace

**Goal:** An investigator can progress from question to evidence to reviewed finding to report without rebuilding context.

**Start in:** `UI/CaseFileView.swift`, `UI/HomeView.swift`, `CaseNextSteps`, existing source viewers, review tables and `Personas/JobResultHandoff.swift`.

**Implement:**

1. Opening or resuming a case restores the case, task, selected record, search/filter and source position. Use a clear default landing view for a new case.
2. Present an actionable case overview: the investigation question, reading limitations, items awaiting review, evidence requests and the next case-specific step.
3. Keep the main work list and a source/detail pane available together. A reviewed finding can be added to chronology or selected for a report using the existing handoff service.
4. Use progressive disclosure for the existing jobs: show a small set relevant to the current task, with search and keyboard access to the complete catalog. Preserve all current persona commitments.
5. Preserve list selection and back-navigation position. Support keyboard review, visible focus and VoiceOver labels. Essential explanations must not require hover.
6. Extend existing safe bulk operations with a preview and appropriate undo/audit behavior. Do not bulk-approve adverse findings, identity merges or other professional judgements.

**Acceptance:** Starting from Home, an unfamiliar user imports the sample, opens a cited passage, records a decision, adds the same item to a chronology/report and resumes after restart. No retyping of the finding, source or review rationale is required. The full journey is tested in the app, not only through service calls.

### P1-B — A collection request that can actually be followed through

**Goal:** The investigator knows which missing material to pursue and what arrived.

**Start in:** `Personas/Investigator/InvestigationHypothesis.swift`, `InvestigationAnalysisService`, `InvestigationAnalysisRepository`, the shared task engine and `CaseNextSteps`.

**Implement:** Extend the existing evidence request with a linked allegation/question, custodian, requested item and date range, due date, request/response history, received source-version references and outstanding items. Represent partial delivery, refusal and inability to obtain separately. Keep acceptance or fulfilment a recorded human decision. Link a newly received source to the request and show which questions or reviewed findings may need revisiting.

Generate a draft request from the existing record when useful. Sending it is a separate authorized action; do not silently email custodians. Do not mark a request fulfilled merely because some file arrived.

**Acceptance:** Request three monthly statements, receive two and one duplicate, and preserve the missing month. A new statement updates coverage and the affected work queue without changing an approved finding automatically. Existing requests survive migration.

### P1-C — Search, identity, chronology and money that preserve context

**Goal:** The basic investigative tools reduce repeated lookup and avoid misleading aggregation.

**Implementation approach:** Inventory current support before adding features. Reuse the existing retrieval, entity, chronology and exact-decimal services; this review does not establish that every feature below is absent.

Provide reliable exact/phrase lookup and useful case/source/date/person facets, saved searches and visible search scope. Preserve the query and result position while checking passages. Add proximity or other query options only where task tests establish a need. AI results supplement inspectable source search.

Keep identity matching as a proposal with evidence and an undoable human decision. Preserve namesakes and uncertainty. For timelines, distinguish event time, message time, document date, publication date and later amendment; retain original wording, precision, ranges and time zone. For money, show explicit currencies, transaction identity, gross/returned/net amounts and reconciliation limits. A cash-flow difference is not automatically a proven loss.

**Acceptance:** Two people with the same surname remain separate; an Indian-formatted amount and equivalent wording reconcile correctly; publication date is not substituted for event date; the same transaction in two documents counts once; totals across currencies require an explicit conversion basis. Check opening the underlying passage from every result.

### P1-D — A report that reuses decisions and survives handover

**Goal:** A recipient can understand the work without the investigator reconstructing it outside the app.

**Start in:** `JobResultHandoff`, `CaseOutputService`, existing studio exporters, citation opening and review-state code.

Use the existing frozen package and authorization path for all relevant outputs. Carry the investigator's selection, source references, reviewed text and exact revision forward. A report should identify scope, method, reviewed findings, contrary material, unresolved questions, limitations and source references as relevant to its persona.

Make the report preview usable, including supported editing of narrative sections without losing the distinction between a quotation and the investigator's explanation. Provide a readable export and structured evidence index using the product's supported formats. Prioritize an editable handover format only after confirming what intended users actually submit; do not add every possible format at once.

An exported snapshot must be distinguishable from a live case. Links need stable document identifiers and human-readable page/section locators, with a permitted source bundle where appropriate. An external recipient must be able to trace included evidence using what is actually supplied. Do not silently include excluded originals.

**Acceptance:** Reopen the package outside the app; verify every material claim's intended locator. Recheck after source rename, supported restore and reingestion. Change privilege or source revision between preview and write and verify the existing release gate catches it. Expired subscriptions retain the promised read/export/recovery behavior.

### P1-E — Predictable cost, progress and recovery

**Goal:** The investigator can start, interrupt and resume useful work without surprise spending or ambiguous results.

**Start in:** `App/Store/AICredits.swift`, `Routing/Providers/Online/AIPricing.swift`, `CaseWholeReading`, provider/helper/relay request handling and the existing background-task infrastructure.

Build on the implemented limits and prefix reuse. Show the estimated first read, remaining allowance and actual reported usage for a case. Distinguish estimates from provider-confirmed charges. Do not promise cache savings before a cache hit is observed. Keep plan credits and own-key provider charges understandable without exposing unnecessary technical detail.

Verify reservation and reconciliation across concurrent requests, retries, timeouts and cancellation. Prevent duplicate application-side debits; if provider billing after a timeout is uncertain, record that uncertainty instead of showing a fictitious zero. Respect the accepted spend caps. A budget failure must be a visible blocked state rather than a blank result or silent change of answering mode.

For long operations, show actionable progress, preserve checkpoints and recover after restart. Test the actual cancellation semantics of each parser/provider. If an underlying OCR call cannot stop immediately, the interface must reflect that and prevent late results from reviving an erased case.

**Acceptance:** Reject a key; exhaust credits; trigger rate limiting; cancel a request; restart during ingestion; switch mode while permission is pending; erase a case while a job runs. Confirm honest status, no unauthorized send, no duplicate case result, no erased content returning and consistent usage accounting. Test the current real route and a controlled fault-injection route.

Async provider batches are a later optimization unless profiling establishes a launch-critical need. They require durable submission, polling, result attribution and credit handling; a TODO alone is not evidence they should precede usability work.

### P1-F — Onboarding and help that match the live product

**Goal:** A beginner completes a real task without learning the app's architecture.

**Start in:** `UI/Help/HelpTutorial.swift`, `HelpRegistry`, `HelpDocsRenderer`, `HelpLinks`, `DisabledReason`, `HomeView` and the existing isolated sample archive.

Retain the sample isolation and replayable tutorial. Reduce the beginner journey to a small number of outcomes inside the persistent case: create/open the sample, inspect reading coverage, check a proposed finding, record a decision and export the selected work. The sample must work in the default mode; optional AI steps must explicitly use the current eligible mode, plan and permission behavior.

Provide a short beginner guide, a searchable full guide and concise help beside unfamiliar decisions. Hover help can explain secondary controls, but essential meaning and blocked-state remedies must be visible and keyboard/screen-reader accessible. A carousel is optional; make it skippable, manually controlled and replayable if it proves useful. Do not use it as a substitute for a coherent workflow.

Reconcile Home, onboarding, Settings, pricing, permission explanations, privacy copy and help with the current accepted contract. Explain where originals reside, what protection applies and what Online use sends without unsupported blanket security promises. Provide a content-free diagnostic summary with a user-previewed support export; do not include documents, keys or passages by default.

**Acceptance:** A novice using default settings reaches a reviewed sample export without personal assistance. An experienced user can skip setup and use shortcuts. VoiceOver, keyboard navigation, text scaling and a small supported window remain usable. Every blocked control gives the cause and remedy. Test the tutorial against the shipping route, not a test-only response.

### P2-A — Focused interoperability and capture handoff

**Goal:** Reduce manual re-entry between tools the investigator already uses.

First inventory supported imports, Share/Services entry points and exports. Publish a truthful format matrix with limits. Prioritize source-preserving email/document/spreadsheet handoffs and structured evidence indexes based on observed customer tasks. Preserve filename, origin URL where applicable, acquisition time and method, source bytes/hash, parent attachment or container and timezone provenance.

For third-party capture bundles, begin with documented, permitted interchange formats and a mapping preview. Account for every file and reject unsupported structures clearly. A hash establishes consistency of retained bytes, not the truth of the page or a universal guarantee of admissibility.

Treat broad web crawling, a transform marketplace and enterprise collaboration as separate product expansions. The current single-user release can interoperate with specialist collection tools without reproducing them. This is a roadmap item unless a committed launch journey already depends on it.

## 6. One end-to-end acceptance example

Use a new, synthetic supplier-payment fixture designed for testing. Do not reuse a development case and call it a fresh benchmark.

**Inputs:** 40 imported source occurrences representing 36 canonical documents. Of the 36, 34 have readable text; one is password-protected and one failed OCR. Two readable documents are restricted from Online use, leaving 32 eligible readable documents. Include a quoted instruction whose earlier email is absent, repeated message bodies with different recipients, two people with the same surname and a transaction repeated in two statements.

**Required journey:**

1. Intake shows 40 occurrences, 36 canonical documents and the exact two reading problems. It distinguishes content duplication from separate acquisitions or communications.
2. The local user sees which material is permitted for AI. An answer describes the 32 documents supplied; it does not claim to have read all imported evidence. Restricted details stay out of the outbound payload.
3. The sole surviving quoted instruction remains available, with original context. Repetition does not create false corroboration.
4. The investigator asks whether a supplier was paid twice. The app presents the relevant transactions, invoice and statements. It does not infer a second payment from a duplicate record.
5. A separate controlled example has a confirmed ₹1,000 outflow and ₹200 return in the same currency. Show ₹1,000 gross outflow, ₹200 returned and ₹800 net outflow; do not label ₹800 a proven loss while liability or other relevant records remain unresolved.
6. A genuinely conflicting instruction is shown beside both passages. An updated payment estimate is distinguishable from a contradiction. A dismissal survives rerun.
7. The missing statement becomes a structured evidence request. Receiving an unrelated file does not fulfil it; receiving only part leaves it partial.
8. The investigator records a supported finding and an unresolved question, then carries both into the report without re-entering text or citations.
9. Change one source revision and one protection decision before export. Only affected work is marked stale, and the release authorization prevents prohibited material from leaving.
10. Reopen the permitted exported package outside IME and restore a supported backup on the target Mac setup. Check source traceability and the recorded review state.

This fixture demonstrates functionality. Human task timing and fresh accuracy evaluation remain separate evidence.

## 7. Delivery sequence and completion records

Use milestones with exit evidence rather than promising a calendar before engineering capacity and Mac access are known.

| Milestone | Work | Dependency | Exit evidence |
|---|---|---|---|
| **M0: trustworthy baseline** | Pin current head, reconcile current contract, inventory existing functionality, define metrics and record baseline journeys. | None | Revision/build IDs, task scripts, source inventory, baseline timings and explicit unknowns. |
| **M1: faithful reading and outcomes** | P0-A and P0-B, plus the small reader-capability check. | M0 | Controlled omission/coverage/verifier fixtures pass; live UI shows honest scope and recovery states. |
| **M2: lower review burden** | P0-C, P1-A and P1-B. | M1 | Correct review persistence, inline decisions, structured collection follow-through and complete sample journey. |
| **M3: usable deliverables** | P1-C through P1-F; only committed P2 interoperability necessities. | M2; some independent UI/help work can start earlier | Supported output opens correctly, cost/recovery tests pass, novice journey works and named-hardware evidence is recorded. |
| **M4: prove the benefit** | Fresh candidate evaluation, paired human tasks, all promised persona journeys and remaining existing release gates. | Frozen M3 candidate | Quality, time, cost, usability and distribution evidence attached to the exact release candidate. |

A sensible first engineering batch is: preserve sole quoted content; introduce truthful answer states; connect coverage; fix stale Home/help claims; make `CloudReaders.isEmpty` complete. Then shorten the case review path. Do not combine all of this into one unreviewable rewrite.

Each work package must record: source revision, exact behavior changed, migration impact, meaningful tests, actual app walkthrough result, remaining limitations and the evidence path. A passing service test is not a UI pass; a development UI pass is not a distribution-signed pass.

Update existing execution/readiness/persona records rather than creating competing status authorities. Use Proposed, Implemented, Automated-verified, UI-verified and Release-verified distinctly, or map these meanings to the repository's existing status scheme. Do not fill a human evidence column with an AI judge's decision.

## 8. How to prove “measurably easier”

### Measure the complete job

The primary measure is **time to a usable, checked work product at an agreed quality standard**. Count preparation, import, waiting, searching, source checking, correction, review and export repair. Record both active human time and elapsed wall-clock time. A fast incorrect report is a failed task, not a speed improvement.

Also record task completion, material omissions, incorrect claims, source-tracing failures, false-alert minutes, repeated entry, assistance requests and actual operating cost. Include subscription allocation separately from model usage rather than hiding either in one unexplained figure.

### Comparator design

Use tools appropriate to the same job rather than demanding one competitor win every category:

- **Everyday baseline:** the investigator's normal PDF viewer, email search, spreadsheet and word processor.
- **Evidence-to-chronology/report task:** Casefleet or CaseMap+ where a legitimately available account supports the task.
- **Document organization/retrieval task:** DEVONthink or Gemini Notebook with the same permitted sources and clearly stated differences in capability.
- **Specialist collection/link-analysis tasks:** Hunchly, Maltego or i2 only when evaluating those specific capabilities. Do not compare acquisition in one tool with completed investigation reporting in another.

No account purchases or external uploads are implied by this plan. Use properly licensed access and authorized synthetic/public materials. If a suitable competitor is unavailable, report that limitation and retain the everyday baseline; do not invent a comparison.

Start with five novice sessions to expose obvious usability failures. Then run a directional paired study with roughly 12–20 appropriate users, mixing beginners and practitioners, and report the actual mix. This is a suggested study size, not a statistical power calculation. A claim requiring a small detectable effect needs a variance-informed sample-size calculation.

Give users equivalent but different case packs in counterbalanced order. Using the same case twice rewards memory. Balance training, task difficulty and allowed assistance. Lock task definitions before comparing results. Have independent humans grade outputs against a source-supported rubric, resolving disputed material judgements through another reviewer. Keep all failures and timeouts in the results.

### Proposed targets

The targets below are proposals to adopt before the new evaluation. They have not been achieved by this review. They supplement, and do not silently replace, the accepted release contract.

| Measure | Proposed criterion | Guard against gaming |
|---|---|---|
| End-to-end task time | At least 30% lower median paired time than the everyday baseline; aim for 20% lower than the closest suitable specialist on the selected task. | Same quality threshold; include setup, correction, failures and export repair. Publish uncertainty and per-task results. |
| First value | Checked finding within 10 minutes after indexing in the beginner fixture; reviewed sample export within 20 minutes. | Also report indexing and total wall-clock time. Do not use precomputed findings hidden from the user. |
| Beginner completion | At least 4 of 5 formative novices finish the specified sample without live coaching. | This is a formative threshold, not proof of population-wide usability. Record every help request. |
| Repeated work | No retyping of an already reviewed claim, source or rationale when carrying it to a supported output. | Inspect both text fidelity and revision/citation continuity. |
| Coverage | Every input occurrence has a visible, accurate disposition in controlled tests; all partial/unreadable inputs accounted for. | Counts must reconcile, including duplicates, denied items and container members. |
| Citation traceability | Every material exported claim in the test pack opens or resolves to the intended permitted passage. | Test restored and independently opened packages, not just in-memory links. |
| Error gate | Preserve the accepted ≤1% wrong-answer requirement per measured mode/family on fresh material. | Predefine the denominator; publish wrong claims, wrong answers, abstentions, failures and useful-answer coverage separately. |
| Useful coverage | Proposed ≥95% recall of predefined material facts for supported task families. | A system cannot achieve safety by refusing everything; record completeness separately from precision. |
| Review prompts | Proposed ≥90% precision and ≥90% recall of seeded material contradictions on representative fresh tasks. | Report confidence intervals and alert volume; a tiny sample or zero alerts cannot establish success. |
| Persistence | No repeated dismissed alert on unchanged evidence; affected decisions reopen visibly when relevant sources change. | Keep source revision and decision history. |
| Responsiveness | Initial target: p95 source opening under 1 second and search under 2 seconds on the declared supported corpus/hardware. | Record cold/warm runs, data sizes and actual workload. AI latency is measured separately. |
| Cost | Complete per-case reported usage and consistent budget enforcement, with billing uncertainty visible. | Include retries and failures where charged; do not assume every cached call is discounted. |

For the 1% gate, sample size and uncertainty matter. Observing a rate below 1% in a small sample does not establish the true rate is below 1%. With zero errors, about 300 independent trials give a one-sided 95% upper bound near 1%; questions clustered within a few cases are not independent trials. Use an appropriate case-aware analysis and show raw counts. Do not pool dissimilar tasks to conceal a failing family.

### Freshness and candidate control

Earlier prosecution, Enron and six-case packs have already informed development. Keep them as regression material. Assemble a genuinely new held-out collection for the frozen candidate, with new sources and questions, a locked rubric and human review. Record case/source overlap and benchmark provenance. If the set is used to fix the product, retire it from final holdout status.

Measure AI off and each currently shipping answering route separately. Record actual API model identifiers/configuration rather than relying on informal model names. Ensure enough permitted credits and storage before starting; a failed run must be reported or rerun under its declared protocol, not blended with a different mode.

### Performance that matches real use

Test at least the existing supported Mac baseline and the actual minimum supported configuration available for validation. Declare OS, CPU, RAM, disk space and app build. Use cases measured in pages, bytes, attachment count and scan proportion, not only document count.

Include table-rich PDFs, imperfect English OCR, long email threads, attachments, duplicate occurrences and supported large structured inputs. English v1 does not require adding unapproved language support; international names, currencies and date formats should still be represented. Test cold and warm opening, concurrent ingestion and review, restart recovery and Online latency/cost separately.

### Cover all nine personas through the same workflow

Use the following outcome checks alongside the existing persona acceptance matrix. These are validation tasks, not a request for nine new engines or additional advertised jobs.

| Persona | Work product to complete through the UI | Essential check |
|---|---|---|
| Investigator | Evidence-supported finding, contrary material and collection plan | A hypothesis stays distinct from an established finding; unresolved requests remain visible. |
| Lawyer | Fact chronology and selected evidence/exhibit index | Privilege and source permissions survive review, selection and export. |
| HR/Compliance | Allegation-by-allegation report | Response, contrary evidence and the chosen proof standard follow the existing approval rules. |
| Forensic accountant | Reconciled transaction schedule | Duplicate records do not double-count cash; currencies and missing periods remain explicit. |
| Insurance SIU | Supported issue/referral summary | Suspicion, documentary facts and a human decision remain distinguishable. |
| Journalist | Claim-checking file and publication preparation | Each adverse claim retains its evidence, response status and unresolved qualification. |
| Researcher/Historian | Source-supported synthesis and screening record where relevant | Repeated reports are not independent studies or independent corroboration. |
| Genealogist | Identity hypothesis and source-backed family chronology | Namesakes and uncertain relationships are not silently merged. |
| Individual/Family | Clear personal case timeline and next-action summary | A beginner can understand sources, uncertainty and practical next steps without specialist terminology. |

## 9. Instructions to the implementing agent

1. Rebase the assessment on the actual remote head and read the latest accepted decisions before editing. Preserve unrelated working-tree changes. This report's revision is a baseline, not a command to reset newer work.
2. Turn each P0/P1 package into a bounded implementation ticket with its evidence, user-visible outcome, dependencies and acceptance cases. Identify existing implementation first; close a ticket as already satisfied only with current evidence.
3. Implement the M1 fixes first, then the end-to-end M2 journey. Use existing ledger/review/export authorities. Do not introduce another evidence truth store or an uncontrolled provider route.
4. Run meaningful automated tests for the affected behavior and required repository checks. Migrations, evidence transformations, privacy/race behavior and export authorization warrant real tests. Avoid tests that only repeat the implementation.
5. Walk through the actual UI after the service tests. Use the production application route and a disposable fixture. Do not modify the investigator's saved folders or real cases to make a test convenient.
6. Verify the signed candidate at the appropriate release stage. Record build identity and actual evidence; do not infer signed behavior from Debug or development-only tests.
7. Maintain one source of status truth. Reconcile `FINAL_BRIEF_EXECUTION`, readiness, release evidence and persona acceptance records. Mark stale reports as superseded with their historical context intact.
8. Run the fresh measurement protocol only after candidate freeze. Keep human judgement, AI grading and automated assertions separately labelled. Do not rewrite an answer key merely to improve the score.
9. Continue routine implementation and repair without unnecessary permission requests. If completion actually depends on a person's credentials, account authority or independent review, prepare the exact work product and identify the specific dependency; never invent approval or a human result.
10. Finish with a concise release recommendation tied to the exact candidate: verified outcomes, unresolved blockers, measured time/quality/cost and known supported limits. An implementation checklist alone cannot justify the claim that the app makes investigations easier.

## 10. Source register

All links were consulted or retrieved during the 4 November 2026 research. Review pages can change; the dates below describe particular relevant material, not a promise that the entire page concerns that release.

| ID | Source | Evidence and limitations |
|---|---|---|
| R1 | [Casefleet reviews — Capterra](https://www.capterra.com/p/155618/CaseFleet/reviews/) | Individual excerpts from 2024–2026 on organization, timelines, support availability and transcription. Direct fetch was blocked by a content-type issue; indexed excerpts were available. |
| R2 | [Casefleet reviews — G2](https://www.g2.com/products/casefleet/reviews) | Small historical set, including incentivized reviews; evidence linking/report reuse and OCR recovery comments. Do not treat it as a current broad survey. |
| R3 | [CaseMap reviews — Capterra](https://www.capterra.com/p/35995/CaseMap/reviews/) | Specific August and November 2025 cloud-workflow complaints from indexed review text. These are user reports, not reproduced defects. |
| R4 | [CaseMap+ AI reviews — G2](https://www.g2.com/products/lexisnexis-casemap-ai/reviews) | Much of the visible review material concerns older desktop versions despite the current product heading. |
| R5 | [Case IQ reviews — G2](https://www.g2.com/products/case-iq/reviews?qs=pros-and-cons) | Actual reviewer passages alongside AI-generated theme summaries. Includes 2026 reviews with different experiences of setup, reporting, navigation and upload performance; seller-invited reviews are present. |
| R6 | [Everlaw reviews — G2](https://www.g2.com/products/everlaw/reviews), [review themes with individual excerpts](https://www.g2.com/products/everlaw/reviews?qs=pros-and-cons) | Relevant 2026 individual reviews and bulk-workflow comments. The extracted page varies between fetches. Aggregate theme counts were not used as prevalence measurements. |
| R7 | [DEVONthink pricing and AI discussion — developer forum](https://discourse.devontechnologies.com/t/annual-update-pricing-model-criticism-and-dt4-ai-features/85385) | October 2025 discussion; replies clarify optional updates and the original poster revises some criticism. |
| R8 | [DEVONthink 4 upgrade — Mac Power Users](https://talk.macpowerusers.com/t/devonthink-4-upgrade/40685) | May 2025 beta-era discussion; useful for expectations, not current defect claims. |
| R9 | [DEVONthink 4.3 announcement](https://www.devontechnologies.com/blog/20260521-devonthink-43-herschel) | Vendor release information, used to check that later capabilities supersede earlier comments. |
| R10 | [A Critical Look at NotebookLM — University of Michigan](https://lsa.umich.edu/technology-services/news-events/all-news/teaching-tip-of-the-week/a-critical-look-at-notebookLM.html) | Hands-on educational assessment; not a controlled investigative benchmark. |
| R11 | [NotebookLM grounding incident — Google AI Developers Forum](https://discuss.ai.google.dev/t/critical-regression-gemini-3-1-pro-update-feb-19-completely-broke-notebooklm-s-rag-grounding/126857) | February 2026 user reports with a subsequent reported fix, and later discussion. Users' conjectures about internal causes were not treated as facts. |
| R12 | [OCR concern — NotebookLM user discussion](https://www.reddit.com/r/notebooklm/comments/1wo65ua/hallucination_with_bad_ocr/) | September 2026 anecdotal report; not independently reproduced and not a general error rate. |
| R13 | [Hunchly — Bellingcat Online Investigation Toolkit](https://bellingcat.gitbook.io/toolkit/more/all-tools/hunchly) | Practitioner overview of capture and investigative workflow; not a user-sentiment poll. |
| R14 | [Hunchly page compatibility support](https://support.hunch.ly/category/61-page-compatibility) | Vendor documentation for known compatibility categories; does not imply every page on every named platform currently fails. |
| R15 | [Hunchly/video-comment discussion — r/OSINT](https://www.reddit.com/r/OSINT/comments/1o5wd74) | October 2025 user report; limited evidence of one task. |
| R16 | [Maltego — Bellingcat Online Investigation Toolkit](https://bellingcat.gitbook.io/toolkit/more/all-tools/maltego) | Practitioner explanation and tested-version context for graph/pivot workflows. |
| R17 | [Maltego suitability/cost discussion — r/OSINT](https://www.reddit.com/r/OSINT/comments/1kxvdt1) | May 2025 practitioner opinion about smaller investigations; pricing/value can vary by plan and task. |
| R18 | [Maltego search credit-limit support](https://docs.maltego.com/support/solutions/articles/15000062761-credit-limit-reached-or-no-valid-maltego-search-license) | Official explanation of a credit/license-related search block and remedies. |
| R19 | [Link-analysis replacement discussion — r/1811](https://www.reddit.com/r/1811/comments/1gmn8rk) | November 2024 practitioner discussion values Analyst's Notebook after a contract ended; the reason for ending it is not established. |
| R20 | [i2 import-preparation discussion — r/vba](https://www.reddit.com/r/vba/comments/100sdnw) | January 2023 novice import difficulty; historical and too sparse to identify a current main complaint. |
| R21 | [i2 Analyst's Notebook getting started](https://docs.i2group.com/anb/10.1.1/anb_get_started.html) | Primary documentation for import mapping/specifications. |

### IME primary evidence

- [Inspected repository revision](https://github.com/sasmalgiri/kalsmritikosh/tree/d0d6638a77383832f025a189e6dfd5e96ccd0299)
- [CaseReader.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Brain/CaseReader.swift)
- [AppState+CaseReading.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/App/AppState%2BCaseReading.swift)
- [CaseWholeReading.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Personas/Investigator/CaseWholeReading.swift)
- [Coverage manifest builder](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Ingestion/Coverage/CaseCoverageManifestBuilder.swift)
- [Case contradiction screen](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/UI/CaseContradictionsSection.swift)
- [Evidence-request model](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Personas/Investigator/InvestigationHypothesis.swift)
- [Reviewed result handoff](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Personas/JobResultHandoff.swift)
- [Case output service](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift)
- [Help tutorial](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/Kalsmritikosh/UI/Help/HelpTutorial.swift)
- [Support envelope](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/docs/SUPPORT_ENVELOPE.md)
- [Historical agent-run case comparison](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/docs/agent-reviews/real-case-old-six-ai-comparison-2026-11-04.md)
- [Accepted decisions and historical changes](https://github.com/sasmalgiri/kalsmritikosh/blob/d0d6638a77383832f025a189e6dfd5e96ccd0299/SHIP_DECISIONS.md)
