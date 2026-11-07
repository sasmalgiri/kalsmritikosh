Result: FAIL

# Output routes through the UI — AGENT evidence

Candidate: 8212704862ce96de1adf264d8cdacb2d122abbce

Run by: AGENT (Claude), not a person. 2026-11-02, sample archive mode, Debug build from HEAD 82127048 (app code identical to the candidate), pid 3485.

- Routes are numbered as in docs/OUTPUT_ROUTES_INVENTORY.md.
- Evidence paths are relative to docs/evidence/ui-candidate-2026-11-02c/.
- Files were saved to ~/CaseBench/ui-candidate-82127048/exports. Copies and clipboard captures are in exports/, with SHA-256 digests in exports-sha256.txt.
- Nothing was sent off the Mac.
- Print follows the owner's decision of 2026-11-02 (no print entitlement): each Print opens a print preview. No print dialog was looked for.

| # | Route | Result | What was checked | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Case file › Case file report… | PASS | Markdown with the DRAFT banner. The case log records sha256 41f1aa75748be4d5, which equals the file. Note: "Named in the case documents" gives quotes without file names | exports/Case file - Investigator sample case.md |
| 2 | Case file › Case log… | PASS | CSV, 22 actions with who and when; earlier exports listed with their digests | exports/Case log - Investigator sample case.csv |
| 3 | Case file › Exhibit list… | PASS | CSV header only (no exhibits registered) | exports/Exhibits - Investigator sample case.csv |
| 4 | Case file › Custody report… | PASS | 8 sources, each with file name and SHA-256 | exports/Custody - Investigator sample case.md |
| 5 | Case file › Personal data export… | PASS | John Carter: role Witness, interview Planned. Screen notice digest c18f60e20b86 equals the file | exports/Personal data - John Carter.md, B06-people-tree.txt |
| 6 | People › Export statement for signature… | PASS | Statement with signature lines ("no statement recorded"). Notice digest 8b3c7315db9f equals the file | exports/Statement - John Carter.md, B-case-evidence-tree.txt |
| 7 | Evidence › Save notice to send… | PASS | Custodian typed; plain-text notice to John Carter from the investigator | exports/Preservation notice - John Carter.txt, B07-notice-tree.txt |
| 8 | Evidence › Export redaction log… | PASS (defect) | CSV row "Signatures · Personal phone number"; notice digest c1e8bf47de74 equals the file. Defect: the Document column is a version UUID, not the file name | exports/Redactions - Investigator sample case.csv |
| 9 | ACH › Export Markdown | PASS | Matrix, scores, assessment; disclaimer now names Investigations Made Easy | exports/ach-why-is-the-injury-date-inconsistent?.md |
| 10 | ACH › Copy report | PASS | Clipboard identical to route 9 except the "Generated" time; notice "Copied. Released — NOT yet recorded: … no case to record it in" | exports/B10-ach-copy-report.txt, B10-tree.txt |
| 11 | ACH › Print | PASS (preview) | Print preview window opened with 2 pages, Close and Save as PDF…. Defect: the pages draw blank on screen. "Save as PDF…" pressed once: the Save panel appeared, then closed by itself before OK, and no PDF was written. Close recorded nothing | B11-print-windows.txt, B11-print-tree.txt, B11-print-preview.png, B11-after-close-tree.txt |
| 12 | Job result › Export… | PASS | Source reliability: state, limitations, 8 rows each with file name, version and quoted passage | exports/Source reliability.md |
| 13 | Persona studio (Privilege Log) › Copy / Export / Print | PASS (preview) | Copy and Export hold the same log (only the seal time differs). Export saves a .txt file holding Markdown. Print / Save as PDF opened a preview (2 pages, blank on screen), then Close | exports/privilege-log-evidence-review.txt, exports/B13-privlog-copy.txt, B13-print-preview-region.png |
| 14 | Handoff & Review › Export findings | NOT REACHABLE | No export control is shown for the Investigator sample case: findings not approved, 11 rules await attestation | B14-handoff3-tree.txt |
| 15 | Handoff › Copy sealed conformance certificate; Export verification bundle | PASS (certificate) | Certificate copied: constitution SHA-256, per-rule status, no document text. No verification-bundle export control was shown | exports/B15-conformance-certificate.txt |
| 16 | DataLab exports | NOT REACHABLE | "NO DATASETS YET". The "Build from evidence" menu opened once, then did not open again under AX, so no dataset was built | B16-datalab-tree.txt, B16-datalab2.png |
| 17 | Work Center › Copy Report / Print | PASS (preview) | Plain-text report. Print preview opened (1 page, blank on screen). The single documented Save as PDF… wrote WF-2026-0001.pdf: 1 page, text identical to the copy | exports/B17-workcenter-copy-report.txt, exports/WF-2026-0001.pdf, B17-print-preview.png, B17-saved-pdf-render.png |
| 18 | Studio outputs › Export… | NOT REACHABLE | No Studio outputs sheet in the Tools menu (only "Bring documents in") or the Jump palette | — |
| 19 | Export Center › Export table | NOT REACHABLE | Not in the Tools menu or the Jump palette | — |
| 20 / 37 | Ask › Copy answer | PASS | Plain text, no Markdown marks, "Source: contract.md" / "Sources: • invoice-432.eml • supplier_abc_25.eml" | exports/B37-ask-copy-q1.txt, exports/B37-ask-copy-q2.txt |
| 21 | Convert › Copy / Save | NOT REACHABLE | Needs a file chosen from outside the app; no file was chosen in this pass | B21-convert-tree.txt |
| 22 | Query / Highlights / Redaction exporters | PASS (Query) | Query: Events ▸ Run ▸ Export CSV wrote 16 events (Date, Title, Kind, Status; no source column). Highlights: not in the Tools menu or Jump palette. Redaction: needs a PDF chosen from outside the app; not run | exports/events-query.csv, B22-redaction-tree.txt |
| 23 | Compliance Board › Copy board as hardcopy | PASS | Markdown table of SOPs, no document text | exports/B23-compliance-board-copy.txt |
| 24 | Diagnostics › Compose e-mail | NOT REACHABLE | Sends data off the Mac; excluded by the run's rules | — |
| 25 | Transcripts › Export quotes… | NOT REACHABLE | "No audio or video sources" in the sample | B25-transcripts-tree.txt |
| 26 | Ask › Export verifiable receipt… | PASS | 4 entries: the answer plus 3 passages, each naming its file with sha256. Verify Receipt: "Integrity check passed — hash chain is internally consistent", seal 7ce9ff79… equals the file | exports/Verifiable receipt — Was invoice 432 paid?.json, B26-verify-result.png |
| 27 | Issue chronology › Export | NOT REACHABLE | Chronology report sheet not in the Tools menu or the Jump palette | — |
| 28 | Case Story › Save | PASS | "Project Delta" story exported; sections cite file names | exports/case-story-Project Delta.md, B28-story.png |
| 29 | Case slice › Save | NOT REACHABLE | Case slices sheet not in the Tools menu or the Jump palette | — |
| 30 | Cross-Doc Matrix › Export Markdown | FAIL | Export works through AX (4 rows, file names, verbatim passages; Date column is the ingest date). The screen draws its search field and content above the window (hosting view at y −349), so a person cannot reach it | exports/matrix-invoice 432.md, B30-matrix.png, B30-matrix-tree.txt |
| 31 | Cross-Doc Matrix › Export receipt | FAIL | Receipt with 4 entries, each naming its file; Verify Receipt passed (seal f6a9c73c…). Same off-screen screen as route 30 | exports/receipt-invoice 432.json, B31-verify-result-tree.txt |
| 32 | Knowledge › Export dossier… | NOT REACHABLE | Only in an entity row's context menu; AXShowMenu on the row, cell and name opened no menu, and right-click was not used | B32-knowledge-tree.txt |
| 33 | Notebook › Save investigation report | NOT REACHABLE | "No investigations yet"; Investigate was not run | B33-notebook-tree.txt |
| 34 | Compare Documents › Export comparison brief | PASS | amendment-7.md vs invoice-432.eml: fields only one source states, sources named | exports/comparison-brief.md |
| 35 | Workspaces › Compose & Export… | PASS (defects) | 74 bullets, 74 unique (dedupe fixed); facts cite file names. Defects: the Sources section has 96 lines for 8 distinct files; "Delivery was delayed because of delivery delayed." | exports/General-generalSummary.md |
| 36 | Workspaces › Verifiable receipt… | PASS | 74 entries, 71 naming a file (the other 3 are missing-evidence notes). Verify Receipt passed, seal 3daed30f… | exports/receipt-General-generalSummary.json, B36-verify-result.png |
| 38 | Ask › Export proof bundle… | NOT REACHABLE | The answer menu offers only Save answer as text…, Export verifiable receipt…, Send to DEVONthink | B26-context-menu.png |
| 39 | Ask › Save answer as text… | PASS | UTF-8 .txt: question, answer, sources by file name | exports/Answer — Who signed the master supply agreement?.txt, exports/Answer — Was invoice 432 paid?.txt |
| 40 | Ask › Send to DEVONthink | PASS | DEVONthink is not installed. Finder opened the folder "kalsmritikosh-devonthink" showing "Was invoice 432 paid?.md". Its content was not read: it is in the app's sandbox temp folder | B40-finder.png, B40-finder-windows.txt |
| 41 | Ask › AI review sheet › Copy | NOT REACHABLE | Needs Online AI, which was never turned on | — |

## Notes

- The print preview's pages draw blank on screen on all three routes tried (11, 13, 17). The saved PDF has the text.
- No protected-identity register entry was exercised, so no scrub or refusal was observed.

## Limits

- Sample archive only, Debug build, agent-driven through Accessibility.
- The display was shared with other agent-driven apps (focus taken at times; one clipboard read was redone).
- This is evidence by an agent, not a person's approval.
