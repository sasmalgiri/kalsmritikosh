# Acceptance traceability — AT-01 … AT-20 (Stage 13 / T-G5.2)

Maps each release-acceptance scenario to the concrete behavior, the test(s)
or commit that cover it, and an honest status. This is the release-evidence
spine required by the Completion Directive's Stage 13.

**Numbering note.** The directive itself (an external attachment) is not in the
repo, so the AT *numbers* below are reconstructed from the gate structure and
the fragments the plan anchors (AT-05 composer, AT-15 backup, AT-17 deletion,
AT-18 adversarial are confirmed; the rest are provisional slots to reconcile
against the directive's authoritative list before sign-off). The *behaviors*
and their coverage are real.

Status legend: ✅ covered by an automated test · 🧪 covered but needs a booted
app to fully exercise (walkthrough item) · 🔒 owner-gated (no agent can run it).

| AT | Behavior (release scenario) | Covered by | Status |
|----|-----------------------------|------------|--------|
| AT-01 | App boots with no provider/model and stays usable (deterministic answers) | `ReleaseCapabilityProfile`, U-0 privacy closure; boot path | 🧪 |
| AT-02 | Ingest a mixed folder; per-source state is honest (parsed/partial/preserved/unsupported/failed) | `FileIndexStatusTests`, `OCRAccountabilityTests` | ✅ |
| AT-03 | Double-boot performs zero writes when nothing changed (idempotent) | `DoubleBootZeroWriteTests`, `DurableReadinessProofTests` | ✅ |
| AT-04 | Precise Q&A (Workflow A): answer separated from evidence; every claim cited | `AnswerPresentationTests`, `AskTheLedgerTests` | ✅ |
| AT-05 | Composer acceptance + adversarial: question-is-not-proof, wrong-date, subject-swap, injection, negation, currency | `AskTheLedgerTests` (question-is-not-proof, wrongDate, subjectSwap, injection, negation, currency), `ToolGroundedComposer` | ✅ |
| AT-06 | Chronology (Workflow B): dated chain, event-time vs doc-time, bounded causal links | `CausalLinkPolicyTests`, `LedgerToolsTimelineShelfTests` | ✅ |
| AT-07 | Comparison brief (Workflow C): agree / disagree / different-unit / unresolved, sourced | `ComparisonMatrixTests`, `ComparisonBriefTests`, `ComparisonServiceTests` | ✅ |
| AT-08 | Workflow C on live data: read each doc's facts, discover shared fields, honest verdicts | `ComparisonLedgerResolverTests`; `AppState.compareDocuments` adapter (5f3ea63) | ✅ |
| AT-09 | Comparison brief is reachable + renders + exports Markdown | `.compareDocs` route (4db6546); `ComparisonBriefView` #Preview render-verified | 🧪 |
| AT-10 | Unanswerable questions ABSTAIN (no citation escape) | `GoldWallTests` | ✅ |
| AT-11 | Evidence sufficiency is disclosed, not hidden | `EvidenceSufficiencyDisclosureTests` | ✅ |
| AT-12 | Scope is enforced BEFORE retrieval (fail-closed under narrowed scope) | Access-context threading (eeaa298); `SensitiveRetrievalPolicy` | ✅ |
| AT-13 | Field provenance cites source blocks + real snippets, not the subject id | `AskTheLedgerTests.lookupFieldCitesSourceBlocksNotSubject` (60a2c68) | ✅ |
| AT-14 | Durable conversation reopening restores citations/status/receipt | `DurableReopenTests` (schema v128) | ✅ |
| AT-15 | Backup to a clean profile round-trips; incomplete backup is refused, not partial | `BackupServiceTests`, `BackupManifestTests`; Settings action (ed8960f) | ✅ |
| AT-16 | Migration safety: every milestone version 0→128 migrates with row/FK integrity | `MigrationMatrixTests` | ✅ |
| AT-17 | Deleting a document cascades to all derived rows; no orphaned vectors | `DeletionCascadeTests` (eae45ea) | ✅ |
| AT-18 | Prompt-injected document text is defanged, not obeyed | `AskTheLedgerTests.documentInjectionIsDefangedNotObeyed` (2acfab4) | ✅ |
| AT-19 | Source opening resolves a citation to an exact location, with whole-document fallback | `SourceLocationTests`; exact-passage highlighting UI | 🧪 |
| AT-20 | Persona/professional workflows trace end-to-end (approval gates, redaction, receipts ≠ admissibility) | `LawyerPersonaAcceptanceTests`, `JournalistIndividualAcceptanceTests`, `ResearcherPersonaAcceptanceTests`, `PersonaAcceptanceInvestigatorTests` | ✅ |

## Remaining to fully close Stage 13
- **🧪 walkthrough items (AT-01, AT-09, AT-19):** need the app booted and viewed
  once to confirm render/behavior — the live walkthrough. Logic underneath each
  is already tested.
- **🔒 owner-gated (not in this table):** M4 perf budgets (Stage 9), signing /
  notarization / StoreKit / submission (Stage 14), screenshots + usability
  participants (Stage 15), and the live end-check → reseal → merge to `main`.
- Reconcile the provisional AT numbers above against the directive's
  authoritative list before release sign-off.
