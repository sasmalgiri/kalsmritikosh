# AGENT USABILITY EVALUATION — five AI agent participants, not human users (owner direction 2026-11-01)

This is not a human study. One AI agent played five first-time users, one after another. Each participant worked only from the app's own words and its Help. The agent did not use its knowledge of the code to find anything. The report records only what was observed. The SUS-style scores are the agent's estimates.

## Build, commit, processes

- **Checkout:** `investigations-next` at `234c2c9a`. This is the board-doc commit on top of `f0bb8bfd`; no source changes between the two.
- **App:** Debug build `…/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app`, binary dated 2 Nov 03:26.
- **Launch:** every time with `open -n -a … --args -kalsmritikosh.sampleArchiveMode YES`. lsof confirmed `DemoArchive/sample-knowledge.sqlite`. "Back to my archive" was never pressed.
- **Process IDs, one fresh launch per participant:**
  - P1: 51486
  - P2: 52198
  - P3: 52420
  - P4: 52791
  - P5: 52913
- **Quitting:** always with `kill -TERM <pid>`, never ⌘Q.
- **Before the run:** a Debug instance (pid 30817) was already running. It had no window and no ledger open, only `.tipkit`. It was ended with SIGTERM (`00-preexisting-instance.txt`). The ho16 bench host (pid 51430, `~/CaseBench/dd-ho16`) was left untouched.
- **Online mode:** never turned on. Nothing was sent off the Mac. One save panel was opened and cancelled, so no file was written.
- **Crashes:** none during the run. The newest Kalsmritikosh `.ips` in `~/Library/Logs/DiagnosticReports` is from 00:17, before the run.

## Method

- **Driver:** `build/axdrive/axdrive`. It does AX press and tree dumps, sends CGEvent clicks, and types with `typek`. Before any keystroke it ran `activate <pid>` and checked `front`.
- **Evidence:** screenshots with `screencapture -R` of the app window. Everything is in `docs/evidence/ui-usability-2026-11-02/`, named by participant (`P<n>-NN-*`).
- **Steps:** one step is one deliberate user action (click, typed entry, menu choice, scroll).
- **Time:** wall clock, from the participant's first action to the end.
- **Harness stalls in P1:** while P1 was running, the tool host's pre-command hook timed out repeatedly. That added about 38 minutes of dead time between steps, so P1's wall clock does not measure the app.
- **Clipboard:** reading the clipboard from the shell was blocked. To check what Copy produced, the copied text was pasted into the app's own question field, read through AX, then cleared.
- **Limits:** the driver has no right-click or drag. The case-name column could not be widened by dragging, and the context menu had to be opened through AXShowMenu.

## Results

| Participant | Task | Outcome | Steps | Time | Main issues |
| --- | --- | --- | --- | --- | --- |
| P1 HR investigator | Who signed the master supply agreement; save/copy with its source | **Completed with difficulty** | 11 | 43 m 34 s wall clock (about 5–6 min of real interaction; the rest was harness stalls) | Answer is a pasted passage, not a sentence. "Copy" leaves out the source file name and keeps `**` markdown. The only way to save is a hidden right-click "Export verifiable receipt…", which saves `.json`. Status reads "Partially supported" even though the signers are quoted |
| P2 Lawyer | Open the sample case, find a contradiction, see both sources | **Failed** | 12 | 2 m 32 s | Case names collapse to "…". The case has no contradictions view. Review and Insights show each claim's source as plain text "source on file", with no name and nothing to click. Asking the question returned a generic "History of the user's archive" dump. The working path (Findings ▸ Contradictions ▸ "2 sources") was not reachable from the sidebar or from Jump-to "contradiction"; it was only seen later, in P5's tutorial |
| P3 Journalist | Learn from Help how to keep a confidential source's name out of exports, then find where to set it | **Failed** | 20 | 12 m 52 s | Help says protected identities are "kept out" and "scrubbed", but never says how a person becomes protected. "hide name" finds nothing; Jump-to "confidential" finds nothing relevant. The only control found is a free-text "Protection" box in Work Center ▸ Source map step 3, and nothing says it affects exports. Professional Jobs disappeared from the sidebar, the persona reset, and the Work Center layout is clipped |
| P4 Individual (privacy) | Does anything leave my Mac; how to back up and erase | **Completed with difficulty** (backup and erase found); **misled on privacy** | 5 | 0 m 55 s | Settings says the app "has no network access" and is "built without the network permission". The build's signature carries `com.apple.security.network.client`, and the same Settings screen offers Online mode with your own key. Settings also opens with red developer alarms |
| P5 Researcher | Replay the tutorial and finish at least five steps | **Completed** (steps 1–5, step 6 also done) | 16 | 3 m 20 s | Tutorial works and the window grows correctly. The step 4 answers are passage dumps that don't match "What you should see". In step 6 the sources shown differ from the ones the tutorial names. Naming differs between the tutorial and the app (Sources vs Files) |

## Findings by severity

### BLOCKER

**B1. Settings gives a false privacy statement (P4).**
- **What the user sees:**
  - Settings ▸ Privacy: "This app has no network access; there is nothing to toggle." and "The app is built without the network permission, so no document, question, or answer can leave your computer."
  - Settings ▸ Modules ▸ Connection: "This app has no network permission (checked from its signature)."
- **Why it is false:**
  - The same Settings screen offers "Online (your own key)", "Answers with your own cloud AI key", "Let your cloud AI read the documents about a person (Online)" and "Mask personal details before sending".
  - The app's own Help says Online AI is optional.
  - The build's signature carries `com.apple.security.network.client`.
- **Impact:** a privacy-anxious user is told something untrue about whether data can leave the Mac.
- **Evidence:** `P4-03-privacy-tree.txt`, `P4-03-privacy.png`, `P4-05-modules-tree.txt`, `P4-04-build-entitlements.txt`.

**B2. Nothing a first-time user can find explains how to protect a confidential source (P3).**
- **Help:**
  - Searching "confidential source" returns only "Recipe — Journalist". It matched because of the phrase "Expose confidential source", buried in an unpunctuated "Professional limits" list.
  - Searching "protect" returns topics saying exports "keep protected identities out" and "scrub" them, but none says how an identity becomes protected.
  - Searching "hide name" returns "No help topic matches".
  - Jump-to "confidential" finds only Compare Documents and Dispute File.
- **The only control found:** Work Center ▸ Source map ▸ step 3 "Note source protection", a free-text "Protection" box captioned "Confidential-source handling — never expose a protected source." Its "Open Review" button leads to the contradictions Review screen, which is unrelated.
- **Impact:** nothing tells the journalist whether typing there keeps the name out of exports. They could wrongly believe the source is protected.
- **Evidence:** `P3-03-help-search-tree.txt`, `P3-04-help-search-*.txt`, `P3-12-jump-confidential.txt`, `P3-10-step3-tree.txt`, `P3-10-step3.png`.

**B3. A contradiction's two sources can't be opened from the screens a lawyer is sent to (P2).**
- **Review and Insights:** Jump-to "contradiction" offers Review ("Resolve contradictions…") and Insights. Both list "Conflicting dates for 'Contract modified' / 'Invoice issued' / 'Delivery delayed'" with Claim A and Claim B. Each claim's source is plain text "source on file": no file name, no action, and clicking does nothing.
- **Review queue:** it asks the user to pick "3 Source A preferred" or "4 Source B preferred" without ever naming either source.
- **Inside the case:** the "Lawyer sample matter" (Overview, Evidence, Chronology) has no contradictions view.
- **Asking instead:** asking "When was the delivery delayed? Do the documents disagree?" returned "History of the user's archive", with raw `##` headings and "(No reasoning provider available — chapters ship without LLM prose)". The conflict line read "Multiple emailReceived events for the same subject".
- **The path that works:** Findings ▸ Contradictions ▸ "2 sources" opens supplier_abc_22.eml and invoice-432.eml. The agent saw it only in P5's tutorial step 6. Findings is not in the sidebar and does not come up for "contradiction".
- **Evidence:** `P2-04-evidence-tree.txt`, `P2-05-chronology-tree.txt`, `P2-06-jump-contradiction.txt`, `P2-07-review*.{txt,png}`, `P2-08-*`, `P2-09-review-queue.png`, `P2-10-insights-tree.txt`, `P2-11-ask-conflict*.{txt,png}`; the working path: `P5-15-step6-findings.txt`, `P5-16-two-sources.txt`.

### MAJOR

**M1. Case names are unreadable.** The Cases table's first column is about 15 pt wide, so every name shows as "…". All 11 sample cases look identical; names exist only in AX ("Open Lawyer sample matter", …). Evidence: `P2-02-cases.png`, `P2-02-cases-tree.txt`.

**M2. Copying and saving an answer loses the source, and saving is hidden.**
- **Copy:** the copied text keeps `**Effective Date:**` markdown and ends "Confidence: moderate · 1 source", without the file name `contract.md`.
- **Saving:** the Outputs ("Answer Journal") entry has no save or export control. The only save route is the right-click menu "Export verifiable receipt…". It appeared detached at the toolbar and swallowed the typed text.
- **The save panel:** it offers `receipt-Who signed the master supply agreement?.json`, a technical format for an HR user. It defaults to an old folder, `acceptance-exports-2026-10-30e`.
- **Evidence:** `P1-06-pasted-copy-full.txt`, `P1-11-output-expanded.*`, `P1-12-jump-export.png`, `P1-13-state.png`, `P1-14-*`, `P1-15-save-panel.txt`.

**M3. Answers read as raw passage dumps, and the badges contradict them.**
- "Who signed…" returns the contract and amendment text, including "The source says: Amendmentno7: …", and is rated "Partially supported", though it names both signers.
- The Amendment 7 answer says "Note: your sources disagree on some of these points" while its strip says "Conflicts: 0".
- "Was invoice 432 paid?" is a dump of three emails, badged "Supported", with no plain "no payment is recorded".
- Evidence: `P1-04-answer.png`, `P1-05-answer-tree.txt`, `P5-10-step4-answer1.png`, `P5-11-step4-answer2.png`, `P2-11-ask-conflict.png`.

**M4. Settings opens with developer alarms in front of every user.**
- **Shown at the top:** a red "Self-check found issues 13/15 checks" and a red "Model won't run well — No reasoning model available — enable Local GGUF runtime".
- **Advanced is expanded by default and shows:** "RELEASE READY: NO", "Check if ready to ship", "Wipe & re-ingest everything", "Recover legacy .doc/.xls" and "schema head v168".
- **Contradiction:** "Apple AI writes the final answer" is ticked right under "no AI model is used".
- Evidence: `P4-02-settings-tree.txt`, `P4-06-yourdata.png`.

**M5. The sidebar changes under the user.** The top sidebar group reorders between launches and screens. At P1's start it read Guide / Cases / Knowledge / Professional Jobs; at P3's start, Guide / Insights / Review / Cases. Professional Jobs was gone, so the sidebar press failed and P3 had to go through Home ▸ Resume a case. Leaving Professional Jobs and coming back reset the persona from Journalist, and the Source map job was gone. Evidence: `P1-02-start-tree.txt`, `P3-02-help-tree.txt`, `P3-05-jobs-tree.txt`, `P3-11-connections-tree.txt`.

### MINOR

1. **Work Center layout is clipped (P3).** The sidebar is cut off on the left ("ERSONA · RESEARCHER", "O TO") and the "How this job works" panel is cut off on the right (close ✕ partly hidden). Evidence: `P3-08-sourcemap.png`.
2. **The source sheet highlights the wrong lines.** It highlights the header block, not the "Signatures" sentence the answer quoted. Evidence: `P1-07-source-sheet.png`.
3. **Names don't match between Help, tutorial and app:**
   - Sidebar "Files" vs screen title "Sources" vs Help/tutorial "Open Sources … Add Folder…".
   - Help's "Complete backup" vs buttons "Back up now…" / "Back up everything…".
   - Sidebar "Outputs" vs window title "Answers" vs heading "Answer Journal".
   - Help's step 2 "Open Professional Jobs" while that item can be missing from the sidebar.
   - Evidence: `P3-02-help-tree.txt`, `P4-06-yourdata-tree.txt`, `P1-13-after-export-windows.txt`.
4. **Sample state carries over between launches.** Ask history and the Answer Journal keep earlier sessions' questions, and every new answer is listed twice in the journal (two 3:48 AM entries). Evidence: `P1-02-start-tree.txt`, `P1-10-outputs-tree.txt`.
5. **Tutorial content doesn't match what is shown:**
   - Step 6 names the 8 April and 18 April emails plus the amendment, but "2 sources" shows supplier_abc_22.eml and invoice-432.eml.
   - The step 4 answers don't match "What you should see".
   - The tutorial starts on top of whatever screen is open (Settings).
   - Evidence: `P5-14-step6.txt`, `P5-16-two-sources.txt`, `P5-02-tutorial-step1.txt`.
6. **Accessibility gaps:**
   - Many text fields have no label (case Overview, Evidence, Chronology).
   - Twelve unlabelled `AXButton [730,478 10x22]` appear on every screen.
   - Evidence: `P2-03-lawyer-case-tree.txt`, `P1-02-start-tree.txt`.
7. **Jargon in user-facing text:** "fresh 0%", "experts", "KO", "T3", "HISTORY Phase A", "Move A", "MoE", "knowledge.sqlite". Help's "Professional limits" is one unpunctuated run of phrases. Evidence: `P4-03-privacy-tree.txt`, `P4-05-modules-tree.txt`, `P3-03-help-search-tree.txt`.
8. **Persona cards are hidden off-screen.** In Professional Jobs the cards scroll sideways; Journalist, Lawyer, Researcher and SIU start out of view. Evidence: `P3-06-resume-tree.txt`.
9. **The persona label always reads "RESEARCHER"**, whatever the user picks. The sample's conflict-of-interest button shows the Mac owner's real name. Evidence: `P2-03-lawyer-case-tree.txt`.
10. **An unexplained dialog.** After typing in Work Center, an `AXDialog` holding only a "Siri Waveform Orb" button appeared on the app's process; its origin is unknown. Evidence: `P3-08-sourcemap-tree.txt`.

## System Usability Scale–style score (agent's estimate, not a measured SUS)

| Participant | Est. score | Reasoning |
| --- | --- | --- |
| P1 HR investigator | **55** | The answer and its source came quickly, and the citation chip opens the document. But the answer is a wall of passage text, the copy leaves out the source name, the save is hidden in a context menu, and the format is JSON. A non-technical user would not feel confident |
| P2 Lawyer | **35** | The case was hard to identify. The contradictions were visible but their sources could not be opened from where the app pointed, the decision buttons ask for a source preference without naming the sources, and the Ask fallback produced developer text |
| P3 Journalist | **30** | Help never answered the question. The only control found is an unlabelled free-text box with no stated effect on exports, the navigation shifted, and the layout was clipped. The task's safety goal was not achieved |
| P4 Individual (privacy) | **45** | Backup and erase were easy to find and clearly worded. But the privacy answer is wrong, the same page contradicts it, and red developer alarms at the top would alarm exactly this user |
| P5 Researcher | **70** | The tutorial is clear, steps advance, "Show me" works and the column fits the window. Points were lost because answers didn't match "What you should see" and the names differ |

Mean of the agent estimates: 47 (below the conventional 68 "average" line).

## Not observed / limits

- No real right-click or drag was available through the driver.
- The case-name column may be widenable by dragging; that was not tried.
- Online mode was not exercised, by instruction.
- P1's wall-clock time includes about 38 minutes of tool-harness stalls that had nothing to do with the app.

## Fixes after the evaluation (second commit, 2026-11-02)

| finding | fix | verified by |
|---|---|---|
| M1 case names "…" | Cases table: the Case column has a minimum width of 200 pt (ideal 300); Owner and Next due shrink first | build; to re-check in the next UI run |
| M2 copy loses the source | "Copy this answer" puts plain text (no `**`/`#` marks) on the clipboard, ending "Source: contract.md" / "Sources: • …" by file name, through the same protected-export gate | UsabilityFixesTests.copiedAnswer |
| M3 "sources disagree" beside "Conflicts: 0" | the low-agreement note no longer claims a disagreement: "the readings of these sources only partly agree — check the cited passages before relying on this" (recorded contradictions still show as conflicts) | build; Citation/Slot/Patent verifier suites green |
| M4 rest | Advanced is collapsed each time Settings opens (no longer remembered); the red "Model won't run well" banner is not shown when AI is off (no model is needed); the AI-composition toggles ("Apple AI writes the final answer", council, self-critique) are hidden when no AI model is used | build |
| M5 sidebar reorders; persona reset | the recently-opened rows keep the screens' fixed order; Professional Jobs remembers the profession last picked there and reopens the matter that was open | PersonaJobsModelTests green (restore is off in the test host) |

M2 (save): a Save button beside Copy and "Save answer as text…" in the answer's menu write the question, the plain answer and its sources to a .txt (protected-export gate); the receipt is named "Verifiable receipt — …json" and its panel says what it is for. The old default folder was the evaluator's own last-used folder (macOS remembers it), not an app default.

Still open: M3 passage-dump answers to "who signed" / "was invoice 432 paid" — the answer composer for document questions, not the proceeding answerer; the minor items 1–10.
