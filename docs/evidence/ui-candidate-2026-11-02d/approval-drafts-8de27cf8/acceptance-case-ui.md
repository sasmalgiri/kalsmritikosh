Result: FAIL

# Acceptance case through the UI — AGENT evidence

Candidate: 8de27cf8b54896c29f3f706ab0ea67b7a66b67e2

Run by: AGENT (Claude), not a person.

This record combines two agent runs on the sample archive. The second is a targeted re-check on the candidate itself.

- **Run 2 (re-check, on the candidate):** 2026-11-02, 20:48–21:40 IST. Debug build from HEAD 8de27cf8 (`git diff 8de27cf8 HEAD -- Kalsmritikosh` empty). Launched with `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES`, pid 13734, quit with `kill -TERM 13734`. Evidence: docs/evidence/ui-candidate-2026-11-02d/ (JOURNEYS.md, AX trees, screenshots, exports/, exports-sha256.txt).
- **Run 1 (full walkthrough, on 82127048):** 2026-11-02, 17:51–20:36 IST, pid 3485. Evidence: docs/evidence/ui-candidate-2026-11-02c/ (JOURNEYS.md and files).
- **Code between the two runs:** the app code changed only in commit 8de27cf8, in four files: UI/RootView.swift, UI/AppPrinting.swift, UI/CitationChips.swift and UI/QualityStrip.swift. The changes were:
  1. every screen pinned to the real detail viewport;
  2. print-preview pages drawn black on white, and "Save as PDF…" opened as a sheet on the preview window;
  3. the answer footer saying "no AI involved" when AI and Online mode are off;
  4. a Review contradiction source opening at the line that shares its words and date.

  Steps that touch none of these are carried over from Run 1 and marked "(Run 1)". Steps re-checked on the candidate are marked "(Run 2)".

## A — acceptance steps

| Step | Result | Evidence |
| --- | --- | --- |
| A1 Open the sample case (Run 1). Professional Jobs resumed "Investigator sample case" (8 documents in scope), and Cases ▸ Open opened the case file. Run 2 opened the same case Overview again, with its content on screen | PASS | 2026-11-02c: 02-start-jobs.png, C3-a.png, B-case.png; 2026-11-02d: R3-04-case-overview.png |
| A2a "Who signed the master supply agreement?" (Run 2): verbatim quote of the signature sentence, cited to contract.md, Supported; no dump | PASS | 2026-11-02d: R1-q1-live.png, R1-q1-live-tree.txt |
| A2b "Was invoice 432 paid?" (Run 2): "No document found records invoice 432 as paid", quoting invoice-432.eml and supplier_abc_25.eml; no dump (the third quote still ends in a stray " -") | PASS | 2026-11-02d: R1-q2-live.png, R1-q2-live-tree.txt |
| A2c A rule answer says "no AI involved" (Run 2). The footer under both answers reads "Read from your documents by fixed rules — no AI involved. It can be incomplete or wrong. …", and the body says "Answered from your records — no AI involved." | PASS | 2026-11-02d: R1-q1-live-tree.txt, R1-q2-live-tree.txt, R1-q2-live.png |
| A3 Open a source from a citation, at the quoted passage (Run 1): contract.md opened with the signature sentence highlighted | PASS | 2026-11-02c: A3-source-sheet.png |
| A4 Review contradictions (Run 2). 2 conflicts, no invoice 401/432 pair, both sources named. All 4 sources open with their passage highlighted, including supplier_abc_22.eml for "Contract modified on Apr 8, 2024" (its "Date: Mon, 08 Apr 2024" line). The same source opens highlighted from the review queue | PASS | 2026-11-02d: R2-review.png, R2-open-A.png, R2-open-B.png, R2-open-C.png, R2-open-D.png, R2-queue-open-B.png |
| A5 Professional Jobs (Run 1): Source reliability run → saved result (8 rows) → exported | PASS | 2026-11-02c: A5-result.png, exports/Source reliability.md |
| A6 Help (Run 1): Replay the Tutorial (Step 1 → 2 of 10, Stop) and Help ▸ Guide. Run 2 opened Guide again, with its content on screen | PASS | 2026-11-02c: A6-tutorial.png, A6-help.png; 2026-11-02d: R3-19-guide.png |

## C — usability checks

| Check | Result | Evidence |
| --- | --- | --- |
| C1 Cases names readable, 12 rows (Run 1). Run 2: same list on screen | PASS | 2026-11-02c: C1-cases.png; 2026-11-02d: R3-03-cases.png |
| C2 Settings: Advanced collapsed, no model banner (Run 1). Run 2: Settings content on screen | PASS | 2026-11-02c: C2-settings.png; 2026-11-02d: R3-14-settings.png |
| C3a Sidebar shortcuts fixed (Run 2). On 20 screens the four shortcut rows (Professional Jobs y 302, Cases 343, Review 384, Guide 425) and the GO TO rows (Home 496 … Settings 713) sit at identical positions. No screen draws content above the window, including Cross-Doc Matrix and Reasoning Studio | PASS | 2026-11-02d: R3-sidebar-rows.txt, R3-layout-check.txt, R3-contact-sheet.png |
| C3b Layout regression (Run 2): every screen's content sits beside the sidebar. **Work Center** lays out its workflow rail from x 0, under the app sidebar: "All workflows", "Source map", the run number and the Summary button are hidden, and only fragments show. **Knowledge** puts its own kind list (5 rows) at x 0–220, entirely under the app sidebar. Both were beside the sidebar in Run 1 | FAIL | 2026-11-02d: R3-06-workcenter.png, R3-06-workcenter-tree.txt, R3-07-knowledge.png, R3-07-knowledge-tree.txt; 2026-11-02c: B17-workcenter.png |
| C4 Persona cards (9) visible, Investigator highlighted, label "PERSONA · INVESTIGATOR" (Run 1) | PASS | 2026-11-02c: C3-a.png |
| C5 Verify Receipt and Case Story render on screen (Run 1). Run 2: both on screen, and Verify Receipt verified a matrix receipt | PASS | 2026-11-02c: B26-verify-result.png, B28-story.png; 2026-11-02d: R3-15-verify.png, R3-16-casestory.png, R5-verify-result.png |

## Other defects observed

- Print preview pages are still blank on screen (Run 2: ACH and Work Center, 0 dark pixels in the page area), although the AX tree holds the text. "Save as PDF…" now works as a sheet and wrote a 2-page ACH PDF containing the text.

## Limits

- Sample archive only; the `--acceptance-case` fixture was not walked.
- Debug build, not a signed or distribution build.
- Agent-driven through Accessibility. Other apps may have shared the display.
- No protected-identity register entry was exercised.
- This is evidence by an agent, not a person's approval.
