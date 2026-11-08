# Investigations Made Easy: recursive case map

## Feasibility and implementation plan — 8 November 2026

**Inspected repository:** sasmalgiri/kalsmritikosh  
**Branch:** investigations-next  
**Inspected commit:** 58717ec8bfbc543e9bf7700d2dd66c2c4b867135  
**Commit timestamp:** 8 November 2026, 03:46:03 IST  
**Purpose:** Extend the existing app into the owner's fully connected, deeply expandable case record. This is a plan based on source and repository evidence, not a claim that the target product has been implemented or verified in a signed application.

**Owner clarification incorporated — 8 November 2026:** The final product must also coordinate a mother case and recursively linked child actions, accept contributions from authorized participants, update the map, and create/route follow-up work through configured automation. One investigator and a genuine multi-user team use the same case/action model. Section 17 specifies this extension. Team contribution and orchestration are required for this expanded final product; the earlier single-user release remains an intermediate scope, not completion of this vision. The source baseline below has not been re-audited at a newer commit for this amendment.

**Final smart-map completion contract — 8 November 2026:** The owner reaffirmed that making investigation easier through the map is the main goal. Section 18 finalizes the bounded usability requirements and the evidence needed to claim that goal is achieved. A fresh branch check still returned 58717ec8; the current plan is finalized for implementation, while the expanded product remains incomplete and its user benefit unmeasured. Workflow and team services support the map; they must not displace it as the investigator's primary working surface.

## 1. Feasibility decision

The owner's central concept is technically achievable: every relevant recorded object can participate in a case graph; any object can open further evidence, questions, work, history and conclusions; the same object can be reached from different branches; and AI can assist without being necessary to maintain the case.

The present app supplies a useful foundation. It now includes a real case-scoped map, stable identities, persisted layout, case search, changes, revision capture, historical checkpoints and checked map exports. This is substantially more than the source reviewed on 6 November. Extend that implementation rather than starting another canvas or rebuilding the ledger.

Combining selected investigation capabilities associated with DataWalk, i2, Casefleet, Maltego and Palantir is achievable. Replicating every feature, connector, deployment model, operational integration and scaling characteristic of all five is a separate, open-ended platform program. A map cannot itself supply those underlying systems or access to external data. No feature-parity claim is established by this review.

The practical objective is one integrated investigation experience with strong native case/evidence/work/history/money capabilities and explicit adapters for specialist tools. Improvement over alternatives must be demonstrated on relevant tasks. Automatic truth, guaranteed case resolution, unlimited hardware capacity and universal file interpretation are not valid completion criteria.

**Recommended decision:** proceed with the recursive case architecture. Treat this as a substantial product extension with several integration milestones, not one final UI patch or an unlimited instruction to an AI coding agent.

## 2. The owner's intended product, preserved without flattening it

The map is the whole working case record. A report is not merely a card linking to a PDF. It can contain its summary, separately addressable key points, source passages, qualifications, questions, examinations, assigned work, results and conclusions. Each of those can expand further, participate in several contexts and connect to other parts of the case.

There is no fixed product depth of three or four levels. Finite traversal, rendering and resource budgets protect the machine without discarding deeper records. Folding affects presentation, not the existence or availability of the underlying information.

The required product contract is:

1. Every authorized case record is reachable through the map or an equivalent linked list/table, with source and state visible.
2. Any eligible record can anchor further investigation: questions, evidence, tasks, observations, decisions and outputs.
3. A record may appear in several branches without creating conflicting copies of its content.
4. Evidence, assertions, investigator observations, AI suggestions and conclusions remain distinguishable. Conflicting accounts can be recorded before anyone resolves them.
5. Each object has its relevant event times and work/revision history; uncertainty and missing times stay explicit.
6. People, organizations, witnesses, investigators, accounts, transactions, assets, documents, recordings and specialist reports participate in the same connected model.
7. Daily work updates the case, and changes identify affected questions, summaries and conclusions without silently rewriting them.
8. An investigation can examine another investigation's records, decisions and available-at-the-time evidence through controlled references.
9. AI proposes useful structure and analysis and can execute explicitly authorized organizational/workflow operations; manual entry, import, search, comparison and review remain complete workflows.
10. A completed case can be understood, reviewed, exported, restored and reopened while retaining its recorded reasoning.
11. A mother case owns recursively linked child actions with responsible people, dependencies, expected results, review and recorded outcomes. Completing work updates the case without automatically declaring its assertions true.
12. Authorized contributions from the investigator, team members and limited external contributors enter a controlled intake, update relevant map objects and trigger configured follow-up work. A single investigator can fill the applicable roles without fictitious team accounts.

This plan extends the 6 November living-map plan and supersedes its narrower treatment of recursive content, money, investigator activity and history. Those capabilities, team contribution and case/action orchestration belong to the core of this expanded final product. The new team requirement supersedes single-user-only as the final target, while preserving a usable single-investigator mode. It does not change pricing, existing entitlements, the AI provider policy or unrelated release decisions.

## 3. What the current app actually provides

I checked the latest branch through GitHub, fetched its source and inspected the implementation at the exact commit above. PR #169 remains open. Its body is stale and still describes 4147e106; use the actual head and evidence files.

The branch is 21 commits ahead of the 6 November review at 68addaa4. CI run 42419808339 completed successfully on 58717ec8, with all seven jobs successful: build-and-test, release-build, migration-matrix, parser-fixtures, sensitive-export, report-receipt-integrity and architecture-guards. This establishes those CI results, not signed-app usability or the new vision's completion.

The latest committed UI record describes a PARTIAL agent walk of the Debug sample app on 7–8 November. It records navigation, source-scoped search, contradiction review, evidence requests, one report export, and map controls/presence. It also records fixes for contradiction identities and overlapping map cards. It explicitly does not close the acceptance-case, consent/plan or all-output-routes checks. No new Mac or signed-app journey was executed for this review.

The execution matrix still contains earlier NOT RUN/uncommitted descriptions. Reconcile it with the later walk and actual commit; do not treat either blanket statement as a substitute for a check-by-check record.

| Area | Current evidence | Extension needed |
|---|---|---|
| Case map | CaseMapProjection/Service project canonical case records into typed nodes and links, with stable IDs, source references, review state and scope boundaries. [C01–C02] | Broaden the projected record inventory and supply object-level investigations. |
| Folding | CaseMapGroup groups nodes by kind plus unlinked material. Filters collapse those groups. [C01, C03] | Nested frames anchored to any object, multiple memberships, cross-links and path-specific navigation/layout. |
| Layout and navigation | Stored positions, new-item placement, saved views, Map/List, inspector, navigation history and explicit re-layout exist. [C04–C05] | Branch expansion, local arrangements, search-to-deep-item navigation and stable multi-context appearances. |
| Map coverage | Every projected item is counted as shown/collapsed/filtered/hidden. [C03] | A separate reconciliation against all relevant canonical case records. Projected-item completeness is not whole-case completeness. |
| Omitted case material | The map snapshot deliberately leaves out contacts, credibility notes, holds, redactions, review batches, conflict checks and the action log for performance. These records exist elsewhere. [C06] | Load these as explicit lazy branches; expose investigator work and governance details through authorized views. |
| Report structure | Evidence/document nodes and report items exist. Current map record kinds have no general report-section/key-point/sub-investigation model. [C01] | Source-linked report sections and key points that can own further work, evidence and results. |
| People and investigators | CasePerson, contacts and interviews exist; InvestigatorProfile is a name/organization for one Mac user; actions store an actor string. [C07] | Stable participant identities, case roles and work attribution; authenticated contribution/collaboration required for the expanded final product. |
| Case work and automation | CaseTaskItem references the existing ProfessionalTask engine and deadlines; CaseAction records case activity. [C07] | A recursive child-action contract, assignment/review policy, authorized contribution intake and durable event processing. An activity-log entry is not an executable child action. |
| Time | Nodes expose recordedAt, eventDate and human-readable history lines. [C01] | Multiple typed time assertions with precision, timezone, intervals, competing interpretations and per-object history. |
| Changes | A case change feed exists; impact analysis lists direct neighbors and a second neighborhood. [C08] | Typed dependency traversal to any relevant depth, with bounded/cancellable queries and review invalidation. |
| History | Schema 173 captures selected record before/after values and records map checkpoints with manifests and digests. [C09–C10] | Extend revision coverage and checkpoint format to all new object kinds, memberships, actor records and summaries. |
| Search | CaseSearchQuery/Matcher/Service and live scope resolution now support case evidence search and coverage. [C11] | Search all new record kinds and navigate directly into their folded context; keep exact and semantic retrieval distinct. |
| Finance | ForensicEngagement/FAMoney provide decimal arithmetic, currency classification, duplicate controls and reconciliation; FundFlowView supplies separate payment-flow views. [C12–C13] | Canonical account/transaction/ownership objects and links in the recursive case graph, with one authoritative calculation path. |
| Historical overlaps | CaseDeconfliction finds other cases mentioning canonical people/organizations/phones/emails and returns titles/stages/counts. [C14] | Explicit authorized cross-case evidence references, additional identifier types, pattern comparisons and review-case links. |
| Audit integrity | AuditChain seals existing event ledgers; CaseRecordRevisions captures selected mutations transactionally. [C09, C15] | Include every new meaningful mutation and distinguish recorded attribution from authenticated activity. |
| Export | CaseMapExport routes frozen PDF/PNG/CSV outputs and evidence tables through CaseOutputService and current protection checks. [C16] | Recursive export manifests and a portable navigable case package with explicit selection boundaries. |

Existing performance evidence is promising but narrow. A synthetic Debug test on an Apple M4/16 GB Mac projected 50,001 records and 47,950 links from 5,000 generated documents; it recorded about 3.56 s cold projection, 0.96 s warm same-service projection, and 646 MiB peak process memory. The measurement identifies base 2108ca5f with then-uncommitted changes, not an exact rerun of 58717ec8. It did not measure real parsing/OCR, signed Release rendering or the deeper graph proposed here. Only about 4.8 MB of generated document text was used. The map's display budget and paged list are not evidence of unlimited case capacity. [C17]

## 4. Combining the five product families

This is a capability plan, not an exhaustive vendor feature audit. The references establish relevant existing capabilities, not their relative quality or IME superiority.

| Product reference | Capability to bring into IME's map | Native core or integration boundary |
|---|---|---|
| DataWalk | Connect disparate records, resolve entities, traverse relationships and financial flows. [V01] | Native case graph and explicit imports first; large enterprise data federation through separately scoped adapters/infrastructure. |
| i2 Analyst's Notebook/iBase | Relationship analysis, temporal views, stored intelligence and clear investigative charts. [V02] | Native exploration, stable layout, graph queries and export; interoperable formats only where implemented and verified. |
| Casefleet | Evidence-linked facts, witnesses, chronology and reviewed AI proposals. [V03] | Native report/key-point workflow and source inspection using existing case services. |
| Maltego | Explore connections across internal data and external intelligence sources. [V04] | Native graph exploration; external enrichment requires configured, permitted data services and recorded retrieval provenance. |
| Palantir Gotham | Connected objects, graph/table/timeline views, change history, dossiers and operational work. [V05] | Native linked case/work/history; concurrent organizational collaboration and deployment are separate engineering packages. |

Do not describe vendor data subscriptions, proprietary formats, forensic acquisition tools or organization-wide deployment systems as obtained merely by adding their names to the interface. Build an equivalent capability or implement an actual supported integration. Keep external tool names out of the product promise unless interoperability was tested.

IME can aim to improve the investigator's journey: less repeated setup, less manual linking, a consistent source inspector, deeper report-to-work navigation, and visible consequences of changes. Whether it succeeds requires task comparisons.

## 5. Architecture: extend the existing ledger and services

Keep the current encrypted ledger and canonical repositories initially. A graph is a data model; it does not require replacing the storage engine with a graph database. Profile actual workloads before introducing another datastore, synchronization system or deployment dependency.

Use four cooperating parts:

1. **Canonical records and revisions:** the source of truth for cases, people, evidence, financial entries, work and decisions.
2. **Graph adapters and relationships:** stable references to those records, typed connections and authorized traversal. New domain records get canonical homes; the graph is not a duplicate copy of every existing table.
3. **Interpretation and work services:** report decomposition, search, comparison, financial calculations, summaries, tasks and AI proposals.
4. **Recursive workspace:** nested frames, links, source inspector, timelines, history, tables and export selection over the same records.

Extend CaseMapSources/Service and the existing output routes. Do not create a fourth competing graph UI or a parallel reporting pipeline. Existing revision fences, generation tokens, case-scope checks and no-write-after-erasure guards must continue to apply to every asynchronous operation.

### 5.1 Required object contracts

Names below are proposed contracts, not claims that these types already exist. Choose final names consistently with the repository.

| Contract | Required content |
|---|---|
| Object reference | Case/context, canonical kind and ID, revision reference, schema version and availability state. Preserve existing CaseMapNodeID identities. |
| Investigation frame | Anchor object, purpose/question, child memberships, work state, result references and saved exploration state. A frame can be opened for any supported object. |
| Membership | Frame, member reference, purpose/order and provenance. This organizes a view; it does not assert a real-world relationship. |
| Relationship assertion | Typed endpoints, direction, relevant period, source references, who asserted it, review state and rationale. Several incompatible assertions can coexist. |
| Report key point | Source report/version, exact locator, text, author/producer, qualifications, extraction provenance, review state and related questions/results. |
| Temporal assertion | Time meaning, original expression, normalized instant or interval if known, timezone/offset status, precision, uncertainty, source and review. |
| Participant and work record | Stable actor ID; person, organization, software or reported external actor; role in this case; assigned/performed/reviewed work; attribution basis. |
| Financial record | Transaction identity and classification, accounts/parties, amount/currency, dates, source references, matching/reconciliation decisions and revisions. |
| Derived summary | Referenced object revisions, included scope, exclusions/coverage, author or model/rule version, generation time, review and staleness state. |
| External/cross-case reference | Origin case/source/version, authorized selection, retrieval/import time, snapshot/live-link behavior and current availability. |
| Child action | Mother case, primary parent, triggering object revisions, question/purpose, expected result, owner/helpers/reviewer, dependencies, state, outcome, automation policy and complete event history. Reuse the task engine; do not confuse this with the existing CaseAction audit-log type. |
| Contribution | Submitter and attribution basis, submission/request ID, captured/received times, original content, scope/access, intake state, source versions and incorporated object references. |
| Automation policy and run | Versioned case policy, permitted triggers/operations, eligible roles, creation/send budgets, idempotency key, dependencies, execution status, recorded effect and failure/remedy. |

### 5.2 Structural rules

- Containment is an acyclic organization of frames; investigative relationships may have cycles. Multiple membership is allowed. Traversal must be cycle-safe.
- A record can appear in several frames without copying its canonical contents. Layout belongs to a view/frame context, not to a second version of the fact.
- Distinguish person identity from a case role. A witness can also be an account holder; a named investigator is not automatically a subject of wrongdoing.
- Preserve incompatible statements and different source dates. Storing a report does not approve its assertions.
- Record missing, unreadable, unsupported and unreviewed material. Never silently omit it from the case inventory because no extraction succeeded.
- Closure is typed: completing an examination is different from answering a question or supporting an allegation. Do not derive truth from the number of completed child nodes.
- Deep nesting has no arbitrary semantic depth limit; operational queries have visible budgets, pagination and continuation. A resource limit must not become silent record loss.

## 6. The core report-to-investigation workflow

This is the first decisive vertical implementation. It preserves the depth of the final vision while providing a testable path.

1. Import a forensic report; preserve the original and processing coverage. A preview/image is a derivative, not a replacement.
2. Create a report frame with author/laboratory, version, relevant dates, material examined and a sourced summary.
3. Extract or manually select key points. Each point has its own stable ID and exact source/qualification. Preserve extraction versions; do not erase hand-edited or reviewed points on re-import.
4. Open a key point as an investigation frame. Add questions, supporting and challenging evidence, observations, assignments and requests.
5. Attach an investigator's examination and its result. The result can be another structured report with its own key points and deeper frames.
6. Link the result to a witness statement, transaction, person or earlier case, with a typed explanation for the link.
7. Record a proposed contradiction or comparison, keeping the two accounts and their context accessible.
8. Record the investigator's disposition, rationale and further work. Keep unresolved items visible.
9. Update parent summaries from identifiable child revisions. Mark summaries stale when their dependencies change; do not silently rewrite a finalized finding.
10. Produce a reviewed case output through the existing export service, preserving the underlying branch and source relationships.

Manual entry must support the whole path. AI speeds extraction and comparison but is not required to create any of these records.

## 7. Time, history, investigator activity and impact

Preserve both the event being investigated and the investigation's own activity. The current recordedAt/eventDate pair is a starting point; it cannot express several competing time assertions or the full lifecycle of every object.

Introduce typed times for occurrence, creation/signing, collection, receipt, import, assignment, performance, review, correction and supersession where relevant. Unknown times remain unknown. Preserve source wording and precision; a date-only record must not become an apparently exact midnight event. Conflicting time assertions remain separate until the investigator records an interpretation.

Every meaningful mutation must write its record revision and work/audit event in the same transaction. Preserve the existing history baseline for older cases. Do not manufacture historical values that were never recorded. Checkpoints are known recorded states; they should not imply an exact state at every arbitrary past instant unless replay coverage actually supports it.

Add participant IDs while retaining original actor strings for migration. For external work entered by the user, record both the reported performer and the person who entered the record. For automated actions, record the software actor and triggering user/context. A display name is not authentication.

Generalize change impact from neighborhood exploration to typed dependencies. A change to a cited report point can affect a comparison, a summary, a finding and a final report several steps away. Traverse dependency edges with cycle detection; report which revisions became stale. Mere social/mention adjacency should not invalidate an unrelated conclusion.

Parent summaries should show counts and links to unresolved, challenged, changed or awaiting-review items. Never average confidence scores or translate branch completion into probability of guilt or truth.

## 8. Financial case records are core

Reuse the existing financial arithmetic and reconciliation code after reviewing its assumptions. Connect it to the case graph instead of maintaining an independent map-calculation engine.

Required records and behavior:

- Accounts, owners/controllers with relevant periods, transactions, invoices/claims, assets, counterparties and source statement lines.
- Exact stored amounts with explicit currency and precision; display formatting must not change stored values or assume every currency uses two decimal places.
- Distinguish an amount mentioned in a document from an actual movement. Classification remains explicit.
- Preserve all source occurrences and distinguish repeated documents from distinct economic transactions. Matching needs evidence; identical amounts alone do not justify merging.
- Separate paid, received, returned/reversed, outstanding and disputed figures. Internal transfers and multi-step paths must not inflate totals by counting the same funds at every hop.
- Reconcile by account, period and currency; expose missing periods, unclassified items and differences.
- Display the assumptions behind tracing allocations. A path between accounts does not by itself establish that particular funds traversed it.
- Open every displayed figure to its contributing transactions and original evidence. Mark partial or filtered totals explicitly.

The standalone Fund Flow screen uses corroboration-related ribbon language as well as money views. Reconcile this in the integrated map: label whether a visual weight means amount, count or evidence state, and never imply that thickness proves a transaction.

Specialist forensic accounting methods, large bank connectors and specialized asset analytics may remain optional capabilities. The ability to record and follow ordinary source-linked money within a case is core.

## 9. Historical cases and investigation of an investigation

Reuse CaseDeconfliction for its existing entity-overlap signals. It currently exposes other case names/stages/counts rather than their underlying passages. Preserve that boundary until explicit cross-case access is implemented.

Add two separate workflows:

**Historical comparison:** compare authorized past material by exact identifiers, time sequences, roles, amounts and optional semantic similarity. Show the matching basis and important differences. Record a candidate match independently of a reviewed same-person decision. AI memory alone is not a source.

**Review case:** create a separate case that examines selected records, actions or findings from another case. References pin the reviewed version or explicitly follow later changes. The review case owns its own questions and decisions. It cannot mutate the original findings simply by reviewing them.

Cross-case links must not bypass current same-case write checks. Introduce an explicit reference/authorization boundary or an authorized frozen package. Recheck permissions, privilege and availability when reading, summarizing and exporting. Counts, hidden-node labels and AI summaries must not leak inaccessible records. Erasure or changed access leaves an appropriate unavailable/redacted reference rather than a retained secret copy.

## 10. AI assistance and automatic configuration

Automatic configuration should initialize a useful structure from the actual supplied data, preserve the user's organization and state what could not be determined. It can apply allowed presentation and work-routing changes under a versioned case policy. It should not automatically merge people, decide credibility or make unsupported case conclusions. Section 17 defines how automatic action creation differs from accepting an interpretation.

The assistant should use constrained case tools to search, inspect sources, propose report points, suggest connections, compare timelines, draft summaries and suggest follow-up work. Proposed changes are structured records with source references and dependencies, not free-form commands executed against the ledger.

Required behavior:

- Interpretive suggestions may appear immediately in an identifiable proposal layer. Accept, edit, reject and defer are explicit, recorded actions. Pre-authorized layout, organization and action-routing changes can run without a separate approval dialog each time; record the policy and effect, and preserve undo/history.
- Ingestion can record conflicting statements without a truth decision. Proposal approval governs the assistant's interpretation, not whether the original source is preserved.
- Each important proposed claim/link identifies supporting passages or is labelled an investigator/model hypothesis without documentary support.
- Recheck case scope, permissions and source revisions when applying a proposal. A result from an earlier case, consent state or document revision cannot write into the new state.
- Reuse current provider, consent, masking, failure and injection controls. Case data cannot grant a model new tools or permissions.
- Use change-driven processing and explicit analysis jobs. Do not resend the whole case on every pan, expansion or keystroke. Cache by authorized scope and source revisions, with budgets and cancellation.
- Preserve human edits and decisions when regenerating a branch. Record model/version, scope and relevant generation provenance without putting sensitive content into ordinary logs.
- Distinguish possible contradiction, apparent difference and investigator-reviewed conflict. Compare entity identity, time period, units, currency, context, source dependence and later corrections.

The map should work fully in Private mode. AI may improve speed and discovery; its actual benefit and error/correction burden must be measured.

## 11. Navigation, performance and complete reachability

Extend the existing workspace rather than substituting a small fixed dashboard for the owner's full structure.

- Open any eligible node into a frame with a summary and all its relevant branches. Preserve cross-links to objects outside that frame.
- Maintain breadcrumbs, Back/Forward and a return-to-case control. Restore selection, zoom, folds and source position after restart.
- Add a local timeline and activity/history view to each object. A case-wide timeline remains available as an aggregation.
- Support simultaneous inspection of competing accounts. A user should not need to memorize one passage while opening the other.
- Preserve existing positions during normal updates. Place only new appearances; make rearrangement explicit and undoable.
- Show folded counts and unresolved/changed indicators. Count unique records separately from appearances so multi-membership does not inflate totals.
- Search across folded content and open the exact result in context. Filters and pagination must not make material disappear from coverage accounting.
- Keep keyboard, accessible outline and table views equivalent to spatial actions. Help should explain the selected item and action in context.

Do not load every large branch to draw the first screen. Add indexed adjacency queries, paged child loading, summary caches, incremental invalidation and viewport rendering. Distinguish stored case size, loaded graph size and drawn items. The current model-level stress benchmark is a baseline, not permission to claim the deeper system scales indefinitely.

Proposed engineering targets, to validate on named hardware: ordinary cached branch expand/collapse and focus navigation p95 under 200 ms; warm initial case overview under 1 s on the defined normal fixture; no unintended movement of existing pinned items; full coverage accounting and reachability at the published stress workload. Record misses honestly and set a separate cold-load target after profiling the new schema. These are targets, not measured results.

## 12. Implementation packages and dependencies

Each package must deliver working behavior, migration handling and evidence. Proposed names are implementation guidance; extend existing equivalents where appropriate.

| Package | Main work and existing entry points | Exit evidence |
|---|---|---|
| R00 — baseline and inventory | Reconcile PR/matrix/walk/CI records. Inventory every case record and every job-output type with its canonical owner, current map adapter and missing path. Start from C01–C07 and the capability inventory. | Every record class accounted for as reachable, deliberately excluded with reason, or remaining work. Exact branch/build recorded. |
| R01 — record and relationship contracts | Extend CaseMapNodeID/RecordKind, source locators and versioned references; add missing report points, frame membership, participant and temporal records in new migrations. | Existing IDs/deep links survive; new records enforce ownership, revisions, erasure and backup rules. |
| R02 — recursive map frames | Extend CaseMapGroup, layout/filter/model/canvas/inspector. Add arbitrary nested frames, multiple membership, cross-links, paged expansion and persisted local navigation. | A deep branch and cyclic cross-links remain usable; no copied facts, lost links or unrelated node jumps. |
| R03 — report/key-point/work loop | Add a report adapter and point editor, sourced summaries, questions, recursive child actions, examinations and result attachments. Reuse the task engine and CaseFile/Studio services; include owner, expected result, dependencies and outcome. | A report point produces assigned further work, a new report and a deeper point, all navigable back to originals without AI; work completion does not silently resolve the originating question. |
| R04 — complete histories and dependency impact | Extend temporal records, CaseRecordRevisions, CaseHistoryRepository, AuditChain and CaseChangeImpactAnalysis. | Per-object event/work timelines; revision-bound summaries; a deep source change flags every affected derived result without rewriting decisions. |
| R05 — people and investigator work | Extend CasePerson/contact/interview adapters and InvestigatorProfile migration to participant IDs; expose assignments, work and reviews. | Witness and investigator histories are reachable; recorded external work is distinct from authenticated actions; actor renaming does not rewrite history. |
| R06 — financial graph | Adapt ForensicEngagement/FAMoney/FundsTrace to canonical accounts, transactions, ownership and source records. | Correct transaction identity, per-currency totals, refunds/transfers/reconciliation and source drill-down in the same recursive map. |
| R07 — historical and review cases | Extend CaseDeconfliction with explicit authorized comparison and pinned review references. | A review case reconstructs selected prior decisions without broadening source access or altering the original case. |
| R08 — AI-assisted graph operations | Extend current AI routes with constrained read/propose/apply operations, dependency tracking, proposal review and policy-controlled action creation/routing. | Grounded proposals and authorized workflow operations survive revision checks; failure, changed consent/scope and malicious document instructions cannot cause unauthorized writes/sends. |
| R09 — closure and portable case output | Extend CaseMapExport/CaseOutputService to branch/case selection, recursive manifests, source tables and a navigable read-only package. | Recipient can inspect permitted branch detail and sources offline; restrictions, missing originals and exclusions are explicit; restore round-trip verified. |
| R10 — specialist imports and connectors | Add adapters for chosen forensic/financial/media exports and external historical sources, with format/version contracts. | Each advertised adapter passes representative fixtures, malformed/unsupported cases, provenance and round-trip checks where applicable. |
| R11 — actual team collaboration | Required for the final team-capable product: authenticated identities, case/record authorization, role bindings, assignments, conflict handling, synchronization and permission-aware audit. Design these boundaries during R01/R05. | Two distinct users cannot impersonate each other or read forbidden records through graph, history, AI, counts or export; revocation, offline/concurrent edits and single-person mode tested. |
| R12 — product verification | Real-data intake, deep graph tests, signed Mac journeys, performance, accessibility, recovery and comparative task evaluation. | Candidate-specific evidence separates automated service checks, observed UI, signed-build checks and measured benefit. |
| R13 — durable case/action orchestration | Extend the one task engine with versioned team/action templates, event/outbox processing, recursive dependency checks, idempotent trigger handling, bounded automatic creation, routing, reassignment and outcome roll-up. | Duplicate events produce one logical action; no endless child generation; authorization is rechecked on execution; returned work updates its parent and affected branches without manufacturing conclusions. |
| R14 — contributor intake | Build authorized team submission and narrowly scoped external request/upload intake; preserve provenance, review/include decisions, processing coverage and receipts. Connect accepted contributions to R13. | Two contributors can return work to the same case safely; an external contributor cannot browse the case; delayed, duplicate, malformed and rejected submissions remain correctly accounted for. |

R00 → R01 → R02/R03 is the critical foundation. R04 and R05 extend the same contracts. R06 and R07 follow once identity/revisions are stable. R08 builds on those records rather than creating its own truth store. R09 and R12 apply throughout, not only at the end. R10 is delivered adapter by adapter. Design R11 authorization and synchronization contracts with R01/R05; implement a local R13 action loop after R03, then connect authenticated R11/R14 contributions. Final integrated acceptance requires R11, R13 and R14. Representing several people's recorded work on one Mac can precede them, but is not team collaboration.

Apply Section 18's SM-01–SM-10 user-experience contract across these packages. It does not add another standalone product or task system. Implement the orientation, branch navigation and exact-source path with R02/R03, before expanding automatic action generation. Carry the complete map experience through the existing packages and measure it under R12.

Do not schedule a precise completion date from a code count. Finish the first report-to-deep-investigation path, measure the actual implementation and correction effort, then estimate the remaining packages by complexity and dependencies. This is likely several release-sized increments. An agent can implement substantial portions, but code generation is not a substitute for actual source access, data-service credentials, signed hardware checks or human usability evidence.

## 13. A representative acceptance case

Use a fictional supplier-payment investigation with known source records and an explicit expected-answer ledger. Extend the existing acceptance fixture instead of replacing its established checks.

The case contains an invoice, two distinct payments, a refund, an account ownership document, a witness interview, a digital-forensic report, an amended report, an earlier case mentioning the same account, and investigator work records. Include a near-identical unrelated person's name and a source with an uncertain timezone.

Required journey:

1. Start with mixed PDF/Office/email/CSV/scanned material and an unsupported attachment. See intake coverage, preserve originals, retry a failed scan and keep the unsupported attachment represented.
2. Open the forensic report and navigate its sourced summary and individual key points.
3. From one key point, create a question, an assigned examination, a result report and a further point. Continue through at least six levels in the journey; stress fixtures also exercise much deeper nesting without a semantic limit.
4. Link the same witness and transaction from separate branches. Editing the canonical record updates both appearances while preserving revisions.
5. Compare the witness statement with a report point. Record a possible conflict, supporting and contrary material, follow-up work and a reasoned disposition.
6. Trace two INR 50,000 payments and an INR 50,000 refund to their sources. Show INR 100,000 gross paid, INR 50,000 returned and INR 50,000 net outflow for this fixture; do not label net outflow as proven loss. Duplicate source copies do not create extra payments.
7. Open the historical same-account signal, inspect the authorized comparison and reject the unrelated same-name person match.
8. Inspect an investigator's work and distinguish reported examination time, entry time and review time.
9. Import the amended forensic report. Preserve original points and decisions, identify changed points, flag dependent summaries/findings several levels away, and keep unrelated branches stable.
10. Create a separate review case examining the earlier finding and the information available at that checkpoint.
11. Close with unresolved matters explicitly recorded, export the chosen recursive record, restore on a clean profile and reopen to the same case context.
12. Repeat the workflow with AI off; then enable AI for the permitted scope and measure time saved and correction effort separately.
13. Repeat with a lead investigator, financial examiner and limited external contributor using separate identities. Return a statement through intake, generate one contradiction action, route its children, submit results, request revision and accept an outcome. Repeat in single-person mode with honest self-review attribution. Exercise duplicate events, revoked access, offline edits and the automatic-creation budget.

Add distinct cases for a workplace dispute and a historical/documentary investigation so financial assumptions do not become mandatory in every case. Use each supported persona's actual work products and terminology where advertised.

## 14. Verification requirements

| Concern | Meaningful check |
|---|---|
| Whole-case reachability | Reconcile canonical inventory with reachable objects and explained omissions; include currently omitted contacts, actions, reviews and studio outputs. |
| Identity and membership | Re-import, rename, re-order and multi-membership preserve IDs; same-name people stay distinct unless a recorded identity decision links them. |
| Deep/cyclic structure | Deep containment, many memberships and cyclic relationships terminate safely; pagination and fold counts remain correct. |
| Representation | Exact passage/row/message/timestamp navigation and native-original availability are checked; summaries preserve qualifications and unresolved alternatives. |
| Source/record revisions | Old citations keep their version; changed sources invalidate appropriate dependencies; stale async work cannot overwrite current human edits. |
| Time | Date-only, intervals, unknown timezone, conflicting times and later corrections preserve their meanings. |
| Money | Two real equal payments, copied source records, returns, fees, internal transfers, different currencies and missing periods produce correct labelled results. |
| Cross-case access | Links, search, history, aggregate counts, AI and exported packages all respect the current authorized scope. |
| Work attribution | External reported actor, actual recording user and software actor remain distinguishable. Team authentication tested separately when implemented. |
| Orchestration | Retries/duplicate events create one logical action; cross-branch dependencies do not deadlock; assignment respects access and role; revoked/erased/closed state is rechecked; bounded runs cannot generate endless children. |
| Contributions | Trusted and external submissions preserve attribution and originals; only approved scope enters the case; requests, rejected material, duplicates and partial intake have explicit receipts. |
| Erasure and holds | New records, graph caches, summaries, checkpoints and attachments follow erasure/hold rules; background jobs cannot resurrect erased content. |
| Export and recovery | Freeze complete selected dependencies, verify written output, preserve usable links, disclose omissions and round-trip through restore. |
| Accessibility | Keyboard/list users can perform the same substantive actions and reach the same deep records as spatial-map users. |
| Performance | Measure source ingestion, projection, rendering, branch expansion, updates, search, memory and restore separately on named hardware and builds. |
| User benefit | Compare realistic tasks against the current app and a familiar baseline, including setup, map maintenance and correction time. Measure source-finding errors and omissions alongside time. |

Current owner release policies remain authoritative; this plan does not silently restore previously removed approval gates. However, claims that the new map is easier or better than alternatives require actual comparative evidence. Successful compilation, green CI or an attractive screenshot cannot establish that claim.

## 15. Scope, risks and completion definition

### Required core for this vision

Recursive frames; complete source-linked case records; report key points and subsequent work; people/witness/investigator context; time and work history; basic money tracing; controlled historical comparisons and review-case references; manual and AI proposal paths; change impact; searchable/accessible navigation; checked export, recovery and closure. The expanded final scope also requires mother-case/child-action orchestration, editable team templates, authenticated participant contributions and policy-controlled automatic organization/routing, alongside complete single-person operation.

### Additional capabilities

Large enterprise data federation, paid intelligence feeds, specialist forensic acquisition/decoding, advanced AML/accounting algorithms and organization-wide deployment can be optional integrations or later products. Preserve the ability to attach and inspect their supplied results in the core. Basic case-team collaboration is now required for the final vision; a single-user recursive release may be an intermediate milestone, not the completed team product.

### Main risks and response

- **Duplicate truth stores:** use adapters and canonical references, not copies of the same case data in map JSON.
- **Graph explosion:** indexed lazy traversal, folds, stable local layouts and explicit continuation, without hiding coverage.
- **Wrong inferred links:** retain provenance and separate proposals from reviewed assertions; preserve contradictions and identity uncertainty.
- **History gaps:** extend transactional revisions from the beginning and state migration baselines honestly.
- **Cross-case disclosure:** authorize at query/apply/export time, including metadata and summaries.
- **AI maintenance burden:** measure corrections and use explicit, change-driven work rather than continuous whole-case regeneration.
- **Undefined parity:** maintain a bounded capability matrix and validate each advertised behavior. Do not claim all features of five vendors were reproduced.

The expanded product is complete for a stated release scope when the agreed record types and workflows are reachable through the recursive map; the report-to-investigation loop works at depth; histories and dependencies remain correct across changes; money and cross-case references are traceable; manual use is complete; and the actual candidate passes the corresponding verification evidence.

An investigator's final approval records a reviewed conclusion and its reasoning. It is not a guarantee of universal truth. The system's strongest promise is faithful representation, connected context, inspectable work and conclusions that can be revisited.

## 16. Immediate instructions to the implementation agent

Read this plan alongside the latest source and owner decisions. Start from 58717ec8 or record the newer head you actually use. Preserve uncommitted work. Do not treat the old PR body or old execution-matrix status as the current baseline.

First deliver R00–R03 as a working vertical path: inventory, compatible record contracts, recursive frames and a forensic-report point that produces further investigation and another report. Include actor/time/revision fields in that foundation so later work does not need a destructive migration. Keep the existing map behind its preview mechanism until its relevant candidate checks are actually complete.

Then complete R04–R09 for the core vision and the specifically advertised parts of R10. Design R11 identity/access boundaries early and complete R11/R13/R14 for the final team-and-action vision described in Section 17. Carry R12 checks throughout. Every package's completion record must name code, candidate SHA, migration, service tests, observed UI path and remaining limitations separately. Update the source's scope/decision records to reflect this newer owner direction when implementing it; do not claim that the old single-user contract already includes collaboration.

Do not reduce the target back to a fixed overview, a single-level entity chart or links to disconnected studios. Equally, do not satisfy the request by adding a node type without making its contents, sources, work, history and deeper relationships usable.

## 17. Mother case, child actions and the investigation team

### 17.1 Product meaning

The mother case is the persistent container for the investigation's purpose, scope, people, evidence, questions, work, decisions and outputs. A child action is a unit of work anchored to a question or case object. Its result can update several branches and justify additional child actions. Each action remains traceable to the mother case, the initiating question and the source revisions that triggered it.

This is feasible. It adds an operational engine beneath the map: accepted contributions and recorded changes lead to appropriate work; completed work returns evidence and results; those results update the map and the next steps. The map is the investigator's visible interface to that engine.

The system can organize and progress the work automatically within configured authority. It cannot guarantee that a witness responds, unavailable evidence appears, conflicting accounts can be resolved, or a case reaches a certain conclusion. Keep genuine unknowns and exhausted lines of inquiry visible. Completion of all assigned tasks is not a proof that the case is solved.

An action is not a separate child case by default. Create a distinct linked case only where separate scope, permissions, retention or independent review requires it. Ordinary examinations, contradictions and follow-ups stay in the mother case. A shared action can contribute to several questions through links while retaining one canonical identity and one responsible owner.

### 17.2 Editable investigation-team structure

Provide templates that bind responsibilities to actual people. Start with a compact general-investigation template; let the owner add specialist roles or combine them. Templates assist configuration and do not impose a fixed hierarchy or a mandatory headcount.

| Role | Responsibility | Assignment/access rule |
|---|---|---|
| Case lead | Defines scope, work policy, priorities and case disposition. | One accountable lead by default, with recorded delegated authority where needed. Lead does not imply unrestricted access to every protected compartment. |
| Investigator/action owner | Performs assigned interviews, checks, collection and analysis. | Each action has one accountable owner; helpers may be added. Access must cover the required inputs. |
| Specialist | Performs a defined financial, digital, forensic or other examination. | Route by declared capability and authorization, not an AI guess about a person's expertise. |
| Evidence coordinator | Handles intake, source identity, processing failures and inclusion decisions. | Can be the lead or an investigator; intake authority does not confer authority to decide every finding. |
| Reviewer | Reviews a submitted result and records acceptance, return or disposition. | Separate identity where required by case policy; optional self-review in solo mode is labelled as such. |
| External contributor | Returns an assigned statement, document or specialist result. | Access only to the specific request and permitted shared material; no general case browsing or team powers. |

Case participants, people appearing in evidence and authenticated application users are different concepts. A witness may submit material without becoming an investigator. A person named in the case need not have an app account. Register reported external work with both the claimed performer and the authenticated person who recorded it.

In single-person mode, bind the applicable internal roles to the same investigator, omit unnecessary team setup, and preserve the same action/history model. Do not create fictional independent reviewers. If a case's own policy requires independent review and none is available, show that specific unmet requirement; do not invent completion.

Team membership and role changes are versioned. Departure or access revocation transfers pending ownership through an explicit rule and invalidates queued operations that are no longer authorized. Existing history retains the original actor identity. Names and email addresses alone are not authentication.

### 17.3 One complete child-action contract

Build on the existing ProfessionalTask engine. Do not introduce another disconnected task list or reuse CaseAction, which currently means an activity-log record, as an ambiguous executable task type.

Every child action needs:

- Stable action ID, mother-case ID, optional primary parent action, and links to all affected objects/questions.
- Action type and a specific question/purpose, with trigger provenance and source revisions. Examples: inspect an apparent contradiction, obtain missing records, verify an identity candidate, reconcile payments, conduct an interview, examine an artifact, review changed evidence or prepare an output.
- Expected deliverable and completion/review criteria. “Investigate further” alone is insufficient.
- Accountable owner, optional helpers and reviewer; required capability/access; assignment reason and reassignment history.
- Priority, target date and its basis, dependencies, blocked reason and remedy. AI must not manufacture a legal deadline from a generic template.
- Work state, review state and substantive outcome as separate values.
- Input/output references, revisions, event history, automation provenance and cancellation/supersession reasons.

A useful work lifecycle is proposed → ready/assigned → in progress → submitted → accepted/completed. Waiting and blocked states retain their reason. Review can return work for revision; cancellation, supersession and reopening are recorded transitions. Avoid forcing all action types into identical completion criteria.

Outcome is separate: for example, discrepancy explained, contradiction remains, evidence unavailable, no relevant result, hypothesis challenged or further work needed. A completed interview can leave a contradiction unresolved. Accepted results update the relevant branch's recorded outcome; they do not silently convert every source assertion into a fact.

Parent ownership must be acyclic, and scheduling dependencies must reject cycles that make work impossible. Investigative relationships may still contain cycles. One action used by several branches must not be counted or executed several times because it has multiple map appearances.

### 17.4 Contribution-to-action processing

Implement this sequence through the existing case services and the new R11/R13/R14 boundaries:

1. **Receive:** preserve the original contribution, submitter, attribution basis, request ID and received time. Authenticate internal users; use narrowly scoped external submissions. Show whether a sender identity was verified or merely reported.
2. **Inspect and include:** check access, case scope, format, processing coverage, duplicate identity and applicable inclusion policy. Unknown or external material can enter a review queue. Preserve the existing auditable “Review new documents” boundary; automation may execute a specifically authorized inclusion policy, not bypass scope review silently.
3. **Represent:** add accepted canonical records and map appearances. Link new versions to old ones. Keep unreadable/unsupported items visible with processing remedies. Quarantine or rejected material follows its access/retention policy and is not treated as included evidence.
4. **Analyze changes:** evaluate deterministic rules; if enabled and authorized, run AI on the permitted changed material and relevant context. Create sourced summaries, relationship candidates and possible issues without overwriting reviewed work.
5. **Plan work:** reuse an existing action where the same issue is already being examined; otherwise create a proposed or policy-authorized child action with a concrete deliverable.
6. **Assign:** apply the case's routing rules. Show the selected owner and why. If no eligible owner exists, put it in a visible unassigned queue with the remedy rather than guessing or silently granting access.
7. **Return results:** attach submitted work and sources to the action and its affected branches. Review according to the action policy. Update summaries, dependency state and follow-up suggestions from the accepted revisions.
8. **Continue or stop:** create further work only when a new, recorded condition justifies it. Leave unresolved questions open, or close a line with its outcome and rationale. A closed case receives new material in a pending intake/reopen workflow instead of being silently rewritten.

People may contribute at different times and from different devices. “Live” means changes converge promptly when connected; offline contributions show pending/sync state. Conflicting edits to evidence, decisions, assignments and reviews cannot be silently resolved by last-write-wins. Define record-specific merge and conflict behavior, and preserve both versions when human resolution is needed.

### 17.5 What automation is allowed to do

Give each case explicit, versioned automation settings. Provide three usable modes: manual, suggestions, and configured execution. Automation settings are separate from permission to send document content to an AI provider. Manual mode and local deterministic rules remain useful with AI off.

| Operation | Intended behavior |
|---|---|
| Create map items | Automatically represent included records and their source identity. AI-extracted statements remain identified as extractions/proposals until their required review. |
| Configure/fold the map | Apply the chosen template and reversible local grouping; preserve pinned layout, manual organization and current focus. Collapsed branches show new/changed/blocked counts. |
| Relate records | Apply structural links such as “submitted for action” or “source of extraction.” Show inferential links, uncertain identity and suggested contradictions with their status and basis. |
| Create child actions | Rules can create actions under the case policy. AI may propose or create an explicitly permitted action type, with a trigger and expected result; creation does not approve its underlying suspicion. |
| Assign work | Choose only among eligible authorized participants under the routing policy; allow designated-person overrides. Log why it selected the owner. |
| Produce summaries | Generate source/revision-bound summaries, disclose missing coverage and mark affected summaries stale after changes. Reviewed/final text is not silently replaced. |
| Decide substantive findings | Require the relevant investigator/reviewer decision and rationale. An AI confidence score or completed-task count is insufficient. |
| Contact people or disclose material | Use a separately configured communication authorization and permitted recipients/content. Assigning an internal action must not implicitly contact a witness, send a report externally or widen access. |

After capability and access checks, routing can use explicit designation, specialization, conflicts of interest, availability, existing ownership and workload. Display its reason; do not choose owners based on opaque personality scores. If policy permits automatic assignment, do not ask for a repetitive confirmation for every routine assignment.

Automatic folding should expose what changed while keeping the case readable. Preserve the user's spatial memory, make organization undoable, allow “show all new items,” and never let a fold conceal a blocked obligation or unresolved contradiction from the relevant summary.

### 17.6 Durable execution and bounded growth

The workflow engine needs more than model prompts:

- Commit domain changes and their pending workflow events atomically. Deliver events through a durable queue/outbox; resume after crashes and expose failed runs with retry/remedy.
- Assume events may be delivered more than once. Idempotency keys include the originating event/revision, rule/policy version and action purpose, so retries have one logical effect. Separate exact duplicate prevention from human review of merely similar actions.
- Recheck case state, permissions, consent, source revisions, holds and erasure generations immediately before applying changes or sending data. Cancellation and revocation invalidate pending work.
- Track causation and correlation. Prevent an AI-generated summary from repeatedly creating the same issue or an action from endlessly spawning equivalent children.
- Give automatic runs visible budgets for new actions, compute, provider spend and external requests. A budget stop leaves work pending with a reason. This is not a fixed maximum depth for manually created investigations.
- Trigger follow-up from material new evidence or a recorded condition, not every cosmetic edit, map pan or repeated model opinion. Debounce related updates and process affected branches.
- Record template, rule/model, policy and input revisions for every automatic operation. Retain the effect and rationale without leaking case text into ordinary telemetry.
- Preserve existing erasure, legal-hold, backup and no-resurrection guarantees across queues, cloud copies, submissions, indexes and caches. Restoring a backup must not replay completed assignments or resend old external requests.

Remote intake and team synchronization require an actual shared service or supported collaboration infrastructure. A local-only Mac cannot receive live remote contributions while offline without some receiving infrastructure. Choose deployment, encryption/key access, availability and notification boundaries explicitly. Reconcile the data-flow inventory and product privacy statements when those flows are implemented; they are not covered by the old single-user description.

### 17.7 Representative branch and acceptance evidence

For the supplier case, a witness says one payment was made, while two distinct bank entries appear. The system creates a **possible discrepancy** linked to both sources. It checks whether an existing action already covers it, then creates a child action: “Determine whether the second entry is a separate settlement, reversal or duplicate representation.”

That action has financial and interview children. The financial examiner supplies transaction references and reconciliation; the investigator records the witness's response. A refund found during examination creates a further verification action if required by policy. The resulting evidence updates every affected appearance and marks the earlier summary for review. The reviewer may conclude the entries have been explained, that a contradiction remains, or that evidence is insufficient. None of those outcomes automatically proves wrongdoing.

Run the branch end to end with AI off, suggestions enabled and configured execution. Then test it with three separate identities and with one investigator filling the applicable roles. Required checks include:

1. An external contributor can return material to the assigned request but cannot browse the case or infer protected record names/counts.
2. One contribution delivered repeatedly creates one original submission and one logical trigger effect; two genuinely different payments are not merged because their amounts match.
3. Routing chooses an eligible person, explains the decision, respects a manual override and queues unmatched work visibly.
4. Child results update the correct mother case and all relevant branches. Cross-case IDs, stale replies and erased-case results are rejected or safely accounted for.
5. A completed task can leave its question unresolved; independent review is not fabricated in solo mode.
6. A source amendment makes the right derived results stale and generates no duplicate investigation storm. Closed-case amendments enter the explicit reopen/intake path.
7. Revocation, offline concurrency, retry after crash, unavailable AI, denied consent, insufficient budget and restore do not leak data, lose work or repeat external effects.
8. The map shows pending, blocked, new and review-required work inside folds; accessible list/table users can do the same work.

Record correctness, time to find the next action, missed/unassigned obligations, assignment corrections, duplicate-action rate and time spent maintaining the map. These establish whether orchestration makes the investigation easier. Passing them is different from claiming that the case can solve itself or that all accepted conclusions are certainly true.

## 18. Final smart-map contract: make the investigation easier

### 18.1 Honest status and the product promise

The vision is coherent and feasible. The current code has not achieved the complete vision. The branch was checked again for this finalization and remained at 58717ec8. The existing map, search, source inspector, changes/history, task services, contextual help and partial Debug walkthrough are a foundation. They do not establish that recursive report-to-work investigation, authenticated contributions and action orchestration are complete, or that investigators work faster with fewer omissions.

Finalize this promise for the target product:

> From one connected case map, an authorized investigator can understand the recorded case, inspect the basis of any claim, follow any branch to its detail, identify unresolved matters, perform or assign the next work, and see how new results change the investigation.

Every material feature must serve that promise. The full model retains the user's complex, multi-level case: reports, people, transactions, source details, work, history and further branches. The display selects what to expose at a given moment without flattening or discarding that structure. A map overloaded with equally prominent items can increase investigation effort even when its data model is complete.

### 18.2 The questions the map must answer

The opening view and any selected branch should make these questions answerable through concise, linked information:

1. What is being investigated, and what is this branch about?
2. What is recorded or currently concluded, and what is the evidence for it?
3. Which accounts conflict, what is uncertain, and which relevant material is missing or not yet examined?
4. Who and what are connected, in what way, at what time, and on what basis?
5. What changed since the investigator last reviewed this part of the case?
6. What work matters next, why, who owns it and what is blocking it?
7. How was the current position reached, and what would need revisiting if an input changed?

Show a compact case/branch brief with exact links into the map. Use explicit states and a manually editable summary when AI is off. With AI on, keep generated summaries source-linked, revision-bound and visibly stale after relevant changes. Do not force investigators to interpret a bare graph before they can orient themselves.

### 18.3 Required improvements and observable completion

These are required extensions or acceptance requirements, not claims that every underlying control is missing. Reuse the source inspector, saved views, changes/history and help already implemented.

| ID | Investigator need | Required behavior | Observable acceptance |
|---|---|---|---|
| SM-01 | Understand the case quickly | A sourced case/branch brief shows purpose, current position, unresolved questions, recent material changes and next work. Distinguish source statements, reviewed findings and uncertainty. | A newcomer can explain the main issue and remaining uncertainty without opening every document; each factual brief item opens its basis. |
| SM-02 | Explore complete detail without losing context | Recursive frames, semantic zoom, breadcrumbs, pinned context, Back/Forward and exact return position. Search can reveal a deeply folded result directly. | Navigate report → point → examination → result → further point and back; preserve all levels and cross-links without duplicating canonical records. |
| SM-03 | See the same case from different perspectives | Extend the manual view strip with relevant Questions, People, Evidence, Money, Time, Work and Changes/History views. Share canonical selection and scoped filters; allow saved views and user ordering. | Switching perspective retains the same selected object/context; totals and source identity agree between map, list, table and timeline. No forced automatic carousel. |
| SM-04 | Understand and verify a relationship | Selecting a node or link explains its type, direction, time, source, author, review state and uncertainty. Open the exact passage, row, region or media time where supported. | Inspect the basis of a relationship and return to the same position; unknown, unsupported and unavailable locators are explicit. A path does not imply causation, independence or wrongdoing. |
| SM-05 | Examine conflicting and alternative accounts | A comparison workspace puts both accounts and their source context beside each other; compare relevant identities, dates, amounts, units, qualifications and dependent sources. Attach alternative explanations and child actions. | A date difference, copied report, reversal or same-name person does not silently become a proven contradiction; disposition retains both original accounts and the investigator's rationale. |
| SM-06 | Notice changes and their consequences | “Since my last review” links to new/changed records and dependent summaries, questions, findings and actions. Separate unread activity from substantive review required. | An amended report exposes the changed point and all affected dependencies, including folded ones; unrelated branches remain stable and original decisions remain inspectable. |
| SM-07 | Know what is missing and what to do next | Explicit evidence gaps, unassessed questions, pending intake, failed processing, unassigned work and blockers connect to actionable remedies. Recommend next work with a reason based on deadlines, dependencies and investigator-set priority. | One action can be started, assigned, deferred or dismissed with a reason in context. No generic “analyze more” task, opaque guilt score or suggestion that unsearched material does not exist. |
| SM-08 | Keep the map current with little maintenance | A single contribution updates its canonical record and all appearances; preserve manual organization, layout and review decisions. Allow correction/undo of automatic organization and identity proposals. | No repeated typing/copying between map, task, chronology and report; duplicate events do not create extra records or tasks. Measure correction and map-maintenance effort. |
| SM-09 | Learn the workflow and use it accessibly | Start with a question, file or existing case; use an optional worked sample, contextual help, hover/focus explanations, keyboard commands and equivalent outline/table controls. Advanced details expand locally. | A new investigator completes the sample without coaching; keyboard users can complete the same substantive journey. Familiar controls reveal depth instead of requiring a separate “expert” product. |
| SM-10 | Hand over, review and conclude the case | A navigable briefing path or manually stepped sequence links the current conclusion, evidence, unresolved work, changes and decision history. A frozen permitted package preserves that structure for recipients. | A second investigator can take over and locate the reason for a finding, its source and outstanding actions; export/restore preserves usable references and disclosed scope. |

Do not replace the full map with the opening brief. The brief is an entry point into the complete record. Likewise, a manually curated briefing sequence is a view over the graph, not a fixed linear structure imposed on the investigation.

### 18.4 One coherent workspace

Use a stable workspace with a case identity/scope header, question/branch navigation, the map, a source/detail inspector and an optional time/change panel. Those are presentation regions, not limits on nesting. On smaller windows, collapse panels while preserving access and context.

Selecting a node should expose the same predictable actions: inspect evidence, compare, add/link material, open deeper work, create/assign an action, and review history. Show only applicable actions and explain unavailable actions with the remedy. Reuse the current services rather than sending investigators through disconnected studios and making them reconstruct the context when they return.

Use a restrained visual language: labelled relationship types, explicit status text/icons and optional color. A thick line must state whether it represents an amount, a count or another measure. Distinguish a claim being disputed from work merely being incomplete. Never use color alone. An auto-folded branch should still signal new material, unresolved questions and blocked work visible to the current user.

Make “why is this here?”, “what changed?”, “show its source” and “return to where I was” consistently available. Expose filtered or unloaded coverage without leaking inaccessible records. The investigator should not have to guess whether an empty view means no data, no access, an active filter or unfinished processing.

### 18.5 Smart behavior without forced AI

Deterministic structure can provide substantial value: source-to-extraction links, request-to-response links, assigned work, dates, changed revisions, dependency blockers, saved views and exact scoped search. These work without a model. AI optionally accelerates extraction, summaries, candidate relationships and follow-up proposals through the existing consent and review rules.

On any automatically organized branch, provide a compact explanation of what was added, linked, folded or assigned and its basis. Distinguish reversible presentation changes from changes to evidence, identity or decisions. Model failure should leave the investigator able to continue manually with visible pending analysis, not an empty or frozen case.

Record suggestions that were rejected or deferred so they are not regenerated continuously from unchanged material. A materially changed input may justify reconsideration, with that reason shown. Preserve alternative explanations and contrary evidence instead of ranking everything solely by support for the current leading theory.

### 18.6 Completion evidence for the ease-of-use promise

Use Section 13's supplier case and separate workplace and documentary/historical cases. Build realistic mixed evidence, known omissions, contradictory accounts, amended sources and different participants into their fixtures. Define expected case states and source locators before the measured runs. The final map journey must include intake, understanding, deep inspection, comparison, action, incoming result, change review, handover and output.

Track three distinct statuses for every SM requirement:

1. **Implemented:** code and service checks exist at the candidate commit.
2. **Observed:** the complete behavior ran through the candidate UI, with the relevant signed-build checks recorded separately.
3. **Measured benefit:** representative investigators completed the tasks against a named baseline, with errors, omissions and maintenance counted.

For a small initial evaluation, recruit at least five representative users spanning novices and experienced investigators. This is an initial usability signal, not proof about all investigators or superiority to every competitor. Use comparable case variants and counterbalance the order between the candidate and the chosen baseline, such as the current app or the user's document-and-spreadsheet workflow. Record onboarding, setup, waiting, correction and map maintenance as well as task execution. Assess AI-off and AI-enabled results separately so model performance does not conceal a poor map workflow.

Adopt these initial, predeclared product targets for the defined fixtures. They are proposed acceptance targets, not measured achievements or universal performance promises:

| Task or outcome | Initial target and measurement rule |
|---|---|
| Initial understanding | Within two minutes on the bounded fixture, identify its purpose, current recorded position, a material unresolved matter and the responsible next action; score against a prewritten rubric. |
| Evidence access | From a selected sourced assertion, one direct command opens its precise supported locator. Locating a known item from the case entry view should take a median of at most 30 seconds on the defined test tasks. |
| Changed evidence | Every deliberately seeded material source change exposes its affected recorded dependencies; no test case may present a stale finalized conclusion as current. |
| Next work | Each mandatory fixture action has an eligible owner or a visible unassigned/blocked state and remedy; no assigned task silently disappears inside a fold. |
| Total effort | Aim for at least 30% lower median end-to-end time on successful matched tasks, including setup, corrections and maintenance. Include failures/timeouts in the report rather than excluding slow failures. |
| Quality | No observed critical source misattribution, unauthorized disclosure, record loss or false claim of completion in the acceptance fixtures. Task correctness/omission performance must not worsen relative to the baseline. Report per-user and per-case results alongside aggregate figures. |
| Learnability | At least four of the first five users complete the defined first-case journey without live coaching after the optional ten-minute sample; record every failed step and the assistance required. |
| Responsiveness | Validate the named-hardware targets in Section 11 in the actual UI, alongside cold load, ingestion and export. Model projection timings alone do not close this row. |

Freeze tasks, success rubrics, baseline and thresholds before the evaluation. If results miss them, improve the product or narrow the corresponding claim; do not retrospectively change the test to declare success. Expand the participant sample before making broad comparative marketing claims. Test any specifically named competitor before claiming superiority over it.

These are completion criteria for the new smart-map capability and evidence for its ease-of-use claim. They do not silently reinstate previously removed legal/practitioner release approval gates. App Store distribution, security, privacy, purchase and other release obligations remain separately tracked; passing map tasks alone does not establish ship readiness.

### 18.7 Final implementation order and scope boundary

1. **Understanding and navigation:** deliver SM-01–SM-04 on the canonical recursive model. Show a real case with its complete evidence path and deep report branch. Establish the initial task baseline now.
2. **Investigation and change:** deliver SM-05–SM-07 with the existing contradiction, history, financial and task services. A returned child result must update the relevant case context and preserve uncertainty.
3. **Low-maintenance collaboration:** deliver SM-08 through R11/R13/R14. Validate solo mode first, then distinct identities and contributions. Automatic task creation must reduce missed work without increasing duplicate or unnecessary work.
4. **Learning, handover and output:** complete SM-09/SM-10 using the existing help and export foundations. Keep these usable throughout development rather than postponing accessibility to the end.
5. **Candidate evidence:** execute R12 across the frozen scope and record implemented/observed/measured status separately. Fix failed journeys and repeat only affected checks plus the appropriate regressions.

The functional specification is now finalized for this target. Treat subsequent requests as explicit changes, not a reason to keep adding loosely related features. Core money, people, evidence, history, child actions and basic case-team contribution remain within scope. Paid intelligence feeds, specialist acquisition tools, enterprise administration and speculative extra personas remain separate integrations or later work unless a stated core task requires them.

The agent must maintain one completion matrix linking R00–R14 and SM-01–SM-10 to code, candidate SHA, automated checks, observed journeys and benefit measurements. Do not create competing “100% complete” summaries. Mark this expanded product complete only when the promised scope works end to end and its evidence supports the claimed benefit. Until then, use precise statuses such as implemented, UI-verified or benefit not yet measured.

## Sources

All code links below are pinned to the inspected commit. These are source anchors, not proof that every behavior was exercised in the signed app.

- [C01 — CaseMapProjection.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapProjection.swift)
- [C02 — CaseMapService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapService.swift)
- [C03 — CaseMapViewFilter.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapViewFilter.swift)
- [C04 — CaseMapRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapRepository.swift)
- [C05 — CaseMapWorkspaceModel.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/CaseMapWorkspaceModel.swift)
- [C06 — CaseFileDocuments.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseFileDocuments.swift)
- [C07 — CaseFile.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseFile.swift)
- [C08 — CaseChangeFeed.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseChangeFeed.swift)
- [C09 — CaseRecordRevisions.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseRecordRevisions.swift)
- [C10 — CaseHistoryRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseHistoryRepository.swift)
- [C11 — CaseSearchLive.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseSearchLive.swift)
- [C12 — FAMoney.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/FAMoney.swift) and [ForensicEngagement.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/ForensicEngagement.swift)
- [C13 — FundFlowView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/UI/FundFlowView.swift)
- [C14 — CaseDeconfliction.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseDeconfliction.swift)
- [C15 — AuditChain.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Forensics/AuditChain.swift)
- [C16 — CaseMapExport.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/Kalsmritikosh/Investigate/CaseFile/CaseMapExport.swift)
- [C17 — recorded stress measurement](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/docs/evidence/case-map-perf-2026-11-07/case-map-perf-stress.md)
- [Current partial UI walk](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/docs/evidence/ui-walk-2026-11-07/JOURNEYS.md), [execution matrix](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/docs/CASE_MAP_EXECUTION_MATRIX.md), [owner decisions](https://github.com/sasmalgiri/kalsmritikosh/blob/58717ec8bfbc543e9bf7700d2dd66c2c4b867135/SHIP_DECISIONS.md), [CI run](https://github.com/sasmalgiri/kalsmritikosh/actions/runs/42419808339), [PR #169](https://github.com/sasmalgiri/kalsmritikosh/pull/169).
- [V01 — DataWalk investigations](https://datawalk.com/solutions/investigations/).
- [V02 — i2 iBase and Analyst's Notebook integration](https://i2group.com/solutions/i2-ibase).
- [V03 — Casefleet](https://www.casefleet.com/) and [AI-proposed facts](https://support.casefleet.com/en/articles/13057134-using-the-ai-assistant-to-create-facts).
- [V04 — Maltego Graph](https://www.maltego.com/graph/).
- [V05 — Palantir Gotham published service definition, Graph/Dossier sections](https://assets.applytosupply.digitalmarketplace.service.gov.uk/g-cloud-14/documents/92736/801146272055049-service-definition-document-2024-05-02-1537.pdf).
