# Team work over a shared folder — design (ARCH-08, owner decision 2026-11-18)

Status: implemented on `investigations-next` (schema v198). The owner chose this architecture on 2026-11-18 instead of a server or
CloudKit: **no server, no accounts, no network**. Tracker row ARCH-08's acceptance text ("not a shared-file mockup") is overridden
by that decision. What a shared folder cannot give is listed under *Not provided* and stays open in the tracker.

## Responsibilities

| Part | Where | Does |
|---|---|---|
| Shared folder | any folder the people can all reach (SMB/AFP share, external disk, a synced folder) | holds `case.json` (name, `teamCaseID`, purpose), `members/` (display name + public key), `log/<member>.jsonl` (each Mac's signed, hash-chained log), `requests/<id>/inputs/`, `submissions/<id>/` |
| Each Mac (client) | `App/Team/TeamCase.swift`, `TeamCaseExchange.swift` | writes only its own log; signs every entry with its Keychain key (`TeamIdentity`, this device only); reads others' logs only up to their first bad entry |
| The case (ledger) | `Investigate/CaseFile/CaseTeamWork.swift`, `CaseTeamRecords.swift`, `CaseTeamService.swift`; tables `case_team_*` | link, requests, submissions file by file, shared work with its delivery state, conflicts |
| Intake | `InvestigationWorkspaceIntake.admitTeamSubmission` | every submitted document goes through the case-intake contract (channel `teamSubmission`, who supplied it), included by a person or a named team-submission policy |

## Folder purposes

- **Contribution folder** holds requests and what comes back, never the case. Giving an outside contributor that folder
  gives them no general case access (TEAM-03). They use *Cases ▸ Contribute to a team folder…*, which needs no case.
- **Team folder** is for case members. Assignments and action reviews are exchanged as versioned records (TEAM-05).

## Synchronisation and offline behaviour

- Every write is recorded in the case first. A request, receipt or shared record is *pending* (only on this Mac) until it is in the
  folder (*confirmed*); a failed write keeps *error* with the reason and is written again on the next read. Writing is idempotent per
  id, so a retry never duplicates (TEAM-07).
- A submission's files are copied and checked by SHA-256 before it is announced; a cut-off copy leaves a marker and is finished by
  *Finish the cut-off copy*. The requester checks every file again against the announcement before reading it in.
  A file the case already received is a duplicate and is not read twice.
- A folder that cannot be reached changes nothing in the case; the link records the last error (PERF-09).
- **Concurrent edits**: each record has a revision and the revision it was made from. A change made from the revision held here
  replaces it; two changes made from the same revision by different members are both kept (`case_team_conflicts`) until a person
  keeps one or takes the other, which is shared as a new revision after both (TEAM-06). Nothing is last-write-wins.

## Keys, encryption and trust

- Integrity: Ed25519 signatures and a hash chain per member; a changed, removed or reordered entry is reported and nothing after it
  is used.
- Identity: a member is an installation's key with a display name. **A signature proves which Mac wrote an entry, not which
  person.** The key never leaves the Mac (Keychain, this device only, not in backups): a restored or moved ledger must join the folder
  again as a new member and cannot write as the old one (RECOVERY-08).
- Confidentiality: the folder's own access controls who can read it. **Folder contents are not encrypted by the app.** This is said
  in the tool and in this document; SEC-04 stays open.
- No provider sends: nothing here talks to a network service; a synced folder's own provider is the people's choice.

## Operating cost

None to the app or the owner: the folder is the people's own storage.

## Not provided (open in the tracker)

Authenticated accounts, passkeys or MFA (ACCESS-01, PEOPLE-05), invitation links with expiry or revocation (ACCESS-07), encryption of
shared content (SEC-04), per-viewer restriction of what a folder member reads (PEOPLE-10), distinct-user journeys with real
authentication (QA-07), a hosted service and its operations (SHIP-03, PERF-12). The two-Mac walk (TEAM-01) is the owner's.

## Tests

`KalsmritikoshTests/CaseTeamFolderTests.swift`: contribution round trip, interrupted copy and folder outage, policy, closed case and
decline, shared work and conflicts across two ledgers, another installation's key and tampering, migration v197 → v198.
`CaseScreensRenderTests/teamFolder` draws the tool with real records (`docs/evidence/case-screens-2026-11-18/team-folder.png`).
