# UI walk of the running macOS app (UI only, not AI answers) — AGENT run, 2026-11-07

**Result: INCOMPLETE. Do not use this record to pass a gate.** Items 1 and 2 were checked and passed. Items 3–10 were not run, because the agent's tool calls stalled for about 40 minutes and the 60-minute time box ran out.

**AGENT run.** An agent (Claude) did this run, not a person. Only what was observed is recorded.

Candidate: 54ed48b94811dd7a4d46d71da1b441b1572e54f4

## Setup

- **Branch:** investigations-next. HEAD is 54ed48b9, which is also the last commit that touches `Kalsmritikosh/` (00-build.txt).
  - The working tree has Xcode-made edits to the two InfoPlist.xcstrings files and an xcuserdata plist, which are not app code.
- **Build:** xcode-tools BuildProject, Debug, 14:05 IST, "The project built successfully."
  - The binary is dated 14:05:27 and the debug dylib 14:05:23. No Swift file is newer than the dylib.
- **Keeping the Mac awake:** `caffeinate -dimsu` ran from 14:05 (pid 10375). It was killed at 15:02.
  - Another caffeinate (pid 10641) was running too. This walk did not start it and left it alone.
- **Launch:** `open -n -a <Debug app> --args -kalsmritikosh.sampleArchiveMode YES` at 14:06:07 gave **pid 10738**.
  - `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) as a ledger, plus the TipKit store (01-launch.txt).
  - The owner's ledger was not opened, and "Back to my archive" was never pressed.
- **Method:** the same as the 2026-11-06 attempts:
  - `build/axdrive/axdrive` for AX reads and presses;
  - `/tmp/walk/safe.sh` checked the frontmost app before every keystroke;
  - `screencapture -l` captured the app window only.
- **Stall:**
  - The safe wrapper stopped keystrokes twice because Xcode, and later "LawyerFleet", was frontmost: "ABORT: not frontmost -> FRONT: Xcode pid=68528". Those keystrokes were never sent.
  - From about 14:21 to 15:01, almost every shell call that drove the app failed at the host with "PreToolUse hook did not respond before its timeout". Each failure took about 10 minutes.
  - The screen was not locked: `CGSSessionScreenIsLocked` was absent at 14:51.
- **Quit:** `kill -TERM 10738` at 15:02:03. No instance remained.
- **Data and settings:**
  - Two AX presses changed the case's tab or scroll position: the "0, open evidence request(s)" count and the "2, contradiction(s)" count.
  - The Overview segment was pressed once.
  - No decision, note, request or setting was written. "Case map (preview)" was never turned on and stayed off.
  - The contradiction-note text was never typed. Screenshot 03a-after-stall shows the note field still empty.
- **Network:** no purchase, no key entered, no AI send, no consent sheet opened.

## Checks

| # | Check | Result |
| --- | --- | --- |
| 1 | Sidebar: Cases, Evidence, Search, Outputs, More tools, Settings, Help; ⌘1–⌘4 switch; More tools lists the other screens | **PASS** (see the notes below) |
| 2 | Cases: sample case, "This case at a glance" with question, coverage, counts, next step; counts clickable | **PASS** |
| 3 | Contradictions: confirm one, dismiss one with a reason, ⌥⌘ keys with the note focused, long note does not widen, persists after kill and relaunch | **NOT RUN** (stall; the typing was blocked by the frontmost guard, then by the hook timeouts) |
| 4 | Evidence request: 3 monthly items, linked document, partial with the missing months, copy the draft letter | **NOT RUN** |
| 5 | Search: defaults to the active case; witness, counts, receipt; "Whole library" is an explicit choice | **NOT RUN** |
| 6 | Case map (preview on): view strip, map/list, inspector, legend, Reset view, What changed, history state with Return to current | **NOT RUN** (the switch was never turned on) |
| 7 | Outputs: export the case report with the coverage and evidence-request sections and the confirmed contradiction | **NOT RUN** |
| 8 | Help: tutorials, keyboard help in the Help menu, help search for "evidence request" | **NOT RUN** |
| 9 | Plans sheet and AI setup sheet wording | **NOT RUN** |
| 10 | Copy on Home and onboarding; "Resume a case" opens Cases | **NOT RUN** |

### Item 1 notes (observed)

- The sidebar shows, under "GO TO":
  - "Cases ⌘1", "Evidence ⌘2", "Search ⌘3", "Outputs ⌘4";
  - then, below a divider, "More tools ⌘6", "Settings ⌘9" and "Help".
  - Screenshot: 01-sidebar-case-overview.png.
- Above "GO TO", the persona block "PERSONA · INVESTIGATOR" also lists "Professional Jobs" and "Review". This is not a failure, but it means the sidebar has more than the seven entries.
- Each shortcut opened its area (screenshots 01-cmd1 to 01-cmd6):
  - ⌘2 opened the Evidence screen (title "Evidence").
  - ⌘3 opened Search on "Search case evidence", with the text "Searches only this case's documents, word for word, on this Mac…".
  - ⌘4 opened Outputs on the Answer Journal.
  - ⌘6 opened More tools.
  - ⌘1 returned to the case.
- More tools lists the other screens in groups.
  - "Case analysis views" has Timeline, History, Case Story, Dossier, Explore, Connections, Findings, Assertions, Competing Hypotheses, Review, Insights, What Changed, Cross-Doc Matrix, Compare Documents, Fund Flow, Email Threads and Transcripts.
  - "Professional workspaces" has Professional Jobs, Work Center, Logs & Trackers and more.

### Item 2 notes (observed)

- The app opened on "Investigator sample case" (Stage: Intake), on the Overview tab.
- "This case at a glance" shows:
  - **Question:** "No question recorded yet — write what was reported in Intake below, or give the case a purpose."
  - **Counts:** "2 contradiction(s) waiting for a decision", "74 job-result row(s) not yet reviewed" and "0 open evidence request(s)".
  - **Coverage:** "What the app could read — Read: 8 · Partly read: 0 · Not read: 0".
  - **Reading limits:** two lines.
  - **Next step:** "Next: Rate the complaint and decide whether to investigate, decline or refer it."
- The counts are clickable:
  - Pressing "0, open evidence request(s)" opened the case's Evidence tab ("Sources in the case", "Evidence requests") (02-glance-evreq-click.png).
  - Pressing "2, contradiction(s)…" scrolled to the Contradictions list ("2 listed · 2 waiting for a decision") (02-glance-contra-click.png).
  - The "74 job-result row(s)" count was not pressed.
- The ⌥⌘ key hint is shown on screen: "Keys: ⌥⌘↓ and ⌥⌘↑ move through the list; ⌥⌘Y confirms, ⌥⌘N dismisses, ⌥⌘L defers." It was not tested.
- The change feed lists "2 × Review decided". Those decisions are left over in the sample ledger from an earlier walk. Both contradictions show "Not reviewed".

## Gates

No approval file was written. ui-consent-and-plans, acceptance-case-ui and output-routes all depend on items that were not run (3–10).

## To re-run

- Keep the screen unlocked, and avoid switching to other apps during the run. Xcode and LawyerFleet took the front twice.
- Expect host hook stalls. Keep each shell call short and simple; the plain calls (`date`, `screencapture`, `kill`) went through while the longer driving calls timed out.
