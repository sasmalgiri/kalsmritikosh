# RELEASE_EVIDENCE_INDEX

**Status: CURRENT.** Created 2026-07-24 (MASTER-001). One index for every release gate and the
evidence that proves it. A gate is **PASS** only when it names concrete, reproducible evidence
(a green CI run URL/id, a test identifier, a recorded owner-hardware run, a signed-build log).
No gate is PASS on assertion alone. Authority: `SHIP_DECISIONS.md` §3 + this file, under
`WHOLE_PROJECT_COMPLETION_PROGRAM.md`.

Evidence states: `PENDING` · `IMPLEMENTED` · `UNIT` · `INTEGRATION` · `REAL_DATA` · `RELEASE` ·
`PASS`.

## A. Functional gates
| Gate | Requirement | Evidence | State |
|---|---|---|---|
| F1 | All advertised formats pass a declared matrix | (link parser fixture matrix + CI job) | PENDING |
| F2 | All five persona primary workflows complete | (per-persona workflow run + acceptance) | PENDING |
| F3 | All material Claims reopen exact evidence | (verifier test ids) | PENDING |
| F4 | Report and receipt match | report/receipt identity tests (per template) | INTEGRATION |
| F5 | Previous work-product runs reopen | (OPS-004 reopen tests) | PENDING |
| F6 | Workflow runs resume after relaunch | (Stage 3 gate test) | PENDING |

## B. Truth gates (all must be zero / always)
| Gate | Requirement | Evidence | State |
|---|---|---|---|
| T1 | Persona truth divergence = zero | (cross-persona truth test) | PENDING |
| T2 | Unsupported material Claims exported = zero | fail-closed validator tests | INTEGRATION |
| T3 | Duplicate evidence counted as independent corroboration = zero | (QUALITY-002 independence tests) | PENDING |
| T4 | Silent global fallback = zero | no-fallback assembly tests + arch guard | INTEGRATION |
| T5 | Confirmed professional decisions always have a human audit record | (decision-audit tests) | PENDING |

## C. Security gates
| Gate | Requirement | Evidence | State |
|---|---|---|---|
| S1 | No network provider available in Release | PrivacyGate + release-build check | IMPLEMENTED |
| S2 | Sensitive evidence never leaks across scope | SensitiveScope ledger + authority hardening DONE (OPS-003A/A.1/A.2 — schema v71, lineage-aware effectiveLabel, brokenLineage denial, userConfirmed authority, 7th Claim branch, File→KO legacy sync, 32 SSA tests); OPS-003B retrieval+prompt enforcement corrected and DONE (SensitiveRetrievalPolicy fail-closed non-doc summaries + WalkStep evidence-KO filtering; HybridRetriever scoped path is sole authority — legacy privilege filter bypassed on scoped path; raw PromptTemplates overloads internal; PromptContextAuthorizer async revalidation; retrieveAuthorized()+promptAuthorizer on all 8 experts; answerStream access: mandatory non-optional; SensitiveScope.globalPermissive() for UI/test callers; 34 unit tests); enforcement surfaces (OPS-003C report/receipt/export + OPS-003D screen) PENDING | UNIT |
| S3 | Text + visual redaction verified | RedactionVerifier tests (F7) | PENDING |
| S4 | Temporary exports cleaned safely | (export-cleanup test) | PENDING |
| S5 | Prompt injection cannot alter system authority | PromptInjectionGuard tests | IMPLEMENTED |
| S6 | Archive traversal + malformed-file tests pass | (ingest hardening tests) | PENDING |

## D. Scale gate
| Gate | Requirement | Evidence | State |
|---|---|---|---|
| SC1 | Market only the largest corpus actually tested on owner hardware | recorded owner-hardware run (GB figure) | PENDING |
| SC2 | No unverified 100 GB / 1 TB claim in any copy | copy audit vs SHIP_DECISIONS | PENDING |

## E. Owner acceptance (per persona: Investigator, Researcher, Journalist, Individual, Lawyer)
For each persona, record a dated run:
```
create workspace → add real sources → complete primary workflow → inspect evidence
→ create work product → seal receipt → quit and reopen → resume/reopen everything
```
| Persona | Evidence (dated owner run) | State |
|---|---|---|
| Investigator | (pending) | PENDING |
| Researcher/Historian | (pending) | PENDING |
| Journalist | (pending) | PENDING |
| Individual | (pending) | PENDING |
| Lawyer | (pending) | PENDING |

## F. App Store gates
| Gate | Requirement | Evidence | State |
|---|---|---|---|
| AS1 | Signed archive | (archive log) | PENDING |
| AS2 | Clean Mac installation | (clean-machine run) | PENDING |
| AS3 | Offline workflow | (offline run) | PENDING |
| AS4 | Privacy manifest | (file) | PENDING |
| AS5 | Privacy policy | (draft/host) | PENDING |
| AS6 | Terms / EULA | (draft/host) | PENDING |
| AS7 | Support page | (draft/host) | PENDING |
| AS8 | Screenshots without personal data | (assets) | PENDING |
| AS9 | Limitations disclosed | (copy) | PENDING |
| AS10 | Early-access wording | (copy) | PENDING |
| AS11 | Final capability matrix | SUPPORTED_FORMATS / matrix | PENDING |

## G. CI evidence (CI-001A)
| Item | Evidence | State |
|---|---|---|
| Named GitHub checks on HEAD | `build-and-test` + `architecture-guards` (workflow "Build + Guards") | PASS |
| First green hosted run | run **30107577371**, conclusion **success**, SHA `fbd124358f5cf01583800b91a4a6ac1486e0eb1a`, 2026-07-24 | PASS |
| Full test target executed (from .xcresult) | verifier: `result=Passed total=781 passed=781 failed=0 (floor=781)` | PASS |
| Runner / toolchain | macOS 26.4, Xcode 26.6; test run `MACOSX_DEPLOYMENT_TARGET=26.4` (labelled compatibility override, within macOS 26 floor — NOT proof the pinned 26.5 point release passed) | RECORDED |
| Architecture guards green | `ci/guards/run-all.sh` on ubuntu-latest | PASS |
| Latest green hosted run | run **30140696084**, success, SHA `b0f33428332ff41cf5b88bd2bcd6fd3b55fe1f4a` (MIG-001B), verifier `total=794 failed=0 (floor=794)` | PASS |
| Migration matrix (MIG-001A) | 10 milestone fixtures → v67, preservation + integrity + fk, reopen | Integration verified |
| Migration fault atomicity (MIG-001B) | boundary faults A/B/E/F, genuine DDL/backfill/SQLITE_FULL failures, malformed partial schemas fail-closed | Integration verified |
| Real-archive migration | synthetic v66→v67 archive, correct hash semantics + preservation | Integration verified (synthetic) |
| Sanitized REAL owner archive — CAPABILITY | MIG-001C: `OwnerArchiveMigrationAcceptanceTests` + manifest schema + rewritten `verify-real-archive.sh` run the REAL migration path on an external archive; end-to-end self-test PASSED on a synthetic owner-like archive (report: `ci/migrations/fixtures/synthetic-selftest-001-acceptance-report.json`) | Integration verified |
| Sanitized REAL owner archive — RUN | owner supplies sanitized archive + manifest per `ci/migrations/real-archive-manifest.schema.json`; then `ci/migrations/verify-real-archive.sh <archive> <manifest>` | PENDING (owner run) |
| **CI-001B five named checks (all green)** | run **30144232341**, success, SHA `806325933ba9c7034488f80cd9ee1bcb23d1d6d2`, 2026-07-25: `architecture-guards` ✓ · `build-and-test` ✓ (794 executed, 0 failed, floor 794) · `migration-matrix` ✓ (23 tests, 4 suites) · `parser-fixtures` ✓ (78 tests, 20 suites) · `report-receipt-integrity` ✓ (68 tests, 6 suites). Group manifests: `ci/test-groups/*.json` @ this SHA. | PASS |
| parser-fixtures status rule | Green proves the CURRENTLY REGISTERED fixtures only — release gate F1 (complete advertised-format matrix) remains PENDING | RECORDED |
| sensitive-export job | NOT created — OPS-003 SensitiveScope unimplemented; a green placeholder would mislead | PENDING (depends OPS-003) |
| OPS-001 Issue Engine (schema v68) hosted-green | run **30148706330**, success, SHA `1673900ffb04907ac26130a4400794e61cf4f8a9`, 2026-07-25: build-and-test 810 total / 808 passed / 2 skipped (env-gated) / 0 failed, floor 810; migration-matrix 23/4 suites; parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓ | PASS |
| OPS-002 Task/Deadline Engine (schema v69) hosted-green | run **30156183281**, success, SHA `1f7bd0a2cc03edd342ec447468557e78ab7eed32`, 2026-07-25: build-and-test 837 total / 835 passed / 2 skipped (env-gated) / 0 failed, floor 837 (raised 810 → 837: +27 OPS-002 tests); migration-matrix 31/6 suites (adds ProfessionalIssueMigrationTests + ProfessionalTaskMigrationTests, floor 23 → 31); parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Truth rule `DeadlineCandidate ≠ Deadline` enforced in SQL (`UNIQUE(source_candidate_id)`) and repository, proven by tests. CORRECTION 2026-07-25: this row was recorded before the reviewer's NO-GO; it proves the IMPLEMENTATION run only. Acceptance required OPS-002.1 — closed by the row below. | IMPLEMENTATION PASS — acceptance closed by OPS-002.1 |
| OPS-002.1 confirmation-provenance hardening (schema v70) hosted-green | run **30160395578**, success, SHA `b84b11f9b8d6d26499764ceedc01728919a20421`, 2026-07-25: build-and-test 842 total / 840 passed / 2 skipped (env-gated) / 0 failed, floor 842 (raised 837 → 842: +4 ProfessionalTaskProvenanceTests, +1 v69→v70 migration test); migration-matrix 32/6 suites (floor 31 → 32); parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Corrections proven: rule confirmation requires candidate-scoped `deadlineBasis` links resolving to EXACT evidence (EvidenceBlock+source version, or Claim with exact evidence ref) — entity/context/task-scoped/KO-only links refused; cross-workspace primary Issue rejected (`crossWorkspacePrimaryIssue`); confirmed Deadlines only on open/inProgress/blocked tasks (`taskNotOperational`); rule ID + version persisted on `professional_task_reviews` (v70, NULL for pre-v70 rows, survives reopen). | PASS — acceptance still held pending OPS-002.2 |
| OPS-002.2 exact evidence binding + race-safe confirmation hosted-green | run **30182173679**, success, SHA `58e9f36a963b3e799018d89e895c49f8f6f2fafc`, 2026-07-26: build-and-test 845 total / 843 passed / 2 skipped (env-gated) / 0 failed, floor 845 (raised 842 → 845: +3 ProfessionalTaskProvenanceTests — mismatchedEvidencePairRefused, staleValidationCannotCreateDeadline, concurrentConfirmationsYieldOneDeadline); migration-matrix 32/6 suites; parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Schema unchanged (v70). Corrections proven: Claim evidence path now binds block and source version as a matched pair (`JOIN source_versions sv ON sv.id = b.source_version_id AND sv.id = r.source_version_id`) — block from version A with source_version B refused; `Database.withSavepoint` synchronous isolated closure makes all validation (candidate pending, task operational, precision, exact evidence, no existing Deadline) non-interleavable — validate-then-write race eliminated. Correction history: `04388c7` closed the original four-gap review. OPS-002.2 closed the remaining evidence-pair and confirmation-race findings. | PASS — closes OPS-002 final acceptance |
| OPS-003A SensitiveScope protection ledger (schema v71) hosted-green | run **30184159312**, success, SHA `44c4b3d`, 2026-07-26: all five checks green, xcresulttool floor 857 (raised 845 → 857: +12 SensitiveScopeRepositoryTests); migration-matrix 37/7 suites (adds SensitiveScopeMigrationTests); parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Schema v71: `sensitive_scope_assignments` + `sensitive_scope_reviews` (append-only; SAVEPOINT-atomic assign/revoke); `SensitivityInheritance.inherit(from:)` (max sensitivity, sticky privilege), `SensitivityInheritance.canRelease(_:at:)`; base CRUD `SensitiveScopeRepository`. NOTE: implementation run only — acceptance required A.1 + A.2, closed by the rows below. | IMPLEMENTATION PASS — acceptance closed by OPS-003A.2 |
| OPS-003A.1 protection authority lineage + legacy compatibility hardening hosted-green | run **30193365206**, success, SHA `1720bae`, 2026-07-26: build-and-test 891 IDE / 875 xcresulttool total / 889 passed / 2 skipped (env-gated) / 0 failed, floor 857 → 875 (+18 new tests: SensitiveScopeRepositoryTests 7 → 25); migration-matrix 37/7 suites; parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Schema v71 unchanged. Delivers 10 of 13 reviewer requirements: `SensitiveScopeTarget` (kind+id hashable key), `AssignmentAuthority` enum, target-existence validation in savepoint, lineage-aware `effectiveLabel` (8 kinds), `ProtectionResolution.brokenLineage`, legacy `knowledge_objects.privileged` sync (KO targets only), batch keyed by `SensitiveScopeTarget`, `reviews(forAssignmentID:)`, throwing `decodeAssignment`. NOTE: three gaps identified by reviewer in follow-on NO-GO — closed by OPS-003A.2. | HARDENING PASS — acceptance closed by OPS-003A.2 |
| OPS-003A.2 human-authority + Claim-lineage + File-legacy-sync hardening hosted-green | run **30194470481**, success, SHA `1fb9c7c`, 2026-07-26: build-and-test 882 xcresulttool total / 880 passed / 2 skipped (env-gated) / 0 failed, floor 875 → 882 (+7 tests: SensitiveScopeRepositoryTests 25 → 32); migration-matrix 37/7 suites; parser-fixtures 78/20; report-receipt-integrity 68/6; guards ✓. Schema v71 unchanged. Closes all three reviewer gaps over A.1: (1) `userDirect` renamed to `userConfirmed(actorID:confirmationID:privileged:)` — actorID stored as `assigned_by`, confirmationID embedded in origin as `"user_confirmed:<UUID>"`, whitespace-only actors rejected after trim in assign+revoke; (2) Claim lineage 7th UNION ALL branch: Claim→EB(`claim_evidence_ref.evidence_block_id`)→`evidence_block_objects`→KO→File — proven by `lineage_claimViaEBThroughEBOToProtectedFile` (ref row carries both `knowledge_object_id`=public KO and `evidence_block_id`=EB linking to restricted KO's file); (3) `assign()` propagates `privileged=1` to ALL child KOs when target is File+privileged; `revoke()` checks each child KO and clears `privileged=0` only when no remaining direct-KO or active-file privileged assignment covers it. `1fb9c7c` descends from `44c4b3d` and `1720bae` — this single hosted-green run proves the combined code state. | PASS — closes OPS-003A combined acceptance |
| OPS-003B retrieval+prompt enforcement — all 10 reviewer corrections applied (schema v71 unchanged) | Two-pass correction of reviewer NO-GO on local `717ca27`; floor raised 882 → 926 (+34 original tests → 916; +10 second-pass tests → 926; SensitiveRetrievalEnforcementTests 18 → 27; SensitivePromptEnforcementTests 16 → 17). All 10 required corrections: (1) `globalPermissive()` removed from `SensitiveScope`; `testUnrestricted(purpose:)` is `#if DEBUG`-only with sentinel UUID; all production callers use `testUnrestricted()` in DEBUG; (2) raw `RetrievalResult` PromptTemplates overloads are now `private` (not merely internal) — compile-time enforcement proven by updated test 13 + arch guard test 17 (`unscopedRetrievalThrowsWhenNoAccessContextPresent`); (3) pre-enrichment entity filter in `HybridRetriever` before authority density seeding loop; pre-enrichment authority KO filter before chunk injection; blocked entities/KOs cannot seed DocumentFitness or authority-chunk injection; (4) workspace enforcement: `SensitiveRetrievalPolicy` checks `workspaceRepository.koIDsInWorkspace` + `entityIDsInWorkspace` in step 3; fails closed on any repo error; sentinel scope skips enforcement; proven by 9 new workspace enforcement tests (cross-workspace chunk/event/entity denied, same-workspace allowed, multi-workspace source, repo-error fail-closed, sentinel bypass); (5) memory path: `phase1Instant` checks `memory.keyEventIDs` (empty → withheld), then filters events through policy — any blocked event withholds entire narrative; proven by `memoryPhase1WithheldWhenContributingEventNotInWorkspace`; (6) table fast path: `tableFastPath` always returns nil — cannot prove block→KO workspace membership; (7) all `MasterBrain` entry points (`answer`, `answerWithDiagnostics`, `computeVerified`, `tryReconstructHistoryStreaming`, `phase1Instant`, `tableFastPath`) require mandatory non-optional `access: SensitiveAccessContext`; corrective retrieval in `computeVerified` and `tryReconstructHistoryStreaming` both use scoped retrieve path; (8) `Expert.retrieveAuthorized()` throws `SensitiveRetrievalError.unscopedRetrieval` when `access == nil`; raw `PromptTemplates` overloads `private`; both enforced by compile time + arch guard test; (9) S2 remains UNIT until hosted-green; (10) amending `717ca27` to fold all corrections. PENDING hosted-green. | UNIT |
| Branch protection ruleset for `main` | OWNER repo-settings step — now require ALL FIVE checks: `build-and-test`, `architecture-guards`, `migration-matrix`, `parser-fixtures`, `report-receipt-integrity`; branch up-to-date; conversations resolved; no force-push/deletion | PENDING (owner) |

---

**Note on current CI evidence.** The latest `main` records **781/781 tests green on a real
hosted GitHub run** (see §G) — local counts are no longer the sole gate. Remaining F-series
gates stay below `PASS` until their specific jobs exist (CI-001B) and the branch ruleset is
configured + recorded here.
