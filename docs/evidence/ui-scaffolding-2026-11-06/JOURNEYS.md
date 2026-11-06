# New-scaffolding UI walk (Package A + B) on the candidate — AGENT run, 2026-11-06 (second attempt)

**Result: INCOMPLETE. Do not use this record to pass a gate.** The Mac's screen was locked before the first look at the app. No check was run.

**AGENT run.** An agent (Claude) did this run, not a person. Only what was observed is recorded.

Candidate: 06e4b3a93edfad2864b3e5a084ab4c187c349ebd

## Earlier attempt (interrupted)

The first attempt ran on 572b5893 and stopped at 12:11 when the screen locked. Items 1 and 2 were partly checked. Its record and screenshots are in `prev-attempt-572b5893/`. They describe 572b5893, not this candidate, and do not count for it. That attempt also wrote to the sample ledger: 1 contradiction confirmed and 1 deferred.

## This attempt

- **Branch:** investigations-next. HEAD is 06e4b3a9, which is also the last commit that touches `Kalsmritikosh/`.
  - The working tree has Xcode-made edits to the two InfoPlist.xcstrings files and an xcuserdata plist, which are not app code. It also has `release/approvals/legal-privacy.md` modified and `docs/agent-reviews/candidate-review-06e4b3a9-legal-privacy.md` untracked. A separate review made those two; this walk did not (00-build.txt).
- **Build:** xcode-tools BuildProject, scheme Kalsmritikosh, Debug, 12:59:59 IST, "The project built successfully."
  - The binary is dated 12:59:58 and the debug dylib 12:59:56. Both are after the 06e4b3a9 commit time of 12:49:03.
  - No Swift file under `Kalsmritikosh/` is newer than the dylib.
- **Keeping the Mac awake:** `caffeinate -dimsu` ran from 12:59 (pid 22192). `pmset -g assertions` showed it holding PreventUserIdleDisplaySleep, PreventUserIdleSystemSleep and PreventSystemSleep. It was killed at 14:16.
- **Launch:** `open -n -a <Debug app> --args -kalsmritikosh.sampleArchiveMode YES` at 13:51:06 gave **pid 23061**.
  - `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) as a ledger, plus the TipKit store (01-launch.txt).
  - The owner's ledger was not opened, and "Back to my archive" was never pressed.
- **Lock:** at 14:11 the first AX read of the app found the frontmost app was `loginwindow` (pid 413), and the app exposed no windows.
  - The screen was polled every 10 s from 14:11:27 to 14:16:28 and stayed locked.
  - So the screen locked even though caffeinate was holding its sleep assertions. The likely causes are a manual lock, or a screen-saver or lock policy that caffeinate does not stop.
  - The agent's tool calls were slow: several shell calls timed out at the host hook, about 10 minutes each, between 13:00 and 14:11. That is why the gap from launch to first look is about 20 minutes.
- **Quit:** `kill -TERM 23061` at 14:16:39. No instance remained (99-finish.txt).
- **Interaction:** none. No key, click or AX press was sent to the app.
- **Settings and data:** nothing was changed and nothing was written to the sample ledger.
- **Network:** no purchase, no key entered, no AI send.

## Checks

| # | Check | Result |
| --- | --- | --- |
| 1 | Overview "This case at a glance": coverage, counts, next step; counts clickable; contradiction count scrolls to the list; reading-limit wording | **NOT RUN** (screen locked) |
| 2 | Contradictions: dismiss with a reason and history; persists after kill + relaunch; ⌥⌘↓/↑/Y/N/L with the note focused; long note does not widen the page | **NOT RUN** (screen locked) |
| 3 | Workspace restore (tab, selection, search) across kill + relaunch | **NOT RUN** (screen locked) |
| 4 | Evidence request: 3 monthly items, linked document, partial with the missing month, copy draft letter | **NOT RUN** (screen locked) |
| 5 | Case report export: coverage and evidence-request sections, confirmed contradiction | **NOT RUN** (screen locked) |
| 6 | Professional Jobs: current step, ⌥⌘F, Show all | **NOT RUN** (screen locked) |
| 7 | Help: new tutorial steps, help entries, search "evidence request" | **NOT RUN** (screen locked) |
| 8 | Plans sheet and AI setup sheet wording | **NOT RUN** (screen locked) |
| 9 | Copy: Home, onboarding, help | **NOT RUN** (screen locked) |

## To re-run

- The owner must keep the screen unlocked for the run. caffeinate alone did not prevent the lock.
  - Turn off "Require password after screen saver begins or display is turned off" for the duration, or stay at the Mac.
  - Restore that setting afterwards.
- The method is unchanged: `build/axdrive/axdrive` for AX dumps, presses and keys, window-only `screencapture -l`, and a frontmost check before every keystroke (`/tmp/walk/safe.sh` wrapper).
