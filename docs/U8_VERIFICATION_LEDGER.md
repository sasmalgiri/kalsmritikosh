# U-8 — Completeness verification ledger (implement-all)

Each 🔎 item from the instruction pack, confirmed against the tree at the
`v11-implement-all` head. One line each; a miss becomes a unit.

| Item | Verdict | Evidence |
|---|---|---|
| list composer (not only a router case) | ✅ present | `EventAnswerComposer.composeList` |
| aggregation composer | ✅ present | `EventAnswerComposer.composeAggregation` |
| comparison composer | ✅ present | `EvidenceVerifier.composeComparison` |
| conflict / evolution composer | ✅ present | `EvidenceVerifier` conflict rendering (both values, both citations) at the `:957` region; `QuestionShape.conflict` routed to it |
| relationship composer | ✅ present | `EvidenceVerifier` `.reconstructRelationship` path (`:177`) → reconstruction engine; `QuestionShape.relationship` |
| compose twin is post-hoc / non-blocking | ✅ present | `ComposeTwin.swift:79` — "Fired AFTER an answer ships; its only outputs are a flag/receipt" |
| node scoping | ◐ present at the answer layer, not in `SubjectResolver` | `AppState.composeToolGroundedAnswer` writes the A2.2 "Scoped to: ‹node›" receipt via the `entity_communities`/`community_summaries` query; `SubjectResolver.resolve(question:anchors:)` still resolves against anchors (its header notes it "proceeds unscoped, as today"). Scoping HAPPENS; moving it into the resolver is a future refinement, not a blocker. |
| reviewer sample archive exists and loads | ✅ present | `App/DemoArchive.swift` (the "Try with sample documents" ledger) |
| alias expansion (A2) | ✅ present | `SlotFieldResolver.expandAliases`, used in `AppState.composeToolGroundedAnswer` |
| two-part decomposition (A2) | ✅ present | landed in #141 (verified in the -3 instruction pack's own ledger) |
| placement twin (VT) | ✅ present | `Knowledge/Twins/PlacementTwin.swift`, on the reachability manifest |
| second-door persistence | ✅ present | `composeStoryAnswer → persistStoryFromAsk` |
| archive-wide NF numbers | ✅ present | `archiveTotals` provider (#139) + U-6 `EvidenceSufficiency.archiveDocumentsSearched` |
| RS-U6 model-version stamp in receipts | ✅ present | `LegalNotice.modelStamp()` in `ToolGroundedComposer` receipt lines |

**Misses promoted to future units (not 1.1 blockers):**
- Node scoping inside `SubjectResolver.resolve` (currently at the tool-grounded layer). Filed for the FM-native lane (U-7 T0 work), where the plan twin will carry the node.

Verified during the implement-all run; no code change — this is the audit record for the end-check ledger.
