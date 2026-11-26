# UI acceptance + output routes on the candidate — AGENT run, 2026-11-02

**Result: FAIL** (see A4, C3, B11, B28, B35, B36 and the off-screen layout defect)

**AGENT run** — performed by an agent (Claude), not a person, by the owner's direction of 2026-11-01. Only what was observed is recorded.

- **Candidate:** f766b0357b18b7efd0e3ce43781bbf1cec35a512.
- **Build:** Debug, `…/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app`, binary dated 2 Nov 2026 15:27, built from HEAD 5e754a59. `git diff f766b035 HEAD -- Kalsmritikosh` is empty, so the app code is identical to the candidate. The working tree also has Xcode-made edits to `InfoPlist.xcstrings` (a display-name localisation string, state "new"). That is localisation metadata, not app code (00-build.txt).
- **Launch:** `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES` at 15:28:51 IST, **pid 82834**, the only instance. `lsof` shows only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) open (01-open-ledger.txt). "Back to my archive" was never pressed.
- **Method:** `build/axdrive/axdrive` (AX tree dumps, AX press/setvalue/action), `screencapture -R` on the window frame, and the Jump palette driven by AX setvalue.
  - Typing used key codes (`typek`) twice, each time right after a frontmost check.
  - Three CGEvent right-clicks were tried on the Ask answer. During them Xcode (pid 24918) became frontmost, and an Xcode Dock menu was found open (cause not established). The menu was dismissed by a left click on an empty Ask area and no item was chosen (00-build.txt). From then on only AX actions were used: no keystrokes, no CGEvent clicks.
  - Small helpers lived in /tmp: `rc` (right-click), `lm` (menu list), `exp.sh` (save only when the panel's Where is `exports`), `jump.sh` (Jump palette).
- **Exports:** all saved into `~/CaseBench/ui-candidate-f766/exports` (new folder). Copies are in `exports/` here, with digests in exports-sha256.txt. Nothing was overwritten.
- **Network:** Online mode was never turned on. No AI send, lookup, purchase, "Send to DEVONthink" or e-mail.
- **Quit:** `kill -TERM 82834` at 16:02:52; no instance remained (99-finish.txt).
- **Not walked:** the acceptance-case fixture (`--acceptance-case`, supplier double payment INV-2041). The run was restricted to sample mode, so the sample's "Investigator sample case" / Project Delta documents were walked instead.

## A — acceptance steps (sample case)

| Step | Result | Observed | Evidence |
| --- | --- | --- | --- |
| A1 Open the sample case | **PASS** | The app opened in the sample archive (purple banner) on the sample ledger. "Investigator sample case" opened from Professional Jobs ▸ Resume (0 of 15 jobs resolved, 8 documents in scope) and from Cases | 01-open-ledger.txt, A5-matter-open-tree.txt, B-case-tree.txt |
| A2a "Who signed the master supply agreement?" | **PASS** | "The document states: “This agreement is signed this 12th day of January 2024 by John Carter (Procurement Director, Northwind) and Maria Lopez (VP Operations, Supplier ABC).”" Supported, strong, chip "1 contract.md". A verbatim quote, not a passage dump | A2-q1-answer.png, A2-q1-answer-tree.txt |
| A2b "Was invoice 432 paid?" | **PASS (with a note)** | "No document found records invoice 432 as paid. They say: “Invoice No. 432 … OVERDUE” / “This invoice remains unpaid as of June 14, 2024.” / “invoice 432 issued … overdue as of 2024-06-29. - Risk: residual risk …”". Supported, 2 sources (invoice-432.eml, supplier_abc_25.eml). Note: the third quote carries an unrelated "Risk:" clause. Both answers also show the strip "AI-assisted answer — it can be incomplete or wrong" under "Answered from your records — no AI involved", which is contradictory wording | A2-q2-answer.png, A2-q2-answer-tree.txt |
| A3 Open a source from a citation | **PASS** | Chip "Source 1: contract.md. Opens at the quoted passage." opened sheet "contract.md" with the quoted sentence highlighted in the Signatures section | A3-source-sheet.png, A3-source-tree.txt |
| A4 Review contradictions (two sources named, opens at the claim) | **FAIL** | Findings ▸ Contradictions lists 3 conflicts. "Review" on "Conflicting dates for "Invoice issued"" opens a verdict form ("Review fact", Action, Reason, Save) **naming no source**. "2 sources" names invoice-401.eml and invoice-432.eml. Opening invoice-432.eml shows the whole e-mail **with nothing highlighted** (not opened at the claim). The conflict pairs two different invoices (401 and 432), so it is not a real contradiction | A4-contradictions.png, A4-review-tree.txt, A4-two-sources-tree.txt, A4-open-source.png |
| A5 Professional Jobs job run → saved result | **PASS** | Investigator case ▸ "Source reliability" ▸ Run: card "Draft — 8 row(s) to review", work log 2→3 actions, progress "2 to review". "Open result": "Draft — awaiting your review · 8 row(s) · saved 2/11/2026, 3:47 PM", rows by file name with "Open source" | A5-after-run-tree.txt, A5-result.png, A5-result-tree.txt |
| A6 Help / tutorial opens | **PASS** | Help ▸ "Replay the Tutorial (Sample Case)": `tutorial.panel` "Step 1 of 10" at x 1150–1470 inside a window grown to 1470 pt, with Next and Stop inside; Stop returned the window to 1421 pt. Help ▸ "Investigations Made Easy Help" opened Guide with search, "Replay the tutorial", and the 10-step "Get started" | A6-tutorial.png, A6-tutorial-tree.txt, A6-after-stop-windows.txt, A6-help.png |

## C — usability re-checks

| Check | Result | Observed | Evidence |
| --- | --- | --- | --- |
| C1 Cases table names readable | **PASS** | 12 rows with full names ("HR sample matter" … "Project Delta slip" ×2), Stage chips, Open buttons | C1-cases-table.png |
| C2 Settings: Advanced collapsed, no red model banner | **PASS (with a note)** | All disclosure groups, including "Advanced", have value 0 (collapsed), and there is no model banner. A red chip "Self-check found issues 13/15 checks · all formats" is shown at the top; what fails is not shown | C2-settings.png, C2-settings-tree.txt |
| C3 Sidebar order stable across two screen changes | **FAIL** | The top sidebar group is replaced as screens change. Start: Professional Jobs, Work Center, Findings, Guide. Later: Professional Jobs, Findings, Verify Receipt, Guide; then Case Story, Competing Hypotheses, Cases, Guide. Home → Ask kept it. Ask → Files dropped "Guide" to 3 items, and GO TO moved up 41 pt (y 478 → 437), shifting every fixed row | C3-sidebar-order-1.txt, C3-sidebar-order-2.txt, C3-files.png, A6-help.png, B09-ach-tree.txt |
| C4 Persona cards all visible; label follows the pick | **PASS (with a note)** | All 9 cards are visible without scrolling. After pressing "Investigator" the label read "PERSONA · INVESTIGATOR". Before the pick, the "Lawyer / Professional Reviewer" card was highlighted while the label read "PERSONA · RESEARCHER" | A5-jobs.png, C4-pick-investigator.png, C4-pick-investigator-tree.txt |

## Other defects observed

- **Off-screen layout (FAIL).** Verify Receipt and Case Story drew blank: an empty sidebar and an empty detail area, with the banner text cut ("undled example documents…"). The AX tree places the content at y −1307 / −740 in a 3578-pt-high hosting view. The receipt check still ran via AX (B26-verify-screen.png, B26-verify-result-tree.txt, B28-casestory.png, B28-casestory-tree.txt).
- **Stuck context menu.** After the AX AXShowMenu attempts on the Ask answer, the answer's menu (Save answer as text…, Export verifiable receipt…, Send to DEVONthink, one untitled item) stayed drawn over the Findings screen (A4-open-source.png). It was usable via AX press. The untitled item is still present.
- **Old brand name.** The ACH report disclaimer reads "generated by Kalsmritikosh" (exports/ach-…md).
- **Print.** ACH "Print" opened no print dialog. The screen then read "Not released (cancelled or not available); nothing was recorded." (B11-after-print.png). Whether this is the app or the AX-press path is not established.

## B — output routes

See `release/approvals/output-routes.md` for the route table. Exported files and digests: exports/, exports-sha256.txt.

Recorded digests checked against the files on disk (identical):

| File | Digest |
| --- | --- |
| Case file report | 27dbe75ba10751da |
| Case log | 393fab3c58fba265 |
| Exhibit list | 628f530f6bf22cfd |
| Custody report | 5872ceffa1d43408 |

The Ask receipt verified in Verify Receipt: "Integrity check passed — hash chain is internally consistent", seal 38cab0d3…, matching the file.

## Limits

- Sample archive only. The `--acceptance-case` fixture was not walked.
- Debug build, not a signed or distribution build.
- Text fields could not be filled by AX (SwiftUI bindings ignore AX value), and keystrokes were avoided after Xcode took focus. Routes that need typed input were not reached.
- No protected-identity register entry was exercised, so "no protected identity" means none of the sample's names was scrubbed or refused. A scrub was not observed.
- Routes 13, 14/15, 18, 21, 22, 25, 27, 29–34 were not run in this pass.
