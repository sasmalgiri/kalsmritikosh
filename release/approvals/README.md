# Approval records

One file per human gate of `ci/release-gates.json`, written by the responsible person, never by
the agent or a script. `scripts/release-check.sh` reads them; it does not create them.

Format (`<gate-id>.md`):

```
Decision: approved | not approved | approved with conditions
By: <name>
Role: <owner | counsel | practitioner (<persona>) | adjudicator | user-evaluation lead>
Date: <YYYY-MM-DD>
Commit: <full candidate sha>
Evidence: <paths, run ids, archive and upload identifiers>
Notes: <conditions, limitations, who else took part>
```

Evidence gates (`ci.md`, `acceptance-case-ui.md`, `output-routes.md`) hold the run identifiers and
artefact paths for the candidate commit and may be written by whoever ran the check, agent
included, as long as every figure in them was produced by the run they name.
