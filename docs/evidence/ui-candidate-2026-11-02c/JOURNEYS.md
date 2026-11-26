# UI acceptance + output routes on the candidate — AGENT run, 2026-11-02 (third pass)

**Result: FAIL** (A2 footer, A4 one source not opened at its line, C3 sidebar moves, Cross-Doc Matrix and Reasoning Studio drawn off-screen, print preview pages blank on screen)

**AGENT run** — performed by an agent (Claude), not a person, by the owner's direction of 2026-11-01. Only what was observed is recorded.

- **Candidate:** 8212704862ce96de1adf264d8cdacb2d122abbce (HEAD at the time of the run; `git diff 82127048 HEAD -- Kalsmritikosh` is empty). The working tree had Xcode-made edits to `Kalsmritikosh/InfoPlist.xcstrings`, `KalsmritikoshShare/InfoPlist.xcstrings` and an xcuserdata plist (localisation/user metadata, not app code). See 00-build.txt.
- **Build:** Debug, `~/Library/Developer/Xcode/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app`, binary dated 2 Nov 2026 17:50:09, after the candidate commit (17:48:54).
- **Launch:** `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES` at 17:51:04 IST, **pid 3485**, the only instance. `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) open (01-open-ledger.txt). "Back to my archive" was never pressed.
- **Method:** `build/axdrive/axdrive` (AX tree dumps, AX press / focus / setvalue / AXShowMenu), window-only screenshots (`screencapture -l <window id>`), the Jump palette driven by AX setvalue (`/tmp/jump82.sh`), and two small AX helpers in /tmp (`wid2` lists the app's windows; `axsel` sets AXSelectedRows on an outline, used once for Compare Documents).
  - Keystrokes were sent only right after the app was activated and verified frontmost: the two Ask questions, cmd+shift+G + Return in save/open panels (4 times), the custodian name "John Carter", the Case Story subject and the matrix topic "invoice 432".
  - No right-click (CGEvent) was used. No ⌘Q.
- **Shared screen (limit):** another app, LawyerFleet (pid 7379), and Xcode were being driven at the same time on the same display. They took focus several times, and once the clipboard held "Cess" from the other app; the copy was repeated and read immediately. Two attempts to type the Case Story subject left no text in the app's field. They were typed right after a frontmost check, but focus moved, so the keystrokes may have reached another app. The third attempt (AX focus first) landed.
- **Exports:** all saved into `~/CaseBench/ui-candidate-82127048/exports` (new folder). Copies, plus clipboard captures (B10, B13, B15, B17, B23, B37), are in `exports/` here, with digests in exports-sha256.txt.
- **Network:** Online mode was never turned on. No AI send, lookup, purchase or e-mail. "Send to DEVONthink" was run once: DEVONthink is not installed (mdfind found no bundle), and the note was shown in Finder.
- **Quit:** `kill -TERM 3485` at 20:36:44; no instance remained (99-finish.txt).

## A — acceptance steps (sample case)

| Step | Result | Observed | Evidence |
| --- | --- | --- | --- |
| A1 Open the sample case | **PASS** | Sample archive banner. Professional Jobs: "Resumed matter "Investigator sample case"", 0 of 15 jobs resolved, 8 documents in scope. Cases ▸ Open Investigator sample case opened the case file | 02-start-jobs.png, C3-a.png, B-case.png |
| A2a "Who signed the master supply agreement?" | **PASS** (quote + cite) | "The document states: “This agreement is signed this 12th day of January 2024 by John Carter (Procurement Director, Northwind) and Maria Lopez (VP Operations, Supplier ABC).”" Supported, strong, 1 source, chip "1 contract.md". A verbatim quote, not a dump | A2-q1-answer.png, A2-q1-answer-tree.txt |
| A2b "Was invoice 432 paid?" | **PASS** (quote + cite) | "No document found records invoice 432 as paid. They say: “Invoice No. 432 — Project Delta milestone 2 — OVERDUE” / “This invoice remains unpaid as of June 14, 2024.” / “invoice 432 issued for milestone 2 and overdue as of 2024-06-29. -”". 2 sources (invoice-432.eml, supplier_abc_25.eml). The earlier "Risk:" clause is gone; the third quote ends in a stray " -" | A2-q2-answer.png |
| A2c Rule answers say "no AI involved" | **FAIL** | Both answers say "(Quoted verbatim …; no model was consulted.) Answered from your records — no AI involved." The per-answer footer under both still reads "AI-assisted answer — it can be incomplete or wrong. …", not the new "Read from your documents by fixed rules — no AI involved …" line | A2-q1-answer-tree.txt (id=ask.evidence), A2-q2-answer.png |
| A3 Open a source from a citation | **PASS** | "Source 1: contract.md. Opens at the quoted passage." opened a "contract.md" sheet with the signature sentence highlighted | A3-source-sheet.png |
| A4 Review contradictions | **FAIL** (1 of 4) | 2 conflicts: "Contract modified" (Jan 12 vs Apr 8, 2024) and "Delivery delayed" (Apr 8 vs Jun 14, 2024). There is no invoice-401/432 pair. Each claim names its source (amendment-7.md / supplier_abc_22.eml; supplier_abc_22.eml / invoice-432.eml), in the card and in the review queue's decision form. Opening each source: amendment-7.md, supplier_abc_22.eml (delivery) and invoice-432.eml open with the passage highlighted. **supplier_abc_22.eml for "Contract modified on Apr 8, 2024" opens with nothing highlighted** | A4-review.png, A4-queue-tree.txt, A4-open-source-A/B/C/D.png |
| A5 Professional Jobs job → saved result | **PASS** | "Source reliability" ▸ Run → "draft: 8 row(s)", work log 6 actions. Open result: "Draft — awaiting your review · 8 row(s) · saved 2/11/2026, 6:42 PM". Export… wrote "Source reliability.md", rows by file name with quoted passages. Note: "Chain of custody" ▸ Run gave the banner "8 custody manifest entr(y/ies)" while its card read "Ran — nothing saved to review" | A5-after-run2-tree.txt, A5-result.png, exports/Source reliability.md, A5-after-custody.png |
| A6 Help / tutorial | **PASS** | Help ▸ Replay the Tutorial: tutorial.panel "Step 1 of 10", Next → "Step 2 of 10", Stop closed it. Help ▸ Investigations Made Easy Help opened Guide with "Replay the tutorial", "Get started" and recipes per persona | A6-tutorial.png, A6-help.png, A6-help-tree.txt |

## C — usability re-checks

| Check | Result | Observed | Evidence |
| --- | --- | --- | --- |
| C1 Cases names readable | **PASS** | 12 rows with full names, Stage chips, Open links | C1-cases.png |
| C2 Settings | **PASS** | Every disclosure group, Advanced included, value 0 (collapsed). No model banner. A red chip "Self-check found issues 13/15 checks · all formats" is shown | C2-settings.png, C2-settings-tree.txt |
| C3 Sidebar shortcuts fixed, no row moves | **FAIL** | The shortcut set is always Professional Jobs, Cases, Review, Guide. Sidebar extracts are byte-identical (md5 b8ae064e…) on Privilege Log, Professional Jobs, Ask, Verify Receipt, Review, Settings, Cases, Guide, the case file, ACH, Case Story, Workspaces, Handoff and Compare Documents. But rows move on other screens: Knowledge and Query −12 pt (GO TO y 466 vs 478); Reasoning Studio −307 pt (Professional Jobs y −5); Cross-Doc Matrix −349 pt (most rows off-screen) | C3-sidebar-md5.txt, 02-start-sidebar.txt, C3-a-sidebar.txt, B26-verify-screen-tree.txt, B32-knowledge-tree.txt, B18-studio-tree.txt, B30-matrix.png |
| C4 Persona cards and label | **PASS** | 9 cards visible; Investigator highlighted; label "PERSONA · INVESTIGATOR" | C3-a.png |
| C5 Verify Receipt and Case Story render | **PASS** | Verify Receipt: header, Open receipt…, result and 4 claims on screen. Case Story: "Story of “Project Delta”" with Overview, Parties and Export on screen | B26-verify-result.png, B28-story.png |

## Other defects observed

- **Off-screen layout (FAIL), same class as the fixed Verify/Case Story defect.** Cross-Doc Matrix draws its content at y −349 in a 1666-pt hosting view (the search field is at y −222, the sidebar shifted, the banner cut to "undled example documents…"). Reasoning Studio's title is at y −80. Routes 30/31 still worked through AX (B30-matrix.png, B30-matrix-tree.txt, B18-studio-tree.txt).
- **Print preview pages blank on screen.** Each preview window (ACH, Work Center, Privilege Log studio) has 1–2 AXPage elements, the line "Printing from this app is not available. Save the pages as a PDF …", and Close and Save as PDF…. The pages draw white with no text, both in window-only captures and in a screen-region capture with the app frontmost. The saved Work Center PDF does contain the full text (1 page, B17-saved-pdf-render.png) (B11-print-preview.png, B13-print-preview-region.png, B17-print-preview.png).
- **ACH Save as PDF wrote nothing.** "Save as PDF…" was pressed once on the ACH preview. A Save panel ("ACH — Why is the injury date inconsistent?.pdf") appeared, then closed by itself before OK was pressed, and no PDF was written. The cause was not established (other apps were taking focus). One documented second attempt was made on the Work Center preview, with OK pressed at once: it wrote WF-2026-0001.pdf (13,249 bytes, 1 page, text identical to the Work Center copy). Closing a preview recorded nothing ("Print preview closed — nothing was saved or recorded.").
- Workspace report: "Delivery was delayed because of delivery delayed." is still present. The Sources section lists 96 lines for 8 distinct files.
- Redaction log CSV names the document by version UUID, not file name. Query CSV and Cross-Doc Matrix "Date" carry the ingest date (2026-10-30) or no source column.
- Privilege-log "Export Markdown" saves a `.txt` file holding Markdown.

## Limits

- Sample archive only, Debug build, agent-driven through Accessibility, on a display shared with other agent-driven apps.
- The `--acceptance-case` fixture was not walked.
- No protected-identity register entry was exercised, so no scrub or refusal was observed.
