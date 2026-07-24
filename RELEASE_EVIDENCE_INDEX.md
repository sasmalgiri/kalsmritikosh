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
| S2 | Sensitive evidence never leaks across scope | SensitiveScope (OPS-003) screen/prompt/export tests | PENDING |
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
| Branch protection ruleset for `main` | OWNER repo-settings step — require `build-and-test` + `architecture-guards`, up-to-date, conversations resolved, no force-push/deletion | PENDING (owner) |

---

**Note on current CI evidence.** The latest `main` records **781/781 tests green on a real
hosted GitHub run** (see §G) — local counts are no longer the sole gate. Remaining F-series
gates stay below `PASS` until their specific jobs exist (CI-001B) and the branch ruleset is
configured + recorded here.
