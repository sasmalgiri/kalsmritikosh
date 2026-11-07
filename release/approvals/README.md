# Approval and evidence records

`scripts/release-check.sh` (logic in `scripts/release_check.py`) reads these records; it never creates
them. Since N1 of the autonomous completion mandate (2026-11-01) every field is parsed exactly; an
unreadable, partial or ambiguous record fails or stays OPEN, never passes.

## Human gates — `release/approvals/<gate-id>.md`

Written by the responsible person, never by the agent or a script.

```
Decision: APPROVED | ACCEPTED | PASS          (exactly one of these; anything else — "NOT APPROVED",
                                               "approved with conditions", blank — is not a pass)
By: <name>
Role: <owner | counsel | practitioner (<persona>) | adjudicator | user-evaluation lead>
Date: <YYYY-MM-DD>
Commit: <full 40-character candidate commit>
Evidence: <paths, run ids, archive and upload identifiers>
Notes: <conditions, limitations, who else took part>
```

Each of Decision, By, Role, Date and Commit must appear exactly once. Conditions belong in Notes; a
conditional approval is recorded as a separate decision once the conditions are met. Exact parsing does
not authenticate the person — the record's provenance is reviewed separately.

## Evidence gates — the file named in the manifest

Hold the run identifiers and artefact paths for the candidate and may be written by whoever ran the
check, agent included, as long as every figure was produced by the run they name. The file must carry
exactly one line `Candidate: <full 40-character commit>` and no placeholder.

## Artifact gates — `release/artifacts/<gate-id>.json`

For results an automated run produces (distribution archive, TestFlight install, StoreKit run,
distribution persona journeys). The record binds the result to files by digest:

```json
{
  "gate": "<gate-id>",
  "candidate": "<full 40-character commit>",
  "result": "pass",
  "artifacts": [{"path": "<repo-relative or absolute path>", "sha256": "<hex digest>"}],
  "external_ids": {"app_store_connect_build": "<id>"}
}
```

Every listed file must be present and match its digest where the check runs.
