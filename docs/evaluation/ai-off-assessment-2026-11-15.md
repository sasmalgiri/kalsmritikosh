# AGENT assessment (not a human study)

**Question (owner):** "Does our app, WITHOUT AI, make an investigation easy?"
**Assessor:** Claude (agent), 15 November 2026, HEAD `6a021297`, branch `investigations-next`. No product code changed.
**Status under the frozen protocol** (`docs/evaluation/measurably-easier/PROTOCOL.md` §10): conclusion (1), *technical tests
passed, human benefit unmeasured*. This is an agent walkthrough of the code, help and tests. Under PROTOCOL §10 it is
not a participant session. BENEFIT-02 to BENEFIT-07 remain NOT_STARTED.

## Verdict: PARTLY

With AI off, the app makes the **bookkeeping** of an investigation clearly easier than folders, Excel and Word. It shows
which files were read and which failed, and why. It drops byte-identical copies. It searches the case's words with a
receipt and opens the exact passage. It checks a quote against its source, does the money arithmetic per currency
without calling net outflow a loss, keeps amendments beside the originals, tracks who did and reviewed what, finds an
account number in a prior case, and exports a record that is checked again at release. All of this works, and the AI-off
journeys pass (below). It does **not** make the **finding** much easier. Without AI the app does not write an answer:
Ask returns passages. The rules did not catch the decisive conflict in either fixture we have evidence for. The
witness's "one payment" against the bank's two debits on INV-104 is not flagged, because the rules read only `$`
amounts (inferred from the code; no run was made). The rules also found nothing on the walk's Dalmia case (observed on
screen). Case money must be typed in record by record, and statement import has no button. The case's chronology is
built by hand or accepted proposal by proposal. Several core steps (money, actions, review of action results, the case
package) sit behind "Case map (preview)". That switch is off by default and was broken on screen in the last GUI walk
(D2; the fix is not yet re-observed). An organised investigator would save real time on intake, search, citation
and export. The thinking work stays manual, and the route through the app is long and full of jargon. Whether this is
"easy" for real people is unmeasured.

## 1. AI-off journeys run on this Mac (real counts)

Run with xcode-tools RunSomeTests, 14:45 IST, 49.8 s. The console log has 0 "hung before" lines; the evidence file is
`docs/evaluation/ai-off-assessment-2026-11-15-test-run.txt`.

| Test | Result | What it proves |
|---|---|---|
| SmartMapAcceptanceJourneyTests/decisiveJourney | PASS (49.2 s) | §G journey over INV-104 with AI off. It covers intake states, the brief, nine map levels with exact return, both sources kept, money 100,000 / 50,000 / 50,000, amendment impact, prior-case overlap, self-review, search receipt, close, export read-back, backup, erase and restore with no resurrection. It records 7 declared skips (steps 1, 6, 7, 13, 16, 17, 18): team identities, a real reviewer, a second Mac and AI modes. |
| SmartMapAcceptanceJourneyTests/hostileAndFailureVariants | PASS | Local role revoked during an export, malformed statement, stale review, erased case, tampered backup. |
| SupplierINV104AcceptanceTests/supplierINV104 | PASS (48.3 s) | INV-104 matches the hand-written answer key (section 2). |
| BaseCaseMultiDayTests/daysThreeFourSix | PASS | A duplicate request, debit and return kept apart, a namesake kept distinct, findings carried into the report and the map export. |
| CaseMapFramesTests/journey | PASS | Report → point → question → action → result → deeper point, twice; exact return through 8 frames. |
| PlanJourneySimulationTests/offlineJourney | PASS | No plan, no key, Online off: Ask returns "Search results for …" and sends nothing. |
| BaseCaseJourneyTests/baseCaseJourney | PASS **with 1 known issue** | OCR did not answer on this Mac ("TextRecognitionProbe.works == false"). **The scan-reading step was NOT verified in this run.** |

**Important reading of these tests.** They call the production services, not the GUI. The investigator's judgements are
typed in by the test from the answer key: report points, the discrepancy links, actions, people, money accounts and
statement rows. So the tests prove the app **keeps, checks, counts and exports** those records correctly with AI off.
They do not prove that the app **finds** them by itself, or that a person can do them on screen.

## 2. INV-104 against the answer key (AI off)

| Answer-key item | App result | Who did it |
|---|---|---|
| 10 readable documents processed; originals unchanged (SHA-256) | ✔ all 10 processed; hashes unchanged | **App** |
| Byte-identical bank copy is not a new source | ✔ aliased; the statement has 1 version; the copy is never a second search hit | **App** |
| Unreadable scan is a recorded failure, not an empty document | ✔ failed, 0 chunks; admitted as "not read" with a reason; named in brief and coverage; never a hit | **App** |
| Unsupported attachment has an explicit state | ✔ refused or not processed; never searchable | **App** |
| Bank lines: 3 rows with dates, UTR refs, kinds and amounts | ✔ parsed by `importStatementRows` in the §G test. The INV-104 test parsed them with a test helper. **No UI button calls statement import** (grep: no caller). A person records each row with "Record money…". | Parse: app service. Entry on screen: **person** |
| Gross paid 100,000 / returned 50,000 / net outflow 50,000 INR; 2 distinct settlements; copy rows excluded (3); invoice not a movement | ✔ all exact. The money report prints "INR 100,000.00" and never the word "loss". | Arithmetic: **App**. Classifying each row (payment, refund, invoice): **person** |
| Net outflow not labelled loss; missing amount is not zero | ✔ | **App** |
| Forensic report FR-12: 3 points, each verified as quoted in FR-12's own version | ✔ verified | Quote check: **App**. Choosing and typing the points: **person** (the map's "Suggest points (rule-based, AI off)" can propose them; not exercised by these tests) |
| Timezone uncertainty recorded | ✔ | **Person** typed it |
| Amendment withdraws finding 2; original stays inspectable; dependent work flagged | ✔ point 2 marked changed, point 1 requalified, point 3 unchanged; the parent action flagged for review; nothing overwritten | Impact marking: **App**. The "supersedes" link: **person** |
| Discrepancy: witness "one payment" vs two debits, both sources kept, left open | ✔ kept and left open | **Person** created both links. The rules do not detect it: `CaseContradictionFinder` reads amounts only with `$` (`CaseContradictionFinder.swift:356, 392`), equal amounts are not a conflict, and its count rule covers only victims and counts. This is code reading, not a run. |
| Parent action + financial and interview children, interview waits for the trace; question open after work completes | ✔ | **Person** created them; the app enforces structure and status |
| One canonical witness in two branches | ✔ 1 node, 2 appearances | **App** keeps it; the person places it |
| Namesake Arjun Mehta not merged; 0 automatic identity decisions | ✔ "weak candidate" at most; the person records "different people" | **App** declines to merge; the **person** decides |
| External examiner is reported, not authenticated | ✔ | **Person** records it; the app labels it |
| Prior case 2025-17 shares account 8804 (exact) without exposing its content | ✔ exact-identifier overlap, counts and case names only | **App** after the person chooses "8804" |
| Known unknowns (timezone, who approved, loss not decided) | ✔ none asserted as fact; no "fraud" or "guilty" text | **App** asserts nothing. The **person** writes them down |
| Chronology | **Not checked by any INV-104 test.** The whole-library Timeline extracts dates by rule. The *case* chronology holds only entries the person adds. | Not measured |
| People and roles from the documents | **Not checked by any INV-104 test.** Names are extracted by the NaturalLanguage tagger into "Named in the case documents"; roles (witness, signatory) are assigned by the person. | Not measured |

**Summary.** On everything the answer key fixes, the app's records are **correct and safe**: no double counting, no
invented loss, no false merge, no lost original, nothing missing silently. Most of the investigative content was
**entered by the person** (or the test standing in for one). The app's own detection with AI off covered intake,
duplicates, unreadable items, quote verification, money arithmetic, amendment impact and the prior-case account
overlap. It did not find the central discrepancy.

## 3. Task inventory (AI off)

Step counts are approximate, counted from the SwiftUI code and the help. Manual figures are **agent estimates** for a
50–500 document case (PDF reader, folders, Excel and Word) and are not measured.

| # | Task | Doable AI-off? | App: how / ≈ steps | Manual way / effort | Automation gain | Friction |
|---|---|---|---|---|---|---|
| 1 | Take in documents; know what was or wasn't read | **Yes** | Evidence ▸ Sources ▸ "Add Folder…" (≈3), then Professional Jobs ▸ "Start matter" ▸ "Add documents to this case" ▸ confirm (≈4). Coverage: "Read · Partly read · Not read" with reasons | Open each file, keep a log in Excel: ≈1–2 min per document, so 1–15 h | OCR of scans (on by default), parsing of about 20 formats, hashing, byte-identical copies aliased, a named failure for every unread file | Three layers (library → workspace → case scope). "Projects" vs "Workspaces" naming. A paid Workbench plan or trial is needed to start a matter. The intake receipt showed a false "not reached 10" (D3; fix seen on the Evidence side only). OCR was **not verified on this Mac** this run. |
| 2 | Find a fact or a person across documents | **Yes** (words only) | "Search case evidence": type and Search (≈3), or the rule builder (≈6–10); results show "Open source", "Add to chronology…" and "Select for report", with a receipt of what was searched. Ask returns passages, not an answer | Spotlight or Acrobat search document by document; no proof of what was covered: minutes per query | Case-scoped search with a coverage receipt, exact highlight, and one click to the source | No meaning-based matching with AI off. Locators read "version 8E7886A8 · passage CCAC4593 · characters 90–97". Operators such as `NEAR/5` and `stated-on:` are for experts. |
| 3 | Build a chronology | **Partly** | Whole-library Timeline (⌘7) is automatic but not case-scoped. Case chronology: hand entry (≈5 per entry), "Add to case chronology…" from a hit (≈4), or "Draft from the documents" proposals accepted one by one | Excel row per event: ≈2–5 min per event, so 50–300 events take hours to days | Rule-extracted dates (library-wide); date precision kept honestly in the report | The case chronology is not filled automatically. Undated events can fall back to the file date at low confidence. The case chronology exports only inside the Markdown case report. |
| 4 | Who is connected to whom and to which money | **Partly** | Explore, Connections and Fund Flow are automatic but library-wide. Case-scoped links and "Find paths" are on the map only (≈6) | Hand-drawn chart or i2-style tool: hours | Name extraction; "Also in other cases" automatically | Needs "Case map (preview)". Fund Flow needs "paid" relationships that the rules do not appear to create, so it is likely empty with AI off (code reading). |
| 5 | Follow the money (gross, returned, net) | **Partly** | Map ▸ Case tools ▸ Money ▸ "Record money…": 6 fields, ≈7 steps per record. Then figures for gross, returned, fees and net, per currency | Excel: type rows, write SUMIFs, de-duplicate by eye: ≈1–2 min per row plus checking | Correct arithmetic per currency; the copy's rows are not counted twice; net never labelled loss; money report export | **No statement import button**: every row is typed. The default kind "unclassified" counts in no figure, and no screen reclassifies a record. The form has no source or quote field. Map only. The kind picker shows raw values ("reserve", "reversal"). |
| 6 | Spot conflicting accounts | **Partly** | Overview ▸ Contradictions ▸ "Find contradictions" → "Confirm / Dismiss (reason) / Defer" (≈3–4 per item) | Reading and memory: the main manual cost of an investigation | Rules for `$` amounts, dates of proceeding steps, ages, counts of victims or counts, roles and sentence lengths; both sides kept; decisions recorded | **Missed both observed cases**: INV-104 by code reading; Dalmia on screen ("0 found by the rules"). Non-`$` currencies (INR) are never compared. |
| 7 | Allegations/questions → evidence → findings | **Yes** | Plan & allegations: add, link evidence (Supports, Contradicts, Neutral, Why, Quote), record response and finding, ≈12 per allegation with one link | Word table: similar typing, but with no quote check | The quote is checked against the source version; an unverified link "counts for nothing"; respondent-response rule | All typing is by hand. Labels such as "Exception — why this adverse finding is recorded without the respondent's response". |
| 8 | Assign and track work | **Yes** | Tasks ▸ "Add a task" (≈5; due date becomes a reminder). Map: "Create action…" (≈7) and "Waiting for me" | Spreadsheet or email | Reminders; parent and child actions; dependency waits; reopen proposals when a source changes | Two parallel systems (Tasks tab vs map actions). The richer one is on the map only. |
| 9 | Check a prior case | **Yes** | People & interviews ▸ "Also in other cases" (automatic, 0 extra steps); map "History set" (≈4) | Ask colleagues, search old folders: hours | Exact identifier overlap across cases without exposing their content | "History set" vs map "History" are easy to confuse. |
| 10 | Review and approve | **Yes** | Job result: decision per row, "Save review", "Mark completed" (≈4 + 1 per row). Map: "Submit result for review" / "Accept result" | Tracked changes in email | Revision-pinned review; self-review labelled; stale review refused | Action-result review is on the map only. "revision" and "Restore as current" are jargon. |
| 11 | Report/export with citations to the source page | **Partly** | "Log & exports" ▸ "Case file report…" (≈3) writes **Markdown**. Map: case package (HTML), money report (.md), map PDF | Word report with hand-typed footnotes: hours to days | Every citation printed with its quote; checked again at release; recorded with a digest; read back | **No page numbers** in the case report (quote + "version/document/block" IDs). No Word or PDF of the case report. Markdown is unfamiliar to a court, HR team or insurer. |
| 12 | Keep privileged material out | **Partly / mostly no** | Export refuses sources labelled privileged, but **no investigator screen sets the label** (`SensitiveScopeMutationService` has no UI caller). Workarounds: "Exclude ticked" from scope; Lawyer review coding (optional module); Journalist "Protected identity" | Separate folder, by hand | Release-time recheck (when a label exists) | No direct "Mark privileged" control for an investigator. |
| 13 | Close and reopen | **Yes** | "Close the case" (rationale, unresolved items) ≈3; "Reopen" with reason ≈2 | Move the folder, write a memo | Closure records the unresolved items; a closed case refuses new writes | — |
| 14 | Backup and erase | **Yes** | Settings ▸ Your data ▸ "Back up everything…", "Check a backup…", "Restore…" ≈3 each; "Erase this case" ≈5 | Copy folders; deleting by hand misses copies | SHA-256 of every original; erased case not resurrected on restore; recovery key | Help says "Complete backup", but the button reads "Back up everything…". Words such as "ledger" and "manifest". |

## 4. Beginner path (install → first useful report, AI off)

- **Route, about 10 steps** (BEGINNER_GUIDE §2 plus the code):
  1. Paywall: start the Workbench trial. It is needed to add documents or start a matter. "Look around first (read-only)" and the sample case are free.
  2. Onboarding.
  3. Add a folder and wait for "Ready".
  4. Professional Jobs ▸ profession ▸ "Start matter".
  5. "Add documents to this case".
  6. Run a job.
  7. "Open result", decide the rows, "Save review".
  8. "Include in report".
  9. "Case file report…".
  10. Open the .md file.
- **What helps:**
  - Every empty or failed screen names a next action.
  - Help has 76 topics and a "When something goes wrong" group.
  - The sample case is free.
  - Disabled AI buttons explain why.
- **Where a beginner gets lost:**
  - **Three homes for documents.** These are the library (Evidence), the workspace ("Projects → Add sources…", but the screen is titled "Workspaces") and the case scope. If the workspace step is missed, the case has nothing in it.
  - **"Matter" vs "case".** A case is started in Professional Jobs ("Start matter") but resumed in Cases.
  - **About 63 destinations.** There are 4 sidebar areas plus "More tools" with 5 groups. Investigator jobs carry names such as "CAPA register", "DataLab" and "Causal analysis".
  - **The map is needed and hidden.** The Smart Map Guide's step 1 is "turn on Case map (preview)". It is off by default, labelled "preview", and was broken on screen in walk 1 (D2). Its fix was seen only on Evidence, not on the map.
  - **Stale and wrong wording.** Onboarding still mentions the "Sources tab" and the "Explore tab". The "Read with AI…" tooltip says Settings ▸ Modules, while the manual says Settings ▸ Online.
  - **Ask with AI off.** It gives passages, not an answer. A beginner who expected an answer may think the app failed.
- **Agent judgement:** a careful first-time investigator could reach a cited Markdown report with AI off by following
  BEGINNER_GUIDE §2. Getting money figures, actions and a case package means finding and trusting a "preview" map. That
  is where a first-timer would most likely stall. This is unmeasured; the pilot criterion (4 of 5 users without
  coaching) has not been run.

## 5. Top 5 friction points (ranked by impact on "easy"), with suggested fixes

These are suggestions only. None was implemented, and none is AI-quality work.

1. **Core case work lives behind "Case map (preview)", off by default.** This covers money, actions, action review, the
   case package and case-scoped links.
   - *Fix:* expose Money, "Create action…", "Submit/Accept result" and the case-package export from the ordinary case
     screen as well, or turn the map on by default once D2 is re-verified on the map.
   - *Fix:* drop "preview" from the label when it ships.
2. **Money is typed row by row, and a record can silently count for nothing.**
   - *Fix:* add an "Import statement rows…" button that calls the existing `importStatementRows`, with a preview and
     confirm step.
   - *Fix:* add "Account…" and "Classify…" actions, using the existing `addMoneyAccount` and `classifyMoney`.
   - *Fix:* make the kind a required choice instead of defaulting to "unclassified", or show "N records in no figure —
     classify" beside the totals.
   - *Fix:* add a source document and quote to "Record money…".
3. **Conflicting accounts are missed without AI.**
   - *Fix:* make the existing rule checks currency-agnostic. Read INR, ₹, Rs., € and £ with their currency, as
     `EntityExtractor` and the money ledger already do.
   - *Fix:* add a deterministic "statement vs ledger count" check, for example "witness or record says one payment;
     the case money shows two payments of the same amount to the same payee". It can come from the case's own money
     records.
   - *Fix:* when nothing is found, say plainly that the rules cover only $ amounts, dates, ages, counts, roles and
     sentences, so the person knows to keep reading.
4. **Reports are Markdown and carry no page numbers.** A court, HR team or insurer expects Word or PDF with "p. N".
   - *Fix:* print the page (and the email message or sheet cell) in each citation, using the locator the app already
     stores (`SourceLocation` page; `CitationRecord` has a "p. N" formatter).
   - *Fix:* offer the case file report as PDF and DOCX through the existing export writers.
   - *Fix:* replace the version, document and block UUIDs in the human text with "document name, page, paragraph", and
     keep the IDs in an appendix.
5. **Too many places and words before the first result.**
   - *Fix:* merge "Start matter" and "Start from a question" into one "New case".
   - *Fix:* add documents straight into the case. The workspace stays implicit, with one "General" workspace unless the
     person asks for another.
   - *Fix:* rename "Projects" to match the "Workspaces" screen.
   - *Fix:* hide non-investigator jobs (CAPA, DataLab, …) for the Investigator profession.
   - *Fix:* fix the stale onboarding tab names and the Settings ▸ Modules vs Online mismatch.
   - *Fix:* say "Back up everything" consistently.
   - *Fix:* add a plain "Mark privileged" control on a document in the case (the release check already honours the
     label).

## 6. Limits — what an agent cannot establish

- **Real time saved, real ease and learnability** need people. PROTOCOL §5–§9 calls for a five-person pilot, then
  12–20 within-subject participants on matched packs A, B and C against their normal workflow, with two human
  reviewers. None of this has happened (BENEFIT-02 to BENEFIT-07 are NOT_STARTED). Every manual-effort figure above is
  an agent estimate.
- **The GUI walk is incomplete.**
  - Walk 1 found D1 (a new window re-ran boot) and D2 (the map laid out off-screen).
  - Walk 2 re-observed only the launch half of D1 and the Evidence side of D2, D3 and D5.
  - The map, output routes, exports, ACH, statements, small window, keyboard and VoiceOver have **never been seen
    working on screen**. Step counts here come from code, not observation.
- **OCR was not verified in this run.** The scan step of BaseCaseJourneyTests was skipped as a known issue because text
  recognition did not answer on this Mac.
- **The tests stand in for the person.** They prove the records are kept and computed correctly; they do not show
  whether a person would enter them correctly, quickly or at all.
- **Conflict detection and automatic extraction on INV-104 were not run.** I avoided running a snippet in the app
  process, so that the owner's ledger could not be touched. The statements about missed conflicts, the empty Fund Flow
  and extraction come from code reading.
- **No real-world case** was used on this Mac. INV-104 is one small fictional supplier case of 12 items. The protocol
  forbids generalising from one task family to the others (workplace allegation, email chronology, journalism,
  identity).
- **AI-on vs AI-off comparison** was not attempted (out of scope: no AI-quality work).
