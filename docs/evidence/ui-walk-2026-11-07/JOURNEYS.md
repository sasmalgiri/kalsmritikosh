# UI walk of the running macOS app (UI only, not AI answers) — AGENT run, 2026-11-07 (second run)

**Result: INCOMPLETE. Do not use this record to pass a gate.** Items 1 and 2 were re-checked and passed. Item 3 was partly run. Items 4–10 were not run, because the agent's shell calls stalled again at the host's PreToolUse hook (about 10 minutes per failed call, from 17:44 to 18:35).

**AGENT run.** An agent (Claude) did this run, not a person. Only what was observed is recorded.

Candidate: 93a3870ddd0a6020559b038af4baf9560b51a294

## Setup

- **Branch:** investigations-next. HEAD is cad7c50f, which changes only gate records. The last commit that touches `Kalsmritikosh/` is 93a3870d (00-build.txt).
  - The working tree has Xcode-made edits to the two InfoPlist.xcstrings files and an xcuserdata plist. These are not app code.
- **Before starting:** `pgrep -lf LawyerFleet` matched only a sleeping watcher shell. The LawyerFleet UI-test run it watched had already ended at 17:35 ("== exit build-failed" in ~/LFRelease/uitestrun.log). No LawyerFleet app, xcodebuild or test runner was running. Nothing of it was touched.
- **Build:** xcode-tools BuildProject, Debug, 17:41:36 IST, "The project built successfully." The binary is dated 17:41:35 and the dylib 17:41:31. No Swift file is newer than the dylib.
- **Keeping the Mac awake:** `caffeinate -dimsu` (pid 33741) ran from 17:41:26. It was killed at 18:35. No other caffeinate was running.
- **Launch:** `open -n -a <Debug app> --args -kalsmritikosh.sampleArchiveMode YES` at 17:41:48 gave **pid 33836**.
  - `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) as a ledger, plus the TipKit store (01-launch.txt).
  - The owner's ledger was not opened, and "Back to my archive" was never pressed.
- **Method:** the same as the first run:
  - `build/axdrive/axdrive` for AX reads and presses;
  - `/tmp/walk/safe.sh` checked the frontmost app before every keystroke, and `/tmp/walk2/k.sh` re-activated the app once if needed;
  - `/tmp/walk2/shot.sh` (`screencapture -l`) captured the app window only.
- **Stall:**
  - From 17:44 to 18:35, five of the seven shell calls that drove or read the app failed with "PreToolUse hook did not respond before its timeout (host client may be unreachable)". Each failure took about 10 minutes. Plain `date` calls went through.
  - When the stall began, Xcode had taken the front, and the open reason menu closed.
- **Quit:** `kill -TERM 33836` at 18:35:19. No instance remained.
- **Data written to the sample ledger:**
  - Contradiction "Contract modified" was **confirmed** with a long note.
  - On "Delivery delayed", the reason "Changed or updated estimate" was chosen but never saved. Its note was not typed and Dismiss was not sent, so the app quit with it still unsaved.
  - No evidence request was created, and no setting was changed. "Case map (preview)" was never turned on and stayed off.
- **Network:** no purchase, no key entered, no AI send, no consent sheet opened.

## Checks

| # | Check | Result |
| --- | --- | --- |
| 1 | Sidebar: Cases, Evidence, Search, Outputs with ⌘1–⌘4 | **PASS** (r1-cmd1…r1-cmd4) |
| 2 | Case overview "This case at a glance" | **PASS** (r1-cmd1) |
| 3 | Contradictions: confirm, dismiss with a reason, ⌥⌘ keys with the note focused, long note does not widen, kill and relaunch | **INCOMPLETE**: confirm, ⌥⌘Y, ⌥⌘↓ and the long note PASS. The dismissal with a reason, ⌥⌘N and the kill/relaunch restore were NOT RUN. |
| 4 | Evidence request | **NOT RUN** |
| 5 | Search: active case by default, witness, counts, receipt, explicit "Whole library" | **NOT RUN** |
| 6 | Case map (preview on) | **NOT RUN** (the switch was never turned on) |
| 7 | Outputs: case report export | **NOT RUN** |
| 8 | Help | **NOT RUN** |
| 9 | Plans sheet and AI setup sheet | **NOT RUN** |
| 10 | Home and onboarding copy, "Resume a case" | **NOT RUN** |

### Item 1 (observed on 93a3870d)

- The AX descriptions read "Cases, ⌘1", "Evidence, ⌘2", "Search, ⌘3" and "Outputs, ⌘4". Below them are "More tools, ⌘6" and "Settings, ⌘9".
- Each key opened its screen:
  - ⌘2 opened "Evidence";
  - ⌘3 opened "Search";
  - ⌘4 opened "Outputs";
  - ⌘1 returned to "Investigator sample case".

### Item 2 (observed)

- "This case at a glance" shows:
  - the Question;
  - "2, contradiction(s) waiting for a decision" and "0, open evidence request(s)", both clickable;
  - "Read: 8 · Partly read: 0 · Not read: 0";
  - "Next: Rate the complaint and decide whether to investigate, decline or refer it."
- Pressing the contradiction count scrolled the list into view.

### Item 3 (partly observed)

- **Long note:** a single-line note of about 380 characters was typed into `case.contradictions.note` (r3a-long-note). The field stayed 443 pt wide and the window stayed 1100 pt. The content scroll area stayed 856 pt. The page did not widen.
- **⌥⌘Y with the note focused:** this confirmed the item (r3b-after-optcmdY). The row now reads "Conflicting dates for "Contract modified". Confirmed by Shirshendu Sasmal on 7 Nov 2026 at 5:43 PM: Confirmed by agent walk 2026-11-07: …".
- **⌥⌘↓ with the note focused:** this moved to "Delivery delayed" (sources supplier_abc_22.eml and invoice-432.eml, "Not reviewed yet"). The focus stayed in the note field (r3c-optcmd-down).
- **Reason menu:** it offers "No reason chosen", "Different event or transaction", "Different person", "Changed or updated estimate", "Transcription or typing error", "Not enough context to decide" and "Other (say why in the note)". Dismiss reads "Unavailable: Choose why you are dismissing it." until a reason is chosen. "Changed or updated estimate" was then selected.
- **Not run:** the note, ⌥⌘N, Dismiss, and the kill/relaunch restore. The stall began at this point.

## Earlier run (54ed48b9, 14:05–15:02 IST)

Items 1 and 2 passed and items 3–10 were not run. Shell calls stalled at the host's PreToolUse hook for about 40 minutes, and the frontmost guard blocked the typing twice (Xcode or LawyerFleet took the front). Its screenshots are the 01-*, 02-* and 03a-* files in this folder.

## Gates

No approval file was written.

- **acceptance-case-ui:** needs items 3–7 and 10, which are incomplete or not run.
- **ui-consent-and-plans:** needs the consent sheet, the plan picker, the credit meter and offline search, none of which were run.
- **output-routes:** needs every route in docs/OUTPUT_ROUTES_INVENTORY.md (file, clipboard, print), none of which were run. This walk's item 7 alone would not cover it.

## To re-run

- The owner must be at the Mac to answer the host's permission prompts. The stalls match prompts that went unanswered. Only `date` passed without a prompt.
- The sample ledger now holds one confirmed contradiction ("Contract modified"). Item 3 can reuse it for the relaunch restore check and for item 7 (reviewed results).
