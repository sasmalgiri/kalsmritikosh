# Evidence — permission sheet, plan picker, credit meter, offline search results walked in the GUI (gate `ui-consent-and-plans`)

Candidate: e61f9002e1c653d5377620ceb28942f72fda223f
Walked by: agent (Claude), 2026-11-18/19, Debug builds of `56b9e08c` (permission sheet) and of the tree committed as `e61f9002`
(plans, meter, offline results); disposable ledger (`--acceptance-case`), simulated AI Included plan (`--ui-walk-simulated-plan`),
nothing bought, no key, nothing sent. Screenshots: `docs/evidence/ui-walk-2026-11-18/`.

| Part | Result | Screenshot |
|---|---|---|
| Once-per-case permission sheet | Appears on the first question in the case; lists 9 documents and the 1 not read, the estimate and credits left; waits | consent-sheet.jpg |
| Not now | Nothing sent; "You have not allowed the AI to read this case's documents, so these are search results" | consent-not-now.jpg |
| Allow for this case | The send goes ahead (stopped by the walk simulation, nothing leaves) | consent-allowed.jpg |
| Credit meter | "1,650 of 2,000 credits left this month · resets …" in the Online bar | credit-meter.jpg |
| Plan picker (no plan) | Workbench monthly / yearly, 14-day trial, renewal disclosure, Restore / Manage / Terms / Privacy | plan-picker-workbench.jpg |
| Offline search results | The passage, the AI-off sentence, confidence and source; the reason named | w17.jpg, exports/ |

TODO (owner, after the relay is deployed — SHIP-13): walk the plan picker again with AI Included and AI Pro offered (they are attached only once a relay host is configured), and the credit meter on a real AI plan in TestFlight. Until then this gate stays OPEN.
