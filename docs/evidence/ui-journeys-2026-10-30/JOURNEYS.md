# Persona UI journeys — 2026-10-30

## Build under test (NOT the Distribution build)

| Item | Value |
|---|---|
| Commit | `93511fd9` (branch `investigations-next`, working tree had only `.xcstrings` / scheme-management edits) |
| Scheme / configuration | `Kalsmritikosh`, **Debug** |
| Signing | **Development-signed** (`CODE_SIGN_IDENTITY = Apple Development`, TeamIdentifier `6TPTCJD42Q`, `get-task-allow = true`), App Sandbox on |
| Product | `~/Library/Developer/Xcode/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app` |
| Launch arguments | `-kalsmritikosh.sampleArchiveMode YES` (the only extra argument; passed via `open --args`) |
| Ledger opened | **Sample-archive ledger only** — `…/Containers/ecosanskritiinnovation.Kalsmritikosh/Data/Library/Application Support/DemoArchive/sample-knowledge.sqlite`; the purple "Sample archive — … Your own documents and answers are untouched" banner with the "Back to my archive" button was present on every screen (`00-first-screen.png`). The owner's encrypted ledger was never opened; "Back to my archive", "Erase", "Forget", "Delete", purchase/Online/cloud controls were never pressed. |
| Sample corpus | 8 ProjectDelta fixture files, all "Searchable" and "Evidence-ready", 13/13 embedded (`02b-files-sample-ledger.png`) |
| macOS / display | Darwin 27.0.0; 1470×956 pt (2940×1912 px Retina) |
| Date / time | 2026-10-30, 09:08–09:35 local |

This is a development-signed Debug build run from DerivedData; it is **not** the Distribution/App Store build and no claim here transfers to a signed Release artifact.

## How the journeys were driven (deviation from the brief)

The brief asked for the Xcode `DeviceInteraction*` tools. They **cannot target macOS**: `DeviceInteractionStartWorkspaceSession` returned
"The device you are targeting is not supported for Device Interaction. Supported: iOS [Simulator] 27.0+; watchOS [Simulator] 27.0+; tvOS [Simulator] 27.0+"
(and with `deviceIdentifier: "My Mac"` it listed only iOS simulators). So there was no session to start or end. Substitute, with the same safety envelope:

1. `BuildProject` (Xcode, scheme Kalsmritikosh, Debug) — green.
2. Launched the built product with `open -n -a <app> --args -kalsmritikosh.sampleArchiveMode YES` (verified in `ps`: the process carried exactly that argument).
3. Drove the UI through the macOS Accessibility API (a small compiled Swift AX tool: element dump, `AXPress`, CGEvent click/scroll/typing) and captured with `screencapture -R <window frame>`. Every press targeted an element found in the AX tree (no blind coordinate taps, except clicking into a text field to give it keyboard focus before typing).
4. Quit the sample-mode instance at the end (`pid 12687` ran the whole session — no crash, no relaunch).

Persona selection in this app: the per-persona jobs surface is **Professional Jobs** (`PersonaJobsView`, `Destination.work`). It is not in the simplified sidebar; it was reached with ⌘K ("Jump to…") → typed "Professional Jobs" → Return, after which it appeared in the sidebar's "For you" rows. On that screen a horizontal row "Choose a professional focus" lists the nine personas (Content Creator is hidden by its module flag, as designed). Each persona needs a **matter**: typed a title into "Matter title" and pressed "Start matter" (intake job → creates a case in the chosen workspace). Jobs then show `Run`, and after a saved result `Open result`.

Pre-step that was necessary: the first matter ("HR sample matter") was created with **0 source(s) in scope**, because intake copies the *workspace's* sources into the case and the auto-created "General" workspace had none. Fixed in the sample ledger through the UI: Projects → General → "Add sources…" → "Select All Visible" (8 selected) → "Add Sources" (`02c`, `02d`). Every later matter reported "with 8 source(s) in scope".

## Per-persona table

| # | Persona (label on screen) | How reached | Matter | Job launched (button) | Result state shown | Sources visible on rows | Screenshot | UI defect seen |
|---|---|---|---|---|---|---|---|---|
| 1 | Compliance / HR Investigator | Professional Jobs → persona card (default-selected) → Start matter | "HR matter with sources" (8 sources) | **Statement comparison** (Run) → then **Documentary evidence register** (Run → Open result) | Statement comparison: outcome banner "blocked: 0 row(s) — The case's documents contain no statement attributed to a named person…" — **no saved result / no Open result**. Documentary evidence register: **Draft — awaiting your review · 8 row(s)** | Yes — every row has date, snippet, "Open source" link | `03-hr-matter-opened.png`, `03-hr-statement-comparison-result.png`, `03-hr-documentary-evidence-register-result.png` | D3 (blocked outcome not inspectable) |
| 2 | Lawyer / Professional Reviewer | persona card → Start matter | "Lawyer sample matter" (8) | **Document coding** (Run → Open result) | **Draft · 8 row(s)**; "Limitations of this run" explains privilege withholding; per-row Issue codes / Relevance / Privilege fields, "⚑ not coded — relevance and privilege are the reviewer's" | Yes | `04-lawyer-document-coding-result.png` | none |
| 3 | Journalist | persona card → Start matter | "Journalist sample story" (8) | **Source map** (Run → Open result) | **Draft · 8 row(s)**; Independence family prefilled ("Family 1 (independent by text)"), Relationship/Protection left to the reviewer, "⚑ not assessed" | Yes | `05-journalist-source-map-result.png` | none |
| 4 | Researcher / Historian | persona card → Start matter | "Researcher sample question" (8) | **Chronology & periodisation** (Run → Open result) | **Draft · 30 row(s)**; flags "⚑ disputed date" / "⚑ date stated in text"; Period + Dated (optional) fields | Yes | `06-researcher-chronology-result.png` | none |
| 5 | Genealogist / Family Historian | persona card → Start matter | "Genealogist sample family" (8) | **Family lines & timeline** (Run → Open result) | **Draft · 0 row(s)** with limitation "No sentence states a kinship between two named people…" and Next actions; Add a row offered | n/a (no rows) — honest empty draft | `07-genealogist-family-lines-result.png` | none |
| 6 | Forensic Accountant | persona card → Start matter | "Forensic sample engagement" (8) | **Workpapers & custody** (Run → Open result) | **Draft · 3 row(s)** (WP-001 USD 540,000, WP-002 USD 25,000, WP-003 USD 1,800,000), Calculation/Inputs fields, "⚑ workpaper — stated amount" | Yes | `08-forensic-workpapers-result.png` | none |
| 7 | Insurance Fraud (SIU) | persona card → Start matter; result reopened via "Resume where you left off → Open" | "SIU sample claim" (8) | **EUO / interview prep** (Run → Open result) | **Draft · 8 row(s)**; each question "Put to John Carter: “…” — confirm, deny or explain", "⚑ question tied to its passage", Topic / Question / Documents to put fields | Yes | `09-siu-euo-prep-result.png` | none (first Open-result attempt failed only because my scroll left the card out of the lazy grid; worked after resuming the matter) |
| 8 | Investigator | persona card → Start matter | "Investigator sample case" (8) | **DataLab** (Run → Open result) | **Draft · 66 row(s)**; row 1 is the query ("filter: none · group by: label · total: amount", "51 of 51 value(s) admitted… sources: 8 document(s)", "⚑ query — edit the fields and run the job again to recompute"), then computed field rows "⚑ computed from the cited rows" | Yes (cited passages listed per row) | `10-investigator-datalab-result.png` | none |
| 9 | Individual | persona card → Start matter | "Individual sample topic" (8) | **Career & education** (Run → Open result) | **Draft · 1 row(s)**; limitation "37 dated item(s) in the case are not career or education entries…" | Yes | `11-individual-career-education-result.png` | none (content note C1) |

Every result sheet showed the same footer: `Export…`, `Save review` (disabled until a change), `Completion note (required to complete)`, `Mark completed` (disabled until the note is filled). `Export…` was not pressed (it opens an NSSavePanel).

## Step 4 — accept a row and Save

On the HR **Documentary evidence register** result: pressed the first row's `Accepted` radio (AX value flipped 0→1), then `Save review`. The sheet showed "Review saved as a new revision." and the header gained "Reviewed by me, 30/10/2026, 9:26 AM"; the state stayed Draft (correct — completion requires the note). No required field was shown for this job (its contract has no typed fields), so none was filled. Screenshot: `03-hr-documentary-evidence-register-accepted-saved.png`. No save dialog opened.

## Defects and observations

| ID | Severity | What | Evidence |
|---|---|---|---|
| D1 | Medium (layout) | **Window launched 1100 × 2343 pt** — more than twice the 956 pt screen height. On the first screen (Cases) the empty-state text "No cases yet" and its "New case" button sat at y≈1240–1400 and the sidebar's Live panel ("Ready") at y≈2331, i.e. off-screen; the visible area ended in blank space. Setting a smaller window size via AX was ignored twice (frame stayed 2343 tall); pressing the zoom button fixed it (1470 × 847). `.defaultSize(1100×720)` in `KalsmritikoshApp.swift:116` was not what appeared; the oversized frame is either a restored frame or a min-height pressure from the content. Worth reproducing on a fresh user account. | `00-first-screen.png` (visible part only; AX frame logged as `AXWindow|Cases|…|1100x2343`) |
| D2 | Low (palette) | **⌘K palette list did not match the action.** Typing "Professional Jobs" rendered a single result row "Home — Start here — pick the lens that fits your work", yet Return opened Professional Jobs. Either the list is stale/filtered wrongly or the highlighted row is not what Return runs. | `01-palette-professional-jobs.png` |
| D3 | Low (consistency) | **Blocked outcome without an inspectable result.** HR "Statement comparison" reported "blocked: 0 row(s) — …" only in the transient outcome banner; no result record was saved, so no "Open result" button and no "Blocked — open to see what is missing" card status appeared (executor jobs persist blocked results via `PersonaJobService.swift:312`; this path does not). The person has nothing to open after the banner changes. | `03-hr-statement-comparison-result.png` |
| D4 | Low (onboarding) | **First matter opened with 0 sources in scope.** From a fresh sample ledger, "Start matter" auto-creates the "General" workspace empty, so intake reports "with 0 source(s) in scope" and jobs block on "no documents"; nothing on the Professional Jobs page says that sources must first be added to the workspace (Projects → Add sources…). | `03-hr-matter-opened.png` |
| C1 | Content (not UI) | Individual → Career & education's single row is "We expect the certified material on 2024-04-22." — a procurement sentence, not a career/education entry (a false positive of the career classifier on this corpus). | `11-individual-career-education-result.png` |

No overlapping or truncated text, no unresponsive control (every AXPress returned success and produced the expected change), no crash (single pid for the whole session; `log show` for the process surfaced no error/fault lines).

## Not done / caveats

- Xcode Device Interaction session could not be started or ended (macOS unsupported) — replaced by AX scripting as described; screenshots are of the on-screen window (the oversized launch window is captured only as far as the screen).
- `Export…` was not exercised (system save panel); no export bytes or redaction bytes were produced in this run.
- The owner's ledger was not touched. Side effects were confined to the sample ledger (8 matters, workspace sources) plus UI-journey state keys (`kalsmritikosh.jobs.ran.*`, `kalsmritikosh.jobs.log.*`) in the app's shared UserDefaults, which are keyed by the sample cases' UUIDs.
- Screenshots `02b`–`02d`, `03-hr-matter-opened` document the setup steps; `01`/`00` document D1/D2.
