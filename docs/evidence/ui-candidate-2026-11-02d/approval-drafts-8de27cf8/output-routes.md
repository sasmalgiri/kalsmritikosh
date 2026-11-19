Result: FAIL

# Output routes through the UI — AGENT evidence

Candidate: 8de27cf8b54896c29f3f706ab0ea67b7a66b67e2

Run by: AGENT (Claude), not a person. Sample archive mode, Debug build.

This record combines two agent runs.

- **Run 2 (targeted re-check, on the candidate):** 2026-11-02, Debug build from HEAD 8de27cf8 (`git diff 8de27cf8 HEAD -- Kalsmritikosh` empty), pid 13734.
  - Evidence: docs/evidence/ui-candidate-2026-11-02d/.
  - Files saved to ~/CaseBench/ui-candidate-8de27cf8/exports. Copies and SHA-256 digests are in the evidence folder's exports/ and exports-sha256.txt.
- **Run 1 (full walkthrough, on 82127048):** 2026-11-02, pid 3485.
  - Evidence: docs/evidence/ui-candidate-2026-11-02c/.
  - Files saved to ~/CaseBench/ui-candidate-82127048/exports. Copies and digests are in the evidence folder's exports/ and exports-sha256.txt.
- **Code between the two runs:** the app code changed only in commit 8de27cf8 (UI/RootView.swift, UI/AppPrinting.swift, UI/CitationChips.swift, UI/QualityStrip.swift). The changes were:
  1. every screen pinned to the real detail viewport;
  2. print-preview pages drawn black on white, and "Save as PDF…" opened as a sheet on the preview window;
  3. the "no AI involved" answer footer;
  4. Review sources opening at the matching line.
- **Which run each result comes from:** Run 2 re-checked routes 11, 17, 30 and 31. Every other result is carried over from Run 1 ("Run 1" in the table).
- Routes are numbered as in docs/OUTPUT_ROUTES_INVENTORY.md.
- **Print:** by the owner's decision of 2026-11-02 (no print entitlement), each Print button opens a print preview with page images, "Save as PDF…" and "Close". A print route passes only if the preview shows its pages with visible text. No system print dialog was looked for.
- Nothing was sent off the Mac. Online mode was never turned on.

| # | Route | Result | What was checked | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Case file › Case file report… | PASS (Run 1) | Markdown with the DRAFT banner. The case log digest equals the file | 2026-11-02c: exports/Case file - Investigator sample case.md |
| 2 | Case file › Case log… | PASS (Run 1) | CSV, 22 actions with who and when | 2026-11-02c: exports/Case log - Investigator sample case.csv |
| 3 | Case file › Exhibit list… | PASS (Run 1) | CSV header only (no exhibits registered) | 2026-11-02c: exports/Exhibits - Investigator sample case.csv |
| 4 | Case file › Custody report… | PASS (Run 1) | 8 sources, each with file name and SHA-256 | 2026-11-02c: exports/Custody - Investigator sample case.md |
| 5 | Case file › Personal data export… | PASS (Run 1) | John Carter, role Witness. The notice digest equals the file | 2026-11-02c: exports/Personal data - John Carter.md |
| 6 | People › Export statement for signature… | PASS (Run 1) | Statement with signature lines. The notice digest equals the file | 2026-11-02c: exports/Statement - John Carter.md |
| 7 | Evidence › Save notice to send… | PASS (Run 1) | Plain-text preservation notice to John Carter | 2026-11-02c: exports/Preservation notice - John Carter.txt |
| 8 | Evidence › Export redaction log… | PASS (Run 1, defect) | CSV row written; the Document column is a version UUID, not the file name | 2026-11-02c: exports/Redactions - Investigator sample case.csv |
| 9 | ACH › Export Markdown | PASS (Run 1) | Matrix, scores, assessment; the disclaimer names Investigations Made Easy | 2026-11-02c: exports/ach-why-is-the-injury-date-inconsistent?.md |
| 10 | ACH › Copy report | PASS (Run 1) | Clipboard identical to route 9 except the time | 2026-11-02c: exports/B10-ach-copy-report.txt |
| 11 | ACH › Print (print preview) | FAIL (Run 2) | Print opened "Print preview — ACH — …" with 2 pages, Close and Save as PDF…. The pages draw blank on screen: 0 dark pixels in the page area in window, screen-region and scrolled captures, although the AX tree holds the text. "Save as PDF…" opened a sheet on the preview and saved a 2-page PDF (18,717 bytes) holding the full report text, black on white when rendered. The notice says "Saved as PDF from the print preview. Released — NOT yet recorded …" | 2026-11-02d: R4-ach-preview.png, R4-ach-preview-region.png, R4-ach-preview-scrolled.png, exports/ACH — Why is the injury date inconsistent?.pdf, R4-ach-pdf-text.txt, R4-ach-pdf-render.png |
| 12 | Job result › Export… | PASS (Run 1) | Source reliability, 8 rows with file name, version and quoted passage | 2026-11-02c: exports/Source reliability.md |
| 13 | Persona studio (Privilege Log) › Copy / Export / Print | FAIL (Run 1; print part) | Copy and Export hold the same log; Export saves a .txt holding Markdown. Print opened a preview whose 2 pages drew blank on screen. Not re-run in Run 2, where the same blank preview was seen on routes 11 and 17 | 2026-11-02c: exports/privilege-log-evidence-review.txt, exports/B13-privlog-copy.txt, B13-print-preview-region.png |
| 14 | Handoff & Review › Export findings | NOT REACHABLE (Run 1) | No export control for the sample case: findings not approved, 11 rules await attestation | 2026-11-02c: B14-handoff3-tree.txt |
| 15 | Handoff › Copy sealed conformance certificate; Export verification bundle | PASS (Run 1, certificate) | Certificate copied (constitution SHA-256, per-rule status). No verification-bundle control was shown | 2026-11-02c: exports/B15-conformance-certificate.txt |
| 16 | DataLab exports | NOT REACHABLE (Run 1) | "NO DATASETS YET"; no dataset was built | 2026-11-02c: B16-datalab-tree.txt |
| 17 | Work Center › Copy Report / Print (print preview) | FAIL (Run 2) | Print opened "Print preview — WF-2026-0001" with 1 page, drawn blank on screen (0 dark pixels); Close closed it. The Work Center rail is now laid out under the app sidebar: Summary and most of Copy Report sit at x 14–204, behind the 220-pt sidebar. In Run 1 the copy was plain text and the saved PDF held the full text | 2026-11-02d: R4-wc-preview.png, R4-wc-preview-region.png, R3-06-workcenter.png, R4-wc-tree.txt; 2026-11-02c: exports/B17-workcenter-copy-report.txt, exports/WF-2026-0001.pdf |
| 18 | Studio outputs › Export… | NOT REACHABLE (Run 1) | Not in the Tools menu or the Jump palette | — |
| 19 | Export Center › Export table | NOT REACHABLE (Run 1) | Not in the Tools menu or the Jump palette | — |
| 20 / 37 | Ask › Copy answer | PASS (Run 1) | Plain text with "Source: contract.md" / "Sources: • invoice-432.eml • supplier_abc_25.eml" | 2026-11-02c: exports/B37-ask-copy-q1.txt, exports/B37-ask-copy-q2.txt |
| 21 | Convert › Copy / Save | NOT REACHABLE (Run 1) | Needs a file chosen from outside the app | 2026-11-02c: B21-convert-tree.txt |
| 22 | Query / Highlights / Redaction exporters | PASS (Run 1, Query) | Query Events CSV, 16 events (no source column). Highlights not found; Redaction needs a PDF from outside | 2026-11-02c: exports/events-query.csv |
| 23 | Compliance Board › Copy board as hardcopy | PASS (Run 1) | Markdown table of SOPs | 2026-11-02c: exports/B23-compliance-board-copy.txt |
| 24 | Diagnostics › Compose e-mail | NOT REACHABLE (Run 1) | Sends data off the Mac; excluded by the run's rules | — |
| 25 | Transcripts › Export quotes… | NOT REACHABLE (Run 1) | No audio or video sources in the sample | 2026-11-02c: B25-transcripts-tree.txt |
| 26 | Ask › Export verifiable receipt… | PASS (Run 1) | 4 entries naming files; Verify Receipt passed (seal 7ce9ff79…) | 2026-11-02c: exports/Verifiable receipt — Was invoice 432 paid?.json, B26-verify-result.png |
| 27 | Issue chronology › Export | NOT REACHABLE (Run 1) | Not in the Tools menu or the Jump palette | — |
| 28 | Case Story › Save | PASS (Run 1) | "Project Delta" story exported; sections cite file names | 2026-11-02c: exports/case-story-Project Delta.md |
| 29 | Case slice › Save | NOT REACHABLE (Run 1) | Not in the Tools menu or the Jump palette | — |
| 30 | Cross-Doc Matrix › Export › Markdown table | PASS (Run 2) | The screen is on screen (title y 188, search field y 248). "invoice 432" returned 4 rows. The saved Markdown lists invoice-432.eml, supplier_abc_25.eml, invoice-401.eml and contract.md with verbatim passages (Date column = ingest date 2026-10-30) | 2026-11-02d: R5-matrix.png, R5-export-menu.png, exports/matrix-invoice 432.md |
| 31 | Cross-Doc Matrix › Export › Verifiable receipt (.json) | PASS (Run 2) | 4 entries, each naming its file with sha256. Verify Receipt: "Integrity check passed — hash chain is internally consistent", 4 claim(s), seal f6a9c73c… | 2026-11-02d: exports/receipt-invoice 432.json, R5-verify-result.png, R5-verify-result-tree.txt |
| 32 | Knowledge › Export dossier… | NOT REACHABLE (Run 1) | Only in an entity row's context menu; AXShowMenu opened no menu and right-click was not used. In Run 2 the Knowledge kind list is drawn under the app sidebar | 2026-11-02c: B32-knowledge-tree.txt; 2026-11-02d: R3-07-knowledge.png |
| 33 | Notebook › Save investigation report | NOT REACHABLE (Run 1) | "No investigations yet" | 2026-11-02c: B33-notebook-tree.txt |
| 34 | Compare Documents › Export comparison brief | PASS (Run 1) | amendment-7.md vs invoice-432.eml, sources named | 2026-11-02c: exports/comparison-brief.md |
| 35 | Workspaces › Compose & Export… | PASS (Run 1, defects) | 74 unique bullets citing file names. Defects: Sources section has 96 lines for 8 files; "Delivery was delayed because of delivery delayed." | 2026-11-02c: exports/General-generalSummary.md |
| 36 | Workspaces › Verifiable receipt… | PASS (Run 1) | 74 entries; Verify Receipt passed (seal 3daed30f…) | 2026-11-02c: exports/receipt-General-generalSummary.json, B36-verify-result.png |
| 38 | Ask › Export proof bundle… | NOT REACHABLE (Run 1) | The answer menu offers only Save answer as text…, Export verifiable receipt…, Send to DEVONthink | 2026-11-02c: B26-context-menu.png |
| 39 | Ask › Save answer as text… | PASS (Run 1) | UTF-8 .txt with question, answer and sources by file name | 2026-11-02c: exports/Answer — Who signed the master supply agreement?.txt, exports/Answer — Was invoice 432 paid?.txt |
| 40 | Ask › Send to DEVONthink | PASS (Run 1) | DEVONthink not installed; Finder showed the note "Was invoice 432 paid?.md" in the app's folder | 2026-11-02c: B40-finder.png |
| 41 | Ask › AI review sheet › Copy | NOT REACHABLE (Run 1) | Needs Online AI, which was never turned on | — |

## Notes

- Print preview pages are blank on screen on every print route tried: 11 and 17 in Run 2, 11, 13 and 17 in Run 1. "Save as PDF…" now works as a sheet on the preview window, and the saved PDF has the text.
- Run 2 found a layout regression: Work Center and Knowledge draw part of their content under the app sidebar. See docs/evidence/ui-candidate-2026-11-02d/JOURNEYS.md, R3.
- No protected-identity register entry was exercised, so no scrub or refusal was observed.

## Limits

- Sample archive only, Debug build, agent-driven through Accessibility. Other apps may have shared the display.
- This is evidence by an agent, not a person's approval.
