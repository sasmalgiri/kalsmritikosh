# Case-methods implementation TODO (2026-11-16)

This is the work order for `docs/Kalsmritikosh_Case_Methods_Gap_Analysis_and_Implementation_Plan_2026-11-16.md`.
The evidence for each gap is in `docs/CASE_METHODS_GAP_RECONCILIATION_2026-11-16.md`. Status is tracked only
in `docs/SMART_MAP_COMPLETION_MATRIX.json`; this file is the order of work, not a second tracker.

**Rules for every item** (plan §G3–4, CLAUDE.md):
- Keep changes small and reviewable. Read the files before editing.
- Use no model names outside Routing/Providers.
- Make schema changes only as a new versioned migration wrapped in a SAVEPOINT. Never edit a shipped migration.
- Map onto existing records first (method runs, tasks, AI proposals, evidence requests, query receipts, change
  dependencies). Add only the relationships or fields that are missing.
- Each item records:
  - the changed entry points;
  - old-data behaviour;
  - the decisive positive and negative scenarios;
  - its actual verification level.
- Run the targeted suites for every changed type, and add regressions where they are missing.
- A build passing is not verification. A UI result needs a recorded interaction.

Legend: **[a]** local agent work · **[d]** needs the owner · **[c]** needs real people. Each item ends with
`→ ROW` (its tracker row).

---

## Stage 0 — Confirmed defects (do first, one commit each)

- [ ] **0.1 Root-cause report sentence** [a] → REPORT-11, OUTPUT-08
  - Remove the fixed "causes traced to evidence and the root cause confirmed by a human" line
    (`RootCauseAnalysis.swift:288`).
  - State the method and what was actually recorded instead.
  - Regression: a draft with a starred cause and only a typed note never says "confirmed by a human"; check
    every route (preview, Markdown, copy, print).
- [ ] **0.2 Contradiction cap disclosure** [a] → SEARCH-13, PERF-11
  - Report "compared N of M documents (the first N; the rest were not compared)" in the run text and the AI
    coverage line.
  - Delete "The rules checked every document." when M > N.
  - Regression: a 401-document case.
- [ ] **0.3 Partial lookup shown as no match** [a] → ADAPT-07
  - In `CaseEnrichment.swift:89`, an empty page with `hasMore` is `.partial`, not `.noMatch`.
  - Regression in SmartMapS12Tests.
- [ ] **0.4 Studio export skips the source re-check** [a] → REPORT-11
  - `exportNow`, `copyNow` and `printNow` call `storage.package` with `authorise`, as the case output routes do.

## Stage 1 — Correct the report, freeze the baseline (plan §D.1)

- [ ] **1.1 Separate evidence state from sign-off state** for root-cause conclusions [a] → REPORT-11
  - Reconcile `RCAApproval.status` with the repository approval so the two cannot disagree on screen or in
    export.
- [ ] **1.2 Inconclusive conclusion** [a] → REPORT-11
  - Add an explicit "inconclusive on the available evidence" value that is complete without a root cause.
  - It must export honestly on every route.
- [ ] **1.3 A reviewed conclusion names its basis** [a] → REPORT-11
  - Supported conclusions list their cited evidence and their review decision.
- [ ] **1.4 Studio links** [a] → REASON-13
  - Add optional `StudioEvidenceRef` citations and explicit assumptions on ideas, fishbone causes and Why
    answers, with a decoding default so old records read unchanged as investigator text.
  - Add "Link source", "Record assumption" and "Request evidence" (reusing the map's request flow).
  - Add an RCA branch to `StudioCasePrefill`.
- [ ] **1.5 Re-export as a versioned replacement** [a] → REASON-13, OUTPUT-02
  - Earlier frozen exports stay byte-identical.
  - A re-export is labelled as a replacement of revision n.
- [ ] **1.6 Recheck the 52 reachability flags** one by one, closing or keeping each with its route or
  reason [a] → QA-16
- [ ] **1.7 Reconcile with the 385-row plan** [d → a] → BASE-10
  - Owner: put the plan and its register in `docs/`.
  - Agent: map every requirement to a row or a recorded reason.
- [ ] **1.8 Document the output routes** that carry Studio text (file, copy, print, case package) [a] → BASE-04

## Stage 2 — Coverage at case scale (plan §D.2)

- [ ] **2.1 Comparison coverage receipt** [a] → SEARCH-13
  - Contents: eligible versioned records, unreadable/unindexed records, records and passages examined,
    subject/batch bounds, remaining work, cursor and termination reason.
  - Store it with each rules run and AI look.
- [ ] **2.2 Question-directed comparison planning** [a] → SEARCH-13
  - Select documents by the case question, record IDs, aliases, dates and account/instrument identifiers, not
    by UUID order.
  - Stable order with a tie-breaker.
- [ ] **2.3 Paging and persisted continuation** [a] → SEARCH-13
  - Replace the silent 400 cap with pages and a Codable continuation that survives a restart.
  - The continuation is invalidated when the corpus revision changes; a changed corpus runs a delta.
- [ ] **2.4 Search receipt gaps** [a] → SEARCH-06, SEARCH-11
  - Make "withheld" distinct from "excluded".
  - Persist the continuation.
  - Give a continuation at the 20,000-document cap.
- [ ] **2.5 Cross-batch comparison** [a] → SEARCH-14
  - Carry identifiers and aliases between batches.
  - Compare promising passages from different groups.
  - Record dropped subjects and passages in the receipt.
- [ ] **2.6 Bounded, resumable units** [a] → SEARCH-14
  - Save progress per completed unit, with time, memory and paid-usage bounds.
  - Cancel and resume skip nothing and do not charge twice.
- [ ] **2.7 Copied text is not independent support** in comparison [a] → SEARCH-14, REASON-05
  - Apply `CaseDerivativeText` / origins in the rules and AI conflict paths.
- [ ] **2.8 Pass tests** [a] → SEARCH-13, SEARCH-14
  - A decisive record beyond the old limit is reached on continuation.
  - An alias split across batches connects.
  - A duplicate statement gives one origin.
  - Failed parsing or denied access is never absence.

## Stage 3 — First AI-off map journey and independent check (plan §D.3)

- [ ] **3.1 The two commands** [a] → MAP-13
  - "Investigate this discrepancy" and "What haven't we considered?" on the whole case and in the inspector
    for case, question, report point, passage and transaction nodes, with keyboard and list equivalents.
  - Back restores the node, the view and the presentation.
- [ ] **3.2 Working context** [a] → BRIEF-09
  - Add "rests on an assumption" and "not checked" sections, plus the comparison/search receipt line, to
    `CaseMapBrief`.
- [ ] **3.3 Check this claim** [a] → SEARCH-15
  - An editable structured query pre-filled from the lead, with the filters shown.
  - Matching and contrary records.
  - Duplicate and currency rules where they apply.
  - A reproducible claim receipt linked to the lead and the revision.
- [ ] **3.4 Money on screen** [a] → MONEY-13
  - Drill a figure to its entries (`drill`).
  - Confirm or split a candidate same-payment pair with a reason (`decideMoneyIdentity`).
  - Each entry opens at its source.
- [ ] **3.5 Versioned result review on the map** [a] → ACTION-13
  - Switch "Record result" / "Accept" / "Return" to `CaseActionWork.recordActionResult` /
    `reviewActionResult`.
- [ ] **3.6 Result to revised brief** [a] → ACTION-13
  - An accepted result offers a new brief version citing it.
  - The earlier brief stays readable.
- [ ] **3.7 Journey test** [a] → QA-17
  - Point → alternative → check → local query → receipt → child action → reviewed result → revised brief.
  - Cover the duplicate-payment pass: two debits, a refund, every entry opened, return to the node.
- [ ] **3.8 UI walk** of 3.1–3.6 in the running app, with the interaction recorded [a, needs an unlocked Mac]
  → MAP-13, MONEY-13, ACTION-13

## Stage 4 — 16-method review and check prioritization (plan §D.4)

- [ ] **4.1 Method applicability review** [a] → REASON-14
  - One assessment per registered method version for a question, revision and scope: useful now / covered /
    needs input / later / inapplicable, each with its reason, or "not assessed".
  - No method is silently omitted.
  - Map it onto existing method runs or tasks first.
- [ ] **4.2 Offline guidance per method** [a] → REASON-14
  - Short deterministic prompts tied to the question.
  - Reuse completed runs at the right revision.
  - "Perform" opens or creates the run through the existing lifecycle.
- [ ] **4.3 Make the methods reachable from the map** [a] → REASON-14
  - The review opens from the MAP-13 commands; the full method sheet is optional.
- [ ] **4.4 Line of inquiry record** [a] → REASON-15
  - Extend `InvestigationHypothesis` (migration) with:
    - predictions;
    - contrary and dependent sources;
    - assumptions;
    - the discriminating observation;
    - originating methods;
    - pursued / deferred / merged (reversible) / reopened statuses.
- [ ] **4.5 No resurrection** [a] → REASON-15
  - Reruns on unchanged inputs keep dismissed lines dismissed.
  - A changed source raises a line again with the exact reason (reuse `CaseProposalMemory` semantics).
- [ ] **4.6 Deduplicate checks by observation** [a] → ACTION-14
  - Add an observation key and a request ↔ hypothesis relationship, so one request can serve several
    hypotheses.
  - Merges are reversible decisions, offered only when the targets are compatible.
- [ ] **4.7 Check shortlist** [a] → ACTION-15
  - Order: a sourced expiry first, then discrimination between live explanations, then effort/cost and
    feasibility.
  - Stable ties. Unknowns stay unknown.
  - Override with a reason.
  - Show the best few plus "Show all", and a continuation at the budget.
  - Kept apart from the obligations in `CaseNextSteps`.
- [ ] **4.8 What each path rests on** [a] → REASON-16
  - Wire `supportOrigins`, `dependenceReviews` and `alternatives` into the inspector.
  - Show "independence unknown" when not reviewed.
  - Show minority paths with the reason they were set aside.
- [ ] **4.9 Pass tests** [a] → REASON-14, ACTION-14, ACTION-15, REASON-15
  - With no contradiction, all 16 are accounted for.
  - Three methods produce one certificate request.
  - A minority path survives.
  - An imminent log expiry outranks a cheap check.
  - Two similar payments to different people do not merge.

## Stage 5 — Optional AI and authorized network work (plan §D.5)

- [ ] **5.1 AI method-review task** [a] → AI-15
  - A typed `CaseAITaskKind` validated to the same contract as 4.1.
  - Unverified suggestions labelled as ungrounded.
  - Bounded batches with a visible continuation.
  - Scripted fake readers only, until the owner allows paid tests.
- [ ] **5.2 Bounded failure outcomes** [a] → AI-15, AI-11
  - Unavailable provider, refusal, timeout, malformed output, changed key/provider/permission, protected
    source and stale case.
- [ ] **5.3 "AI only" and "Network only" modes** [a] → ADAPT-10
  - Consent is never transferred between providers or to a specialist.
- [ ] **5.4 Request delivery states** [a] → ADAPT-10
  - Draft / copied / handed over / confirmed sent / uncertain, reusing `case_external_effects`.
  - Reconcile uncertain delivery before a retry.
  - Preview the recipient, fields, purpose, cost and restrictions.
- [ ] **5.5 Returns staged in intake** [a] → ADAPT-10
  - Keep the original, time, source and scope, linked to the question and item.
  - A partial reply leaves the remaining items open.
- [ ] **5.6 Live submission** through a supported integration [d] → ADAPT-07, ADAPT-10
  - Owner: choose a provider and supply the key.
- [ ] **5.7 Paid relay** [d] → SHIP-13
  - Owner: deploy the relay and supply its host.
  - Agent: signed-build observation of sends and metering.
- [ ] **5.8 Any second provider** (Sol/Astra) [d] → AI-16
  - Owner decision first; then its own adapter with its own consent and tests.

## Stage 6 — Propagate results, close honestly, hand over (plan §D.6)

- [ ] **6.1 Register the new kinds in the dependency graph** [a] → CHANGE-11
  - Method assessment, line of inquiry, comparison/query receipts, evidence request and returned result, in
    `CaseDerivedKind`.
  - Invalidation is limited to the affected results and paragraphs.
- [ ] **6.2 Late contributions on screen** [a] → CHANGE-11, CHANGE-07
  - Show the late-contribution queue, with authorized reopening.
- [ ] **6.3 Handover brief** [a] → BRIEF-10
  - Sections: strongest competing explanation, checks completed with their scope, unresolved questions,
    urgent work, decisions and conditions for reopening.
  - "Inconclusive on the available evidence." when that is the honest outcome.
- [ ] **6.4 Recipient diff** [a] → BRIEF-10
  - What changed since the recipient's prior briefing, with a deep link to each source.
  - Keep both the initial and the amended handovers.
- [ ] **6.5 Pass tests** [a] → CHANGE-11, BRIEF-10, RECOVERY-05
  - A corrected lab result marks its two dependants and leaves the unrelated money finding alone.
  - After backup and restore, links resolve, expired authority stays expired and requests are not re-sent.

## Stage 7 — Related tracks (run alongside Stages 2–6)

- [ ] **7.1 Field capture into a pending inbox**, confirmed before admission [a] → IN-13
- [ ] **7.2 OCR / transcript preview** at region or timestamp, with correction [a] → IN-14
- [ ] **7.3 Competitor-derived outcomes** (CAP-01–10) [a, after 1.7] → QA-18
  - Each shown, or recorded as out of scope with its reason.
- [ ] **7.4 Profile the 6.16 s cold projection** on named hardware [a] → PERF-13, PERF-01, PERF-05/06
  - Also record the 1.63 s intake stall and the 5,000-document stress run.
- [ ] **7.5 Real-window density and accessibility walk** [a, needs an unlocked Mac] → MAP-12, QA-12
- [ ] **7.6 Multi-investigator scope** stays labelled solo for v1 [d/b] → TEAM-*, ACCESS-*, SEC-04
  - The shared release follows existing rows; no new work here.
- [ ] **7.7 Distribution** [d] → SHIP-*, QA-13
  - Freeze the SHA; run `bash scripts/release-check.sh`; follow `ci/release-gates.json`.

## Stage 8 — Decisive fixture and proof of benefit (plan §E–F)

- [ ] **8.1 Pharmaceutical-quality fixture** [a] → QA-19
  - Two confirmations from one raw run, a namesake instrument, a calibration record beyond 400 documents, an
    expiring log with a sourced deadline, one withheld and one unreadable record.
  - Variants: decisive record unavailable; a later correction.
  - Build it early, as the regression target for Stages 2–6.
- [ ] **8.2 Run the five §E steps AI off** [a] → QA-19
  - Including the inconclusive variant and the amended handover.
- [ ] **8.3 Four-mode comparison** on matched cases per family (plan §F) [c, d] → BENEFIT-09
  - Also the 16-method review against plain AI follow-ups.
  - Preregister it as an amendment; keep PROTOCOL.md intact.
- [ ] **8.4 Signed-build recording** [d] → SHIP-*, BENEFIT-09
  - Intake → method review → independent search → request → result → amended brief.
  - List the remaining external dependencies with owner, action and evidence required.

---

**Exit (plan §G5):** the solo local journey (Stages 0–4, 6) is a first release on its own. Full completion also
needs:
- real field capture;
- supported remote operations;
- full coverage disclosure;
- team authorization;
- cross-domain benefit, at the scope actually claimed.
