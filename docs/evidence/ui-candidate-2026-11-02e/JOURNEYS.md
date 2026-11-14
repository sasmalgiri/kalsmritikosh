# Targeted UI re-check on the candidate — AGENT run, 2026-11-02 (fifth pass)

**Result: PASS** for the checks repeated here (the two layout regressions and the blank print preview from the fourth pass)

**AGENT run.** An agent (Claude) did this run, not a person, by the owner's direction of 2026-11-01. Only what was observed is recorded.

- **Candidate:** eaa822f1ae0b1448ca5f77ec3cb675de6a878ac8. It was HEAD at the time of the run, and `git diff eaa822f1 HEAD -- Kalsmritikosh` is empty.
  - The working tree had Xcode-made edits to `Kalsmritikosh/InfoPlist.xcstrings`, `KalsmritikoshShare/InfoPlist.xcstrings` and an xcuserdata plist. These are localisation and user metadata, not app code (00-build.txt).
- **Build:** Debug, `~/Library/Developer/Xcode/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app`. The binary is dated 2 Nov 2026 22:04:25, after the candidate commit (22:03:34).
- **Launch:** `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES` at 22:05:48 IST, **pid 19597**, the only instance. `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) open (01-launch.txt). "Back to my archive" was never pressed.
- **Method:** `build/axdrive/axdrive` (AX tree dumps, AX press) and window-only screenshots. The same two checkers as the fourth pass were run over the AX trees: detail content above y 120, and detail elements under the app sidebar (x+w ≤ 220). Output in S-layout-check.txt. No ⌘Q and no right-click.
- **Exports:** saved into `~/CaseBench/ui-candidate-eaa822f1/exports`. A copy is in `exports/`, digest in exports-sha256.txt.
- **Network:** Online mode stayed off. No AI send, lookup or purchase. No print dialog was looked for (owner decision: no print entitlement).
- **Quit:** `kill -TERM 19597` at 23:24:43. No instance remained (99-finish.txt).

## Checks

| Check | Result | Observed | Evidence |
| --- | --- | --- | --- |
| S1 Work Center rail (fourth-pass regression 1) | **PASS** | The workflow rail is to the right of the app sidebar: "All workflows" and "Source map" at x 234 (were x 14). Steps, Summary, Copy Report, Variant and the Print button are all visible. 0 elements under the sidebar, 0 above the window | S1-workcenter.png, S1-workcenter-tree.txt, S-layout-check.txt |
| S2 Knowledge kind list (fourth-pass regression 2) | **PASS** | Knowledge's own list (People, Companies, Projects, Highlights) sits right of the app sidebar, starting x 236; the entity list (John, John Carter, Maria, Maria Lopez) is to its right. 0 elements under the sidebar. The window title still reads "Person" (as before) | S2-knowledge.png, S2-knowledge-tree.txt |
| S4 layout sweep (9 screens: Home, Ask, Work Center, Knowledge, Cross-Doc Matrix, Reasoning Studio, Verify Receipt, Case Story, Settings) | **PASS** (9 of 9) | Sidebar rows at the same positions on every screen (PERSONA y 284; Professional Jobs 302 … Settings 713). 0 elements above the window and 0 under the sidebar on each. Cross-Doc Matrix title at y 188, Reasoning Studio title at y 198 (still pinned) | S-layout-check.txt, S4-*-tree.txt, S4-*.png, S4-contact-sheet.png |
| S5 print preview, ACH (route 11) | **PASS** | Print pressed 22:55:08. "Print preview — ACH — Why is the injury date inconsistent?" shows the report in black on white: disclaimer, question, hypotheses, consistency matrix, scores. 84,996 pixels darker than 128/255 in the page area (fourth pass: 0). "Save as PDF…" opened a Save sheet on the preview window. Saved: 18,718 bytes, PDF 1.3, 2 pages, 2,016 + 1,474 characters. Notice afterwards: "Saved as PDF from the print preview. Released — NOT yet recorded: … no case to record it in" | S5-ach-preview.png, S5-ach-darkpixels.txt, S5-ach-save-sheet.png, S5-ach-pdf-text.txt, S5-ach-after-save-tree.txt, exports/ |
| S5 print preview, Work Center (route 17) | **PASS** | "Print preview — WF-2026-0001" shows the workflow text (title, status RELEASED, 2/4 operations, the four steps). 24,324 dark pixels in the page area (fourth pass: 0). Close closed the preview; only the Work Center window remained | S5-wc-preview.png, S5-wc-darkpixels.txt, S5-wc-after-close-windows.txt |

## Driving note

- In the ACH Save sheet the agent typed the full target path into the "Save As" name field instead of using ⌘⇧G. The panel kept the folder it was showing (the fourth pass's exports folder) and saved under the literal name `~:CaseBench:ui-candidate-eaa822f1:exports:ACH — ….pdf`. The agent moved that file into this run's exports folder (23:20). This was the agent's input, not app behaviour: the panel did what Save panels do with such a name. The save itself was pressed at 23:10 (S5-ach-save-time.txt), about 15 minutes after the sheet opened.

## Limits

- Sample archive only, Debug build, agent-driven through Accessibility.
- Only the checks listed above were repeated, and the layout sweep covered 9 screens (the fourth pass covered 20). Everything else comes from docs/evidence/ui-candidate-2026-11-02d/JOURNEYS.md (8de27cf8) and docs/evidence/ui-candidate-2026-11-02c/JOURNEYS.md (82127048).
- Between 8de27cf8 and this candidate the app code changed only in eaa822f1: the viewport pin is applied to Cross-Doc Matrix and Reasoning Studio only, and the print preview draws page images instead of a PDFView.
