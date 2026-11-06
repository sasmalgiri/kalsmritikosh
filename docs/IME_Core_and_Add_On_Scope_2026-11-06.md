# Investigations Made Easy: core product and optional scope

6 November 2026 · Proposed scope decision and implementation instructions

Reviewed source: sasmalgiri/kalsmritikosh, investigations-next, commit 68addaa4f8fc9e8197cabc2fef6d60978be3bc7a. This is a companion to IME_Living_Case_Map_Implementation_Plan_2026-11-06.md. It narrows what must be prominent and what must be delivered first; it does not authorize removing existing records or purchased access.

## 1. The decision

Build one complete investigation workspace, with optional specialist capabilities around it. The product definition should be:

> A private case workspace that helps a human investigator collect records, find exact evidence, connect and review it, track unresolved work, and produce a source-backed report.

The core must complete that workflow without cloud AI, a specialist pack, or a connector. AI can help the investigator; it must not be the only way to find, review or export evidence.

The current code declares 60 switchable product modules, in addition to the internal knowledge-module switchboard. It already has a Simple mode and five primary navigation items: Home, Ask, Projects, Files and Outputs. The problem is therefore not simply the number of sidebar entries. It is the number of overlapping concepts, secondary destinations, settings and ways to start substantially the same work.

The strongest simplification is to make the case the organizing unit. Merge related screens into views of the same records. Do not build a second case database to power a new dashboard.

This is a source-level scope review, not a claim that all declared modules work in the signed application. It covers all 60 product-module declarations and the main navigation/contracts; it is not a new runtime acceptance audit of all 168 jobs.

## 2. Required core: a complete investigation, from intake to report

| Capability | Minimum required behavior | Boundary |
|---|---|---|
| Case and scope | Start/resume a case; record purpose, questions, people, dates and boundaries; review new documents before inclusion. | One investigator remains responsible for judgments. A persona changes language and templates, not evidence rules. |
| Evidence intake | Common PDF, Office, image and email formats within a published tested matrix; OCR and retry; attachments; exact deduplication; visible processing status and omissions; preserve originals and provenance. | Ordinary Outlook/email workflows should not require a specialist purchase. Do not promise every PST/OST variant from a module description alone. |
| Precise search | Keyword/phrase/Boolean search, date/person/type filters, saved searches, case scope, matching passages, explicit coverage, pagination and opening the original. | Exact matching is deterministic over the successfully indexed material. It cannot guarantee that OCR, extraction or the collection itself is complete. Semantic results are separately identified. |
| Living case workspace | Overview and stable map/list views of questions, people, chronology, evidence, findings and changes; manual view strip; saved position and useful filters; source inspector. | No automatic carousel rotation. No giant graph required before the person can read a case. List and keyboard access must offer equivalent work. |
| Review and reasoning | Notes, tags, highlights, manual links, unassessed/reviewed states, supporting and contrary material, contradictions, unanswered questions, and clear investigator-entry labels. | A link or quotation does not establish the truth of a claim. Automatic suggestions remain suggestions. |
| Actions and follow-up | Tasks, deadlines, evidence requests, receipts, interview notes and response tracking attached to the case. | Basic follow-up is essential. Formal audit/CAPA methods and automated monitoring can be optional. |
| Findings and outputs | Findings with reasoning and contrary evidence; appropriate response/exception records; report assembly; practical PDF, Word and CSV exports; source links and frozen export provenance. | A usable report must not require an add-on. Specialist legal production and presentation formats may. |
| Protection and continuity | Case isolation, access controls, encryption protections, consent, privilege/redaction checks, legal holds, backup/restore, erasure, history and export integrity. | These protections apply across all modules. Existing vault originals rely on FileVault; the product must continue to describe that accurately. |
| Learning and accessibility | Short first-case guide, a sample case, contextual help, clear empty/error states, keyboard navigation and readable map/list alternatives. | Advanced-feature guides appear when the feature is used. Required help must not become a separate purchase. |

The acceptance fixture should take an ordinary document-heavy case through intake, exact search, source review, chronology, a contradiction, a follow-up request, a reasoned finding and a cited report with optional packs disabled. This is a completeness criterion for the simplified core, not a newly invented external approval gate.

## 3. Simplify navigation by merging, not by discarding evidence

Recommended global navigation: Cases, Evidence, Search and Outputs; Settings and Help remain utilities. Start/resume belongs in Cases. Evidence is the intake/review destination and must always show whether the user is in an active case or the wider library. Search defaults to the active case and makes any wider scope explicit. Ask is available within that case/search context rather than acting as a competing product homepage.

Within an active case, use a manually controlled strip of Overview, Questions, People, Chronology, Findings and Changes. Show the map, list or table appropriate to the selected view. Keep Actions and Report readily available from the same workspace. These are views over shared records, not six additional databases or independently generated versions of the case.

| Current concepts | Consolidation |
|---|---|
| Cases, Projects/workspaces, case glance and investigation start/resume | One case entry and workspace. Where a project genuinely groups multiple cases, preserve that relationship but keep it out of the beginner's path. |
| Timeline, relationship graph, dossier, statements and case connections | Case views sharing selection, filters and source inspector. |
| Findings, assertions, hypotheses, contradictions, gaps and review | Questions and findings workflow, with specialist methods revealed on demand. Preserve distinctions between a claim, a source statement, a hypothesis and a decision. |
| Sources, library, import queue and completeness | Evidence intake and review with clear processing/coverage states. Keep excluded sources excluded. |
| Work, Work Center, registers and separate studios | Contextual case actions and optional professional workspaces. Do not require a novice to choose among 168 job names to advance a case. |
| Saved answers, notebook, rich notes and generated briefings | Case notes and outputs, with record type and provenance explicit. |
| Audit, answer path, authenticity, receipt verifier and citations | Details available from the relevant document, answer or export. Keep audit/export access discoverable without a full-time navigation destination. |
| Archive topics, trends, freshness and raw query tools | Advanced archive/analysis workspace. Do not put these between intake and a reviewed case report. |

Do not remove a screen just because its title overlaps. First map its unique commands and data to the replacement, preserve links, and verify the destination. Keep compatibility routing until saved links and workflows have migrated.

## 4. Optional packs: useful for some investigators, not prerequisites

Optional means the person can enable a capability when useful. It does not automatically mean another subscription. For the first simplification, reorganize currently entitled capabilities into included packs. Commercial changes require a separate, explicit product decision.

| Optional capability family | Contents | What stays in core |
|---|---|---|
| Professional workflows | Legal production/Bates/load files; specialist privilege work products; HR and SIU templates; research screening; genealogy; journalism publication review. | Core evidence/review/response safeguards, basic redaction, holds, case reports and ordinary interviews. Personas can be presets over the same engine. |
| Advanced analysis | Forensic financial reconciliation and tracing; communication networks; statement drift; watchlists; ACH/Fishbone/5 Whys/CAPA; Data Lab and custom entity schemas. | Basic chronology, amounts with currency, manually reviewed relationships, contrary evidence and unanswered questions. No invented totals or automated guilt decisions. |
| Media and geography | Transcription workflows, image similarity, location analysis and specialist browser/message-history formats. | Ordinary scanned evidence OCR, source preview, attachment provenance and safe failure reporting. No face grouping; it was already removed by owner decision. |
| Connections and automation | DEVONthink, Obsidian/Notion imports, Shortcuts/AppleScript, Spotlight, menu-bar access, folder rules, question monitors, encrypted sync and companion-device workflows. | Ordinary file import, simple Share/Add Files capture, saved searches, backup and restore. Connectors should not shape the standalone default experience. |
| AI assistance | Optional online grounded answers, synthesis and paid transcription through supported routes; existing plan/own-key choices remain. | Manual review, deterministic search and report assembly work offline. Consent, masking, source checks and spend controls are mandatory parts of any enabled AI path. |
| Advanced presentation and history exploration | Rich map layouts, curated presentation sequences and reconstructed historical comparisons after the historical data model is sound. | The basic living case map, saved layout, audit/revision records and a useful changes feed. Do not sell access to the history needed to understand one's own evidence. |

These are product families, not a recommendation to create six new paid SKUs. Start with a small capability catalog that reveals only enabled tools. Add paid differentiation later only where there is a distinct maintained professional workflow or recurring service cost.

Team collaboration is different: keep it deferred for v1. Shared identities, permissions, conflicts and audit responsibilities require separate engineering. Do not sell the currently blocked team-review switch as a completed add-on.

## 5. Retire, hide or correct instead of selling

| Candidate | Recommendation | Reason |
|---|---|---|
| Content Creator / Publish Package | Remove from the investigation product's main catalog. Preserve old saved work and route any relevant compliance checks to Compliance. | It expands the product into a different job. It is already hidden by default. |
| Generic FAQ, spoken briefing and decorative mind-map generators | Retire as prominent standalone product features. Preserve a useful cited case summary; retain niche presentation outputs only if users demonstrate a need. | More generated formats do not necessarily reduce investigative work. |
| Personal archive accuracy score | Move to internal diagnostics or clearly bounded experimental evaluation; remove marketing implications of proven personal accuracy. | Questions and checks generated from the same archive do not establish independent real-world accuracy. |
| Person risk score | Remove person-risk ranking. If retained for documents, call it review priority and show the specific signals. | Conflict, recency or a watchlist match does not establish a person's culpability or risk. |
| Corroboration meter | Replace the trust-like meter with explicit source counts, dependence status and review state. | Repeated accounts may share one source. Several citations do not automatically establish independence or truth. |
| Engineering retrieval/synthesis switchboard | Hide from normal settings; retain supported diagnostic controls for development/troubleshooting. | Users should not need to understand rerankers, HyDE or extraction stages to run a reliable case. Essential coverage and integrity controls stay enforced. |
| Duplicate or unreachable graph/canvas implementations | Consolidate after reachability and data-use checks; retain one production path and compatibility routes. | Maintaining multiple incomplete visual engines creates inconsistent behavior. Do not delete a referenced implementation on appearance alone. |
| Automatic carousel movement or decorative graph motion | Do not add to the case dashboard. | It disrupts orientation and reading. The user explicitly wants manual exploration as the case grows. |
| As-of view marketed as historical knowledge replay | Rename to a document-date filter until record-time history supports replay. | The current timeTravel module filters by file date, which differs from what investigators knew at the time. |

## 6. Decisions for every current product module

Disposition meanings: CORE = available in the base workflow; MERGE = retain capability inside a core surface; SPLIT = retain essential behavior and make specialist behavior optional; OPTIONAL = reveal on demand; INTERNAL = diagnostic rather than a product promise; RETIRE = remove prominent product surface while preserving saved work; DEFER = not a v1 offering. These are proposed product decisions, not a claim that the code already enforces them.

| Module key | Disposition | Instruction |
|---|---|---|
| advancedSearchSyntax | CORE | Keep supported syntax, explicit parse errors and case scope; complete tested operator semantics. |
| searchCoverageBadge | CORE | Coverage and omissions are required wherever results appear; distinguish archive and case coverage. |
| signedReceipts | CORE | Preserve import/export provenance; reveal details in context. |
| userTags | CORE | Simple manual organization within case evidence. |
| deepLinks | CORE | Stable passage/source links used throughout review and reporting. |
| shortcutsActions | OPTIONAL | Integration/automation capability, off unless selected. |
| commandPalette | CORE | An accelerator, never the only way to reach a required action. |
| ledgerRelocation | OPTIONAL | Advanced storage setup; safe backup/restore remains core. |
| importQueue | CORE | Visible progress, failures, retry and appropriate controls. |
| proofBundles | SPLIT | Evidence-backed export integrity is core; portable verification packages are an advanced sharing format. |
| gapMap | MERGE | Unanswered/missing-evidence work inside the case; pattern suggestions remain qualified. |
| corroborationMeter | MERGE | Replace meter with transparent counts, source dependence and assessed/unassessed state. |
| devilsAdvocate | MERGE | Finding contrary material belongs in core review; optional AI may assist. |
| timeTravel | SPLIT | Basic document-date filtering core; genuine historical replay is later work. |
| liveFactCheck | MERGE | Report-source checking in core; avoid implying matching text verifies truth. |
| archiveSelfScore | INTERNAL | Do not present as a guaranteed personal accuracy measure. |
| leastDataOnline | CORE | Mandatory minimization and spending/data boundaries whenever Online is enabled. |
| statementDrift | OPTIONAL | Advanced statement comparison; core can record and inspect contradictions manually. |
| caseSlices | SPLIT | Basic redacted case/report export core; specialized signed read-only slices optional. |
| answerPath | CORE | Trace available from an answer/details view, not a separate main workspace. |
| livingDossiers | MERGE | Core case people/organizations; advanced automatic tracking optional. |
| annotations | CORE | Source highlights and clearly labelled investigator notes. |
| emailAuthenticity | SPLIT | Preserve headers/provenance in core; advanced signature diagnostics optional with limits explicit. |
| specPSTReader | CORE | Common supported Outlook intake without a specialist paywall; publish tested coverage and failures. |
| nearDuplicates | SPLIT | Exact duplicate handling core; sophisticated version/similarity grouping optional, never destructive merging. |
| legalProduction | SPLIT | Holds and safe exports core; Bates numbering and production load files optional legal tools. |
| exportFormats | SPLIT | Useful PDF/Word/CSV reports and data access core; specialist interchange variants optional. |
| appLock | CORE | Accessible security setting with sensible defaults; no security upsell. |
| byteRangeItems | CORE | Bound memory, disclose partial reads and exclusions; larger supported capacities must be measured. |
| devonthinkImport | OPTIONAL | Enable for users connecting DEVONthink, not every new investigator. |
| sendToDevonthink | OPTIONAL | Contextual connector action, not a default core destination. |
| timelineGraph | MERGE | Case chronology and relationship view share the canonical workspace and source inspector. |
| proactiveAlerts | OPTIONAL | User-selected rules; basic visible intake/change status remains core. |
| smartCollections | SPLIT | Saved searches core; automatic filing/rules optional. |
| captureExtensions | SPLIT | Simple Share/Add Files capture core; broader capture and companion-device workflows optional. |
| issueChronology | MERGE | Ordinary issue/date chronology core; specialist drafting templates optional. |
| communicationAnalysis | OPTIONAL | Advanced mail/network analysis. |
| watchlists | OPTIONAL | Bulk screening; ordinary name/phone/email case search stays core. |
| reviewCoding | SPLIT | Manual review and sensitive/privileged handling core; bulk discovery coding and suggestions optional. |
| studioOutputs | RETIRE | Remove generic FAQ/audio/mind-map outputs from the main proposition; keep useful cited case summaries. |
| menuBarAsk | OPTIONAL | Convenience feature, normally included rather than a separate paid SKU. |
| imageIntelligence | OPTIONAL | Similarity/crop review with no face grouping. |
| locationMap | OPTIONAL | Geospatial view when coordinates are relevant; no requirement for a general investigation. |
| notesImport | OPTIONAL | Notes-system migration/connectors. |
| onlinePIIMasking | CORE | Part of privacy protection when an Online path is enabled. |
| questionMonitors | OPTIONAL | Explicitly enabled automation, scoped to the case with spend controls. |
| customEntityTypes | OPTIONAL | Advanced schemas/Data Lab; standard people/organizations/events core. |
| riskScore | SPLIT | Remove person-risk scoring; optional document review-priority view with reasons only. |
| ocrUpgrade | CORE | Readable scans, retry and low-quality/partial warnings are ordinary intake needs. |
| extraParsers | SPLIT | Common Office support core; specialized browser/message/legacy formats optional with tested boundaries. |
| mailRecovery | OPTIONAL | Specialist recovery aid; do not imply deleted-space carving the implementation does not perform. |
| teamReview | DEFER | Keep unavailable in single-user v1; do not market as shipped collaboration. |
| onlineAnswers | OPTIONAL | Existing AI plans/own-key path; the full manual investigation workflow remains independent. |
| writtenNotes | CORE | Case notes with revisions and explicit authorship/provenance. |
| userGroups | MERGE | Simple case evidence organization; elaborate archive filing can stay advanced. |
| filingSuggestions | OPTIONAL | Suggestions only; no automatic case-scope expansion. |
| richDocuments | SPLIT | Useful notes/markup core; a full rich-document authoring suite is unnecessary. |
| folderSync | OPTIONAL | Separate optional connection workflow with honest supported-device and conflict behavior. |
| contentCreatorPersona | RETIRE | Keep hidden, preserve existing work, remove from the investigation product pitch. |
| spotlightIndex | OPTIONAL | Explicit opt-in because titles/summaries are copied into operating-system search. |

KnowledgeModule is a different layer. Its extraction, retrieval, ingestion and failure-handling controls must not be bulk-disabled just to make Settings shorter. Replace the normal switchboard with task-oriented preferences; retain diagnostic access where support actually needs it. Background synthesis should be demand-driven or explicitly enabled, with no surprise online sends or spend.

## 7. Personas and commercial boundaries

Use a persona as a language/template preset over one case engine. Do not make nine separate versions of provenance, findings or reporting. Investigator is the general starting point; Individual is its simpler preset. Other professional workflows appear when enabled or relevant to the case.

The current SHIP_DECISIONS contract includes nine active personas and 168 advertised jobs, and records legacy purchase rights and continued access to reading/export/backup/privacy controls after expiry. The present recommendation reorganizes those capabilities; it does not quietly revoke those rights or establish new paywalls.

Preserve verified existing entitlements, all saved outputs and the ability to read/export them. If future editions sell additional packs, distinguish genuinely new maintained capabilities from already promised functionality. Do not charge separately for source links, ordinary OCR/search, security, erasure, recovery, basic redaction or a usable report. Keep a package disabled state separate from a purchase entitlement state.

## 8. Changes to the living-case-map plan

Keep the central idea: the map grows with the case and the investigator can explore it manually. It is the core workspace, not a luxury add-on.

Deliver first: canonical case projection, stable identities, source-linked nodes/edges, an equivalent list, clear relationship/review states, progressive disclosure, basic filters, saved layout, manual view selection, and a changes feed. Preserve existing inclusion, erasure, hold, backup and frozen-export rules.

Defer advanced presentation choreography, multiple competing graph engines, arbitrary user-defined visualization systems, full historical map replay and visually elaborate exports until the daily workflow is reliable. The history events/revisions needed for future replay must be recorded correctly now; postponing the replay interface must not discard evidence history.

Keep sufficient scale handling in the first version: bounded rendering, visible truncation, stable navigation and tested workload limits. A large-case performance failure is not a cosmetic feature that can wait for an add-on.

## 9. Instructions for the implementation agent

1. Freeze the source baseline and produce a machine-readable capability inventory: module/job key, canonical service, view, data owner, dependencies, enabled-by-default state, entitlement and actual verification level. Use this proposal as a scope decision, not as evidence of implementation.

2. Separate four concerns in code: core capability, optional visibility, purchase entitlement and diagnostic/preview flag. Core integrity guarantees cannot be switched off by a persona or pack. Retain explicit user choices and do not enable Online, Spotlight, sync or automated monitoring during migration.

3. Define a small set of core capabilities and optional packs. Split mixed modules before changing defaults: legalProduction, exportFormats, smartCollections, reviewCoding, extraParsers and captureExtensions are examples. Do not turn off an entire mixed module and accidentally lose a core safeguard.

4. Build the case workspace on existing ledger records and canonical services. Route case people, chronology, questions, findings, changes and report actions into it. Preserve source identifiers, revisions, quoted passages and frozen export behavior. Use the existing output/handoff pipeline rather than a second export path.

5. Migrate navigation and deep links safely. Map old destinations to their new contexts, preserve current case and selection, provide a clear destination when an optional pack is disabled, and keep prior saved results readable. Hidden features must not leave blank screens or broken saved links.

6. Remove specialist controls from the beginner path. Add a small capability catalog that explains the investigative task each option supports. Place relevant actions beside the work they perform. Avoid a forced setup questionnaire, automatic carousel or long tour before the first useful result.

7. Retire the misleading/product-misaligned surfaces in section 5. Reword scores before exposing them. Retain any valuable underlying records. Do a reachability/reference audit before removing duplicate code, fixtures or view implementations; include command palette, URLs, menus, shortcuts and tests.

8. Preserve privacy and storage semantics. A hidden or expired pack must not suppress holds, export rechecks, audit history, erasure, cancellation after consent changes, or no-write-after-case-erasure guards. Include derived graph/map state in erasure and backup checks. Do not copy sensitive labels/passages into unprotected layout preferences or logs.

9. Reconcile the code-generated module matrix, help, onboarding, product contract and store copy. Describe the core with concrete outcomes rather than 168 jobs. Keep a complete capability list for existing users. New scope docs must distinguish recommended, built, integration-tested and signed-app-verified states.

10. Run the meaningful tests below on the resulting candidate. Existing release evidence remains governed by the owner's latest decisions. Do not fabricate signed UI verification or claim that a source review establishes shipment readiness. Record external or machine-dependent work as unverified when it could not actually run.

## 10. Acceptance checks for the simplified scope

| Check | Required result |
|---|---|
| Complete base-case journey | With optional packs and Online disabled, import representative PDF/Office/email/scanned evidence, see failures, search it, open sources, create notes/chronology/relationships, record contrary evidence, follow up, make a reviewed finding and export a usable cited report. |
| No accidental core dependencies | Disabling each optional pack leaves intake, search, source opening, manual analysis, history, report/export, backup and erasure usable. Test dependency boundaries rather than every theoretical combination. |
| Prior installation migration | Existing cases, layouts, annotations, saved results, links and verified entitlements survive. Previously disabled privacy-sensitive connections remain disabled. |
| Search honesty | Unsupported syntax is rejected clearly; mixed filters obey documented semantics; paging/truncation and failed/unindexed sources are visible. A zero-match result never implies missing sources were searched. |
| Canonical map/list behavior | The same record and revision appear across views. Selection and position survive normal updates. Unreviewed/suggested links do not silently become accepted findings. |
| Export integrity | Source revisions, privilege changes, missing sources, investigator entries and approval/draft states carry through the existing export checks. |
| Erasure/hold/race behavior | Optional views/derived stores cannot resurrect deleted material, bypass a hold or retain excluded sensitive content. |
| Subscription/pack boundaries | Lapse and pack disablement preserve the contractually retained reading, export, backup, recovery, help and privacy functions. No saved work becomes hostage to a new pack. |
| Accessibility and orientation | Required actions are possible by keyboard and list/table views. The view strip is manual. Help explains case scope, partial intake and evidence states at the point of use. |
| Measurably easier evidence | Compare the same realistic case tasks before/after simplification: time, unnecessary navigation, missed evidence, corrections and assistance needed. Do not claim proven user benefit from fewer screens alone. This supports the product claim without reinstating a superseded release approval requirement. |

The release scope is successful when an investigator can complete an ordinary case without encountering a specialist tool they do not need, while a specialist can enable deeper tools without losing the common evidence model.

## Source anchors

- [ProductModule.swift — all 60 declared product modules, defaults, dependencies and v1 scope](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/App/Modules/ProductModule.swift)
- [RootView.swift — navigation, Simple mode and stage primaries](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/RootView.swift)
- [KnowledgeModule.swift — internal capability switchboard](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Knowledge/Modules/KnowledgeModule.swift)
- [SHIP_DECISIONS.md — product scope, personas, entitlements and dated owner decisions](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/SHIP_DECISIONS.md)

Where older summaries conflict with dated owner decisions, use the latest applicable owner decision. This scope recommendation is a proposal; it is not a record that the repository or store offering has already changed.
