# Smart map M0 — baseline, inventory and contracts (2026-11-08, slice S1)

Authority: `docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md` (tracks BASE, ARCH, DATA; §E, §G) and the
2026-11-08 feasibility plan. Status per task lives only in `docs/SMART_MAP_COMPLETION_MATRIX.json`; this page holds the
records those rows point at. Source state: `investigations-next` at `dd44c70e` plus the uncommitted S1 work
(`docs/RELEASE_CANDIDATE.md`, "Current source state").

## 1. Status documents reconciled (BASE-02)

| Document | What it says | How to read it now |
|---|---|---|
| `docs/RELEASE_READINESS.md` (2026-10-30) | "not ready to release", gates F1–F7, 168 jobs "met to integration level" | **History.** The current release status is the output of `bash scripts/release-check.sh` and `docs/RELEASE_CANDIDATE.md`; the gates the owner removed on 2026-11-04 (accuracy, practitioner, user evaluation) are not restored here |
| `docs/CASE_MAP_EXECUTION_MATRIX.md` (living-map M0–M10, last run 2026-11-07 at schema 173) | UI / signed-build / human columns NOT RUN | Still correct for the living-map packages. `docs/evidence/ui-walk-2026-11-07/JOURNEYS.md` items 5 (search) and 6 (map presence) record PASS in one Debug walk on the sample case and NOT RUN in a later pass of the same file; presence in a Debug walk is not the package's UI verification, so the NOT RUN cells stand. The smart-map tasks are tracked in the smart-map matrix, not there |
| `docs/RELEASE_CANDIDATE.md` | was: schema v170 as the current candidate | Fixed 2026-11-08: a "current source state" section (schema v177, base `dd44c70e`, local changes); the v170 section is marked as the 2026-11-06 history |
| PR #169 summary | written for the 2026-11-06 packages | Not edited from here (GitHub); the next push's summary must cite this page and the matrix |

No earlier run is deleted; each document keeps its history and now says which part is current.

## 2. Canonical data inventory (BASE-04, DATA-08)

The table-level inventory is code: `Kalsmritikosh/Investigate/CaseFile/CaseDataInventory.swift` — every case store with
its record family (§E), owning type, erasure lifecycle and map representation. `SmartMapContractsTests.inventory`
checks it against the migrated schema: any table that carries `case_id`, is named `case_*`/`investigation_*`, or declares
a foreign key to a registered case table must be registered, so a new store without lifecycle handling fails the check.
Every store is in the one encrypted ledger, so a complete backup carries it.

Explicitly outside the table inventory, with the owner of the gap:

| Class | Where it lives | Lifecycle today | Open work |
|---|---|---|---|
| Documents, versions, blocks, chunks, vectors | library tables shared by cases | erased with a case only on request (exclusive sources) | SRC / SEC |
| Original-file vault copies | sandbox container, beside the ledger | erased with exclusive sources | RECOVERY |
| Vector cache | sealed file beside the ledger (AES-GCM, key from the ledger key) | derived; rebuilt from the ledger (erasure behaviour not re-checked here) | RECOVERY |
| Preferences (map memory, workspace) | `UserDefaults` | identifiers and geometry only; erased with everything | SEC-07 |
| Reminders | system Reminders | no titles; removed on case/person/full erasure | — |
| Queued work (`enrichment_jobs`, `job_events`) | ledger, library-scoped | not case data | AUTO — case-scoped queued work has no store yet |
| Financial objects (accounts, transactions, invoices) | the forensic studio's drafts (`ForensicEngagement` in `studio_records`) and job results; no case table of their own | erased with the case's drafts | MONEY — a canonical money record class is still to be modelled |
| Action types | `case_actions.action` free text (one log) | erased with the case | AUTO / TIME |

## 3. Jobs and personas against the map (BASE-05)

The job catalogue is measured by `JobOutcomeMatrixTests.matrixIsMeasured` (`docs/JOB_OUTCOME_MATRIX.md`, 168 advertised
jobs, content creator hidden): 109 launches return case rows, 59 produce a record; 20 jobs have a job-specific studio work
product with a verifying suite, 97 a contract result from a shared executor, 12 a generic kind work product, 39 generic rows
only. Registration is not counted as a work product anywhere.

Map representation, one rule for every retained job: a job's result is a `job_results` row (inventory: Outputs, not on
the map). It reaches the case map **only** when the person carries a row into the case — `JobResultHandoff` makes it
allegation evidence (map: `allegationEvidence` link with its passage) or a report item (`reportItem`); a studio draft is a
`studio_records` row (Outputs). No job writes map records directly. The 39 "generic rows only" jobs therefore have no map
representation beyond what the person carries; each needs either a real work product or retirement (ADAPT-01).

## 4. Baseline journeys (BASE-06)

Named source: `dd44c70e` + S1 working tree, Debug test host on this Mac, 2026-11-08. Fixtures: the INV-2041 case
(`AcceptanceSupplierPayment`) and the INV-104 case (`AcceptanceSupplierINV104`, §G). Service level only — not a UI walk,
not a signed build.

| Journey | Suite (real run, 2026-11-08) | Result |
|---|---|---|
| Import, scope review, tasks, report, reopen (INV-2041) | `AcceptanceCaseTests` | passed |
| Import with duplicate / unreadable / unsupported items, money, report + amendment, discrepancy, child actions (INV-104) | `SupplierINV104AcceptanceTests` | 1/1 passed |
| Search | `CaseSearchTests` | passed (part of 58/58) |
| Source inspection (cited version) | `CitedSourceResolverTests` | passed (part of 58/58) |
| Contradictions | `CaseContradictionFinderTests` | passed (part of 58/58) |
| Export | `CaseOutputServiceTests` | passed (part of 58/58) |
| Backup / restore | `CompleteBackupTests`, `CaseMapRecoveryTests`, `SmartMapContractsTests.identityRoundTrip` | passed |
| Purchase | `PurchaseTests` (StoreKit simulation only) | passed (part of 58/58) |

Later work is checked against these suites on a named build; a UI walk and a signed build are still to be recorded.

## 5. Team architecture — preparation only (ARCH-08)

Not decided; needs the owner (hosting account, cost) and a server/identity service. What the code now gives a future
service, and the decisions it must make:

- **Already in place locally:** stable actor ids per case with legacy names that can never be promoted to accounts
  (`case_actors`); event / receipt / entry / review times kept apart; every case write in one savepoint with its action
  row and before/after revision; frame membership and dependencies as their own records (mergeable by id); the erasure
  register and newer-schema refusal.
- **Decisions required:** (1) client/server split — the Mac stays the system of record per participant, with a relay-style
  service carrying signed contributions, or a hosted case store; (2) identity — Sign in with Apple or another IdP, and how an
  authenticated id binds to `case_actors.identity_ref`; (3) synchronisation — an outbox of committed case actions (ARCH-09)
  replayed by id, conflicts surfaced as conflicts, never averaged; (4) encryption and key boundaries — per-case keys shared
  only with authorised participants, the service holding ciphertext only; (5) provider sends — whether AI calls stay on the
  sender's own route; (6) offline behaviour — contributions queued and re-checked for scope and authorisation on apply;
  (7) operating cost — priced into the plans (owner decision 2026-11-01: the owner pays nothing).
- **Rejected:** the X-5 shared-folder sync as the team transport (one person's devices only; no identities, no
  authorisation) — the TODO's acceptance excludes a shared-file mockup.
