# UI re-check on the candidate — AGENT run, 2026-11-03 (b): fixes for FAIL C and FAIL G, role refresh

**Result: PASS on R1–R6, with one remaining defect.** A chronology entry made by the earlier build (74804bd5) still shows "unverified — the quoted words are not in the cited document" in the Chronology tab. The case file report prints the same entry as "(verified passage)". The tab changes to "quote found in source" only after the report is exported. This is what remains of FAIL C. Entries added on this build are labelled the same way at add time, in the tab and in the report.

**AGENT run.** An agent (Claude) did this run, not a person, by the owner's direction of 2026-11-01. Only what was observed is recorded. It used the same method and record format as `../ui-candidate-2026-11-03a/JOURNEYS.md`.

- **Candidate:** e49783fd7c8af57ca9ea0d401c513dbe82821aa8 (branch investigations-next). It was HEAD at the time of the run, and `git diff e49783fd HEAD -- Kalsmritikosh` is empty.
  - The working tree had Xcode-made edits to the two InfoPlist.xcstrings files and an xcuserdata plist. These are localisation and user metadata, not app code (00-build.txt).
- **Build:** no build and no tests were run in this session. The Debug app is `~/Library/Developer/Xcode/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app`.
  - Its binary is dated 11:24:44 IST and the debug dylib 11:24:43. The commit time of e49783fd, the last commit touching Kalsmritikosh/, is 11:24:59, so the binary is 15 s older than the commit.
  - Every app source file predates the binary. The three files that commit changed are dated 11:22:53–11:23:53, the newest Swift file under Kalsmritikosh/ is 11:22:56, and no Swift file is newer than the binary.
  - So the build was made from the committed tree just before the commit was recorded. It is not a stale build (00-build.txt, "freshness check").
- **Launch:** `open -n -a "<app>" --args -kalsmritikosh.sampleArchiveMode YES` at 12:31:49 IST gave **pid 73745**.
  - `lsof` showed only `…/DemoArchive/sample-knowledge.sqlite` (+wal/shm) as a ledger, plus the TipKit store (01-launch.txt).
  - "Back to my archive" was never pressed.
- **Method:** `build/axdrive/axdrive` (AX tree dumps, AX press / focus / setvalue), window-only screenshots, and the Jump palette.
  - The helper scripts are copies of the earlier pass's scripts in `~/CaseBench/uitools49`, pointed at this evidence folder. Keys and text are sent only after `axdrive front` confirms the app is frontmost.
  - Save panels were driven by `save.sh`: ⌘⇧G, the folder path typed into the Go-to field, Return, then OK. Nothing was typed into a name field.
  - The layout checker is `layout2.py` (S-layout-check.txt).
  - No ⌘Q and no right-click.
- **Settings:** nothing was changed. The Settings › Modules section was only expanded to read the switches and then collapsed again.
- **Data written to the sample ledger:**
  - "Investigator sample case": 1 chronology entry (the invoice-401.eml Search hit), and 1 case file report export recorded in the case log.
  - "Forensic sample engagement": 2 chronology entries (the weekly-digest e-mail hit and the contract.md "Pricing" hit), and 1 case file report export recorded.
  - One Ask question ("Was invoice 432 paid?") in Ask history.
  - The watchlist was screened but not saved.
- **Exports:** saved into `~/CaseBench/ui-candidate-e49783fd/exports`. A copy is in `exports/`, digests in exports-sha256.txt. The digests match the app's notices: 65c9bd983a56… (Forensic) and fffddab08188… (Investigator).
- **Network:** Online mode stayed off. No AI send, lookup or purchase.
- **Quit:** `kill -TERM 73745` at 13:28:23. No instance remained (99-finish.txt).
- **Background job:** the ho22 accuracy job had ended on its own at 12:36:47 with "worker failure: 0". No signal was sent to it.

## Checks

| Check | Result | Observed | Evidence |
| --- | --- | --- | --- |
| R1 (was FAIL C) Chronology › "Open source" | **PASS** | **Entry "Invoice No. 432 … OVERDUE":** the button opens the source sheet "invoice-432.eml" with the whole e-mail. The Subject value "Invoice No. 432 — Project Delta milestone 2 — OVERDUE" is highlighted (grey tint), and the highlight bar is prefilled with the quote. The sheet offers "Add to case chronology…" / Done.<br>**Entry "Pricing" (contract.md):** the whole document opens, with "## Pricing" through "…40% on final acceptance." highlighted across both blocks.<br>The small "Evidence" sheet (quote + "Source KO") is gone.<br>**Digest entry (supplier_abc_25.eml, made on 74804bd5, labelled unverified):** the document opens, but only "program-office@north" in the From line is highlighted | R1-chron.png, R1-open-source-sheet.png, R1-open-source-tree.txt, R1-open-source-pricing.png, R1-open-source-digest.png |
| R2 (was FAIL C) Search hit › Add to case chronology… | **PASS** (entries added on this build) | Search "was invoice 432 paid" → "4 results" (digest, invoice-432, invoice-401, contract.md Pricing).<br>**(a) E-mail hits:** invoice-401.eml (KO 24648521) into "Investigator sample case" gave "Added … citing this passage (verified passage)." The weekly digest (supplier_abc_25.eml) into "Forensic sample engagement" gave "… (verified passage)."<br>**(b) contract.md "Pricing"** into "Forensic sample engagement" gave "… (verified passage)."<br>**Chronology tab:** all three rows read "· quote found in source".<br>**Case file reports:** the Forensic report prints both entries "(verified passage) · Not verified by a person". The Investigator report prints the invoice-401 entry the same way.<br>The digest passage could not be re-added to "Investigator sample case": "This passage is already in that case's chronology. Nothing was added; …". That is why the other sample case was used | R2-search.png, R2a-added-sheet.png, R2a-added-tree.txt, R2b-digest-dup.png, R2b-digest-added.png, R2c-pricing-added.png, R2-forensic-chron.png/-tree.txt, R2-inv-chron-scrolled-tree.txt, exports/Case file - *.md |
| R2x tab vs report for the digest entry made on 74804bd5 | **FAIL** (remaining defect) | In "Investigator sample case", the digest entry added by the previous pass read "· unverified — the quoted words are not in the cited document" in the Chronology tab at 12:4x and again at 13:20 (R1-chron, R2-inv-chron).<br>The case file report exported at 13:21 prints the same entry as "(verified passage)" (line 29).<br>Straight after the export, the tab row read "· quote found in source" (R2-inv-chron-scrolled).<br>The same quote, added freshly to the other case, is verified at once. The first 600 characters are identical (R2-digest-quote-compare.txt).<br>So an entry stored by the earlier build keeps a wrong "unverified" label in the tab until a report export re-checks it, and the tab and the report disagree until then | R1-chron-tree.txt, R2-inv-chron-tree.txt, R2-inv-exported.png, R2-inv-chron-scrolled.png/-tree.txt, exports/Case file - Investigator sample case.md l.22–29, R2-digest-quote-compare.txt |
| R3 (was FAIL G) Watchlists › "Maria Lopez", whole archive › open a result | **PASS** | Tools › Watch & alerts opens a sheet with the tabs Alerts / Watchlists.<br>Screening "Maria Lopez" with "Whole archive" gave "Whole archive · 8 documents searched · 1 of 1 term found", Name, "5 documents · 6 mentions": supplier_abc_23.eml 2×, amendment-7.md, contract.md, supplier_abc_22.eml, supplier_abc_24.eml.<br>**contract.md** opens the source sheet with the whole document. "Maria Lopez" is highlighted in the Signatures paragraph ("…Northwind) and **Maria Lopez** (VP Operations…"), and the highlight field reads "Maria Lopez".<br>**supplier_abc_22.eml** (text match only) opens with "maria.lopez" highlighted in "From: maria.lopez@supplier-abc.com" | R3-watch0.png, R3-watch1.png, R3-watch-results.png/-tree.txt, R3-open-contract.png, R3-open-email.png |
| R4 undated entry shows "No date" | **PASS** | Every chronology entry in both cases shows "No date" in the date column: the 3 from the previous pass, which showed "3 Nov 2026" on 74804bd5, and the 3 added now. The reports print "—" for the same entries | R1-chron-tree.txt, R2-forensic-chron-tree.txt, R2-inv-chron-scrolled-tree.txt |
| R5 role refresh (no Settings touched) | **PASS** | The persona header reads "PERSONA · INVESTIGATOR".<br>The Tools menu now offers "Watch & alerts", "People & connections", "Email forensics", "Writing & checking", "Documents" and "Bring documents in". On 74804bd5 it offered only "Writing & checking" and "Bring documents in".<br>Settings › Modules, read only: Watchlists 1, Who talks to whom 1, Advanced search syntax 1, Tags 1, Highlights and notes 1, Timeline and relationship views 1. On 74804bd5 the first two and the last were 0 | R5-tools-menu.png, R5-tools-menu-items.txt, R5-settings-tree.txt, R5-modules-flags.txt, R5-modules.png |
| R6a Ask "Was invoice 432 paid?" | **PASS** | "No document found records invoice 432 as paid. They say: “Invoice No. 432 — Project Delta milestone 2 — OVERDUE” / “This invoice remains unpaid as of June 14, 2024.” / “invoice 432 issued for milestone 2 and overdue as of 2024-06-29. -”".<br>Answer status Supported. "Confidence: strong · Evidence: 3 passages, 2 files · … Conflicts: 0". Chips "Source 1: invoice-432.eml", "Source 2: supplier_abc_25.eml" ("Opens at the quoted passage").<br>The footer reads "Read from your documents by fixed rules — no AI involved. It can be incomplete or wrong. Verify every fact … Not legal, financial, or professional advice." | R6-ask.png, R6-ask2.png, R6-ask2-tree.txt |
| R6b layout (Home, Ask, Cases, case file, Search, Timeline, case Chronology) | **PASS** | The sidebar rows are at the same positions on every screen: PERSONA 284 … Settings 713, Ready 797. On every screen, 0 detail elements are under the sidebar, and 0 are above the window content except Ask.<br>On Ask, 3 elements are reported above the content line. They are the earlier session's 10:17 AM question and its time stamp, scrolled out of the transcript and clipped by its scroll view. Nothing is drawn there (S4-ask.png) | S-layout-check.txt, S4-*-tree.txt, S4-*.png |

## Other observations

- **Digest entry from the earlier build, Open source.** The document opens, but the highlight covers only "program-office@north" in the From line, not the quoted passage. This is the same entry that the tab labels unverified (R2x).
- **Ask history persists.** The two 10:17 AM questions from the previous pass are still in the Ask transcript of the sample archive.
- **Internal ids are still shown.** Search hits still name their document "KO 24648521 · chunk #0" rather than the file name.
- **Default case in the add sheet.** The "Add to case chronology" sheet defaults its Case menu to the first "Project Delta slip". The two cases named "Project Delta slip" still both appear.
- **Self-check badge.** Settings shows "Self-check found issues 13/15 checks · all formats". It was not opened.

## Driving notes

- Setting the Search field's value through AX did not run the search. The query was typed instead, with the frontmost check.
- Many tool calls in this session were refused by a hook timeout and were repeated. No step was assumed.

## Limits

- Sample archive only (8 documents, 12 sample cases), Debug build, agent-driven through Accessibility.
- R2 used "Forensic sample engagement" for the digest and Pricing entries, because those passages already had entries in "Investigator sample case" from the previous pass.
- Only one earlier-build entry (the digest) could show the remaining tab/report disagreement. The earlier Pricing entry had already been re-labelled by the previous pass's export.
- The Communication ("Who talks to whom") sheet was not reopened. R5 records that its module is on and that "People & connections" is back in the Tools menu.
