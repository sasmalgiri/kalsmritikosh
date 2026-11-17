# Reachability recheck of the 52 "no UI entry point" flags (2026-11-17)

Source: the 52 rows whose `status_note` in `docs/SMART_MAP_COMPLETION_MATRIX.json` carries the 2026-11-15 reachability
note. Each row's service was traced to a UI caller by reading the code at `af1d672d` (a read-only code audit; nothing was
run or walked in the app). Tracker row QA-16.

## Totals

| Verdict | Rows |
|---|---|
| Reachable from the screen | 3 then, +6 after this commit (see below) |
| Partly reachable | 17 |
| Still no entry point | 32 before this commit, 26 after |

## Closed

| Row | Entry point |
|---|---|
| REASON-08 | Inspector of an explanation: "This explanation", "Cited for it", "Cited against it" (`UI/CaseMapOriginsBlock.swift`) |
| MONEY-04 | Case tools → Money: "Same payment…" / "Two payments…" (`UI/CaseMapToolsPanel.swift`) |
| AUTO-10 | Evidence request row: "Prepare for sending", "Record handed over", "Confirm sent" / "Confirm not sent" (`UI/EvidenceRequestDeliveryBlock.swift`) — evidence requests only |
| AI-04, AI-05, AI-06, AI-08, AI-11, AI-12 | This commit: Case tools → Assistant: "Run the assistant" calls `CaseAIAssistService.run` (it had no caller anywhere); proposals then appear for Accept / Reject / Defer. Not walked in the running app. |

## Partly reachable (17)

IN-11 (supplied-by on journal entries, not on documents) · TIME-05 (case file report only) · TIME-10 (history open only) ·
CHANGE-04 (accept a version; no generated proposal is ever made) · PEOPLE-07 (record same/different; rule reasons not shown) ·
MONEY-07 (reconciliation only in the exported money report) · HISTORY-01 (older deconfliction section) · HISTORY-07 ·
HISTORY-08 (review record export; no review case can be started) · ACTION-02 (case templates only) · ACTION-05 (routing
only automatic) · ACTION-06 (status and due menus only) · ACTION-07 (target date only) · ACTION-08 (result report path;
`recordActionResult` has no caller) · ACTION-09 (versioned review used only when a result version exists) · TEAM-08 ·
TEAM-11 (case log; access history not shown).

## Still no entry point (26 after this commit)

IN-06 · REASON-02 · REASON-03 · REASON-04 · REASON-07 · REASON-10 · TIME-03 · TIME-04 · CHANGE-07 · PEOPLE-01 ·
PEOPLE-02 · PEOPLE-03 · PEOPLE-04 · PEOPLE-06 · PEOPLE-08 · PEOPLE-09 · MONEY-08 · MONEY-09 · MONEY-11 · HISTORY-03 ·
HISTORY-04 · HISTORY-05 · HISTORY-06 · ACTION-10 · ACTION-12 · OUTPUT-09.

Functions with no caller anywhere in the app (not only the UI): `applyGeneratedBrief`, `recordActionResult`,
`proposeReopenings`, and `contributeOrQueue` apart from an uncalled path.
