# Case screens drawn off-screen with real records — 2026-11-18

Produced by `KalsmritikoshTests/CaseScreensRenderTests.swift` (run 2026-11-18 09:12 IST, passed; no "hung before" in the log).
The test boots the app's own `AppState` on a temporary ledger and fills one case — "Was the supplier paid twice for invoice
INV-2041?" — with two documents, a person with two roles, a sourced and a supplied profile line, a past whereabouts
observation, a two-person team with one declared capability, a March statement of account 7718 with two rows, an INR→EUR
rate and a supplied signatory. Each screen is then drawn in an `NSHostingView` inside a borderless window that is never
shown; its own loading runs first. The test host is sandboxed, so each PNG is written to the test log as base64 and rebuilt
here.

What this is: proof that each new screen renders with real records from the services (no mock data). What it is not: an
interactive walk — no button was pressed, so the rows stay at their automated level (UI_VERIFIED needs the interactive walk).

| File | Screen | What it shows |
|---|---|---|
| tools-panel.png | Case tools, "People in the case" chosen | The tool list with the new tools (People in the case, Team and work, Closing and reopening); the purpose line; Vikram Rao, "Witness; Account holder — account ending 7718". |
| people-in-the-case.png | People in the case | The add form and the person with both roles (the profile shows after choosing a person). |
| team-and-work.png | Team and work | Ada (lead) and Ben (investigator) with "Work history"; "End membership…" disabled until a reason is typed; Ben's declared capability with its basis; conflict check and "List who could take it". |
| closing-and-reopening.png | Closing and reopening | "No closure position is recorded" with its next step; late material ("Nothing is waiting"); "Check finished work against newer evidence". |
| money.png | Money | Gross paid INR 10,000 (1 entry), returned INR 2,000, net outflow INR 8,000 stated as arithmetic, not a finding; the two records with their statement rows; Statements: account 7718 "Not reconciled — partial" with why; the rate "1 INR = 0.011 EUR (ECB reference rate, 2026-03-05, rate on the payment day)"; Vikram Rao as authorised signatory, "Supplied — not checked against a source"; gaps. |
| history-set.png | History set | The empty state with its next step; "Identifiers to look for in other cases". |

The interactive GUI walk was stopped the same morning: another session was running UI tests on this Mac, and its Xcode window
took focus. A walk needs the screen to itself.
