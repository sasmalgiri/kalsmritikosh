Result: FAIL

# Acceptance case through the UI — AGENT evidence

Candidate: f766b0357b18b7efd0e3ce43781bbf1cec35a512

Run by: AGENT (Claude), not a person — 2026-11-02, 15:28–16:03 IST.

## Build and launch

- Debug build from HEAD 5e754a59. `git diff f766b035 HEAD -- Kalsmritikosh` is empty: app code identical to the candidate.
- Launched in sample mode only: `open -n -a …/Debug/Kalsmritikosh.app --args -kalsmritikosh.sampleArchiveMode YES`, pid 82834, sample ledger only.
- Quit with `kill -TERM 82834`; no instance remained.
- Method: AX driver (`build/axdrive/axdrive`) plus screenshots.

Full record: docs/evidence/ui-candidate-2026-11-02/JOURNEYS.md

## A — acceptance steps (sample "Investigator sample case")

| Step | Result | Evidence |
| --- | --- | --- |
| A1 Open the sample case | PASS | docs/evidence/ui-candidate-2026-11-02/01-open-ledger.txt, A5-matter-open-tree.txt |
| A2a "Who signed the master supply agreement?": a verbatim quote, cited to contract.md | PASS | A2-q1-answer.png, A2-q1-answer-tree.txt |
| A2b "Was invoice 432 paid?": "No document found records invoice 432 as paid" with quotes, 2 sources. Note: one quote carries an unrelated "Risk:" clause, and the strip says "AI-assisted" under "no AI involved" | PASS (note) | A2-q2-answer.png |
| A3 Open a source from a citation: contract.md opens with the passage highlighted | PASS | A3-source-sheet.png |
| A4 Review contradictions: "Review" names no source. "2 sources" names invoice-401.eml and invoice-432.eml, but the source opens without the claim highlighted. The conflict pairs two different invoices | FAIL | A4-review-tree.txt, A4-two-sources-tree.txt, A4-open-source.png |
| A5 Professional Jobs: "Source reliability" run → saved draft result, 8 rows, saved 3:47 PM | PASS | A5-after-run-tree.txt, A5-result.png |
| A6 Help ▸ tutorial (Step 1 of 10, inside the window) and Help guide open | PASS | A6-tutorial.png, A6-help.png |

## C — usability re-checks

| Check | Result | Evidence |
| --- | --- | --- |
| C1 Cases table names readable | PASS | C1-cases-table.png |
| C2 Settings: Advanced collapsed, no red model banner. Note: a red "Self-check found issues 13/15" chip is shown | PASS (note) | C2-settings.png, C2-settings-tree.txt |
| C3 Sidebar order stable across two screen changes: the top group changes contents, and Ask → Files dropped "Guide" and moved the GO TO rows up 41 pt | FAIL | C3-sidebar-order-1.txt, C3-sidebar-order-2.txt, C3-files.png |
| C4 All 9 persona cards visible; label followed the pick (INVESTIGATOR). Note: before the pick the Lawyer card was highlighted while the label read RESEARCHER | PASS (note) | A5-jobs.png, C4-pick-investigator.png |

## Other defects observed

- Verify Receipt and Case Story render blank: content laid out off-screen at y −1307 / −740 (B26-verify-screen.png, B28-casestory.png).
- The Ask answer context menu stayed drawn over another screen after AX AXShowMenu. Real right-clicks did not open it in this run.

All evidence paths are under docs/evidence/ui-candidate-2026-11-02/.

## Limits

- Sample archive only. The `--acceptance-case` fixture (supplier double payment) was not walked: this run was restricted to sample mode.
- Debug build, not signed or distribution.
- Agent-driven through Accessibility. Typed input was not possible by AX, and keystrokes were avoided after Xcode took focus twice.
- This is evidence by an agent, not a person's approval.
