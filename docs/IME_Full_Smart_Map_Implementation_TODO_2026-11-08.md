# Investigations Made Easy — full smart-map implementation TODO

**Date:** 8 November 2026, Asia/Kolkata  
**Repository:** sasmalgiri/kalsmritikosh  
**Baseline branch:** investigations-next  
**Baseline SHA, rechecked for this checklist:** 58717ec8bfbc543e9bf7700d2dd66c2c4b867135  
**Governing specification:** [Recursive Case Map Feasibility and Implementation Plan, version 2](https://chatgpt.com/library?file_id=libfile_e2425398a3388191ba38fc31c1492614&account_id=personal), including the mother-case/child-action model in §17 and smart-map contract SM-01–SM-10 in §18.

**Checklist size:** 330 uniquely identified tasks in 30 work areas, organized into eight delivery milestones. Each task includes an observable acceptance condition. No task is marked complete by this document.

**Research clarification, 8 November 2026:** Appendix L now maps verified public capabilities of DataWalk, i2, Casefleet, Maltego and Palantir to specific task IDs, observable map behavior and scope boundaries. Several existing requirements were made more precise without changing the 330 IDs. This is native implementation guidance informed by documented capabilities, not a claim that the five products are integrated into IME or that feature parity has been achieved.

This is an implementation and acceptance checklist. It does not mark the current product complete. All boxes begin unchecked because completion requires candidate-specific evidence; an unchecked item may already be partly or wholly implemented and must be inspected before changing it.

## A. The outcome to deliver

Deliver one connected, deeply expandable case map through which an authorized investigator can understand the recorded case, inspect sources, compare accounts, trace people and money, identify gaps, perform or assign work, receive contributions, review changes and produce a traceable final record.

The map retains the complete complexity of the case. Any report, key point, transaction, person, question or action can open further detail and work. There is no arbitrary product limit of three or four levels. One canonical object can participate in several branches without conflicting copies. The mother case owns recursively linked child actions; their results update the same case and may justify further work.

One investigator and a real multi-user team use the same model. AI is optional. It can organize, extract, relate and create/route permitted actions under a configured policy. Evidence, source assertions, interpretations, unresolved questions and reviewed findings remain distinct. Completing work does not automatically establish truth or guarantee that a case is solved.

Every feature must improve at least one of these jobs: understand the case; find and inspect material; compare alternatives; determine next work; maintain the case with less repeated effort; hand over or review it. Team and automation infrastructure supports that map experience.

## B. Execution rules and completion evidence

1. Start from the actual latest source, record its SHA and inspect changes since the baseline. Preserve the owner's uncommitted work. Use an isolated branch/worktree where appropriate; do not overwrite another agent's working tree.
2. Reuse existing canonical repositories, the task engine, case scope resolver, source inspector, output pipeline, help system and map workspace. Do not create parallel truth stores or another disconnected canvas/task/report system.
3. Inspect existing behavior before implementing each item. If it already meets the requirement, retain it and supply current evidence. Repair genuine gaps rather than rewriting working code to match proposed type names.
4. Use the newer owner direction for the final scope: recursive smart map, core money/history/work and basic team contribution are required. A solo release can be an intermediate milestone, not a substitute for the final team-capable product.
5. Work through complete vertical journeys. Do not report completion from placeholder screens, a registered node kind, a passing build, or an AI-generated screenshot.
6. Keep three evidence states separate: **implemented**, **observed in the relevant UI/build**, and **measured benefit**. A service test cannot close a UI journey; an agent simulation cannot be labelled a human usability study.
7. Use meaningful tests for data integrity, permissions, concurrency, transformations and failure paths. Avoid tests that merely repeat implementation constants. UI copy/help changes can use inspection unless a specific behavioral risk needs a test.
8. Act on authorized routine engineering decisions without repeated permission requests. If credentials, signing identity, external accounts or an actual person are required, finish the concrete preparatory work, record the exact blocker and continue unrelated tasks. Never manufacture approvals or observations.
9. Do not silently restore older release gates removed by the owner. Keep product correctness, evidence for the new ease-of-use claim, and App Store/legal/business decisions separately recorded.
10. Never replace an unmet requirement with a lower threshold after seeing the results. Document an explicit scope change if one becomes necessary.

Maintain one machine-readable completion matrix and generate its human-readable view. Suggested fields:

`id, requirement, specification_refs, status, owner, dependencies, implementation_paths, commit_sha, migration, automated_evidence, ui_evidence, candidate_build, performance_evidence, benefit_evidence, remaining_limit, blocker, next_action`

Allowed status values: `NOT_STARTED`, `IN_PROGRESS`, `IMPLEMENTED`, `AUTOMATED_VERIFIED`, `UI_VERIFIED`, `BLOCKED`, `DONE`. Record measured-benefit state separately. Use `NOT_APPLICABLE` only for a genuinely conditional subrequirement with a written rationale; it cannot retire a core goal. Check a box only when the item's observable acceptance and applicable cross-cutting checks are satisfied.

For meaningful data or behavior changes, applicable completion includes: canonical persistence and migrations; source/revision integrity; scope and permissions; failure/retry behavior; erasure/hold/backup treatment; relevant tests; observed UI when exposed; and updated user help. Reuse one end-to-end run across several requirements when it actually demonstrates them.

## C. Baseline to extend

At the inspected baseline, the app already has CaseMapProjection/Service/Repository, layout and saved views, a source inspector, scoped search, contradiction review, revision capture/checkpoints, financial services, case tasks, audit chains, checked exports and contextual help. The latest recorded map walkthrough is partial Debug evidence. Earlier CI success does not establish completion of this expanded scope.

The major expansion areas are general recursive frames and report points, broader canonical-record coverage, typed times and participant identities, transitive dependency impact, unified financial/historical branches, authenticated contribution/collaboration and durable case/action orchestration. Extend existing orientation/help/history features rather than treating them all as absent.

## D. Delivery sequence and dependencies

| Milestone | Required tracks | Demonstration before proceeding |
|---|---|---|
| M0 — baseline and contracts | BASE, ARCH, DATA; begin ACCESS, SEC and QA | Compatible data model, real inventory, authorization/storage decisions and seeded fixtures. |
| M1 — first complete recursive case | IN, SRC, GRAPH, MAP, BRIEF, SEARCH, REPORT; initial ACTION | Report → source-linked point → question → examination → result → deeper point, with exact return navigation and AI off. |
| M2 — investigative depth | REASON, TIME, CHANGE, PEOPLE, MONEY, HISTORY | Conflicting accounts, money, source amendment, investigator history and prior-case reference work in the same map. |
| M3 — work and contributions | ACTION, AUTO, ACCESS, TEAM; extend SEC | One investigator and then distinct participants contribute, receive assignments and return reviewed results safely. |
| M4 — optional intelligence | AI, backed by the completed scope/proposal/action boundaries | Manual, suggestions and configured execution modes; failure and hostile input cannot bypass controls. |
| M5 — complete usable lifecycle | OUTPUT, RECOVERY, HELP, ADAPT; finish MAP/BRIEF | Start, investigate, hand over, close, export, restore and reopen without reconstructing the map. |
| M6 — prove the capability | QA, PERF, BENEFIT across the frozen candidate | Relevant automated, actual UI, signed-build and measured-benefit records; defects resolved. |
| M7 — distribute honestly | SHIP and all advertised core tracks | Distribution artifact, operations, support, disclosures and claims match the demonstrated candidate. |

These are dependencies, not permission to defer security, accessibility, recovery or measurement design until the end. Design ACCESS with ARCH; build SEC/DATA guarantees into every mutation; run HELP/QA/PERF work continuously. Optional specialist connectors are delivered only when explicitly advertised, while generic attachment and inspection remain core.

## 01. BASE — reconcile the actual product and freeze the scope

**Specification:** R00, R12. **Depends on:** none. **Exit:** one trustworthy baseline and backlog.

- [ ] **BASE-01 — Record the actual candidate.** Capture branch, full SHA, local changes, PR head, app/schema version, supported platforms and current build instructions. **Accept:** another engineer can identify and reproduce the same source state.
- [ ] **BASE-02 — Reconcile status documents.** Update the execution matrix, readiness record and PR summary from actual evidence; preserve earlier runs as history. **Accept:** stale NOT RUN or green claims do not contradict later evidence without explanation.
- [ ] **BASE-03 — Record the expanded owner scope.** Incorporate solo/team operation, recursive frames, mother-case/child-actions and SM-01–SM-10 into the source's scope decisions. **Accept:** single-user-only v1 is clearly an intermediate historical scope.
- [ ] **BASE-04 — Inventory canonical data.** List every case table/service, attachment, index, cache, action type and job output with its owner, source references, revisions, permissions and map adapter. **Accept:** omitted record classes are explicit and assigned work.
- [ ] **BASE-05 — Reconcile advertised jobs/personas.** Check the actual inventory, including the previously advertised 168 jobs; map every retained job to its real output and required map representation. **Accept:** registration alone never counts as a completed work product.
- [ ] **BASE-06 — Establish baseline journeys.** Preserve working import, search, source inspection, contradictions, tasks, export, restore and purchase behavior. **Accept:** later improvements can be checked for regressions against named builds and fixtures.
- [ ] **BASE-07 — Create the completion matrix.** Use the stable IDs in this checklist and attach evidence as implementation proceeds. **Accept:** the matrix can report blocked, implemented, observed and measured states without an invented overall percentage.
- [ ] **BASE-08 — Prepare the first vertical fixture.** Seed the supplier investigation with source originals, expected assertions, payment identities, contradiction, amendment and expected action outcomes. **Accept:** its expected results exist before implementation tuning.
- [ ] **BASE-09 — Freeze exclusions and integration boundaries.** Identify paid feeds, acquisition tools and enterprise administration outside core; preserve attach/import paths for their results. **Accept:** no implicit promise to duplicate every proprietary capability of five vendors.

## 02. ARCH — one canonical model and coherent services

**Specification:** R01, R05, R11, R13. **Depends on:** BASE. **Exit:** explicit contracts reused across the map and every operation.

- [ ] **ARCH-01 — Preserve canonical identities.** Extend current CaseMapNodeID references for new kinds without deriving identity from titles, coordinates or display order. **Accept:** renaming/rearrangement does not break links, history or external references.
- [ ] **ARCH-02 — Separate data from appearances.** Model canonical objects, relationship assertions, frame membership and view-specific layout independently. **Accept:** one object appears in several branches while edits remain consistent.
- [ ] **ARCH-03 — Define recursive frames.** Any supported object can anchor a frame containing evidence, questions, work, results and further frames. **Accept:** arbitrary meaningful depth is supported with cycle-safe traversal and explicit resource budgets.
- [ ] **ARCH-04 — Separate semantic states.** Give sources, assertions, extracted text, hypotheses, interpretations, reviews and findings distinct contracts. **Accept:** a source's presence or a completed action cannot silently mark an assertion true.
- [ ] **ARCH-05 — Define typed references.** Carry canonical object/version, locator, availability, authorized scope and provenance through every adapter and output. **Accept:** a missing original or inaccessible reference is represented explicitly.
- [ ] **ARCH-06 — Define actor and time contracts.** Distinguish case people, authenticated users, reported external performers and software actors; distinguish event, receipt, entry and review times. **Accept:** attribution and chronology survive all clients and exports.
- [ ] **ARCH-07 — Extend the one task engine.** Represent child actions through ProfessionalTask or its compatible extension, with dependencies, owner, result and review. **Accept:** existing CaseAction activity logs are not confused with executable actions.
- [ ] **ARCH-08 — Choose the actual team architecture.** Document client/server responsibilities, hosting, synchronization, offline behavior, encryption/key boundaries, provider sends and operating cost. **Accept:** a runnable design supports the required identities and contributions; it is not a shared-file mockup.
- [ ] **ARCH-09 — Define mutation and event boundaries.** Commit record changes, revisions and pending events atomically; recheck generation, authorization and source versions when applying work. **Accept:** async results cannot write into erased, closed or changed scope.
- [ ] **ARCH-10 — Keep domain services authoritative.** Reuse financial arithmetic, scope resolution, review and export checks; expose them through map commands. **Accept:** map, list, reports and AI tools return the same canonical results.

## 03. DATA — schema, migrations and persistence

**Specification:** R01, R04, R09. **Depends on:** ARCH; cross-cutting SEC/ACCESS. **Exit:** compatible, recoverable persistent records.

- [ ] **DATA-01 — Add versioned schema changes.** Migrate frames, memberships, report points, participants, temporal assertions, dependencies, contributions and automation metadata through the existing migration mechanism. **Accept:** no destructive reset of existing cases.
- [ ] **DATA-02 — Enforce ownership and references.** Add appropriate keys, constraints and transactional checks for case membership, endpoints, revisions and permitted cross-case references. **Accept:** invalid references fail without partial writes.
- [ ] **DATA-03 — Extend revision capture.** Record meaningful before/after changes and the responsible actor in the same transaction. **Accept:** every new review, assignment, relationship and summary has inspectable revision history.
- [ ] **DATA-04 — Index graph and work access.** Index case/object/frame adjacency, timestamps, dependencies, action states and scoped search fields. **Accept:** ordinary branch reads avoid repeatedly scanning the entire case.
- [ ] **DATA-05 — Migrate legacy attribution honestly.** Retain old actor strings and unknown historical values while introducing stable IDs. **Accept:** legacy names are not presented as retrospectively authenticated users.
- [ ] **DATA-06 — Preserve schema compatibility rules.** Refuse unsupported future ledgers/restores with a clear remedy; test upgrade and interrupted upgrade. **Accept:** an older app cannot silently modify newer data.
- [ ] **DATA-07 — Handle failures transactionally.** Cover full disk, interrupted writes, bad records, incompatible serialized values and failed key access. **Accept:** old data remains usable or recoverable, with precise failure information.
- [ ] **DATA-08 — Extend backup/erase inventories.** Register every new table, cache, queued job, attachment and shared-service copy. **Accept:** inventory checks detect a newly added store that lacks lifecycle handling.
- [ ] **DATA-09 — Verify identity round-trips.** Exercise restart, backup, restore, import/export where supported, and server/client synchronization. **Accept:** canonical IDs, memberships and reviewed references do not drift.
- [ ] **DATA-10 — Use typed values and explicit unknowns.** Preserve exact amounts, units, date precision, original text and missing values across serialization. **Accept:** missing is not zero, false, midnight or an invented default.

## 04. IN — complete and accountable contribution intake

**Specification:** R03, R10, R14. **Depends on:** DATA, initial ACCESS. **Exit:** every supplied item is accounted for and correctly scoped.

- [ ] **IN-01 — Unify intake channels.** Route file/folder imports, drag-and-drop, manual entry, supported messages and team submissions through the same inclusion/provenance contract. **Accept:** no convenient intake path bypasses case scope.
- [ ] **IN-02 — Preserve originals.** Store original bytes and hash/size/type metadata; derivatives never replace the original. **Accept:** scans, rendered pages, OCR and summaries can all open their source when retained and authorized.
- [ ] **IN-03 — Preserve document relationships.** Keep attachments, archive paths, messages, embedded items and source occurrences connected. **Accept:** the investigator can reconstruct where each extracted item came from.
- [ ] **IN-04 — Publish a truthful format matrix.** Separate native parsing, preview rendering, OCR, attachment-only preservation and unsupported processing. **Accept:** arbitrary attachments can be represented without falsely claiming universal interpretation.
- [ ] **IN-05 — Keep inclusion auditable.** Extend Review new documents to team/import channels and explicit trusted-source policies. **Accept:** exclusions persist; automatic inclusion names the authorizing policy and does not broaden scope silently.
- [ ] **IN-06 — Distinguish duplicates and versions.** Separate exact byte copies, content-equivalent sources, multiple occurrences and revised documents. **Accept:** deduplication preserves receipts and does not merge distinct transactions or events.
- [ ] **IN-07 — Track processing by item/stage.** Show received, pending review, included, parsing/OCR/indexing, available, partial, failed, excluded and unsupported states. **Accept:** a failed or unprocessed item remains visible with its remedy.
- [ ] **IN-08 — Support safe retries.** Reprocess failed reads and affected records after reader upgrades without losing manual work or creating copies. **Accept:** retries have one logical effect and terminate with a recorded state.
- [ ] **IN-09 — Handle protected/damaged inputs.** Identify password-needed, wrong-password, corrupt, locked and unsupported-encryption states; never log secrets. **Accept:** original preservation and user recovery choices remain available.
- [ ] **IN-10 — Bound dangerous processing.** Handle malicious filenames, archive traversal/bombs, malformed files and external embedded resources with bounded/sandboxed processing. **Accept:** ingestion cannot escape its storage boundary or silently fetch external content.
- [ ] **IN-11 — Preserve manual and external attribution.** Record who supplied, who entered, claimed author, capture time and actual receipt time separately. **Accept:** a typed witness account does not become a verified signed statement automatically.
- [ ] **IN-12 — Produce intake receipts.** Reconcile selected, received, included, duplicate, excluded, failed and pending items. **Accept:** map coverage can be traced back to the actual intake inventory rather than only successfully parsed records.

## 05. SRC — exact sources, extraction and representation

**Specification:** R01, R03, SM-04. **Depends on:** IN, DATA. **Exit:** map content can be checked against its original context.

- [ ] **SRC-01 — Implement typed locators.** Support the advertised passage/page, spreadsheet sheet/cell/row, message/attachment, image region and audio/video timestamp locators. **Accept:** each supported locator opens the intended source version and location.
- [ ] **SRC-02 — Preserve extraction provenance.** Record reader/OCR/model version, source version, coverage, language and extraction time. **Accept:** investigators can distinguish original wording from transformed or generated text.
- [ ] **SRC-03 — Retain qualifications and attribution.** Keep speaker, reported speech, negation, uncertainty, proposed events, dates and context with extracted assertions. **Accept:** truncating a sentence does not reverse its meaning.
- [ ] **SRC-04 — Keep source and interpretation separate.** Store exact quoted/extracted text independently from a user's or model's paraphrase. **Accept:** editing a summary cannot alter the source quotation.
- [ ] **SRC-05 — Make OCR limitations visible.** Link uncertain/unread pages and text-recognition failures to retry and original inspection. **Accept:** empty OCR is not presented as proof that the original contains no relevant material.
- [ ] **SRC-06 — Preserve non-text originals and derivatives.** Show images/previews, transcripts and descriptions with their derivation links. **Accept:** image conversion does not discard selectable text, metadata or the original file.
- [ ] **SRC-07 — Verify source-linked fields appropriately.** Apply field-specific checks for quotes, names, dates, amounts and summaries. **Accept:** citation existence alone does not validate an unrelated assertion.
- [ ] **SRC-08 — Handle unavailable references.** Distinguish access denied, erased, excluded, missing original, superseded and unsupported locator. **Accept:** no silent fallback to a different document or newer passage.
- [ ] **SRC-09 — Return reliably from source inspection.** Preserve frame, selection, filters, zoom, scroll and media position. **Accept:** checking a source does not force the investigator to rediscover the branch.
- [ ] **SRC-10 — Include all source occurrences.** Show repeated references and source dependence without counting them as independent corroboration. **Accept:** several copies of one report remain one underlying evidential origin unless otherwise established.

## 06. GRAPH — recursive frames and meaningful relationships

**Specification:** R01–R03, SM-02–SM-04. **Depends on:** DATA, SRC. **Exit:** the full case is reachable without duplicating its contents.

- [ ] **GRAPH-01 — Implement general object frames.** Let supported objects expose their source, points, questions, work, results, links and history. **Accept:** a report frame is more than a link to an isolated document screen.
- [ ] **GRAPH-02 — Implement nested membership.** Support deep containment with stable ordering and provenance. **Accept:** no arbitrary fixed product depth; a resource budget yields continuation rather than losing descendants.
- [ ] **GRAPH-03 — Support multiple appearances.** Keep one canonical object in several frames with view-specific geometry. **Accept:** editing it updates all contexts while preserving each view's navigation.
- [ ] **GRAPH-04 — Type relationships.** Define direction, temporal validity, provenance, author, review and uncertainty for evidence, identity, event, work and financial links. **Accept:** an unlabeled connection cannot imply support or causation.
- [ ] **GRAPH-05 — Enforce structural cycle rules.** Reject containment and scheduling deadlocks while permitting legitimate cyclic investigative relationships. **Accept:** traversal, export and dependency inspection terminate safely.
- [ ] **GRAPH-06 — Reconcile whole-case coverage.** Compare all relevant canonical records with projected, unloaded, filtered, folded, hidden and unavailable states. **Accept:** projected-record counts are not misrepresented as complete case coverage.
- [ ] **GRAPH-07 — Add omitted adapters lazily.** Include contacts, work log, credibility observations, governance records and other inventoried omissions under authorized branches. **Accept:** complete reachability does not require reading every table on each pan.
- [ ] **GRAPH-08 — Explain relationships on selection.** Expose both endpoints, relationship meaning, sources, times and decisions. **Accept:** investigators can inspect the basis and revise/withdraw a link with history.
- [ ] **GRAPH-09 — Make identity operations reversible.** Merge/split candidate entities through recorded decisions preserving references and sources. **Accept:** undoing an incorrect merge restores meaningful separate histories and relationships.
- [ ] **GRAPH-10 — Handle scope changes explicitly.** Preserve history but withdraw unavailable material from current authorized views and derived data. **Accept:** cached nodes or summaries cannot expose removed scope.
- [ ] **GRAPH-11 — Support shared work and references.** An action or report can answer several questions without being executed or counted repeatedly. **Accept:** one result updates every authorized dependency consistently.
- [ ] **GRAPH-12 — Validate deep and broad fixtures.** Exercise long branches, many memberships, cycles, disconnected material and missing endpoints. **Accept:** coverage, navigation and integrity remain correct with explicit limitations.

## 07. MAP — spatial navigation and stable interaction

**Specification:** R02, SM-02–SM-04, SM-08. **Depends on:** GRAPH; start HELP/PERF now. **Exit:** depth remains usable rather than becoming visual clutter.

- [ ] **MAP-01 — Extend the existing workspace.** Keep the map, branch navigation and source/detail inspector connected to one selected context. **Accept:** routine investigation does not require copying context between disconnected modules.
- [ ] **MAP-02 — Add meaningful zoom levels.** Reveal progressively richer content while retaining access to full detail. **Accept:** zoom changes presentation, not canonical records, conclusions or scope.
- [ ] **MAP-03 — Preserve spatial memory.** Keep existing/pinned appearances stable; place new items locally. **Accept:** normal refreshes and contributions do not rearrange the investigator's working map.
- [ ] **MAP-04 — Implement local fold/unfold.** Support nested folds, folded counts and new/blocked/review-required indicators. **Accept:** a fold cannot silently conceal important pending work from branch summaries.
- [ ] **MAP-05 — Persist navigation state.** Save breadcrumbs, selection, viewport, folds, filters, inspector and Back/Forward state per view. **Accept:** restart and source-return restore the meaningful working position.
- [ ] **MAP-06 — Extend the manual view strip.** Provide relevant Questions, People, Evidence, Money, Time, Work and Changes/History perspectives with saved/custom views. **Accept:** switching views preserves identity and does not auto-advance like a slideshow.
- [ ] **MAP-07 — Share selection across representations.** Synchronize selected records and subsets across map, outline, table, timeline and useful date/amount distributions over one authorized model. **Accept:** selecting a time range or amount bucket highlights the same records everywhere; filters, currencies, counts and source context remain explicit.
- [ ] **MAP-08 — Provide direct deep navigation.** Search hits, notifications, brief links and task references reveal their exact folded context. **Accept:** no manual expansion of every ancestor is required to reach a known result.
- [ ] **MAP-09 — Make arrangement explicit and undoable.** Support branch-scoped arrange, multi-selection, pin/unpin, reset and custom organization. **Accept:** a layout action does not modify evidence or surprise unrelated branches.
- [ ] **MAP-10 — Explain empty/partial states.** Distinguish no records, pending load, filters, failed processing, denied access and unavailable data. **Accept:** a blank canvas is never the only explanation.
- [ ] **MAP-11 — Use a consistent visual language.** Label link meaning/weight, review/work states and selected context; support non-color cues. **Accept:** line thickness and proximity cannot be mistaken for certainty or guilt.
- [ ] **MAP-12 — Verify real-window usability.** Exercise dense maps, small windows, multiple displays, scrolling, focus and long labels. **Accept:** controls remain reachable, text legible and interaction predictable on supported devices.

## 08. BRIEF — immediate understanding and orientation

**Specification:** SM-01, SM-06, SM-07, SM-10. **Depends on:** MAP, SRC/REPORT/CHANGE services as delivered. **Exit:** the case makes sense before every branch is opened.

- [ ] **BRIEF-01 — Add a case and branch brief.** Show purpose, scope, current recorded position, unresolved matters, material changes and next work. **Accept:** every factual entry links into its supporting map context.
- [ ] **BRIEF-02 — Provide manual and generated summaries.** AI-off users can maintain useful structured briefs; generated text is source/revision-bound and labelled. **Accept:** model unavailability does not remove orientation.
- [ ] **BRIEF-03 — Separate the important states.** Clearly distinguish reported, supported/challenged, unassessed, reviewed and concluded material from task status. **Accept:** progress bars do not claim the case is a percentage true or solved.
- [ ] **BRIEF-04 — Preserve alternative explanations.** Show material contrary evidence and unresolved alternatives alongside the current position. **Accept:** the brief does not become a one-sided narrative through relevance ranking.
- [ ] **BRIEF-05 — Show why information appears.** Explain relevance, source basis and changes for highlighted items. **Accept:** users can inspect and correct relevance without deleting the underlying evidence.
- [ ] **BRIEF-06 — Keep briefs current safely.** Flag stale inputs, incomplete coverage and pending review; preserve accepted text and its prior versions. **Accept:** new evidence cannot silently rewrite a finalized finding.
- [ ] **BRIEF-07 — Provide a personal return view.** Resume the last context and offer what changed, work due and blocked items within permissions. **Accept:** personal unseen activity is distinct from substantive case review.
- [ ] **BRIEF-08 — Build a navigable handover path.** Let investigators curate live briefings with embedded canonical records, sources, branch views and unresolved work, or freeze a revision-bound briefing. **Accept:** live references reveal changes while frozen briefings retain their recorded state; both open into the full graph.

## 09. SEARCH — precise retrieval through the whole case

**Specification:** R01, R02, SM-02, SM-04, SM-07. **Depends on:** IN, SRC, GRAPH, ACCESS boundaries. **Exit:** users can find and verify supplied material without guessing what was searched.

- [ ] **SEARCH-01 — Extend the existing scoped search.** Index new object kinds, report points, notes, work/results, metadata and supported attachment text. **Accept:** case search covers the inventoried record classes and names unindexed categories.
- [ ] **SEARCH-02 — Deliver an explicit query builder.** Support declared exact phrases, Boolean grouping, exclusions, fields, dates, types, people and amount/currency filters, plus typed multi-step relationship patterns without coding. **Accept:** invalid expressions fail clearly; visible conditions and scoped query receipts match the actual deterministic execution.
- [ ] **SEARCH-03 — Separate exact and semantic matching.** Label extracted-field, literal-text and AI/embedding similarity results and their reasons. **Accept:** similarity is never presented as an exact occurrence or verified identity.
- [ ] **SEARCH-04 — Show active scope and filters.** Display the mother case, permitted historical selection, date meaning and all active constraints. **Accept:** widening beyond the case is explicit and cannot leak unauthorized metadata.
- [ ] **SEARCH-05 — Highlight why each result matched.** Show the matching passage/field and open its exact locator, including attachment context. **Accept:** users can reproduce the stated match against the searched representation.
- [ ] **SEARCH-06 — Publish coverage and receipts.** Report searched, pending, excluded, failed and unsupported material with relevant versions and query. **Accept:** “no matches” does not imply that unread or unsearched originals contain nothing relevant.
- [ ] **SEARCH-07 — Use honest counts and pagination.** Distinguish occurrences, unique documents, canonical entities and repeated source copies. **Accept:** result limits/continuations are visible and no default chunk cap silently truncates completeness claims.
- [ ] **SEARCH-08 — Search through folds.** Find records regardless of current visual collapse and navigate into the correct branch. **Accept:** canvas visibility does not limit the authorized search corpus.
- [ ] **SEARCH-09 — Search relationships carefully.** Support typed paths with direction, property conditions, time order and declared interval/length/compute bounds; explain each returned edge. **Accept:** result coverage states the explored scope and limits; no-path within bounds does not assert no connection anywhere, and a path does not prove causation or funds identity.
- [ ] **SEARCH-10 — Support saved searches and revision-bound results.** Version reusable relationship patterns and saved queries, distinguishing live results from frozen sets; permit policy-authorized reruns on material updates. **Accept:** new matches have provenance, duplicate alerts/actions are suppressed, and later changes cannot alter frozen receipts.
- [ ] **SEARCH-11 — Cancel and resume large work safely.** Bound regex/pattern queries if offered, expose progress and handle index rebuild/failure. **Accept:** incomplete work is never displayed as a completed exhaustive search.
- [ ] **SEARCH-12 — Verify retrieval with independent fixtures.** Test normalization, multilingual source text, dates, punctuation, attachment nesting, malformed queries and permission changes. **Accept:** literal search correctness is measured separately from source/OCR correctness and semantic recall.

## 10. REPORT — structured reports and deeper investigation

**Specification:** R03, SM-01–SM-05. **Depends on:** SRC, GRAPH, initial ACTION. **Exit:** every important report point can lead to traceable work and results.

- [ ] **REPORT-01 — Model report identity and versions.** Record producer, author, examined material, report dates, qualifications, methods and originals. **Accept:** amendment/supplement status is explicit rather than overwriting the first report.
- [ ] **REPORT-02 — Create addressable sections and points.** Support source-highlighting and assisted extraction into stable point/assertion IDs, creating the exact citation and links to the relevant question, person and time in one workflow. **Accept:** each point can be investigated independently without retyping or treating the source assertion as established truth.
- [ ] **REPORT-03 — Preserve qualifications and limitations.** Attach relevant uncertainty, exclusions and conditions to extracted key points and summaries. **Accept:** a conditional result cannot become an unconditional finding through summary extraction.
- [ ] **REPORT-04 — Open work from a point.** Create questions, examinations, requests, comparisons and child actions in that point's frame. **Accept:** the new work retains its originating source, purpose and expected deliverable.
- [ ] **REPORT-05 — Return a result as structured material.** Accept a result report with its own points, sources and deeper work. **Accept:** repeated report→point→work→report recursion remains navigable and source-linked.
- [ ] **REPORT-06 — Protect manual/reviewed edits.** Re-extraction creates proposals or new revisions rather than replacing accepted points. **Accept:** generated refreshes cannot erase annotations, decisions or source-bound citations.
- [ ] **REPORT-07 — Link findings across branches.** Reuse the same accepted point in questions, money, chronology and outputs. **Accept:** context-specific use preserves canonical identity and review/version references.
- [ ] **REPORT-08 — Compare report versions.** Highlight changed wording, added/removed qualifications and affected points. **Accept:** changed conclusions propagate review-needed state to dependent work without altering prior decisions.
- [ ] **REPORT-09 — Support supplied specialist results honestly.** Preserve forensic/accounting/media tables, figures and artifacts even when the app cannot independently reproduce the examination. **Accept:** attachment/interpretation is not advertised as performing the specialist acquisition or analysis itself.
- [ ] **REPORT-10 — Demonstrate the full vertical loop.** Run the seeded forensic report through at least six meaningful UI levels and deeper automated fixtures. **Accept:** the return path, sources, times, work owners and revisions remain intact with AI off.

## 11. REASON — evidence, contradictions and alternative explanations

**Specification:** R03, R08, SM-04, SM-05, SM-07. **Depends on:** SRC, REPORT, PEOPLE/TIME as available. **Exit:** the map exposes disagreement without deciding truth by appearance.

- [ ] **REASON-01 — Preserve assertion attribution.** Record who states what, whether it is firsthand/reported, when it applies and its exact source. **Accept:** nearby names do not become speakers without a defensible attribution.
- [ ] **REASON-02 — Type evidence relationships.** Distinguish supports, challenges, mentions, qualifies and unassessed relevance. **Accept:** merely linked documents do not count as support.
- [ ] **REASON-03 — Extend contradiction comparison.** Show both passages with surrounding context, identity/time/units and source versions. **Accept:** the investigator can examine and act without memorizing one passage while opening the other.
- [ ] **REASON-04 — Distinguish difference from contradiction.** Check entity, time, currency, negation, amendments, quoted speakers and differing definitions. **Accept:** a changed circumstance or same-name person is not silently labelled contradictory.
- [ ] **REASON-05 — Preserve source dependence.** Expose copied text, derivative reports and shared origins; leave independence unassessed unless reviewed. **Accept:** ten reports repeating one source do not imply ten independent confirmations.
- [ ] **REASON-06 — Retain uncertainty states.** Use proposed, unassessed, confirmed conflict, explained, dismissed and unresolved states with rationale/history. **Accept:** disappearance from a view does not silently resolve a conflict.
- [ ] **REASON-07 — Create specific follow-up work.** Generate or manually create contradiction child actions with the exact question and needed result. **Accept:** the action links both accounts and permits inconclusive outcomes.
- [ ] **REASON-08 — Extend hypothesis analysis correctly.** Preserve unassessed cells, diagnostic coverage, ties and contrary evidence. **Accept:** incomplete ratings cannot produce a false preferred explanation.
- [ ] **REASON-09 — Keep finding approval rules.** Apply the existing documentary/response requirements where relevant and retain explicit exceptions. **Accept:** an adverse interpretation cannot become approved merely because its child tasks were completed.
- [ ] **REASON-10 — Expose reasoning dependencies.** Link a finding to the precise inputs, alternative explanations considered and reviewer rationale. **Accept:** another investigator can reconstruct why the decision was made at that revision.
- [ ] **REASON-11 — Test false and missed conflicts.** Include equivalent amounts, two true payments, date ambiguity, duplicated reports, denials and source amendments. **Accept:** scored detection and human disposition are reported separately.
- [ ] **REASON-12 — Prevent repetitive proposals.** Persist rejection/defer reasons and suppress unchanged repeats; reconsider only on a material change with explanation. **Accept:** review does not become endless dismissal of the same AI suggestion.

## 12. TIME — event chronology, work history and audit

**Specification:** R04, R05, SM-06, SM-10. **Depends on:** DATA, actor contracts. **Exit:** users can distinguish what happened from when the app learned about it.

- [ ] **TIME-01 — Add typed temporal assertions.** Support occurrence, creation, signing, collection, receipt, import, assignment, performance, submission and review times. **Accept:** these meanings are not collapsed into one generic timestamp.
- [ ] **TIME-02 — Preserve precision and original wording.** Store date-only, intervals, approximate/relative dates, timezone/offset and unknowns. **Accept:** date-only input does not become an apparently exact midnight event.
- [ ] **TIME-03 — Preserve competing times.** Keep source assertions separate from a normalized investigator interpretation. **Accept:** choosing one interpretation records a decision without destroying the alternatives.
- [ ] **TIME-04 — Build per-object timelines.** Show relevant events and work/revision history inside every supported frame. **Accept:** case-wide timelines are aggregations of the same canonical records.
- [ ] **TIME-05 — Handle chronology uncertainty.** Show overlapping/undetermined ordering and timezone assumptions. **Accept:** sorting convenience is not presented as evidence of an exact sequence.
- [ ] **TIME-06 — Attribute every meaningful action.** Record authenticated user, reported performer, software actor and triggering context separately. **Accept:** renaming a profile does not rewrite historical attribution.
- [ ] **TIME-07 — Extend tamper-evident audit coverage.** Include new reviews, assignments, policies, relationships, exports and role changes in the existing audit design. **Accept:** integrity verification names its key/trust limitations without claiming tamper-proof truth.
- [ ] **TIME-08 — Define concurrent audit ordering.** Preserve device/server sequence, causation, receipt time and clock uncertainty. **Accept:** clock skew or offline uploads cannot silently fabricate a trusted order of actions.
- [ ] **TIME-09 — Preserve honest history baselines.** Distinguish captured revisions/checkpoints from unavailable earlier history. **Accept:** arbitrary historical reconstruction is not claimed where replay coverage does not exist.
- [ ] **TIME-10 — Verify historical inspection permissions.** Apply current access restrictions and erasure/hold rules to older snapshots and audit detail. **Accept:** history is not a back door into content no longer available to the viewer.

## 13. CHANGE — meaningful updates and transitive impact

**Specification:** R04, R08, SM-06. **Depends on:** DATA, GRAPH, TIME. **Exit:** relevant changes become visible without rewriting settled work.

- [ ] **CHANGE-01 — Emit typed change events.** Cover new material, amendment, scope, identity, relationship, assignment, review and access changes. **Accept:** semantic events are distinguishable from cosmetic layout changes.
- [ ] **CHANGE-02 — Store derivation dependencies.** Bind summaries, comparisons, findings and outputs to their actual input revisions. **Accept:** dependency inspection explains why an item became stale.
- [ ] **CHANGE-03 — Traverse effects to relevant depth.** Use cycle-safe, cancellable, typed dependency traversal instead of only direct/second neighbors. **Accept:** a deep source change marks all affected derived records and excludes unrelated social adjacency.
- [ ] **CHANGE-04 — Separate refresh from approval.** Regenerate eligible drafts as proposals; keep reviewed/final text with visible stale status. **Accept:** an automated update cannot silently amend an investigator's recorded conclusion.
- [ ] **CHANGE-05 — Build a personal change review.** Track last-seen activity separately from review-required obligations and substantive acknowledgements. **Accept:** scrolling through a feed does not approve changed evidence.
- [ ] **CHANGE-06 — Aggregate without concealing.** Group related changes into readable summaries with complete drill-down. **Accept:** folded/aggregated updates retain count, impact and unresolved state.
- [ ] **CHANGE-07 — Handle closed cases.** Queue new material and reopening decisions under an explicit workflow. **Accept:** background work cannot silently modify a closed case or discard a late contribution.
- [ ] **CHANGE-08 — Invalidate asynchronous work.** Recheck revision/generation/policy at application time and cancel stale jobs where possible. **Accept:** a late model result cannot overwrite newer human edits.
- [ ] **CHANGE-09 — Reconcile outages and missed events.** Support durable event checkpoints and reconciliation from canonical state. **Accept:** crash/reconnect does not lose impact notifications or duplicate their effects.
- [ ] **CHANGE-10 — Verify stable presentation.** Compare before/after branch state, positions and labels. **Accept:** relevant warnings appear while unaffected layout and completed work remain stable.

## 14. PEOPLE — witnesses, investigators and entity identity

**Specification:** R05, R07, R11. **Depends on:** DATA, GRAPH, TIME, ACCESS. **Exit:** people and their involvement can be understood without conflating identities or roles.

- [ ] **PEOPLE-01 — Model identity separately from role.** A person may be witness, source, account holder or investigator in different contexts. **Accept:** case roles do not duplicate the same canonical person or imply wrongdoing.
- [ ] **PEOPLE-02 — Build sourced profiles.** Link names/aliases, organizations, contacts, relevant supplied background and case relationships to origins and time periods. **Accept:** an unsourced note remains identifiable as such.
- [ ] **PEOPLE-03 — Represent whereabouts carefully.** Store supplied/authorized location observations with time, precision, source and uncertainty. **Accept:** a past observation is not shown as a person's live location.
- [ ] **PEOPLE-04 — Preserve interview/statement detail.** Link questions, responses, recordings, transcripts, attestations and amendments. **Accept:** changing a confirmed statement requires a recorded correction rather than silent replacement.
- [ ] **PEOPLE-05 — Add stable participant identities.** Bind authenticated accounts to case roles without converting every case person into an account. **Accept:** external reported performers and actual recording users remain distinguishable.
- [ ] **PEOPLE-06 — Expose investigator work histories.** Show assignments, performed work, submitted results, reviews, reassignment and involvement periods. **Accept:** each entry opens its evidence/work context in the case map.
- [ ] **PEOPLE-07 — Handle same-person candidates.** Use versioned exact/approximate matching rules and relevant identifier/attribute evidence, with reviewed merge/split decisions and original records retained. **Accept:** users can inspect why records matched or stayed separate; identical names or AI similarity cannot automatically merge unrelated people.
- [ ] **PEOPLE-08 — Track capability and conflicts.** Record declared specialist capabilities, availability and case-specific conflict restrictions for routing. **Accept:** assignment does not invent expertise or use opaque personal-risk scores.
- [ ] **PEOPLE-09 — Preserve role changes and departures.** End memberships, transfer pending work and retain historical attribution. **Accept:** old users cannot continue acting through cached authorization or queued jobs.
- [ ] **PEOPLE-10 — Respect profile access and erasure.** Apply restrictions to search, graph links, summaries, history and exports. **Accept:** indirect references cannot disclose protected profile content after access changes.

## 15. MONEY — financial investigation inside the same map

**Specification:** R06, SM-03–SM-07. **Depends on:** DATA, SRC, GRAPH, PEOPLE, TIME. **Exit:** investigators can follow and verify money without duplicate calculations.

- [ ] **MONEY-01 — Add canonical financial objects.** Represent accounts, transactions, invoices/claims, assets, ownership/control and source statement rows. **Accept:** the same objects appear in money, people, time and question views.
- [ ] **MONEY-02 — Reuse exact arithmetic.** Extend FAMoney/ForensicEngagement with explicit currency, precision and units; preserve raw values. **Accept:** formatting never changes stored amounts or assumes every currency has two decimal places.
- [ ] **MONEY-03 — Classify money mentions.** Separate actual movements from balances, invoices, allegations, reserves, estimates and quoted amounts. **Accept:** a mentioned amount is not automatically added to paid or lost totals.
- [ ] **MONEY-04 — Establish transaction identity.** Use supported identifiers and reviewed matching with all source occurrences retained. **Accept:** two equal real payments remain distinct and repeated documents do not multiply one transaction.
- [ ] **MONEY-05 — Separate financial outcomes.** Show gross paid/received, returns/reversals, fees, outstanding and disputed amounts with contributing records. **Accept:** net outflow is not automatically labelled proven loss.
- [ ] **MONEY-06 — Prevent path double counting.** Treat internal transfers and multi-hop tracing according to explicit calculation rules. **Accept:** following funds through several accounts does not inflate aggregate amounts.
- [ ] **MONEY-07 — Reconcile statements.** Calculate by account, period and currency; expose missing periods, unmatched records and differences. **Accept:** partial records never appear fully reconciled.
- [ ] **MONEY-08 — Handle exchange rates explicitly.** Keep original currencies; any converted total records rate source, date and method. **Accept:** incompatible currencies are not silently summed or presented as directly comparable.
- [ ] **MONEY-09 — Model ownership over time.** Link direct/indirect control and beneficial-owner assertions to sources and periods. **Accept:** relationship existence does not imply transaction authorization or liability.
- [ ] **MONEY-10 — Explain flow visuals.** State whether width means amount, count or another measure, and disclose tracing/allocation assumptions. **Accept:** every displayed figure drills down to its contributing sources.
- [ ] **MONEY-11 — Generate actionable gaps.** Create proposed reconciliation/missing-record actions with specific accounts, periods and expected deliverables. **Accept:** no duplicate action storm for each repeated statement occurrence.
- [ ] **MONEY-12 — Verify representative cases.** Exercise equal payments, duplicates, refunds, transfers, fees, mixed currencies, Indian grouping and amendments. **Accept:** calculations agree across map, table, report and exported package.

## 16. HISTORY — prior cases and investigating an investigation

**Specification:** R07, SM-04, SM-10. **Depends on:** GRAPH, TIME, ACCESS. **Exit:** relevant history is inspectable within authorized boundaries.

- [ ] **HISTORY-01 — Extend existing overlap detection.** Reuse CaseDeconfliction and add chosen exact identifiers/patterns with an explicit matching basis. **Accept:** same-name and approximate matches remain candidates.
- [ ] **HISTORY-02 — Separate historical selection from global search.** Let users choose authorized cases, imported collections or configured external sources. **Accept:** AI memory is not treated as a documentary source.
- [ ] **HISTORY-03 — Add explicit cross-case references.** Pin origin case, object/version, permitted scope and snapshot/live-link behavior. **Accept:** existing same-case write checks remain intact rather than being weakened globally.
- [ ] **HISTORY-04 — Compare similarities and differences.** Show relevant times, identifiers, circumstances and source limitations. **Accept:** similarity does not become an asserted common cause or same-person decision.
- [ ] **HISTORY-05 — Implement a review case.** A separate mother case can examine selected records, actions and decisions from another investigation. **Accept:** review findings cannot silently alter the original case.
- [ ] **HISTORY-06 — Preserve available-at-the-time context.** Reference the actual recorded checkpoint/revisions and disclose absent history. **Accept:** later evidence is not presented as something an earlier investigator already knew.
- [ ] **HISTORY-07 — Handle later restrictions.** Recheck access, privilege, erasure and availability in reads, summaries and exports. **Accept:** historical metadata, cached passages and hidden counts do not leak restricted material.
- [ ] **HISTORY-08 — Verify independent review and return paths.** Trace a review finding to its original decision, source and work record and back. **Accept:** the review's own chronology, authorship and conclusions remain separate and exportable.

## 17. ACTION — mother case, child actions and results

**Specification:** R03, R05, R13, SM-07. **Depends on:** ARCH, DATA, GRAPH, PEOPLE; ACCESS for real teams. **Exit:** unresolved matters become accountable work with useful outcomes.

- [ ] **ACTION-01 — Complete the action contract.** Include mother case, primary parent, linked questions/objects, trigger revisions, purpose, expected deliverable, owner/helpers/reviewer, dependencies and history. **Accept:** no action is an untraceable generic task row.
- [ ] **ACTION-02 — Provide editable action templates.** Include contradiction checks, missing evidence, interviews, identity checks, forensic examinations, reconciliation, changed-evidence review and output preparation. **Accept:** templates produce concrete editable work without imposing a fixed investigative method.
- [ ] **ACTION-03 — Separate lifecycle and outcome.** Support proposed, assigned, running, waiting, blocked, submitted, returned, accepted/completed, cancelled and superseded transitions as applicable. **Accept:** completed work can leave the originating question unresolved.
- [ ] **ACTION-04 — Support recursive and shared work.** Create children at any meaningful depth and link one action to several questions. **Accept:** ownership/dependency cycles are rejected and multiple appearances do not duplicate execution.
- [ ] **ACTION-05 — Add eligible assignment.** Resolve designated owner or authorized role/capability/availability/workload/conflict rules. **Accept:** the chosen owner and reason are visible; no eligible person produces an explicit unassigned queue.
- [ ] **ACTION-06 — Make manual control complete.** Investigators can create, edit, delegate, reassign, defer and cancel, including authorized bulk changes with per-item results. **Accept:** automatic routing respects deliberate overrides until the user changes them or a stated invalidation occurs.
- [ ] **ACTION-07 — Handle deadlines accurately.** Distinguish investigator targets, confirmed external deadlines and reminders with timezone/basis. **Accept:** an AI suggestion or template does not invent a legal deadline.
- [ ] **ACTION-08 — Implement result submission.** Attach reports, records, observations and explicit unsuccessful/inconclusive outcomes. **Accept:** results reference the examined inputs and return to all affected case branches.
- [ ] **ACTION-09 — Implement review and revision requests.** Record acceptance/return, reviewer, rationale and the exact result revision. **Accept:** editing an accepted result creates a new revision and exposes re-review needs.
- [ ] **ACTION-10 — Roll up useful parent status.** Show blocked/unassigned/unresolved/review-needed counts and outcomes without averaging truth or treating every child as mandatory. **Accept:** parent closure follows explicit criteria and recorded exceptions.
- [ ] **ACTION-11 — Support solo and role-based operation.** Bind applicable roles to one person in solo mode and preserve self-review attribution. **Accept:** routine use requires no fictional team accounts or independent approvals.
- [ ] **ACTION-12 — Reopen and supersede deliberately.** Link new evidence to prior completed work and create or reopen the appropriate action with explanation. **Accept:** the same unchanged issue does not generate endless repeated assignments.

## 18. AUTO — durable, bounded case-work orchestration

**Specification:** R13, R08, SM-06–SM-08. **Depends on:** ACTION, CHANGE, ACCESS/SEC boundaries. **Exit:** authorized automation advances work safely after real changes.

- [ ] **AUTO-01 — Version case automation policies.** Define allowed triggers, action types, routing, review requirements and budgets, and reusable investigation recipes with typed inputs/outputs, sequential or parallel steps and review checkpoints. **Accept:** every run records its recipe/policy versions, source dependencies and authorized effects.
- [ ] **AUTO-02 — Implement manual/suggest/execute modes.** Keep workflow automation distinct from permission to send data to AI. **Accept:** changing one setting cannot silently enable the other.
- [ ] **AUTO-03 — Use a durable transactional outbox.** Commit state changes and pending events together; expose queued, running, retrying, failed and cancelled work. **Accept:** a process crash does not lose a required action or create a partial mutation.
- [ ] **AUTO-04 — Make retries idempotent.** Use stable event/operation identities and deduplicate logical actions by purpose/context. **Accept:** repeated delivery, a reconnect or policy reevaluation does not recreate the same unchanged work.
- [ ] **AUTO-05 — Prevent recursive task storms.** Track causation and stop equivalent child generation; require a material new condition for renewed work. **Accept:** summary→action→summary feedback cannot generate an unbounded queue.
- [ ] **AUTO-06 — Apply visible resource budgets.** Bound generated work, provider spending, compute and external requests per policy/run. **Accept:** a budget stop leaves a resumable queue with reason, without imposing a semantic depth cap on manual investigation.
- [ ] **AUTO-07 — Debounce and scope analysis.** Coalesce related updates and process affected branches instead of every pan, keystroke or whole-case rescan. **Accept:** cosmetic edits cannot trigger unnecessary investigation tasks or AI sends.
- [ ] **AUTO-08 — Recheck authority at execution.** Verify case state, current access, source revisions, consent, legal hold/erasure generation and policy before effects. **Accept:** revoked or stale queued work cannot apply changes or send content.
- [ ] **AUTO-09 — Expose failure and recovery.** Provide retries, cancellation and actionable errors; distinguish transient failure from an impossible prerequisite. **Accept:** failed automation does not masquerade as completed work or silently disappear.
- [ ] **AUTO-10 — Control external effects separately.** Require configured recipients/content authority for messages or disclosures; use provider idempotency where available. **Accept:** uncertain send outcomes are reconciled instead of blindly resent, and internal assignment does not implicitly contact a witness.
- [ ] **AUTO-11 — Support compensation and history.** Undo eligible organizational effects through recorded changes; preserve already performed work and review history. **Accept:** “undo” does not pretend an external communication or human action never occurred.
- [ ] **AUTO-12 — Prove restart and replay behavior.** Test crash points, double delivery, paused queues, restoration, policy changes and late replies. **Accept:** recovery produces the intended logical state without resending historical external actions.

## 19. ACCESS — identities, roles and scoped authorization

**Specification:** R11, R14. **Depends on:** ARCH/DATA; begin before team implementation. **Exit:** real people can contribute without unauthorized access or impersonation.

- [ ] **ACCESS-01 — Establish authenticated identities.** Implement actual accounts/sessions for collaboration, strong multi-factor/passkey options and tested recovery; require the chosen strong-authentication policy for privileged remote roles. **Accept:** display names/email fields are not identity proof, and account recovery cannot bypass role protections.
- [ ] **ACCESS-02 — Bind roles per case.** Provide editable lead, investigator, specialist, evidence coordinator, reviewer and external contributor responsibilities. **Accept:** multiple roles can belong to one person and roles do not imply global access.
- [ ] **ACCESS-03 — Enforce authorization in services.** Cover case, record, field/compartment where needed, source, action and output operations. **Accept:** hiding a UI control is not the only enforcement layer.
- [ ] **ACCESS-04 — Separate participation from case subjects.** Bind users to participant records while witnesses/subjects may have no account. **Accept:** assigning a case role does not rewrite someone's evidential role or identity.
- [ ] **ACCESS-05 — Scope contributor access narrowly.** Limit external users to their request and explicitly shared material. **Accept:** they cannot browse unrelated cases, attachments, tasks, profile data or search results.
- [ ] **ACCESS-06 — Protect metadata and derived views.** Authorize counts, titles, graph endpoints, thumbnails, summaries, notifications, history and caches. **Accept:** hidden nodes or aggregation do not reveal restricted content indirectly.
- [ ] **ACCESS-07 — Implement invitation and revocation.** Make links scoped, expiring/revocable and resistant to reuse/guessing; verify intended identity where required. **Accept:** an expired or revoked invitation cannot grant a fresh session.
- [ ] **ACCESS-08 — Define offline authorization.** Specify cache access and permitted offline mutations, revalidation and revocation limits. **Accept:** queued edits are checked on reconnection and the product does not promise recall of material already legitimately exported.
- [ ] **ACCESS-09 — Enforce assignment/review authority.** Check who may delegate, approve, waive requirements, change policy or close a case. **Accept:** an action owner cannot elevate permissions by editing their own task.
- [ ] **ACCESS-10 — Preserve separation where configured.** Support case policies requiring a distinct reviewer and disclose self-review in solo mode. **Accept:** lack of an eligible reviewer produces a specific unmet state rather than fabricated approval.
- [ ] **ACCESS-11 — Audit access administration.** Record role, policy, sharing and ownership changes with authenticated actor and affected scope. **Accept:** investigators can review who authorized access and when it changed.
- [ ] **ACCESS-12 — Test hostile and stale clients.** Exercise object-ID substitution, cross-case access, revoked tokens, forged actors, cached privileges and protected aggregates. **Accept:** backend/service boundaries deny unauthorized operations consistently.

## 20. TEAM — contributions, synchronization and real collaboration

**Specification:** R11, R14, SM-08. **Depends on:** ACCESS, ACTION, AUTO, IN. **Exit:** multiple actual identities can advance the same case without losing context or work.

- [ ] **TEAM-01 — Deliver the real shared service.** Implement the selected receiving/synchronization infrastructure and supported clients. **Accept:** two distinct users/devices exchange real case updates through production-equivalent paths.
- [ ] **TEAM-02 — Implement scoped contribution requests.** Define requested deliverable, shared inputs, recipient, due target and submission channel. **Accept:** the map shows the request, response state and responsible person.
- [ ] **TEAM-03 — Make external submission practical.** Provide the chosen limited contributor experience without requiring full case navigation. **Accept:** a permitted contributor can submit the requested item and receive a receipt without receiving general case access.
- [ ] **TEAM-04 — Reuse canonical intake.** Route returned files/statements through IN states, source preservation and auditable inclusion. **Accept:** team submissions do not create a second evidence store or bypass review.
- [ ] **TEAM-05 — Synchronize graph and work state.** Carry canonical records, revisions, memberships, actions and review states with clear pending/confirmed/error indicators. **Accept:** a local unsynced result is not represented as visible to the whole team.
- [ ] **TEAM-06 — Resolve concurrent edits explicitly.** Use record-specific version checks/merges; preserve conflicting substantive edits for resolution. **Accept:** decisions, sources, assignments and reviews are not silently overwritten by last-write-wins.
- [ ] **TEAM-07 — Handle offline and interrupted transfers.** Resume uploads, deduplicate repeated submissions and reconcile queued mutations. **Accept:** users can see what has reached the case and what still needs attention.
- [ ] **TEAM-08 — Notify without leaking.** Provide configured in-app/email/push channels with permission-aware content and notification preferences. **Accept:** locked-screen previews and external messages do not expose unapproved case details.
- [ ] **TEAM-09 — Manage reassignment and departures.** Transfer unfinished work, revoke access and preserve original authorship. **Accept:** a departing investigator cannot leave silent orphaned obligations or keep processing unauthorized queued work.
- [ ] **TEAM-10 — Reconcile case closure and late replies.** Receive late submissions into the explicit pending/reopen workflow. **Accept:** the team cannot accidentally modify a closed or erased case via an old request.
- [ ] **TEAM-11 — Verify team history and briefing.** Show who added, performed, reviewed and changed each relevant item. **Accept:** another investigator can take over directly from the map and find outstanding work.
- [ ] **TEAM-12 — Prove both operating modes.** Run the same case with one person and with lead, examiner and limited contributor identities. **Accept:** solo use remains simple while team behavior uses genuine authentication and conflict handling.

## 21. AI — grounded assistance and configured execution

**Specification:** R08, R13, SM-01, SM-05–SM-08. **Depends on:** SRC, SEARCH, REASON, ACTION, AUTO, ACCESS. **Exit:** optional AI improves the same workflow without becoming a separate truth store.

- [ ] **AI-01 — Keep the entire core usable without AI.** Support manual extraction, links, summaries, comparison and action creation through the same records. **Accept:** disabling AI or losing a provider does not disable investigation.
- [ ] **AI-02 — Reuse current provider eligibility rules.** Apply the actual approved provider/account/data policy to every route, including general Ask and background actions. **Accept:** no fallback silently sends documents to a disallowed provider.
- [ ] **AI-03 — Preview and authorize actual sends.** Show relevant provider, scope and included/excluded material; apply current consent requirements. **Accept:** changed mode, key, provider, scope or privilege invalidates stale pending consent.
- [ ] **AI-04 — Minimize and scope retrieval.** Use authorized relevant records with declared limits and coverage; mask/filter protected material as required. **Accept:** model context cannot contain inaccessible branches or silently imply exhaustive coverage.
- [ ] **AI-05 — Expose constrained tools.** Provide typed search, inspect, compare, propose/apply organization and action operations; compile AI-proposed searches into the same validated scoped query contracts and return computed results with receipts. **Accept:** the model cannot replace query execution with invented matches or run arbitrary writes, network calls or permission changes.
- [ ] **AI-06 — Make outputs structured and sourced.** Store claims/links/actions with input revisions, source locators, uncertainty and provenance. **Accept:** unsupported interpretations remain labelled hypotheses/proposals, not documentary evidence.
- [ ] **AI-07 — Separate allowed automatic effects.** Permit configured structural links, folding and action routing while preserving explicit interpretive review. **Accept:** automatic organization cannot merge identities or approve substantive findings without the required decision.
- [ ] **AI-08 — Ground proposed child actions.** Require a specific unresolved question, trigger, expected result and eligible assignment basis. **Accept:** suggestions are actionable and deduplicated against existing work.
- [ ] **AI-09 — Preserve manual work and rejection history.** Regeneration respects accepted edits, pinned organization and prior decisions. **Accept:** unchanged rejected suggestions do not return repeatedly.
- [ ] **AI-10 — Enforce tool authorization independently.** Treat documents, attachments, metadata and model output as untrusted input; test disguised/split instructions and tool-result injection. **Accept:** hostile content cannot expand scope, alter policy or produce unauthorized effects.
- [ ] **AI-11 — Handle provider failures transparently.** Cover bad keys, rate limits, timeout, cancellation, malformed/partial output and unavailable send logging. **Accept:** failures produce no fabricated answer or unrecorded send, and users can continue manually.
- [ ] **AI-12 — Apply cost and execution controls.** Record actual provider/model identifiers, usage, budgets and job state; cache by authorized scope/revision/policy. **Accept:** repeated navigation cannot trigger uncontrolled spending or cross-user cache leakage.
- [ ] **AI-13 — Revalidate before application.** Check source versions, case generation, permissions and consent after model completion. **Accept:** late answers cannot resurrect erased data or overwrite newer decisions.
- [ ] **AI-14 — Evaluate independently.** Use separate development and fresh held-out sets covering extraction, retrieval, contradictions and action usefulness; record refusal and correction burden. **Accept:** no tuning the scorer to the tested answers or claiming a superseded accuracy gate was met.

## 22. OUTPUT — reviewed case products and portable map

**Specification:** R09, SM-10. **Depends on:** GRAPH, SRC, REASON, ACTION, ACCESS. **Exit:** outputs faithfully represent a frozen permitted case state.

- [ ] **OUTPUT-01 — Reuse the single output pipeline.** Route map, studio, case-report and briefing exports through current verification/approval services. **Accept:** no screenshot or alternate renderer bypasses protection checks.
- [ ] **OUTPUT-02 — Freeze the selected package.** Pin selected objects, revisions, source versions, dependencies, filters, reviews and manifest at export start. **Accept:** concurrent updates cannot create a mixed-state output.
- [ ] **OUTPUT-03 — Make selection boundaries explicit.** Choose whole permitted case, branch, briefing or specific records with required dependencies. **Accept:** omitted, unavailable, unsupported and restricted content is disclosed appropriately without leaking secrets.
- [ ] **OUTPUT-04 — Preserve work and reasoning.** Include permitted source locators, relationship meanings, findings, unresolved matters and action outcomes. **Accept:** a recipient can distinguish what was supplied, inferred, reviewed and left unresolved.
- [ ] **OUTPUT-05 — Deliver a navigable read-only package.** Provide portable linked content and originals/derivatives where permitted and selected, alongside relevant conventional outputs. **Accept:** navigation works offline and untrusted case text cannot execute scripts or fetch external resources.
- [ ] **OUTPUT-06 — Recheck at write time.** Verify current privilege, access, source availability and approval before bytes leave the app. **Accept:** a source protected after draft generation blocks or explicitly excludes the affected output.
- [ ] **OUTPUT-07 — Verify written artifacts.** Read back outputs and reconcile manifest, counts and hashes/format-specific content. **Accept:** export is recorded as successful only for what was actually written and checked.
- [ ] **OUTPUT-08 — Keep draft/approved state honest.** Use appropriate banners, revision identity and approval references. **Accept:** stale or unapproved findings cannot be presented as current approved conclusions.
- [ ] **OUTPUT-09 — Support closure and reopening.** Record unresolved items, waived work, rationale and authorized disposition; preserve a closure snapshot. **Accept:** reopening does not erase the earlier case position or completed work.
- [ ] **OUTPUT-10 — Verify handover with a fresh viewer.** Open the package without the author's existing app state. **Accept:** the viewer reaches the evidence, decisions and remaining work within the disclosed export scope.

## 23. RECOVERY — backup, restore and lifecycle integrity

**Specification:** R09, R12. **Depends on:** DATA and every new store. **Exit:** the whole working case can be recovered without replaying unintended effects.

- [ ] **RECOVERY-01 — Inventory complete backup content.** Include originals when promised, ledger, graph memberships, layouts, revisions, work/results, policy and necessary key metadata. **Accept:** a backup is called complete only when all promised originals and records are present.
- [ ] **RECOVERY-02 — Verify backup consistency.** Freeze or reconcile a coherent state under concurrent ingestion, edits and team updates. **Accept:** its manifest identifies actual versions rather than a collection of unrelated snapshots.
- [ ] **RECOVERY-03 — Test recovery-key paths.** Cover missing key, correct/wrong recovery key, prior unencrypted backup and an existing destination ledger key. **Accept:** failures preserve existing data and provide a precise recovery remedy.
- [ ] **RECOVERY-04 — Restore on a clean profile/device.** Exercise the real supported restore path outside the development environment. **Accept:** sources, map navigation, money, history and deep links function without old caches.
- [ ] **RECOVERY-05 — Prevent replayed external effects.** Restore completed/uncertain outbound operation identities safely and pause pending work for reconciliation. **Accept:** restoring does not resend letters, notifications or old assignments blindly.
- [ ] **RECOVERY-06 — Handle erasure versus old copies.** Define restoration/tombstone checks for erased records, historical backups and shared replicas. **Accept:** the app does not silently resurrect erased content, and backup limitations are disclosed accurately.
- [ ] **RECOVERY-07 — Validate corrupted/incomplete packages.** Detect missing originals, altered manifests, broken references and unsupported schema. **Accept:** partial recovery is explicit; it cannot be represented as a verified complete case.
- [ ] **RECOVERY-08 — Preserve collaboration boundaries.** Restore data without restoring expired authority, tokens or another user's identity. **Accept:** reconstructed sessions require the current valid authorization.
- [ ] **RECOVERY-09 — Test interruption and rollback.** Cover full disk, cancellation, crash and repeated restore. **Accept:** prior data is not partially overwritten and retry behavior is deterministic.
- [ ] **RECOVERY-10 — Exercise close/archive/reopen.** Verify search, history, exports and authorized contributions at each state. **Accept:** archived/closed data remains inspectable without allowing unintended mutations.

## 24. SEC — security, privacy and erasure across the full system

**Specification:** R01, R09, R11–R14; all SM requirements. **Depends on:** ARCH; applies throughout. **Exit:** data protections cover new paths, not just the original ledger.

- [ ] **SEC-01 — Update the threat model.** Include local devices, shared service, contributors, parsers, AI tools, notifications, portable viewers, backups and administrators. **Accept:** trust boundaries and plausible failure/abuse cases map to concrete controls and checks.
- [ ] **SEC-02 — Reconcile the data-flow inventory.** Document every destination, purpose, data category, retention and control, including synchronization and operational logs. **Accept:** actual runtime flows and product disclosures agree.
- [ ] **SEC-03 — Complete storage/key decisions.** Cover ledger, vectors, originals/vault, previews, temp files, shared copies and backups. **Accept:** implementation matches the declared model; any retained FileVault dependence is explicit rather than advertised as app-level encryption.
- [ ] **SEC-04 — Implement shared-data encryption boundaries.** Protect transport and stored shared content; define who can decrypt and how sharing/revocation/rotation works. **Accept:** server-side processing is not falsely described as end-to-end encryption inaccessible to the server.
- [ ] **SEC-05 — Protect credentials and sessions.** Use appropriate secure stores, token lifetimes, rotation/revocation and log redaction. **Accept:** keys, passwords and bearer tokens never enter case summaries, exports or ordinary logs.
- [ ] **SEC-06 — Extend privilege and protected-material checks.** Apply them to intake, search, summaries, AI, graph views, notifications, history and exports. **Accept:** changing protection after a draft is built prevents an unauthorized later send/export.
- [ ] **SEC-07 — Extend case/person/all-data erasure.** Inventory and remove affected records, revisions, indexes, caches, originals where eligible, queued work and shared copies. **Accept:** shared originals remain where legitimately referenced, leftover checks are explicit and legal holds prevent prohibited deletion atomically.
- [ ] **SEC-08 — Prevent resurrection after erasure.** Stop/invalidate background jobs and reconcile replicas, late submissions and old restores with deletion generations/tombstones. **Accept:** stale writers cannot recreate erased content.
- [ ] **SEC-09 — Verify privacy modes by observation.** Capture relevant network behavior with AI off/on, private/team modes and consent changes. **Accept:** every app-originated transmission is accounted for; do not claim zero network activity merely from a mode label.
- [ ] **SEC-10 — Harden untrusted content surfaces.** Test parser boundaries, HTML/media previews, portable packages, remote fetches and file names for injection/traversal/resource abuse. **Accept:** content cannot execute privileged commands or use tools to reach unauthorized services.
- [ ] **SEC-11 — Minimize operational telemetry.** Use necessary identifiers and redacted diagnostics with access/retention controls; keep case text out of routine logging. **Accept:** a support bundle or crash report cannot silently export evidence or secrets.
- [ ] **SEC-12 — Test authorization and race failures.** Include access revocation during export/AI, role change during consent, concurrent erasure and result submission, held records and cross-case ID attacks. **Accept:** failures leave safe, explainable states without partial disclosure.
- [ ] **SEC-13 — Record practical limitations honestly.** Explain retained backups, recipient-held exports, offline caches and key recovery boundaries. **Accept:** the app does not promise remote deletion of every previously distributed copy or absolute protection against all future attacks.

## 25. PERF — scale, responsiveness and operational reliability

**Specification:** R02, R04, R12, SM-02, SM-08. **Depends on:** core services; profile throughout. **Exit:** supported workloads remain usable with explicit coverage and limits.

- [ ] **PERF-01 — Define named workloads and hardware.** Include normal/stress cases, source bytes/pages, OCR burden, nodes, links, depth, users and update rates. **Accept:** reported capacity is tied to an exact build and environment.
- [ ] **PERF-02 — Measure stages separately.** Track intake, parsing/OCR, indexing, projection, rendering, navigation, change propagation, AI waiting, sync, export and restore. **Accept:** fast model projection is not used as proof of responsive on-screen rendering.
- [ ] **PERF-03 — Load graph detail incrementally.** Use indexed adjacency, pagination, cancellation and viewport rendering. **Accept:** first use does not load every branch, while every authorized record remains discoverable.
- [ ] **PERF-04 — Cache by identity and revision.** Include case/scope/permission context and invalidate affected derived states only. **Accept:** cached results are correct after edits, revocation, erasure and reconnection.
- [ ] **PERF-05 — Keep expensive work off interaction paths.** Bound background OCR, layout, extraction and queued analysis concurrency. **Accept:** adding a large archive does not freeze basic navigation or make progress unresponsive.
- [ ] **PERF-06 — Validate responsiveness targets.** Measure cached branch actions p95 under 200 ms and the defined warm overview under one second, or record misses and fixes. **Accept:** targets are observed in the actual UI on named hardware, not assumed.
- [ ] **PERF-07 — Test deep and dense cases.** Include long branches, highly connected hubs, many shared appearances and disconnected evidence. **Accept:** budgets/continuations are visible and preserve correct counts and reachable data.
- [ ] **PERF-08 — Handle memory/disk pressure.** Bound previews, caches, temporary files and pending results; surface safe recovery choices. **Accept:** pressure cannot corrupt case records or silently drop originals/results.
- [ ] **PERF-09 — Exercise service outages and backpressure.** Simulate slow/offline clients, failed shared services, interrupted uploads and retry storms. **Accept:** queues recover without duplicate effects or misleading sync status.
- [ ] **PERF-10 — Measure incremental growth.** Add daily work to an existing large case and compare layout, latency and memory. **Accept:** the whole case is not regenerated or rearranged for each small update.
- [ ] **PERF-11 — Set truthful operational capacity.** Publish tested sizes and resource behavior; avoid arbitrary semantic case/depth restrictions or unsupported unlimited-performance claims. **Accept:** oversized operations fail or continue explicitly rather than silently truncating results.
- [ ] **PERF-12 — Monitor without collecting case content.** Track necessary health, queue lag, error classes and resource use for the deployed service. **Accept:** an operator can diagnose outages while respecting the declared privacy model.

## 26. HELP — onboarding, accessibility and clear guidance

**Specification:** R02, R12, SM-09. **Depends on:** each exposed workflow; implement alongside it. **Exit:** new users can learn by doing and experienced users can work efficiently.

- [ ] **HELP-01 — Build a short first-case entry.** Offer start from a question, files or an existing case; choose solo/team and relevant template without a long mandatory wizard. **Accept:** users reach meaningful case work quickly.
- [ ] **HELP-02 — Deliver an optional worked sample.** Walk through question→source→comparison→action→new result→changed view→output with manual next/back controls. **Accept:** it uses isolated sample storage and cannot register test folders in the user's real case data.
- [ ] **HELP-03 — Explain the map's visual language.** Teach nodes, links, folds, uncertainty, review state and what changed using the actual controls. **Accept:** the legend and on-screen states use consistent terms.
- [ ] **HELP-04 — Add contextual hover/focus help.** Explain the purpose and consequence of unfamiliar controls on mouse hover and keyboard focus. **Accept:** critical instructions are available without hovering and do not rely on jargon.
- [ ] **HELP-05 — Provide useful empty/error states.** Show the next valid action and remedy for missing data, unreadable files, failed AI, absent access and blocked work. **Accept:** users are not stranded by “something went wrong.”
- [ ] **HELP-06 — Complete beginner and full guides.** Cover solo/team operation, intake, sources, deep navigation, money, actions, AI modes, privacy, export and recovery. **Accept:** instructions correspond to current UI and link to the relevant context.
- [ ] **HELP-07 — Preserve complete keyboard operation.** Provide focus order, shortcuts, search, expand/collapse, inspect, create/assign and review through accessible controls. **Accept:** no substantive case action requires a precise mouse gesture.
- [ ] **HELP-08 — Verify screen-reader and text accessibility.** Label nodes/edges/statuses, support appropriate text sizing and maintain readable contrast. **Accept:** a screen-reader user can inspect sources and perform the same action journey.
- [ ] **HELP-09 — Support motion and color needs.** Honor reduced-motion preferences, use text/icons with color and avoid disruptive auto-panning. **Accept:** updates remain understandable with animation or color cues unavailable.
- [ ] **HELP-10 — Keep depth discoverable.** Expand advanced information locally without hiding capabilities behind an unexplained separate mode. **Accept:** novices have clear defaults and experienced users can reach full records.
- [ ] **HELP-11 — Preserve source languages accurately.** Keep multilingual source text, names, scripts and original date/number forms even with an English v1 interface. **Accept:** transliteration/translation is identifiable and never replaces the original.
- [ ] **HELP-12 — Observe learnability.** Run first-use, tutorial replay, narrow-window and keyboard/VoiceOver journeys in the actual candidate. **Accept:** compiled help strings alone do not close usability checks.

## 27. ADAPT — existing jobs, specialist data and interoperability

**Specification:** R00, R03, R06, R10. **Depends on:** canonical contracts and source locators. **Exit:** useful existing capability feeds the map without fragmented workflows.

- [ ] **ADAPT-01 — Map every retained job result.** Connect real outputs from existing case services, shared builders and studios to canonical records and graph adapters. **Accept:** generic placeholder rows do not count as a job-specific result.
- [ ] **ADAPT-02 — Preserve transfer identity and review.** Carry selected results into questions, chronology, money and reports with original wording/source/revision links. **Accept:** repeated carry-over is deduplicated unless the user intentionally creates a distinct record.
- [ ] **ADAPT-03 — Keep specialized terminology contextual.** Use relevant persona/template labels without creating competing data models. **Accept:** investigator, journalist, workplace and other retained workflows share the same evidence and action integrity.
- [ ] **ADAPT-04 — Specify advertised formats.** Define version/field contracts for each supported forensic, financial, email, media or tabular adapter. **Accept:** sample success is not described as universal compatibility.
- [ ] **ADAPT-05 — Preserve unsupported content.** Attach originals, source metadata and supplied summaries when interpretation is unavailable. **Accept:** the map represents the material and its limitation without pretending to decode it.
- [ ] **ADAPT-06 — Implement generic structured exchange.** Provide the chosen documented records/relationships/source-reference interchange, with stable IDs and import receipts. **Accept:** a round-trip preserves the supported meanings and explicitly reports unsupported fields.
- [ ] **ADAPT-07 — Control external enrichment.** Define typed provider adapters returning canonical candidate objects/links with origin, retrieval time, input scope, pagination, cost/usage and restrictions; compose only configured adapters into authorized recipes. **Accept:** empty results distinguish no match from denied, failed or partial lookup; provider subscriptions and keys are actual prerequisites.
- [ ] **ADAPT-08 — Test real adapter failure modes.** Exercise missing columns, changed versions, encodings, nested files, duplicates and invalid identifiers. **Accept:** partial imports are accounted for and cannot corrupt canonical identities.
- [ ] **ADAPT-09 — Verify every named integration claim.** Maintain a bounded matrix for actual supported products/formats and tested versions. **Accept:** describing capability families does not become an untested claim of compatibility or full parity with DataWalk, i2, Casefleet, Maltego or Palantir.

## 28. QA — end-to-end correctness and observed journeys

**Specification:** R12; every SM requirement. **Depends on:** each implementation slice. **Exit:** the claimed candidate behaves as one integrated product.

- [ ] **QA-01 — Maintain independent expected results.** Define fixture facts, source locators, permitted interpretations, expected work and known unknowns before scoring. **Accept:** tests do not merely reproduce implementation output as their own answer key.
- [ ] **QA-02 — Run the supplier investigation.** Include two true equal payments, a refund, copied source, witness disagreement, forensic report/amendment, ownership and prior case. **Accept:** financial results, contradictions and follow-up outcomes match the fixture without inventing loss or guilt.
- [ ] **QA-03 — Run a non-financial workplace case.** Include competing accounts, response opportunity, confidentiality and missing material. **Accept:** money assumptions and financial templates do not control unrelated investigations.
- [ ] **QA-04 — Run a documentary/historical case.** Include uncertain dates, derivative sources, similar names, gaps and later corrections. **Accept:** ambiguity and source dependence remain visible throughout the map and output.
- [ ] **QA-05 — Exercise the full recursive journey.** Navigate six meaningful UI levels and much deeper automated structures; use multi-membership and cyclic relationships. **Accept:** no lost identity, orphaned source or fixed semantic-depth limitation.
- [ ] **QA-06 — Verify all advertised record adapters.** Exercise real data for each retained record/output class, including failures. **Accept:** every required case item is reachable or explicitly unavailable within the user's scope.
- [ ] **QA-07 — Run solo and distinct-user journeys.** Use real authentication boundaries for lead, examiner and contributor. **Accept:** simulated role labels in one privileged session are not accepted as team verification.
- [ ] **QA-08 — Run all AI modes.** Complete core tasks with AI off, suggestion mode and configured execution. **Accept:** model failure or denial of consent cannot break manual work.
- [ ] **QA-09 — Run lifecycle and concurrency races.** Cover erase/hold/scope changes, simultaneous edits, revoked access, late results and closed cases. **Accept:** no stale write, partial erase, unauthorized send or hidden conflict.
- [ ] **QA-10 — Run migration and recovery matrix.** Upgrade representative older ledgers and restore complete/partial/corrupt backups. **Accept:** verified originals, identities, history and queued-effect handling match declared behavior.
- [ ] **QA-11 — Run source and output integrity checks.** Include changed privilege at export, mixed revisions and unavailable originals. **Accept:** written packages match frozen manifests and disclose their limits.
- [ ] **QA-12 — Run actual accessibility and layout journeys.** Cover keyboard/screen reader, small window, long content, reduced motion and dense cases. **Accept:** evidence comes from interaction, not only accessibility identifiers existing in code.
- [ ] **QA-13 — Run the distribution candidate.** Install/launch the actual signed build outside build folders and execute the important case journey, network/privacy and purchase/entitlement paths. **Accept:** development-only success does not substitute for release-artifact behavior.
- [ ] **QA-14 — Verify test isolation and real execution.** Use ephemeral case/settings/folder stores; inspect current result bundles and timestamps. **Accept:** no user data changes, skipped journeys, cached tool output or runner failures are misreported as fresh passes.
- [ ] **QA-15 — Close defects with proportionate rechecks.** Record reproductions, fixes and affected regression evidence; rerun broader suites when the change warrants them. **Accept:** unresolved failures and unobserved paths stay visible in the final matrix.

## 29. BENEFIT — prove that investigation is easier

**Specification:** R12, SM-01–SM-10. **Depends on:** begin design at BASE; measure a stable integrated candidate. **Exit:** the product's ease-of-use claim has actual task evidence.

- [ ] **BENEFIT-01 — Freeze the evaluation protocol.** Name tasks, equivalent case variants, baseline, completion rubrics, timeouts, errors and thresholds before running comparisons. **Accept:** the scoring rules cannot be adjusted afterwards to suit the candidate.
- [ ] **BENEFIT-02 — Include representative investigators.** Start with at least five users spanning new and experienced users for initial usability evidence. **Accept:** actual participant observations are separate from agent walkthroughs, and the limited sample is disclosed.
- [ ] **BENEFIT-03 — Counterbalance learning effects.** Vary order and use matched cases between candidate and baseline. **Accept:** users are not faster only because they already solved the same case once.
- [ ] **BENEFIT-04 — Measure total effort.** Include setup, onboarding, searching, waiting, corrections, map maintenance, handover and rework. **Accept:** reported savings do not omit the work required to create or maintain the map.
- [ ] **BENEFIT-05 — Measure understanding and evidence access.** Use the §18 targets: bounded-case orientation within two minutes, direct source access, median known-item finding within 30 seconds. **Accept:** results include correctness and missed uncertainty, not time alone.
- [ ] **BENEFIT-06 — Measure work coordination and quality.** Count missed/duplicate actions, assignment corrections, unresolved matters, source errors and stale conclusions. **Accept:** faster performance with worse investigative quality is not reported as success.
- [ ] **BENEFIT-07 — Evaluate the declared improvement target.** Aim for at least 30% lower median end-to-end time on successful matched tasks, reporting failures/timeouts and per-user/case outcomes too. **Accept:** AI-off and AI-on results, maintenance and correction costs are reported separately.
- [ ] **BENEFIT-08 — Match claims to the evidence.** Fix failed tasks, retest affected workflows and expand evaluation before broad superiority claims. **Accept:** meeting an initial pilot target does not become a claim about every case, investigator or untested competitor.

## 30. SHIP — complete the actual distributed product

**Specification:** R12 and existing approved release obligations. **Depends on:** all advertised core requirements; preparation can begin earlier. **Exit:** the shipped artifact and its operations match what was verified.

- [ ] **SHIP-01 — Freeze a release candidate.** Record full SHA, dependency versions, schema, build settings and artifact hashes; associate checks with that exact candidate. **Accept:** later code changes trigger the relevant re-verification rather than inheriting unrelated green evidence.
- [ ] **SHIP-02 — Validate packaging and signing.** Check distribution signing, required entitlements, embedded runtime libraries including SQLCipher where linked, extensions and clean-machine launch. **Accept:** the archive does not depend on the development build folder.
- [ ] **SHIP-03 — Complete production collaboration operations.** Deploy the actual scoped service, migrations, backups, monitoring and recovery process; test staging-to-production configuration. **Accept:** team contributions do not rely on a developer's temporary machine or test backend.
- [ ] **SHIP-04 — Reconcile privacy and provider disclosures.** Update in-app text, data-flow inventory, manifests, privacy policy and App Store labels for real team/AI/telemetry behavior. **Accept:** old local-only or “no collection” language is not reused without checking the new flows.
- [ ] **SHIP-05 — Complete applicable owner/legal decisions.** Prepare concrete publisher, terms/EULA, name/trademark, third-party data/provider, retention and encryption-classification materials for the responsible decision-maker. **Accept:** actual decisions are recorded; no agent-generated document is represented as legal clearance.
- [ ] **SHIP-06 — Verify the authorized commercial model.** Test current approved subscription/purchase, trial, restore, refund/lapse and team/contributor entitlements. **Accept:** the map changes do not silently change pricing or strand existing users' evidence contrary to the promised access policy.
- [ ] **SHIP-07 — Provide production onboarding/support.** Publish current beginner/full guides, recovery instructions, support route and safe diagnostic collection. **Accept:** users can report a problem without being asked to expose an entire sensitive case unnecessarily.
- [ ] **SHIP-08 — Check metadata and claims.** Align screenshots, listing, help and landing pages with implemented scope, tested capacities and actual AI/network behavior. **Accept:** no “100% correct,” guaranteed solution or all-five-products-parity claim without support.
- [ ] **SHIP-09 — Run final signed/TestFlight journeys.** Exercise upgrade, first use, deep map work, AI consent, team intake, export, restore and purchase paths on supported hardware. **Accept:** each required path has observed results or an explicitly unresolved blocker.
- [ ] **SHIP-10 — Prepare rollout and rollback.** Define safe version/schema compatibility, service migration rollback/forward recovery and incident response. **Accept:** a failed rollout cannot force destructive downgrade or lose current cases.
- [ ] **SHIP-11 — Assemble the release evidence packet.** Include the completion matrix, exact artifact, results, measured limitations, known issues, disclosures and decisions. **Accept:** another reviewer can distinguish what is implemented, observed, measured and still blocked.
- [ ] **SHIP-12 — Make the final scope verdict.** Review every core checkbox and advertised conditional capability against the candidate evidence. **Accept:** do not call the full smart-map product complete while a core journey is missing, and do not call it shippable solely because the map tests pass.

## E. Mandatory canonical-record coverage

BASE-04 and ADAPT-01 must account for these categories. Use existing types where they already own the data; this table is not an instruction to duplicate them into a new map database.

| Record family | Required representation and connection |
|---|---|
| Mother case and scope | Purpose, authorized sources, case state, lead, questions, policies, history and closure/reopening. |
| Frames and appearances | Anchor, child membership, local organization, saved views, cross-links and stable canonical identity. |
| Evidence and source occurrences | Originals, source versions, hashes, custody/intake events, attachments, extracted text, processing coverage and exact locators. |
| Physical exhibits and examined material | Supplied identifiers, collection/custody records, photos, examinations and reports; physical existence is not implied by a database entry alone. |
| Reports, sections and key points | Producer, methods/limitations where supplied, exact sources, qualifications, amendments, questions and resulting examinations. |
| People and organizations | Source-linked identity, aliases, roles, observations, contacts, relevant supplied background and involvement over time. |
| Witness accounts and interviews | Questions, statements, attribution, recordings/transcripts, attestations, responses and corrections. |
| Events and locations | Typed time assertions, original wording, uncertainty, supplied location/coordinates and source basis; any geographic presentation uses the same records and declared data flows. |
| Financial objects | Accounts, ownership/control assertions, transactions, invoices, assets, currencies, reconciliations and contributing sources. |
| Reasoning records | Questions, allegations, hypotheses, supporting/challenging links, comparisons, contradictions, alternatives, decisions and findings. |
| Work and participants | Child actions, requests, owners/helpers/reviewers, dependencies, submitted results, outcomes, team roles and reported external work. |
| Governance and protection | Privilege, holds, redactions, review batches, conflict checks, erasure records, access policy and relevant audit history. |
| Historical/review references | Authorized prior cases, supplied external material, pinned/live references, checkpoints and review-case conclusions. |
| Derived and operational records | Source-bound summaries, saved/frozen searches, AI proposals, template/policy versions, events/queues, notifications, exports and backups. |

Every family must have a defined canonical owner, map/list representation, source/version behavior, permission model, history, search policy, output treatment and erasure/backup handling. A representation can be lazy-loaded or unavailable with a reason; it must not be silently forgotten.

## F. Traceability to the finalized plan

### Implementation packages

| Plan package | Checklist tracks that complete it |
|---|---|
| R00 — baseline/inventory | BASE, ADAPT |
| R01 — record/relationship contracts | ARCH, DATA, SRC, GRAPH, SEC |
| R02 — recursive map frames | GRAPH, MAP, BRIEF, SEARCH, HELP, PERF |
| R03 — report/key-point/work loop | IN, SRC, REPORT, REASON, ACTION, ADAPT |
| R04 — histories/dependency impact | DATA, TIME, CHANGE, HISTORY |
| R05 — people/investigator work | PEOPLE, TIME, ACTION, ACCESS |
| R06 — financial graph | MONEY, SRC, GRAPH, QA |
| R07 — historical/review cases | HISTORY, PEOPLE, ACCESS, OUTPUT |
| R08 — AI-assisted operations | AI, REASON, AUTO, CHANGE, SEC |
| R09 — closure/portable output | OUTPUT, RECOVERY, DATA, SEC |
| R10 — specialist adapters | IN, SRC, ADAPT |
| R11 — team collaboration | ARCH, ACCESS, TEAM, ACTION, SEC |
| R12 — verification/benefit | QA, PERF, HELP, BENEFIT, SHIP |
| R13 — case/action orchestration | ACTION, AUTO, CHANGE, TEAM |
| R14 — contributor intake | TEAM, IN, ACCESS, SEC |

### Smart-map user outcomes

| User requirement | Primary tracks | What must be demonstrated |
|---|---|---|
| SM-01 — understand the case | BRIEF, REPORT, REASON, BENEFIT | A newcomer explains the purpose, recorded position, uncertainty and next work using the linked brief. |
| SM-02 — inspect any depth | GRAPH, MAP, SEARCH, PERF | Deep expansion and direct search navigation preserve context, identity and return position. |
| SM-03 — change perspective | MAP, MONEY, TIME, PEOPLE | The same canonical item remains consistent across relevant map/list/table/timeline perspectives. |
| SM-04 — verify relationships | SRC, SEARCH, GRAPH, REASON | Exact source and link meaning, time and provenance can be inspected and corrected. |
| SM-05 — compare accounts | REASON, REPORT, MONEY, ACTION | Competing accounts and qualifications are visible together and produce useful follow-up work. |
| SM-06 — see change/impact | CHANGE, TIME, BRIEF, AI | Material amendments identify affected dependencies while preserving original decisions. |
| SM-07 — know next work | ACTION, AUTO, BRIEF, TEAM | Important unresolved work has a specific next step, owner or visible blocker/remedy. |
| SM-08 — maintain once | DATA, GRAPH, MAP, TEAM, AUTO | One accepted contribution updates relevant appearances without duplicate typing or runaway work generation. |
| SM-09 — learn/use accessibly | HELP, MAP, QA, BENEFIT | New and keyboard/screen-reader users complete the substantive workflow. |
| SM-10 — hand over/conclude | OUTPUT, RECOVERY, HISTORY, BRIEF | Another investigator follows the reasoning, sources and unfinished work in a permitted frozen or live case. |

## G. The decisive acceptance journey

Use fictional data with a fixed expected-results ledger. The supplier fixture includes: invoice INV-104 for INR 50,000; two genuinely distinct INR 50,000 settlements with separate bank references; an INR 50,000 refund; a byte-identical copy of one bank document; a witness statement describing one payment; a forensic report and later amendment; account ownership material; a prior case containing the same account; an unrelated same-name person; an uncertain timezone; an unreadable scan; an unsupported attachment; and an externally performed examination.

| Step | Operation | Required observed result |
|---|---|---|
| 1 | Create the mother case and import the mixed material. | Every selected item is accounted for; duplicate, unreadable and unsupported items have explicit states; originals and source occurrences are preserved. |
| 2 | Open the initial brief. | Purpose, preliminary position, uncertainty and next work are understandable; no premature conclusion or loss total is asserted. |
| 3 | Open the forensic report, a point, a question, examination, result report and deeper point. | At least six meaningful UI levels work, with no fixed product depth ceiling and exact back/source navigation. |
| 4 | Link the same witness and transaction from different branches. | There is one canonical record with multiple appearances; no inflated counts or conflicting edits. |
| 5 | Compare the witness account with the two bank entries. | The map records a possible discrepancy, retains both sources and leaves substantive resolution open. |
| 6 | Create the parent discrepancy action and financial/interview children. | Each has a specific deliverable and an eligible owner or visible unassigned state; existing equivalent work is reused. |
| 7 | Have an examiner submit the transaction analysis and a limited contributor return requested material. | Distinct identities and permissions work; submissions enter canonical intake; contributors cannot browse the case. |
| 8 | Classify the settlements and refund. | Gross paid INR 100,000, returned INR 50,000 and net outflow INR 50,000 for this fixture. Net outflow is not automatically labelled loss. |
| 9 | Return one result for correction, then accept its new revision. | Review history is preserved; the parent question can remain unresolved despite completed work. |
| 10 | Examine the authorized historical account overlap and reject the unrelated same-name match. | Similarity and identity decisions are explicit; no unauthorized prior-case content is exposed. |
| 11 | Import the amended forensic report. | The earlier report remains inspectable; changed points and dependent summaries/findings are marked; unrelated branches/layout stay stable. |
| 12 | Trigger a retry, duplicate submission and generation-budget stop. | One logical action per issue, no runaway children, and a visible resumable state for stopped work. |
| 13 | Revoke access while a result/send/export is pending. | Current permissions are rechecked; no late disclosure or unauthorized application occurs. |
| 14 | Inspect investigator work and time history. | Reported performer, actual contributor, software activity, event time, receipt time and review time are distinguishable. |
| 15 | Create a separate review case. | It examines pinned prior decisions and available-at-the-time evidence without mutating the original case. |
| 16 | Hand over the case, close it with explicit unresolved items and export the selected record. | A new reviewer follows the reasoning and sources; written output matches its frozen permitted manifest. |
| 17 | Restore on a clean profile/device and reopen. | Deep navigation, originals, work/history and IDs survive; old external effects are not replayed. |
| 18 | Repeat solo, with a real team, AI off, suggestions and configured execution. | All modes preserve the same integrity; measure effort and corrections separately rather than treating more automation as automatically better. |

Repeat the relevant lifecycle with workplace and historical/documentary fixtures. The supplier fixture alone cannot establish suitability for every retained persona or investigation type.

## H. Product-benefit targets and evaluation limits

These are the finalized plan's proposed targets for defined workloads, not current results:

- Case orientation within two minutes on the bounded fixture, including its material uncertainty and responsible next work.
- One direct command from a selected sourced assertion to its precise supported locator; median known-item finding within 30 seconds on the defined search tasks.
- Every seeded material amendment exposes affected recorded dependencies; no stale finalized conclusion is displayed as current.
- Every mandatory fixture action has an eligible owner or visible unassigned/blocked state with a remedy.
- At least 30% lower median end-to-end time on successful matched tasks, with setup, corrections and maintenance included and failures/timeouts reported.
- No observed critical source misattribution, unauthorized disclosure, data loss or false completion in acceptance fixtures; task accuracy/omissions must not worsen relative to the chosen baseline.
- At least four of the initial five users finish the defined first-case journey without live coaching after the optional ten-minute sample.
- Ordinary cached branch actions p95 under 200 ms and the defined warm overview under one second on named hardware, with cold loading and other stages reported separately.

A small initial study supports a bounded usability statement, not a universal claim about every investigator or superiority over untested competitors. An automated test can establish a specific data invariant; it cannot establish that all case conclusions are true. Keep these distinctions in the final evidence and marketing.

## I. Existing code entry points

All source links below are pinned to the baseline SHA. Inspect current equivalents if later commits move them. They identify reuse opportunities, not instructions to create replacement subsystems.

| Responsibility | Existing source entry points |
|---|---|
| Canonical case projection and loading | [CaseMapProjection.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapProjection.swift), [CaseMapService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapService.swift), [CaseFileDocuments.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseFileDocuments.swift) |
| Saved views, layout and scope | [CaseMapRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapRepository.swift), [CaseMapLayout.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapLayout.swift), [CaseMapViewFilter.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapViewFilter.swift) |
| Workspace, inspector and accessible commands | [CaseMapWorkspaceModel.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapWorkspaceModel.swift), [CaseMapWorkspaceView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapWorkspaceView.swift), [CaseMapCanvas.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapCanvas.swift), [CaseMapInspector.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapInspector.swift), [CaseMapAccessibility.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapAccessibility.swift) |
| Search | [CaseSearchQuery.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Retrieval/CaseSearchQuery.swift), [CaseSearchMatcher.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Retrieval/CaseSearchMatcher.swift), [CaseSearchService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Retrieval/CaseSearchService.swift); [CaseSearchLive.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseSearchLive.swift) |
| Revisions, checkpoints and changes | [CaseRecordRevisions.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseRecordRevisions.swift), [CaseHistoryRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseHistoryRepository.swift), [CaseChangeFeed.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseChangeFeed.swift) |
| Case people and actor profile | [CaseFile.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseFile.swift) |
| Work | [ProfessionalTask.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Core/Models/ProfessionalTask.swift), [ProfessionalTaskRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Storage/Repositories/ProfessionalTaskRepository.swift) |
| Money | [FAMoney.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/FAMoney.swift), [ForensicEngagement.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/ForensicEngagement.swift); [FundFlowView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/FundFlowView.swift) |
| Historical overlap | [CaseDeconfliction.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseDeconfliction.swift) |
| Audit | [AuditChain.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Forensics/AuditChain.swift) |
| Output | [CaseMapExport.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapExport.swift), [CaseOutputService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift); [CaseMapExportRoutes.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapExportRoutes.swift) |
| Help | [HelpRegistry.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/Help/HelpRegistry.swift), [HelpTutorial.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/Help/HelpTutorial.swift) |
| Evidence reconciliation | [CASE_MAP_EXECUTION_MATRIX.md](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/docs/CASE_MAP_EXECUTION_MATRIX.md), [JOURNEYS.md](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/docs/evidence/ui-walk-2026-11-07/JOURNEYS.md), [SHIP_DECISIONS.md](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/SHIP_DECISIONS.md) |


## J. Work requiring concrete external authority or observations

The implementation agent owns routine engineering work and should keep progressing. These boundaries must remain honest:

| Dependency | Finish before treating it as blocked | Never substitute |
|---|---|---|
| Signing/production accounts | Reproducible archive, entitlements, packaging checks, deployment configuration and precise missing credential/action. | A development signature or a compiled test suite for actual distribution execution. |
| New data flows and terms | Actual inventory, concrete label/terms options, provider terms evidence and applicable decision pack. | The agent's draft for the responsible publisher's decision or required legal review. |
| Named-hardware observations | Ready fixture, deterministic steps, logging and expected results. | A simulator estimate or a model-level timing for observed Mac UI performance. |
| Human usability evidence | Recruitment criteria, consent materials where appropriate, frozen tasks, baseline and scoring sheets. | Agent personas or fabricated users for actual participants. |
| External data services | Implemented/configured adapter, required scopes, fixtures, cost/access requirements and test plan. | An invented credential or implied access to private/proprietary databases. |

Do not stop the whole program at the first dependency. Mark the affected items BLOCKED with their exact next action and finish the independent work. Do not send invitations, submissions or other external communications without the applicable authorization.

## K. Final instruction to the implementation agent

Implement this checklist against the current repository and maintain one completion matrix. Begin with M0 and the M1 report-to-deeper-investigation journey. Design team permissions, revisions and lifecycle handling into the foundation, then complete the investigation, action, contribution and AI layers through the same services. Preserve the full map depth and all source/work/history connections.

Use the existing working app as the foundation. Keep all 330 task IDs, recording already-satisfied items with evidence rather than rewriting them. Complete required fixes, migrations and relevant tests, then actually exercise the UI and distribution candidate where the environment permits. Identify unavailable execution environments precisely instead of claiming their results.

Do not call the product complete because the backlog contains code for every feature. Completion requires the integrated journeys, correct failure behavior, recovery, authorization and source integrity, plus evidence for the ease-of-use claim. The final report must name the exact candidate, completed requirements, observed results, measured benefit and any remaining limitations or blockers.

After the core scope is complete, accept further features as explicit changes with a demonstrated user purpose. Keep every subsequent change tied to the target: a dependable smart map that makes investigation easier.

## L. How the five products inform this map — verified capability mapping

**Research date:** 8 November 2026. This appendix distinguishes documented vendor behavior from the IME design derived from it. The earlier plan identified useful capability families; it was not an exhaustive feature-by-feature or hands-on comparison. This follow-up examined official product/help/technical documentation and sharpened the existing tasks without changing their IDs or claiming implementation.

The comparison uses DataWalk, i2 Analyst's Notebook and its data/query ecosystem, Casefleet, Maltego Graph, and Palantir. For Palantir, Gotham's published 2024 service definition supports investigation/Graph/Dossier descriptions; current Foundry documentation is separately identified for object/action architecture. These are related platform references, not an assertion that Gotham and Foundry are identical products. Some i2 pages were available through indexed official documentation while direct navigation required authentication; current structured-search documentation and public versioned manuals were used where available.

No licensed hands-on benchmark of all five was run. Vendor scale/speed claims, exact edition availability, deployment complexity and comparative usability are not established by reading documentation. No code, proprietary data subscriptions or working integrations from these products have been installed into IME by this checklist.

### L1. What is adopted and where it appears

| Product and documented capability | IME behavior derived from it | Tasks and expected investigator benefit |
|---|---|---|
| **DataWalk:** combines heterogeneous information in a graph; supports visual/contextual querying and explainable entity matching while retaining source records. [D1–D3] | A supplied person/account/company has one traceable profile across sources. A no-code pattern query finds relevant multi-step relationships and can be saved/re-run under policy. Matching shows its basis and preserves original records. | ARCH-01–ARCH-05, PEOPLE-07, SEARCH-02/09/10, MONEY-01–MONEY-12. Less manual joining of spreadsheets and repeated reconstruction of identities. |
| **i2:** structured search can constrain properties and linked entities; path analysis can consider direction/time conditions; selections can coordinate chart and distribution views. [I1–I3] | Select a time/amount subset and inspect the same records in the graph, table and timeline. Follow a constrained path with the meaning/source of every edge and visible search bounds. | MAP-06/07/11, SEARCH-02/09, TIME-01–TIME-05, MONEY-10. Easier identification and checking of relevant relationships without treating visual proximity as evidence. |
| **Casefleet:** separates concise fact records from citations and connects them to chronology/issues; proposed AI facts require citations and human acceptance. [C1–C3] | Highlight a passage to create a source-linked assertion/point, attach question/person/time context, and open further work. AI proposals remain distinct from accepted case records and reviewed findings. | SRC-01–SRC-10, REPORT-02/04/05, REASON-01/02/09, AI-06/07. Less retyping and a direct route from every point back to its evidence. |
| **Maltego:** typed Transforms query configured data sources and return entities; Machines compose repeatable Transform workflows. Its 2026 SDK documentation distinguishes Desktop support from Browser limitations. [M1–M3] | A selected entity can run a configured enrichment adapter. A versioned recipe can combine allowed lookups and local checks, record provenance and produce candidate links/actions. Source access, costs, partial failures and review checkpoints remain visible. | ADAPT-07/08, AUTO-01–AUTO-12, IN-01/12, AI-05. Repeat useful collection routines without repeating manual queries or creating unexplained graph items. |
| **Palantir:** Gotham describes collaborative graphs/dossiers whose embedded records retain source links and can form nested information. Foundry documents governed object actions and object/link permissions. [P1–P4] | Reports/briefings embed live canonical records or frozen versions. Investigators submit and review child-action results against the same objects; permissions govern reading, changes, AI and outputs. | BRIEF-08, GRAPH-01/03, REPORT-07, ACTION-01–ACTION-12, ACCESS-01–ACCESS-12, TEAM-01–TEAM-12, OUTPUT-02/05. Less copy-and-paste, clearer handovers and safer work coordination. |

These rows are architectural adaptations. Their usefulness is an IME design hypothesis to verify under BENEFIT, not a vendor-backed claim that IME already outperforms those products.

### L2. Concrete refinements made after this deeper check

The earlier checklist covered these areas broadly. The following details are now explicit acceptance requirements:

1. **Real relationship queries:** SEARCH-02/09/10 require linked-object conditions, direction, time order, stated bounds, reusable patterns and revision-bound receipts. A text search box or drawn graph is insufficient.
2. **Coordinated selections:** MAP-07 now includes shared record subsets and useful date/amount distributions. Selecting a spike must expose its contributing transactions and evidence, not merely draw an attractive chart.
3. **Explainable identity matching:** PEOPLE-07 requires matching-rule versions, attribute evidence and reasons records stay separate. A unified profile must preserve its underlying source records.
4. **Repeatable enrichment:** ADAPT-07 and AUTO-01 require typed adapters and versioned recipes with provenance, limits and review checkpoints. Adding a generic “Research” button does not satisfy this capability.
5. **One-step source-to-point creation and linked briefings:** REPORT-02 and BRIEF-08 specify creation from highlighted material and the distinction between live references and frozen briefing content.
6. **Governed AI and remote access:** AI-05 routes proposed queries through the same scoped execution contracts; ACCESS-01 makes strong remote authentication and safe recovery explicit.

The other security, revision, erasure and workflow requirements continue to apply. These refinements do not authorize new data sources, silently enable cloud sends or accept inferred relationships as proven.

### L3. One case showing how the capabilities work together

Use the supplier case with its two equal settlements and refund, and add a supplied company-register extract and an authorized prior-case account reference:

1. **Unify the supplied records:** connect the supplier, invoice, bank entries and account-owner assertions while retaining each original. Inspect any proposed same-entity match before adopting it.
2. **Query and inspect the pattern:** select suppliers with the specified payment pattern in the chosen period, follow the account/owner relationships, and highlight the returned entries across graph, table and timeline. The query states whether it checked the whole authorized corpus or a bounded subset.
3. **Anchor the explanation to evidence:** open the exact statement row and witness passage. Create source-linked points and an apparent discrepancy without asserting fraud.
4. **Collect additional authorized context:** if a configured provider is available, run the relevant company lookup recipe. Otherwise use the supplied extract/manual request. Record origin and retrieval date; a failed lookup is not “no owner found.”
5. **Coordinate follow-up:** create financial and interview child actions, assign eligible people, receive their results and review them against the original question.
6. **Update the living record:** changed evidence identifies affected points, summaries and findings. A live briefing reveals those changes; a frozen briefing preserves what was recorded at its selected revision.

IME's intended benefit is that this sequence occurs through the same case objects and map context. It does not require the investigator to maintain five separate copies of the case. Whether it saves time and avoids omissions must be measured on the implemented workflow.

### L4. Capabilities not obtained automatically

- Paid intelligence datasets, provider contracts/API keys, proprietary file support and direct interoperability require actual supported integrations and verification.
- Enterprise-scale federation, deployment, availability and classified-environment controls are not supplied by a desktop graph or a shared-service prototype.
- Advanced network analytics, full geographic analysis and specialized domain algorithms are not all included merely because i2/DataWalk/Palantir provide them. Basic supplied locations and typed paths remain represented; additional analytical functions require explicit scope and evidence.
- Reusable collection recipes do not replace the mother-case/child-action model. A data lookup and a human examination have different authority, completion and review semantics.
- AI-assisted case organization and source-linked evidence workflows already exist in this market. Neither AI nor a graph alone establishes novelty or superiority for IME.
- A deterministic query can give reproducible results over declared inputs and conditions. It cannot guarantee that OCR is complete, supplied records are true or every real-world connection has been discovered.

### L5. Official sources used for this mapping

Sources document capabilities; marketing performance claims were not adopted as measured facts.

- **D1:** [DataWalk investigations](https://datawalk.com/solutions/investigations/).
- **D2:** [DataWalk entity resolution](https://datawalk.com/platform/entity-resolution/).
- **D3:** [DataWalk investigation capability description](https://datawalk.com/solutions/investigation/) (redirects to its current investigations page; indexed text also describes visual multi-hop queries).
- **I1:** [i2 Analyst's Notebook 10.1.2 structured search](https://docs.i2group.com/anb/10.1.2/searching_your_chart.html).
- **I2:** [i2 Analyst's Notebook 10.1.0 official manual — Find Path](https://docs.i2group.com/anb/10.1.0/pdf/i2%20Analyst%27s%20Notebook.pdf).
- **I3:** [i2 Analyst's Notebook 10.0.2 coordinated selections/distributions](https://docs.i2group.com/anb/10.0.2/view_distributions_in_a_selection.html).
- **C1:** [Casefleet facts and citations](https://support.casefleet.com/en/articles/9595939-facts-and-citations-explained).
- **C2:** [Casefleet AI proposed facts](https://support.casefleet.com/en/articles/13057134-using-the-ai-assistant-to-create-facts).
- **C3:** [Casefleet key concepts: facts, entities, issues and sources](https://support.casefleet.com/en/articles/1982995-key-concepts-in-casefleet).
- **M1:** [Maltego Transform development](https://docs.maltego.com/en/support/solutions/articles/15000015758-writing-transforms).
- **M2:** [Maltego Machines SDK, updated July 2026](https://docs.maltego.com/en/support/solutions/articles/15000062348-machines-sdk-).
- **M3:** [Maltego data sources and connectors](https://www.maltego.com/maltego-data/).
- **P1:** [Palantir's published Gotham service definition, 2024, Graph/Dossier sections](https://assets.applytosupply.digitalmarketplace.service.gov.uk/g-cloud-14/documents/92736/801146272055049-service-definition-document-2024-05-02-1537.pdf).
- **P2:** [Palantir Foundry actions in Workshop](https://www.palantir.com/docs/foundry/workshop/actions-use).
- **P3:** [Palantir Foundry object permissions](https://www.palantir.com/docs/foundry/object-permissioning/overview).
- **P4:** [Palantir Gotham security documentation](https://www.palantir.com/docs/gotham).

