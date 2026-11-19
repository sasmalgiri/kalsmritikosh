# Investigations Made Easy — living case map implementation plan

**Prepared:** 6 November 2026, Asia/Kolkata  
**Repository:** sasmalgiri/kalsmritikosh  
**Inspected branch:** investigations-next  
**Inspected commit:** 68addaa4f8fc9e8197cabc2fef6d60978be3bc7a  
**Purpose:** Turn the existing case workspace into the growing, manually navigated case map discussed with the owner.

## 1. Decision and scope

Build this as the main working view of a case, using the existing evidence ledger and case services as its authority. The map should help an investigator answer five questions quickly:

1. What is this case trying to establish?
2. What evidence supports or challenges each point?
3. What remains unknown, unreviewed or outstanding?
4. What changed since I last worked on it?
5. What should I do next?

The map represents the case record and the investigator's reasoning. Its visual size, number of links and apparent neatness must not imply that an allegation is proved or that an investigation is complete.

The requested “manual carousel” becomes a strip of saved, focused views of the **same case**. The investigator can select a view directly or move backward and forward. Each view preserves its location and filters. A separate history control shows earlier recorded states. Neither navigation control advances automatically.

This plan covers the dashboard, growing map, focused views, source inspection, work actions, search, changes, history, maturity indicators, accessibility, help, migration and verification needed to make that experience complete. It implements the latest map proposal; it does not reopen unrelated pricing, provider, jurisdiction or product-scope decisions.

**Recommended product behavior:** opening a new case presents the case question and a simple map. Returning to a case restores the person's last workspace, with “Overview” and “What changed” immediately available.

## 2. What was actually checked

This is a source and repository-evidence review of the commit above. I inspected the relevant Swift UI, repositories, graph/search models, case services, tests and committed UI records. I also fetched the actual GitHub check results and the failing job log. No Mac application, signed build, live AI benchmark or new human usability test was run for this review.

The branch has advanced substantially beyond the 4 November competitive plan. Several earlier gaps are now implemented and should be reused.

Current verification state:

- PR #169 remains open and unmerged. Its body still describes head 4147e106, so it is not a reliable summary of current implementation.
- CI run **42232124869**, for **68addaa4**, has **six successful jobs and one failed job**.
- The failed job is **build-and-test**. Its log names **ModuleMatrixDriftTests/committedMatrixMatchesTheCode()** in batch 5. The other nine batches are reported passed. Do not describe the overall run as green.
- The test requires root **MODULE_MATRIX.md** to equal **ModuleMatrixDocument.render()**. Regenerate from that authoritative renderer or its test attachment; an older Python generator has a different format.
- The latest committed new-workspace UI walk, on **06e4b3a9**, explicitly says **INCOMPLETE** and all nine checks **NOT RUN** because the Mac was locked. Earlier partial observations are stored separately for 572b5893. They are not verification of the newer fixes.
- Source tests for workspace state, in-place reviews, evidence requests and coverage exist. Their existence and prior reported results do not establish the new map's usability.

Evidence: [CI run](https://github.com/sasmalgiri/kalsmritikosh/actions/runs/42232124869), [failing job](https://github.com/sasmalgiri/kalsmritikosh/actions/runs/42232124869/job/127940368278), [PR](https://github.com/sasmalgiri/kalsmritikosh/pull/169), and source references below.

## 3. Current implementation versus the proposed experience

“Present” below means found in source, not newly verified on screen.

| Area | Current implementation | Work required |
|---|---|---|
| Case home | CaseFileView has seven sections, stage, question, review counts, requests, reading limitations, coverage and next actions. CaseGlance computes the summary. [C01–C02] | Keep the summary visible while navigating the map. Avoid making the investigator scroll through intake/administration forms to resume work. |
| Return to work | CaseWorkspaceState stores tab, contradiction selection/filter/search, request selection and last source identifiers. [C02] | Extend to selected map item, view, viewport, layout, collapsed groups and source position. Current state is not a persistent map. |
| In-place review | Contradictions have side-by-side passages, confirm/dismiss/defer, reasons, revision-aware reopening and decision history. [C03–C04] | Reuse those commands in the map inspector and update every view from the saved result. |
| Evidence requests | Requests now have custodian, period, due date, expected items, receipts, duplicates, partial/refused/unobtainable states and recorded fulfillment decisions. [C05] | Show requests beside the questions they address; open the existing follow-up UI in context. Do not create another request store. |
| Relationship graph | RelationshipGraphView has pan, zoom, draggable names, a pair timeline and side panel. Its query is archive-wide, defaults to 40 entities from up to 400 aggregated relationships, and its timeline reads recent archive events. [C06] | Add a genuinely case-scoped projection with questions, evidence, events, hypotheses, actions and findings. Existing graph scope is appropriate for its archive tool, not for an embedded case map. |
| Stable layout | Graph positions, zoom and pan are local @State; a node change calls place() again. ForceLayout lays the full graph out from node indexes. [C06–C07] | Persist positions; place new items incrementally; keep existing positions stable; make re-layout explicit and undoable. |
| Evidence canvas | EvidenceCanvasView is a card grid, not a spatial linked board. No production call site was found in the inspected source. A note alone makes isSupported true and can yield “All claims supported.” [C08] | Do not expose that support label. Separate investigator notes, located passages and human-reviewed conclusions. Reuse visual styling only if useful. |
| Alternate graph component | GraphExplorerView is a list of entities/edges. No production call site was found in the inspected source. [C09] | Avoid a third competing graph architecture. Use a shared case projection for both the map and accessible list. |
| Visual provenance | WorkbenchVisualSurface and EvidenceInspectionTarget already model source-backed, derived, scenario and user-entered elements. They provide a useful projection contract. [C10] | Reuse or extend the contract. The existence of 14 visual kinds does not mean 14 complete rendered interfaces exist. Add typed case relationships and plural source references where required. |
| Case records | CaseFileSnapshot includes allegations, evidence grid, tasks, people, interviews, chronology, notes, exhibits, actions and report selections. Hypotheses and requests have their own canonical services. [C11–C12] | Assemble these references into one consistent case projection. Preserve canonical record identity and revision. |
| “What changed” | An archive-level ChangesView and ChangeDigest exist for contradictions/gaps. AppState.changeDigest() reads archive-wide sets and one latest baseline. [C13] | Create a case-scoped change feed and per-case seen marker. Distinguish a disappeared detection from a human-resolved issue. |
| Historical comparison | HistoryDiffEngine compares history outlines by kind/title. Case actions are logged, but some mutable records are overwritten; saveProfile logs profileSaved with no old/new profile payload. [C14–C15] | The log cannot be assumed to reconstruct the full case at any past date. Add explicit revision/checkpoint support and state the historical boundary for existing cases. |
| Search | AdvancedSearchCompiler supports Boolean text syntax, phrases, prefixes, proximity and metadata filters. SearchView shows warnings and coverage; Smart Collections save queries. [C16–C18] | Bring search into case scope, add reliable exhaustive enumeration and visual query editing. Current advanced SQL combines structured filters with AND and applies text matching to chunks; it does not represent arbitrary nested Boolean logic across fields. |
| Search scope/counts | Advanced search defaults to 40 chunks. Existing search coverage counts the archive, not this case. Saved collections have names/queries without a case binding. [C16–C18] | Separate result pagination from total matches; show case coverage, document/occurrence counts and saved search revision. Preserve existing archive search behavior as a distinct scope. |
| Evidence handoff/export | JobResultHandoff preserves reviewed records/citations and checks revisions. CaseOutputService freezes, rechecks, writes, reads back and records outputs. [C19–C20] | Route map actions and exports through those services. A direct screenshot/save path must not bypass them. |
| Help and privacy | Updated tutorial/help, per-case AI permission and content-free last-source identifiers exist. Full/case erasure handles workspace preferences. [C02, C21] | Extend the existing help system. Keep new annotations, query text and historical case content in the encrypted ledger; extend erasure and recovery for every new store/cache. |

The current app has much of the underlying case workflow. The main new work is a **case-scoped visual projection, durable spatial state, shared inspector, meaningful change history and reliable navigation**.

## 4. The complete working screen

### 4.1 Persistent case header

Keep these visible without scrolling:

- Case title, investigator and current human-recorded stage.
- The investigation question, with an expand control for long text.
- A compact reading-coverage indicator with an explanation on selection.
- Counts of unresolved questions, items awaiting review, outstanding requests and overdue actions.
- “What changed”, “Next action”, “Search this case” and “Return to overview”.
- A clear historical-state banner when viewing an earlier checkpoint.

Clicking a count must open the matching items, not merely jump to a vaguely related tab. Counts must come from the same scoped projection as the displayed map.

Administrative forms remain available through case details. They should not occupy the main investigation canvas.

### 4.2 Manual view strip

Initial views:

| View | What it emphasizes |
|---|---|
| Overview | The main question, issue groups, unresolved matters and next actions. |
| Questions | One question/allegation with supporting, challenging and missing material. |
| People | A selected person/organization, statements, events, documents and explicitly supported connections. |
| Chronology | Recorded events, their dates/ranges, date uncertainty and linked evidence. |
| Findings | Proposed, reviewed and approved work products, contrary evidence and review requirements. |
| Changes | New evidence, changed sources, reopened reviews, request receipts and affected findings since the selected baseline. |

Allow direct selection, Previous/Next buttons, keyboard navigation and saved custom views. Custom view names, filters and ordering are persisted. A view stores references and display settings; it does not fork the case.

Display a breadcrumb such as “Overview › Payment authorization › Approval email”. Back restores the preceding focus and source position. View-strip navigation and map panning are separate gestures, so scrolling the map does not unexpectedly change the active view.

### 4.3 Main map

Start with the question and a few meaningful groups. Expand progressively; do not create an unreadable screen with one node for every extracted word, chunk or entity.

Required capabilities:

- Pan, zoom, fit selected branch, fit visible map and return to overview.
- Drag, pin/unpin, collapse/expand and hide from this view.
- Preserve positions when new evidence arrives.
- Search/focus an item without losing the original view.
- Select a link as well as a node.
- Show labels and direction on meaningful links.
- Keep selected items visible; prevent inspector resizing from moving the map unexpectedly.
- Provide undo for layout and view changes.
- Differentiate hiding, withdrawing a link and erasing a record. Hiding has no evidentiary effect.
- Show counts of collapsed, filtered and not-yet-loaded items. A display limit must never imply that the case contains only the displayed subset.
- Keep unconnected evidence discoverable in an “Unlinked material” group/list.

Use icons, text and line styles as well as color. Large nodes, thick lines or central placement must not be presented as measures of credibility.

### 4.4 Shared source and action inspector

Selecting an item opens one consistent panel, with:

- Its type and current recorded status.
- Its exact wording and source provenance.
- Every supporting/challenging source, not only the first reference.
- Original passage plus surrounding context.
- Source version, page/cell/message/timestamp where available.
- “Position unavailable” when only a document reference exists.
- Authorship, review history, changed-source warning and applicable restrictions.
- Existing actions: review, add to chronology, link to allegation/hypothesis, create/follow a request, prepare interview notes, include/exclude from report, or open the full work product.

Selecting an edge explains **why this particular connection exists** and opens the evidence or the investigator's recorded rationale. A filename or a count of co-occurrences is not sufficient provenance for a substantive relationship.

Persist source position as identifiers and a locator; resolve the text from the authorized ledger. Do not restore cached plaintext quotes from preferences.

### 4.5 Equivalent list/table

The same projected records must be usable through a keyboard-accessible list/table, with the same filters, review commands and inspector. Switching between list and map preserves selection.

This is part of the main feature, not a later accessibility add-on. It also provides the practical route for large result sets and investigators who prefer tables.

## 5. Domain model and authority boundaries

### 5.1 Node types

Use stable composite identities such as case ID + canonical record kind + canonical record ID. Keep revision separate from identity.

| Node | Canonical source or extension | Required interpretation |
|---|---|---|
| Case/question | Case header, purpose and existing allegation/lead records | A question is not a factual claim. Add a dedicated question record only if current records cannot represent it without losing meaning. |
| Person/organization | Case people and case-scoped entity references | Same name is not proof of same identity. |
| Event | Reviewed chronology/journal or a linked existing event | Separate alleged, proposed and recorded events. Preserve uncertain dates. |
| Evidence | Exact source version, exhibit or cited passage | A document's existence does not establish the truth of its assertions. |
| Statement | Interview/confirmed statement/addendum and cited attributed passage | Preserve speaker and whether it is direct speech or reported speech. |
| Hypothesis/lead | InvestigationHypothesis and its evidence links | Human decisions remain authoritative. |
| Contradiction/gap | Existing case review service and gap records | Suggested conflicts remain reviewable; a missing record is not an adverse finding. |
| Action/request | Existing task/deadline and EvidenceRequestFile | Receipt of a document does not automatically complete a request. |
| Finding/work product | Existing finding approval and report selection records | Distinguish proposed, reviewed, approved and stale. |
| Investigator note | Existing journal/note authority | Always labelled as a note; never converted to documentary evidence by appearance. |

Group nodes are structural summaries. They disclose which items they summarize and do not invent a new finding.

### 5.2 Link types

Start with a small typed vocabulary:

- supports / challenges;
- mentions / attributed to;
- occurred before / occurred after, only with an explicit temporal basis;
- possible same person, pending review;
- depends on / requests evidence for / received in response to;
- derived from / supersedes;
- selected for report.

For each link record or projection retain:

- stable ID, case ID and endpoints;
- link type and direction;
- canonical origin record(s) and revision(s);
- source version(s), evidence blocks/locators and occurrence context where present;
- asserted by: investigator, rule or model;
- review decision and its author/time/rationale;
- verification state, sensitivity and staleness;
- underlying basis for a derived relationship.

Do not conflate provenance, review status, source reliability and claim truth into one “confidence” number. Model scores must not drive guilt, credibility or case completion.

### 5.3 One source of truth

Use adapters over existing repositories. Do not create a second store containing editable copies of allegations, people, tasks, findings or evidence.

Only genuinely new concepts need persistence:

- saved views and map layout;
- typed annotations/links that have no existing canonical home;
- case revision/change records needed for historical reconstruction;
- immutable checkpoints and their manifests;
- per-case change acknowledgements and saved search definitions.

Prefer extending a canonical record's history over inventing a competing graph-specific decision. For polymorphic references enforce parent-case membership and target existence in the write transaction.

A suggested arrangement, with **proposed filenames** rather than claimed current files:

| Proposed component | Responsibility |
|---|---|
| Investigate/CaseFile/CaseMapProjection.swift | Pure nodes, links, groups, visible counts and provenance. |
| Investigate/CaseFile/CaseMapService.swift | Authorized scoped loading, consistent revision boundary, incremental refresh. |
| Investigate/CaseFile/CaseMapLayout.swift | Stable positions, pinning, clustering and incremental placement. |
| Investigate/CaseFile/CaseMapRepository.swift | New layout/view/link metadata in the ledger. |
| Investigate/CaseFile/CaseChangeFeed.swift | Typed case changes, acknowledgement and affected-record navigation. |
| Investigate/CaseFile/CaseHistoryRepository.swift | Revision/checkpoint manifests and exact historical projections. |
| UI/CaseMapWorkspaceView.swift | Header, view strip, map/list and shared inspector. |
| UI/CaseMapCanvas.swift | Rendering, hit testing, pan/zoom and accessible interaction hooks. |
| UI/CaseMapInspector.swift | Existing-source inspection and canonical actions. |
| Retrieval/CaseSearchService.swift | Explicit query semantics, scoped enumeration, coverage and search receipts. |

Reuse Workbench provenance/inspection types where they fit; extend them for multiple references and relationship bases instead of losing provenance to fit a single-target type.

## 6. Growth, changes and historical truth

### 6.1 How new material enters the map

1. A folder scan discovers material.
2. Intake and parsing states remain visible.
3. Existing “Review new documents” approves case inclusion; the map must not widen scope automatically.
4. The authorized case projection refreshes.
5. New evidence appears near its relevant question/group or in “Unlinked material”.
6. New proposed links enter a review queue.
7. Existing decisions remain recorded. A relevant source change marks dependent work as needing review.
8. The investigator accepts, challenges, defers or links the material through existing commands.

Do not run a cloud model merely because the case or map opened, because the user panned, or because a view changed. Ordinary navigation, clustering and history comparison should work locally.

Each asynchronous load carries case ID, generation token, scope fingerprint and relevant policy/source revision. Discard late results after case switching, erasure, scope changes or access changes. Recheck authority at mutation/export time.

### 6.2 Stable growth

Initial layout should group by question or issue. Seed positions by stable identity. New nodes are placed locally around related nodes or in an arrivals area.

A data refresh must not silently move existing nodes. If a user asks for “Arrange”, show its scope—visible branch or whole view—and provide undo. Honor pinned positions.

Use world coordinates independent of window size. Store per-view viewport and selected node. Fit means fit the actual visible bounds, not simply reset zoom to 100%.

Avoid running the existing full quadratic force simulation on every update. If reused, run it on bounded local groups off the UI path, with cancellation and deterministic tie-breaking.

### 6.3 Case change feed

Record and distinguish:

- document admitted, excluded, unreadable, newly readable or revised;
- evidence link added/withdrawn;
- review decision made/reopened;
- request receipt, duplicate receipt and status decision;
- task due/status change;
- question/hypothesis/finding revision;
- approved output or case stage change.

Use canonical IDs and typed change reasons. Do not use title matching as identity. A removed detection means “no longer detected” until there is a separate basis for “resolved”.

Maintain a per-case seen position. “Seen” or “acknowledged” must not imply “reviewed as evidence” or “accepted as a finding”. A failed feed load must display a failure, not “nothing changed”.

For changed evidence, list directly dependent records and explain the dependency. Describe indirect effects as “may need review”; do not automatically reverse a finding.

### 6.4 Historical states

Keep **event time** separate from **recorded-at time**. Evidence added today may describe an event months ago; it belongs in the earlier event chronology but cannot appear in yesterday's “what was known” view.

Existing action logs are useful, but they are not a full temporal database. Some updates overwrite current values without preserving their previous content. Therefore:

- Start an explicit historical baseline when this feature is installed.
- Label earlier history “full map state not recorded before [baseline]”.
- Preserve existing action/approval records without inventing missing past maps.
- Add immutable revisions or typed before/after records at canonical mutation boundaries, in the same transaction as the change.
- Build checkpoints from a consistent revision boundary, with manifest, scope fingerprint and content digest.
- Include references to retained source versions, decisions, relevant domain revisions and layout.
- If historical display text must be retained because a source authority does not version it, store that immutable material in the encrypted ledger and include it in erasure.
- Use a read transaction or validated revision fence so a checkpoint cannot mix half of the old state with half of a new change.
- Keep history read-only. “Return to current” must be obvious.
- Compare checkpoints using stable identity/revision, with Added / Changed / Withdrawn / Needs review.
- Current privacy/erasure rules still apply when opening history. Do not resurrect erased content through a checkpoint.
- If a retained version is unavailable, say so. Do not silently substitute the current source.

Navigation may offer daily markers and named milestones, but only recorded states are selectable as exact snapshots. If a displayed date is approximate or only a nearest checkpoint, state that explicitly.

## 7. Case maturity without a misleading completion percentage

Derive a readiness panel from explicit case work:

- Questions: unresolved / being investigated / answered with recorded basis.
- Evidence: read / partly read / unreadable, with coverage limits.
- Review: pending / deferred / decided / reopened.
- Requests: open / partial / refused / unobtainable / fulfilled by decision.
- Findings: draft / reviewed / approved / outdated.
- Work: outstanding / overdue / completed / not applicable with reason.

Preserve the current case stage and approval policies. The person can revise or reopen them through existing authorized actions.

A case with 5,000 nodes is not more mature than a case with 50. Ten citations to the same source do not mean ten independent sources. No supporting-versus-opposing vote decides a hypothesis. New contrary evidence can reduce readiness even as the map grows.

## 8. Search inside the workspace

There are two distinct searches:

1. **Find on this map:** locate/filter projected items, including collapsed branches. State whether it searches the current view or the whole case.
2. **Search case evidence:** run an explicit query over authorized case documents and metadata.

Build on the existing compiler, but fix representation before adding a rich visual builder.

Required work:

- Introduce a versioned query tree preserving nested AND/OR/NOT across text and fields.
- Compile parameterized SQL and text predicates from the same query tree shown to the user.
- Support visual rule groups plus a readable query explanation and expert text editing.
- Reject unsupported or malformed clauses in strict mode. If offering a repaired query, show it and require explicit use; do not silently execute a weakened meaning.
- Distinguish file modification time, document-stated date and inferred event date.
- Specify phrase, whole-word and literal-text semantics, including case, punctuation, whitespace, accents and Unicode normalization.
- Keep fuzzy/stemming/semantic expansion explicitly optional.
- Handle document-level AND/NOT and phrase matches across chunk boundaries. Returning other chunk hits must not suppress cross-boundary matches elsewhere.
- Scope candidate generation, matching, counts, snippets and pagination to the case before returning results.
- Keep document counts, source occurrences and passage-match counts separate.
- Paginate all matches with a stable ordering and explicit caps/timeouts. A top-40 preview is not an exhaustive result set.
- For each hit show a witness: matched passage/fields and which query clauses it satisfied.
- Produce a coverage receipt for the actual searched case scope, including failed, partial, excluded and unavailable items.
- Save query version, options, case scope, index/extractor revision and execution time. Distinguish a live saved search from a frozen result receipt.
- Detect new matches when authorized case material changes without silently admitting newly discovered files.
- Use source inspection and the existing handoff commands directly from results.

Never claim “100% correct investigation search”. A defensible claim is that specified matching semantics were checked over a named searchable corpus. Completeness of that corpus and the truth of its statements are separate questions.

## 9. Security, privacy, export and recovery

This visual feature adds meaningful sensitive data: annotations, selected relationships, search terms, review context and historical snapshots. Treat it as case content.

- Put meaningful view names, queries, annotations and historical material in the encrypted ledger. Preferences may retain non-content UI identifiers/geometry only where appropriate.
- Reuse CaseWorkspaceStore's identity-only source-position approach. Do not reintroduce document names or quotes into plain preferences.
- Require the current authorized case scope for every node, link, inspector and search. Case-scoped graph results must not include a globally connected person's unrelated cases.
- Keep explicit cross-case deconfliction separate and governed by its existing behavior.
- Enforce closed-case, subscription/read-only, legal-hold and mutation rules through existing services.
- Reading, safe export and recovery after subscription expiry should retain their existing contract.
- AI suggestions use existing permission and outbound logging. No new automatic sends, web requests, third-party graph service or remote analytics are needed for the map.
- A map layout has no authority to approve a source, disclose protected identity or alter a finding.
- Carry privacy-sensitive content through logs only under the existing logging policy; benchmark traces use synthetic cases.
- Add new tables, dependent records, caches, checkpoints and queued saves to full/case/person erasure. Verify failures roll back and late work cannot recreate erased content.
- On lock, erase or case switch, clear relevant inspector content and cancel/discard pending loads.
- Include the new durable state in backup/restore. Restore must preserve view identity and evidentiary revisions.
- Add a versioned migration using the next available schema number at implementation time; do not assume v171 is still free.
- Check upgrade from the inspected v170 and older supported ledgers, restart during migration and refusal by older incompatible apps.
- Map export must freeze the displayed selection, legend, case/time/scope and sources, then pass through CaseOutputService or an extension preserving its revalidation, privacy, atomic-write and receipt rules.
- A historical map export must say which recorded state it depicts and apply current release restrictions.
- Include a readable relationship/evidence table with exported maps. A picture alone is inadequate for tracing source support.
- Copy, print and image/vector export routes require the same restrictions; a canvas screenshot command is not an exemption.

## 10. Help and learning curve

Extend HelpRegistry and its generated manual/coverage matrix.

Provide:

- A replayable isolated sample case that grows in several manual steps.
- A short first-use explanation of nodes, links, review state and “what changed”.
- Context help for each link type and status.
- Hover/focus text explaining actions; vital information must also be available without hovering.
- Empty states that tell the person what to do next: record the question, review new documents, select a passage or create a request.
- A legend available at all times.
- Keyboard instructions accessible from the same Help menu.
- A visible “Reset view” that resets geometry/filters without deleting case content.
- Help for historical states, missing source versions and incomplete coverage.
- Error messages with one practical next action and retained unsaved work.

The tutorial must teach a real workflow: question → document → passage → review → request → new evidence → revised view → report. Do not force a slideshow before the person can work.

## 11. Implementation packages and completion criteria

Execute these packages in dependency order. The agent may prepare independent fixtures/design specifications while implementing, but should not mark a package complete until its behavior is verified.

| Package | Implementation | Dependencies | Required acceptance evidence |
|---|---|---|---|
| M0 — establish baseline | Recheck latest remote head and owner decisions; reproduce/fix matrix drift using the Swift renderer; reconcile PR/readiness records; run the missing existing-workspace journey on a suitable Mac. | None | Exact commit and check results; incomplete checks remain explicitly incomplete. Do not disable screen-lock protection as a substitute for a functioning test environment. |
| M1 — case projection | Typed stable nodes/links; canonical adapters; source references; case/access scope; coherent revision loading; honest empty/error/partial states. | M0 | Two-case isolation, canonical identity, multiple citations, stale revision and failed-load tests. |
| M2 — persistent workspace shell | Sticky header, manual view strip, common inspector, map/list selection, return position and saved views. | M1 | State survives close/relaunch, case switching and view switching; no copied evidence in preferences. |
| M3 — spatial map and growth | Grouped initial layout, pan/zoom, expand/collapse, pin/drag, incremental placement, limits disclosure, undo and list parity. | M1–M2 | No silent movement of existing/pinned nodes; visible counts reconcile; all content reachable through expansion/list. |
| M4 — investigation actions | Invoke existing review/request/task/chronology/report/hypothesis commands from selected map records. | M2–M3 | One decision appears consistently in map, existing case UI and exports; no retyping or duplicate canonical records; service guards remain active. |
| M5 — case search | Scoped query tree, visual builder, witness matches, exhaustive pagination/counts, coverage receipts and saved searches. | M1–M2 | Independent expected-match fixtures, nested field logic, cross-chunk phrases, date semantics, caps/failures, case isolation. |
| M6 — changes and impact | Typed case changes, per-case acknowledgements, new material, affected records, reopening and view-preserving refresh. | M1, M4–M5 | Read/seen is not approval; removed detection is not automatic resolution; source changes flag affected work without changing decisions. |
| M7 — history and maturity | Revision capture, historical baseline/checkpoints, comparison, event-time/recorded-time distinction and readiness panel. | M1, M4, M6 | Exact replay of post-baseline states; no invented pre-baseline history; no current-state editing from past view; closure unaffected by node count. |
| M8 — privacy/export/recovery | Ledger migrations, erasure, backup, access/lock handling, export manifest and source-table companion. | M1–M7 | Restore/erase/export race tests; protected identity checks; current restrictions on historical content; no direct canvas-export bypass. |
| M9 — usability, help and performance | Keyboard/VoiceOver, narrow layouts, reduced motion, tutorial/manual, loading/cancellation, bounded rendering. | M2–M8 | Actual Mac UI recordings and task outcomes, named-hardware measurements, help consistency checks. |
| M10 — final candidate and measured benefit | Full relevant CI; distribution-signed workflow; comparison with existing tab-based workflow; accurate release/evaluation record. | M0–M9 | Exact commit/build/digest; raw measurements; unresolved items stated; claim limited to evidence. |

Do not make the map the default for existing users until M1–M9 pass on the candidate. Preserve their previous case-view preference. Use a reversible feature rollout; switching views must not delete or transform underlying evidence.

An unavailable Mac or blocked UI session in M0 does not prevent independent implementation work. Keep that verification item open, continue the packages that can be completed, and return to the actual UI before declaring acceptance. A running UI session must use an authorized, unlocked test environment; do not turn security settings off automatically.

## 12. Acceptance case: a map that grows over several days

Use synthetic documents in an isolated test archive. Reuse the existing supplier-payment fixture where suitable, but extend it deliberately rather than depending on the owner's files.

| Stage | New information/action | Expected map behavior |
|---|---|---|
| Day 1 | Record “Was this supplier paid twice, and were the payments authorized?” Admit an invoice and payment record. | Shows the question, two sources and an open explanation; no fraud conclusion. |
| Day 2 | Add an approval email and a witness statement denying approval. | Offers a potential conflict linked to both exact passages. Human review decides whether the statements concern the same event. |
| Day 3 | Request January–March statements; link January and February plus an exact duplicate. | Three expected items; two distinct items received; March outstanding; duplicate provenance retained; no automatic fulfillment. |
| Day 4 | Add a second debit and a later return. Include a namesake in an unrelated document. | Displays currency/date/account context, keeps the namesake distinct, and does not equate gross outflow with proven loss. |
| Day 5 | Revise a source affecting a reviewed finding. | Previous decision remains in history; affected item shows needs review; existing map positions remain stable; new material is highlighted. |
| Day 6 | Record a reasoned finding and select reviewed items for a report. | Finding uses existing approval policy; report retains citations and contrary evidence; no re-entry of reviewed text. |
| Return later | Close/reopen the app, choose a past checkpoint, compare with current state. | Same view/position restored; past state excludes evidence not yet known; differences explain changes; return to current is obvious. |

Add failure variants: unreadable scan, source removed from scope, currently restricted source, provider failure, unsaved note, aborted export, legal hold, case deletion during an async load, restore to a new ledger and revoked/expired subscription.

The sample should end with a usable work product and an explicit account of unresolved material. A visually finished map is not its success criterion.

## 13. Tests that would justify calling it complete

### 13.1 Automated correctness and integration

Use meaningful fixtures with independently specified expected behavior:

- Two cases share one source/entity, but their distinct evidence/actions never cross into each other's map or search.
- Canonical IDs remain stable after renaming, re-ingest, replay and row ordering changes.
- Same-name people, duplicate copies and identical amounts do not merge without the appropriate identity/basis.
- A note-only card cannot display “documentary support verified”.
- Each substantive edge opens its actual supporting/contrary source or recorded rationale.
- Multiple citations survive the projection and handoff.
- Unassessed, unsupported, unavailable, restricted, stale and failed are distinct states.
- Inserting new nodes leaves existing and pinned world coordinates unchanged unless explicitly arranged.
- Collapsed/filtered/unloaded counts reconcile with the complete authorized projection.
- Query tree and rendered explanation mean the same thing; invalid queries cannot quietly become broader searches.
- Exact search fixtures include punctuation, Unicode, negation, chunk boundaries, field OR, document-level NOT and excluded/unreadable files.
- Result counts and all pages match an independent expected-match set; no top-k omission disguised as completeness.
- Review state stays synchronized after actions from either old sections or the map.
- Revisions prevent stale writes and stale approvals.
- A checkpoint is internally consistent under concurrent intake/review.
- Historical queries do not leak later-acquired evidence into an earlier known-at state.
- Case erasure, person erasure and full erasure cover new state; legal hold refuses correctly; queued jobs cannot recreate it.
- Exports recheck changed access, source revision and protected identities immediately before release.
- Save failures retain edits and expose Retry; disk-full, cancellation and migration interruptions are recoverable.

Extend relevant existing suites including CaseWorkspaceTests, ContradictionReviewInPlaceTests, EvidenceRequestFollowThroughTests, PackageBTests, case erasure/output tests and Workbench provenance tests. Add focused map/search/history suites where new behavior needs independent coverage.

### 13.2 Actual UI checks

Run the production services through the real interface on the identified candidate:

1. Start a case and understand its question without opening another screen.
2. Find a source from a node and return without losing place.
3. Review a conflict with the note field focused using both controls and keyboard.
4. Create and partly fulfill a request from the relevant question.
5. Search all case evidence and inspect why each hit matched.
6. Add evidence while viewing another branch; new items appear without disorientation.
7. Close/relaunch; restore view, inspector, filter and source location.
8. Switch cases quickly during loading; no stale data appears.
9. Use only keyboard and VoiceOver to perform the same core tasks through map/list.
10. View a historical checkpoint and return to current without mutating the past.
11. Export a source-traceable map/report, then verify the delivered bytes.
12. Upgrade, restore and erase the feature's state in a signed build.

The latest locked-screen run must be rerun. Compilation, an accessibility tree, a screenshot of the window or a model-level unit test alone does not prove the whole journey works.

### 13.3 Performance targets

These are **proposed engineering targets**, not measured capabilities:

| Workload/operation | Proposed target and measurement |
|---|---|
| Normal case: 500 documents, 2,000 projected records, 3,000 links | Useful overview within 3 seconds cold and 1 second warm on a named target Mac. Count all loaded data and include loading failures. |
| Selection, view switch and local filter | p95 visible response within 150 ms once required data is loaded; slow source I/O gets immediate progress. |
| Pan/zoom and drag | Smooth interaction with no prolonged UI stalls; profile frame times rather than claiming a frame rate from visual inspection. |
| Incremental 100-record update | Existing positions retained; update completes within 2 seconds without blocking input on the normal fixture. |
| Stress case: 5,000 documents and 50,000 projected records | Remains usable through grouping, viewport culling and pagination; all authorized records remain reachable. This is a stress test, not an advertised support limit. |
| Canceled/superseded work | No late write or stale inspector update after cancellation, erase or case change. |

Record hardware, OS, build, fixture size/bytes, memory, cold/warm conditions and raw timing. Include scans, Office files, emails, attachments and long quotations; tiny generated memos alone do not represent a realistic workload. Adjust provisional targets before the final registered evaluation, with a reason, not after seeing unfavorable results.

### 13.4 Human benefit

Use the existing **IME_Measurably_Easier_Test_Protocol_2026-11-04.md** as the evaluation authority. Compare this workspace with the current tab-based IME workflow using different but matched cases and balanced order.

Measure:

- Time to correctly identify the case question, current position and next action.
- Time to first correctly cited, reviewed finding.
- Time to understand what changed since the previous session.
- Time to complete an acceptable report, including corrections.
- Source-checking errors, missed contrary evidence and false connections.
- Navigation detours, repeated typing and help required.
- Whether users mistake a proposed link or incomplete coverage for a verified conclusion.

A proposed success target is at least 30% less median time on the predeclared core workflow with preserved quality; this is a target, not a promised result. Report failures and uncertainty, not only successful participants. Five users can expose early problems; broader advantage claims need the planned comparative study and sample-size rationale.

An agent can run engineering journeys and prepare the study. It cannot supply observations from human investigators by simulating them.

## 14. Instructions to the implementing agent

Implement M0–M10 against the latest branch, rebasing this plan's findings onto the actual head before editing. Keep each package reviewable and preserve unrelated working-tree changes.

For every package:

1. Record the baseline SHA and the exact requirements being handled.
2. Reuse current canonical services and existing UI patterns where they already solve the problem.
3. Implement the behavior and meaningful failure states together.
4. Run the relevant automated suites and architecture guards.
5. Exercise the real UI on the intended Mac when the package changes interaction.
6. Commit the code with the evidence record; run the required full CI on pushes.
7. Update one execution matrix with implementation, automated verification, UI verification, signed-build verification and human-evaluation columns kept separate.
8. Mark blocked/unavailable work honestly. Continue independent work; do not replace missing verification with an agent assertion.
9. Update HelpRegistry/generated help, data-flow inventory, threat model and release documentation for actual new behavior.
10. Produce the final candidate identifier, build digest, test links, migration/recovery evidence, known limits and measured outcomes.

Do not reset accepted commercial/provider decisions or resurrect superseded legal/accuracy approvals from old documents. Reconcile current owner decisions with the release packet, and distinguish agent review from professional or human review.

Completing the map plan establishes the feature only when its acceptance evidence passes. It does not automatically certify the whole app for App Store release, prove legal compliance, or establish competitive superiority.

## 15. Source references

All code links below are pinned to the inspected commit. Symbols/line numbers refer to that snapshot.

- **C01:** [CaseFileView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/CaseFileView.swift) — CaseFileModel, seven CaseFileTab cases, source reopening, CaseGlanceSection, coverage and report entry points.
- **C02:** [CaseWorkspace.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseWorkspace.swift) — CaseSourcePosition, CaseWorkspaceState/Store and CaseGlance.
- **C03:** [CaseContradictionsSection.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/CaseContradictionsSection.swift) — review model, in-place decisions, history, carry and source opening.
- **C04:** [CaseWorkspacePackageATests.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/KalsmritikoshTests/CaseWorkspacePackageATests.swift) — workspace, review, erasure-safe preference and request tests.
- **C05:** [EvidenceRequestFollowUp.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/EvidenceRequestFollowUp.swift) and [InvestigationAnalysisRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/InvestigationAnalysisRepository.swift).
- **C06:** [RelationshipGraphView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/RelationshipGraphView.swift) — archive query at lines 17–44, local state at 66 onward, re-layout on node change, recent-event loader and pair-source behavior.
- **C07:** [ForceLayout.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Brain/Trust/ForceLayout.swift).
- **C08:** [EvidenceCanvasView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/EvidenceCanvasView.swift) — grid, isSupported and header wording.
- **C09:** [GraphExplorerView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/Killer/GraphExplorerView.swift).
- **C10:** [WorkbenchVisualSurface.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Workbench/Visual/WorkbenchVisualSurface.swift) and [WorkbenchSurfaceProjector.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Workbench/Visual/WorkbenchSurfaceProjector.swift).
- **C11:** [CaseFileDocuments.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseFileDocuments.swift), [CaseFile.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseFile.swift), and [CaseFileService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseFileService.swift).
- **C12:** [InvestigationHypothesis.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/InvestigationHypothesis.swift).
- **C13:** [ChangesView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/ChangesView.swift), [ChangeDigest.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Knowledge/Monitoring/ChangeDigest.swift), and [AppState.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/App/AppState.swift#L4027).
- **C14:** [HistoryDiffEngine.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Knowledge/History/HistoryDiffEngine.swift).
- **C15:** [CaseFileRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseFileRepository.swift) — saveProfile, mutable allegation state, journal, case_actions and transactional writes.
- **C16:** [AdvancedSearchCompiler.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Retrieval/AdvancedSearchCompiler.swift) and [ChunksRepository.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Storage/Repositories/ChunksRepository.swift#L360).
- **C17:** [AppState+Search.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/App/AppState%2BSearch.swift) and [SearchView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/SearchView.swift).
- **C18:** [SmartCollectionsView.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/SmartCollectionsView.swift).
- **C19:** [JobResultHandoff.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/JobResultHandoff.swift).
- **C20:** [CaseOutputService.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift).
- **C21:** [Current UI walk record](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/docs/evidence/ui-scaffolding-2026-11-06/JOURNEYS.md), [PackageBTests.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/KalsmritikoshTests/PackageBTests.swift), [HelpRegistry.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/UI/Help/HelpRegistry.swift).
- **C22:** [CaseScopeFingerprint.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/CaseScopeFingerprint.swift), [CaseScopedEntityResolver.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/CaseScopedEntityResolver.swift), [SourceLocator.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Core/Models/SourceLocator.swift).
- **C23:** [CaseErasure.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/Personas/Investigator/CaseErasure.swift), [AppState+Erasure.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/App/AppState%2BErasure.swift).
- **C24:** [ModuleMatrixDriftTests.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/KalsmritikoshTests/ModuleMatrixDriftTests.swift), [ModuleMatrixDocument.swift](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/Kalsmritikosh/App/Modules/ModuleMatrixDocument.swift).
- **C25:** [Current owner decisions](https://github.com/sasmalgiri/kalsmritikosh/blob/68addaa4f8fc9e8197cabc2fef6d60978be3bc7a/SHIP_DECISIONS.md) — read the change-control log as well as older summary tables.

Companion documents:

- [Competitive research and implementation plan, 4 November](https://chatgpt.com/library?file_id=libfile_a4486a7fcacc8191a876d6429fd4569e&account_id=personal)
- [Measurably easier test protocol, 4 November](https://chatgpt.com/library?file_id=libfile_4a3efca508188191bb8de961f6db375f&account_id=personal)

