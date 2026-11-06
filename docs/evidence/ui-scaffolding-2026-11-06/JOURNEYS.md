# New-scaffolding UI walk (Package A + B) on the candidate — AGENT run, 2026-11-06

**Result: INCOMPLETE. Do not use this record to pass a gate.** The Mac's screen locked partway through the walk. After that, the frontmost app was `loginwindow` (pid 413), so the app's accessibility windows could not be read and no keys could be sent safely. The screen was polled for 19 minutes and stayed locked, so the run stopped. Items 1 and 2 were partly checked. Items 3 to 9 were not reached, apart from the Home copy part of item 9.

**AGENT run.** An agent (Claude) did this run, not a person. Only what was observed is recorded.

Candidate: 572b5893c9130fcb31bb8ffd784ea32798c6286b

- **Branch:** investigations-next. 572b5893 was HEAD during the run. It is also the last commit that touches `Kalsmritikosh/`.
  - The working tree had Xcode-made edits to the two InfoPlist.xcstrings files and an xcuserdata plist. These are localisation and user metadata, not app code (00-build.txt).
- **Build:** xcode-tools BuildProject, scheme Kalsmritikosh, Debug, 08:27 IST, "The project built successfully."
  - The binary is dated 08:27:20 and the debug dylib 08:27:17. Both are after the 572b5893 commit time of 08:26:17.
  - No Swift file under `Kalsmritikosh/` is newer than the dylib (00-build.txt).
- **Launch:** `open -n -a <Debug app> --args -kalsmritikosh.sampleArchiveMode YES` at 08:54:43 gave **pid 99845**.
  - `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) as a ledger, plus the TipKit store (01-launch.txt).
  - "Back to my archive" was never pressed.
- **Method:** `build/axdrive/axdrive` (AX tree dumps and AX press / focus) and window-only `screencapture -l`. Keys and text were sent only after `axdrive front` reported pid 99845. No ⌘Q.
- **Settings:** none changed.
- **Data written to the sample ledger** ("Investigator sample case"):
  - Contradiction "Conflicting dates for "Delivery delayed"" confirmed at 9:25 AM.
  - Contradiction "Conflicting dates for "Contract modified"" deferred at 9:27 AM with the note "Waiting for the signed amendment original".
  - The Dismiss reason picker was set to "Different event or transaction", but no dismissal was recorded.
  - The contradictions filter was set to "All".
  - Decisions are append-only, so none of these can be "restored".
- **Network:** Online mode stayed off. No AI send, no purchase, no key entered.
- **Quit:** `kill -TERM 99845` at 12:11:58. No instance remained (99-finish.txt).

## Checks

| # | Check | Result | Observed | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Case overview "This case at a glance" | **PARTIAL PASS** (coverage reasons not exercised) | **Question:** "No question recorded yet — write what was reported in Intake below, or give the case a purpose."<br>**Counts:** "2 contradiction(s) waiting for a decision", "74 job-result row(s) not yet reviewed", "0 open evidence request(s)".<br>**What the app could read:** "Read: 8 · Partly read: 0 · Not read: 0".<br>**Reading limits:** "The AI has not been allowed to read this case; …" and "This case's documents have not been compared for contradictions yet (“Find contradictions”)."<br>**Next steps:** "Next: Rate the complaint and decide whether to investigate, decline or refer it."<br>**Clickable:** "0 open evidence request(s)" opened the Evidence tab. The next step "2 contradiction(s) are waiting for your decision., Overview" is an AX button and pressing it kept the Overview tab selected.<br>No document in the sample is partly read or not read, so a reason was never shown | O1-overview.png/-tree.txt, O2-glance-to-evidence.png, O3-nextstep-contradictions.png |
| 1n | Note: the counts are not all clickable | **NOTE** | Help says "Choose a count or a next step to go to the tab where it is done". Only the open-requests count is a button. "2 contradiction(s) waiting…" and "74 job-result row(s)…" are static text.<br>"Reading limits" says the documents "have not been compared for contradictions yet" while 2 contradictions "Found by the archive scan" are listed below it | O1-overview-tree.txt l.48–58 |
| 2a | Contradiction Confirm (button) | **PASS** | "Confirmed: Conflicting dates for "Delivery delayed"". The list went to "1 listed · 1 waiting for a decision" and the glance count to 1 | X1-after-confirm.png/-tree.txt |
| 2b | Defer with a note (button) | **PASS** | Status "Deferred by Shirshendu Sasmal on 6 Nov 2026 at 9:27 AM: Waiting for the signed amendment original". The glance reads "1, contradiction(s) waiting for a decision (1 deferred)". A "Decision history (1)" disclosure appeared | X3-after-defer-button.png/-tree.txt |
| 2c | Dismiss needs a reason | **PASS** | With "No reason chosen", Dismiss carries "Unavailable: Choose why you are dismissing it." and pressing it recorded nothing. After the reason "Different event or transaction" was chosen, it became enabled | X4-after-dismiss-tree.txt (the press without a reason) |
| 2d | Dismiss with a reason recorded | **NOT RUN** | The screen locked before the dismissal was sent | — |
| 2e | Keyboard shortcuts | **FAIL (as observed)** | ⌥⌘L (Defer) was sent with the app frontmost while the note field had focus. Nothing was recorded: the status stayed "Not reviewed yet" (X2). The Defer button recorded the decision at once (X3).<br>⌥⌘N (Dismiss) was sent with the app frontmost, a reason chosen and focus still in the note field. Nothing was recorded: the status stayed "Deferred by …".<br>Focus could not be moved out of the note field through AX. So it is not shown whether the shortcuts work with focus elsewhere. ⌥⌘↓ was not delivered because the screen locked | X2-after-defer-key.png/-tree.txt |
| 2f | Decision history shown; decision persists after kill + relaunch | **NOT RUN** | The screen locked | — |
| 2x | Layout defect seen while typing the note | **FAIL (layout)** | After the app was activated and the note typed, the detail content became wider than the window. The sidebar was pushed off the left edge ("stigations / e Easy", "ional Jobs"), "Log &" was cut off at the right, and the note field grew from 443 to 567 pt. It returned to normal later and shifted again on the next activation | X2-after-defer-key.png, X2/X3/X4 trees (x 231 vs 327) |
| 3 | Workspace restore across kill + relaunch | **NOT RUN** | — | — |
| 4 | Evidence request (3 monthly items, link, partial, copy draft letter) | **NOT RUN** | — | — |
| 5 | Report / export: coverage + evidence-request sections, confirmed contradiction | **NOT RUN** | — | — |
| 6 | Professional Jobs: current step, ⌥⌘F, Show all | **NOT RUN** | — | — |
| 7 | Help: tutorial steps and entries for new controls | **NOT RUN** (UI). The HelpRegistry source has entries for "This case at a glance" and "What the app could read" | — | — |
| 8 | Plans and AI setup sheet wording | **NOT RUN** (sheets not opened). The Home card reads "Three plans: Workbench (14-day trial), AI Included or AI Pro, monthly or yearly — all nine personas in each." | — | H1-home.png/-tree.txt |
| 9 | Copy: no "preview every send" / "one plan" | **PARTIAL PASS** (Home only) | The Home tree has no match for "preview", "one plan" or "every send". Help was not reached | H1-home-tree.txt |

## Limits

- The run is incomplete because the screen locked. Run it again with the display kept awake and unlocked.
- Debug build, sample archive only (8 documents). It was driven by an agent through Accessibility.
