Result: FAIL

# Acceptance case through the UI — AGENT evidence

Candidate: 8212704862ce96de1adf264d8cdacb2d122abbce

Run by: AGENT (Claude), not a person. 2026-11-02, 17:51–20:36 IST. Debug build from HEAD 82127048 (`git diff 82127048 HEAD -- Kalsmritikosh` empty). Launched with `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES`, pid 3485, quit with `kill -TERM 3485`.

Evidence: docs/evidence/ui-candidate-2026-11-02c/ (JOURNEYS.md, AX trees, screenshots, exports/, exports-sha256.txt).

## A — acceptance steps

| Step | Result | Evidence |
| --- | --- | --- |
| A1 Open the sample case | PASS | 02-start-jobs.png, C3-a.png, B-case.png |
| A2a "Who signed the master supply agreement?" quotes and cites contract.md; no dump | PASS | A2-q1-answer.png, exports/B37-ask-copy-q1.txt |
| A2b "Was invoice 432 paid?" quotes invoice-432.eml and supplier_abc_25.eml; no dump (third quote ends in a stray " -") | PASS | A2-q2-answer.png, exports/B37-ask-copy-q2.txt |
| A2c Rule answers say "no AI involved". The body does, but the footer under both answers still reads "AI-assisted answer — it can be incomplete or wrong" | FAIL | A2-q1-answer-tree.txt, A2-q2-answer.png |
| A3 Open source from a citation, at the quoted passage | PASS | A3-source-sheet.png |
| A4 Review contradictions: no invoice 401/432 pair; both sources named in the card and the decision form; 3 of 4 sources open at the highlighted passage. supplier_abc_22.eml for "Contract modified on Apr 8, 2024" opens with nothing highlighted | FAIL | A4-review.png, A4-queue-tree.txt, A4-open-source-A.png, A4-open-source-B.png, A4-open-source-C.png, A4-open-source-D.png |
| A5 Professional Jobs: Source reliability run → saved result (8 rows, saved 6:42 PM) → exported | PASS | A5-result.png, exports/Source reliability.md |
| A6 Help ▸ Replay the Tutorial (Step 1→2 of 10, Stop) and Help ▸ Guide | PASS | A6-tutorial.png, A6-help.png |

## C — usability checks

| Check | Result | Evidence |
| --- | --- | --- |
| C1 Cases names readable (12 rows) | PASS | C1-cases.png |
| C2 Settings: Advanced collapsed, no model banner (a red "Self-check found issues 13/15" chip is shown) | PASS | C2-settings.png |
| C3 Sidebar shortcuts are always Professional Jobs, Cases, Review, Guide; positions are identical on 14 screens. Rows move on Knowledge and Query (−12 pt), Reasoning Studio (−307 pt) and Cross-Doc Matrix (−349 pt, off-screen) | FAIL | C3-sidebar-md5.txt, B32-knowledge-tree.txt, B18-studio-tree.txt, B30-matrix.png |
| C4 Persona cards (9) visible, Investigator highlighted, label "PERSONA · INVESTIGATOR" | PASS | C3-a.png |
| C5 Verify Receipt and Case Story render their content on screen | PASS | B26-verify-result.png, B28-story.png |

## Other defects observed

- Cross-Doc Matrix and Reasoning Studio draw their content above the window (the same off-screen layout class fixed for Verify Receipt and Case Story).
- Print preview windows open, but their pages draw blank on screen. A saved PDF (Work Center) has the full text.

## Limits

- Sample archive only; the `--acceptance-case` fixture was not walked.
- Debug build, not a signed or distribution build.
- Agent-driven through Accessibility on a display shared with other agent-driven apps, which took focus at times (see JOURNEYS.md).
- No protected-identity register entry was exercised.
- This is evidence by an agent, not a person's approval.
