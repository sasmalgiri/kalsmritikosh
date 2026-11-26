# Practitioner-style review of the job deliverables — agent pass (2026-10-30)

**Status of this document.** This is the agent's review of each persona's deliverables against the named
professional standard, done on the code, the acceptance scenarios and the sample-archive UI journeys
(`docs/evidence/ui-journeys-2026-10-30/JOURNEYS.md`). It is **not** a practitioner review: the release gate
(readiness F7) needs a real practitioner in each field to work a real matter and sign. Findings marked *fixed*
were corrected and re-tested in this pass; findings marked *open* are for the practitioner or the owner.

## Method

For each persona: the standard the contract names (`JobContracts.policy`), the columns the result carries
(`JobFields.specs`), what the executor computes and what it refuses to conclude, the acceptance scenario
(`JobAcceptanceScenarioTests`, `JobDeliverableTests`) and the result screen seen in the journey.

## Findings by persona

| Persona | Standard looked at | What holds | Findings |
|---|---|---|---|
| Lawyer | Production practice (Bates numbering, privilege log, slip sheets), pleading-level issue framing | Coding withholds privileged and partly privileged documents from production with a slip sheet and a log line; Bates numbers are proposed, production assigns them; every deposition question cites its passage; disputed points show both sources; parties merge only by a recorded, reversible human decision | *Open:* a partly privileged document should produce a redacted copy, not a slip sheet — the result says so in its limitation, the production tool does not yet make the copy. *Open:* privilege-log basis is always "Privileged"; a practitioner will want work-product vs attorney-client. |
| HR / compliance investigator | Workplace investigation practice (allegations put to the respondent, statements compared not judged, corrective actions owned) | Statement comparison is point by point on dates and amounts with quotes; wording differences stay the investigator's; an allegation cannot complete until put to the respondent; actions close only with a note | *Fixed:* a matter opened in an empty workspace now says that nothing is in scope and how to add documents (journey finding D4). *Open:* the comparison's "point" is a cluster of shared words; a practitioner may want to name points themselves — the field is editable, the clustering is a start. |
| Forensic accountant | AICPA-style workpapers (every figure traces; calculation, inputs, sign-off), tracing methods applied by the accountant | Every figure in an exported report traces to a workpaper or is flagged untraced and cannot be accepted; totals per currency only; tracing is a manual workpaper with the method the person states | *Open:* a computed figure (a sum) needs a workpaper the person adds; the app does not compute LIBR/FIFO/pro-rata by design — confirm that is the wanted boundary. |
| SIU / insurance fraud | Examination-under-oath preparation; red flags with innocent explanations | Every question cites its passage; disputed points show both sources; red-flag rows carry an "innocent explanation" column | *Open:* none beyond the general ones below. |
| Journalist | Verification practice (independence of sources, right of reply, protection of confidential sources) | Outlets repeating one wire story are one family; publication cannot clear while a reply is unrequested; a protected source's identity is scrubbed and verified in exports and masked on every cloud send, with the send refused if it would survive | *Open:* "one family" is textual (identical long sentences); syndicated rewrites with changed wording are not caught — stated in the limitation. |
| Researcher / historian | Source criticism; chronology with periodisation; editions with apparatus and lineage; competing accounts kept | Uncertain dates keep their range; each annotation attaches to a cited passage with the exact version; opposing accounts each carry supporting and contrary sources; a translation keeps its original and transcription | *Open:* periods are the historian's to name; the executor only prefills ranges. |
| Genealogist | Genealogical Proof Standard (every relationship sourced; unproven drawn as unproven) | Kinship stated by a sentence is drawn solid with its source; a hand-added relationship without a source is dashed "unproven" in the chart; vital events sit on the timeline | *Open:* the kinship patterns cover "daughter of", "married"; parish-register formulae ("bapt.", "s. of") are not read — a practitioner's corpus will show which to add. |
| Investigator | Case scope discipline; reproducible analysis; identity resolution human-gated | The analysis query is saved and re-applied; every computed row cites the rows it came from; merges are proposed, confirmed and reversible | *Open:* the query language is three fields (filter, group, total); a practitioner may want joins — out of scope for v1 by the Workbench contract. |
| Individual | Personal records (versions, expiry, career and education history) | Expired and upcoming dates are flagged; a gap in a career history is shown only between an entry that ends something and the next entry | *Fixed:* a career entry must be about a person — a procurement sentence ("We expect the certified material on …") no longer appears as a career entry (journey finding C1). |

## General findings (all personas)

- *Fixed (workflow review I8, 2026-10-30):* the data-lab query is edited once above the result; large results open as
  a table with a filter, unresolved-only and a selected-row pane; fields show by row kind.
- *Fixed (I9):* a launch window taller than its screen is fitted to it; run b measured `[0,33 1470x843]` on a 956 pt screen.
- *Fixed (I6, I7, I3):* the earlier "Open" items on statement points, source families and the ACH worksheet — the speaker
  follows the reporting verb and an ambiguous sentence stays unassigned; "one family" is a shared-text candidate with the
  lineage decision the journalist's; an unrated ACH cell is unassessed and a tie is presented as a tie.
- *Open:* exports were not exercised through the UI (system save panel); the export path is covered by
  `JobResultIntegrityTests` and `JobDeliverableTests`, not by a journey.
- *Open:* the practitioner evaluation the workflow review asks for (five users, a shared task, time to first cited
  finding and to a reviewed report, detours, errors) — people, not the agent.

## What a practitioner should be given

One matter of their own documents in the signed build, the job list for their persona, and this table. Their
sign-off goes in `SHIP_DECISIONS.md` with the date; their findings open rows in `PRODUCTION_BACKLOG.csv`.
