# GUI walk of candidate c179485f — AGENT run, 2026-11-13 (stopped early: screen locked)

**Result: PARTIAL. This is not a gate record.** Everything below was seen on screen in the running Debug app on
the acceptance-case fixture. At about 12:17 IST the screen locked: a full-screen capture showed only the wallpaper,
with no menu bar. After that, every GUI command timed out at the host hook (10 minutes each). Following the
standing rule, the walk stopped there. Output routes, the consent sheet and the credit meter were not reached.

An agent (Claude) did this run, not a person.

## Setup

| Item | Value |
|---|---|
| Candidate | c179485f2db9e443d19a08b95a329896d885f0ae (branch investigations-next, HEAD = candidate). The working tree had only Xcode edits to the two InfoPlist.xcstrings files and xcschememanagement.plist (not app code). |
| Build | xcode-tools BuildProject, Debug, 11:00 IST: "The project built successfully." No Swift file under Kalsmritikosh/ was newer than the binary (11:00). |
| Scheme | Backed up to /tmp/walk/scheme.backup (sha1 58481b72…). The existing `--acceptance-case` argument was set to enabled. Restored after the walk: sha1 identical, `git status` shows no change to the scheme. |
| Launch | xcode-tools RunProject → pid 25806. `pgrep -fl` showed `…/Debug/Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh --acceptance-case -NSDocumentRevisionsDebugMode YES`. Stopped with StopProject at the end. |
| Ledger | `lsof` could not be run: the call stalled at the host hook. In the app, the folder shown was `…/Containers/ecosanskritiinnovation.Kalsmritikosh/Data/tmp/acceptance-case-documents`. The Live screen read "documents: 9 · chunks: 9 · entities: 25 · events: 3", which is the fixture, not the owner's archive. "Back to my archive", erase, key entry and Online AI were never touched. |
| Purchase | The scheme's StoreKit configuration was active, so the plan picker showed local test products. "Start 14-day free trial" (Workbench yearly) was pressed in the **local StoreKit test environment**. No confirmation sheet appeared, nothing was charged, and the strip read "Free trial: 14 day(s) left". **This test transaction was not cleared**, because the screen locked first. See "Left for the owner". |
| Method | Wrapper scripts in /tmp/walk drove the app: the build/axdrive tool for AX presses and reads, CGEvent clicks and typing, and a frontmost-app check before every key or click. Captures are `screencapture -R` of the app window, saved as JPEG. |

## What was observed

| # | Step | What appeared | Screenshot | Result |
|---|---|---|---|---|
| 1 | Launch | No window opened, only the menu bar (the AX tree had AXMenuBar only). File ▸ New Window opened the window. | — | Observation (see D1: opening that window re-ran the boot) |
| 2 | Plan picker (no plan) | "Investigations Made Easy — all nine personas". Cards: "Workbench monthly $4.99 per month" and "Workbench yearly $39.99 per year · about 33% less than twelve monthly charges", each with a "14-day free trial, then this price". "Start 14-day free trial". Disclosure: "14 days free, then $39.99 per year. Renews automatically at $39.99 per year unless cancelled at least a day before the period ends…". Links: Restore purchases, Manage subscription, Terms, Privacy, "Look around first (read-only)". No AI plans were shown; without the relay this is by design (`PlanOffer.forSale`). | s01-paywall.jpg | PASS (Workbench picker only) |
| 3 | Start an investigation | Home ▸ "Start an investigation" ▸ title "Dalmia Traders payment" ▸ "Start matter". Result: "Created case "Dalmia Traders payment" (rev 1) with 0 source(s) in scope …", plus "0 of 15 jobs resolved". | s04-matter.jpg | PASS |
| 4 | Ingest + unreadable scan | Evidence ▸ "Ingest All" → "10 file(s) ingested". "Needs attention — 1 file(s) could not be read" lists "scan-receipt-unreadable.pdf · stage: parser — loaderFailure … · unreadable", with "Read again" and "Read with AI…" (disabled offline). The text explains that no answer, job or report draws on it. Nine other files are listed "Searchable". | s06c-evidence-zoomed.jpg | PASS (Read again not pressed) |
| 5 | Add sources to the workspace | Projects ▸ Projects and workspaces ▸ General ▸ "Add sources…". The sheet listed 10 files; the scan was marked "Not read — reading failed (metadataExtraction failed)". After "Select All Visible" ("10 selected") and "Add Sources": "10 Sources · 25 People / Entities". | s13-addsources.jpg | PASS |
| 6 | Bring into the case | Matter: "Documents: 0 in scope · 10 new in the workspace, not in the case" ▸ "Review new documents (10)" ▸ "Add 10 documents to this case". Result: "10 document(s) added to the case's scope (revision 11) …" and "Documents: 10 in scope · nothing new in the workspace". | s15-review-new.jpg, s16-approved.jpg | PASS |
| 7 | Case overview | "Read: 9 · Partly read: 0 · Not read: 1 (1 reading failed)". "scan-receipt-unreadable.pdf — not read: reading failed". "A document not read here was not searched, quoted or sent to an AI." "Intake: 10 documents in the case". "Traced to intake receipts: 10 of 10". **"Latest intake batch — Selected 10: received 4, already held 6, duplicates 0, failed 0, not reached 10"** (see D3). Reading limits: "The AI has not been allowed to read this case …". What changed: "10 × Document admitted to the case · 1 × Document could not be read". | s17-overview.jpg | PASS except D3 |
| 8 | Contradictions | An archive-scan item: "Conflicting dates for "Invoice INV-2041 Dalmia Traders"", A Mar 4 03:42 UTC (email-invoice-resend-1.eml) and B Mar 6 11:10 UTC (email-invoice-resend-2.eml). "Find contradictions" gave "Compared 9 document(s): 0 found by the rules (AI reading off — rules only)". | s19-contra-found.jpg | PASS (presentation). The rules did not flag the two witnesses' disagreement. That is answer quality, outside this walk. |
| 9 | Open source and return | "Open source — email-invoice-resend-1.eml" opened the viewer with the whole message, "Where this came from" and "Add to case chronology…". The highlight covered "Invoice INV-2041 Dal" (see D4). "Done" returned to the same scroll position with the same item selected. "Return to the last source — email-invoice-resend-1…" appeared in the case header. | s20-source.jpg, s21-after-source.jpg | PASS except D4 |
| 10 | Dismiss with a reason | Reason "Different event or transaction", note "Two sends of the same invoice; the dates are the e-mail dates", then Dismiss. The list then read "Dismissed: Conflicting dates for …" and "Nothing is waiting for a decision. Choose "All" to see the decided items." The waiting count went 1 → 0. The map card (AX) read "Dismissed by Shirshendu Sasmal on 13 Nov 2026 at 11:52 AM — Different event or transaction: Two sends …". | s23-dismissed.jpg, s26-map-axtree.txt | PASS |
| 11 | Offline case search | "Search case evidence" showed a rule builder ("Match All of these", "Words (in this order)", Add rule, Add group, "Show the text as rules") and a text field. Query `invoice AND "Dalmia Traders" -picnic`. "What will be searched" listed the three conditions. The receipt read: "Mother case: Dalmia Traders payment — only its 10 authorised source versions (9 documents) are read. Prior cases: none …", "Matching: any letter case · accents ignored · no word-ending, approximate or meaning-based matching". Result: "6 matching documents · 20 occurrences · 6 passages · incomplete: see what was not searched" and "Searched 9 documents of this case in full. 1 not searched." Each result showed "Exact text — the words occur in the searched text", one ✓/⊖ line per condition, the highlighted words, and a locator such as "passage 1 · version 8E7886A8 · passage CCAC4593 · characters 90–97 of the searched text", with "Open source", "Add to chronology…", "Select for report", "Save search…" and paging. All of this ran with AI off, on this Mac. | s25-search-results.jpg, s25b-search-results2.jpg | PASS |
| 12 | Case map (preview) on | Only the map cards are visible: "Question: Dalmia Traders payment", "Contradiction", "Evidence — 2 (collapsed)". The header, view strip, toolbar, sidebar and inspector are drawn outside the window (D2). | s26-map.jpg, s26c-map-nosidebar.jpg, s26-map-axtree.txt | **FAIL (D2)** |
| 13 | Map off, after a second window | The switch was turned off with AXPress. The case overview then read, in red, **"This case is not in the ledger (it may have been erased)."** The sidebar showed "93 new files added". Cases then showed **"No cases yet" / "0 active"** (D1). | s28-map-off.jpg, s29-activity.jpg, s30-cases.jpg | **FAIL (D1)** |
| 14 | D1 reproduction | Matter "Repro case" created → Cases "1, active" (s31). File ▸ New Window, ⌘2, ⌘1 → AX "0, active" and "No cases yet". | s31-before-newwin.jpg | D1 reproduced |

## Defects found

- **D1 — High. File ▸ New Window re-runs the app's boot on the shared AppState.**
  - **Where:** the boot `.task` in KalsmritikoshApp.swift (around lines 112–150) is attached to the window's content. It calls `AcceptanceCaseGUIFixture.boot(appState)` in acceptance mode and `appState.boot()` otherwise. `AppState.boot` has no re-entry guard.
  - **Effect in `--acceptance-case`:** the fixture deletes and recreates the disposable ledger, so the open case disappears.
  - **Reproduction:**
    1. Launch with `--acceptance-case`.
    2. Create a matter.
    3. Note that Cases shows "1, active".
    4. Choose File ▸ New Window.
    5. Press ⌘2, then ⌘1. Cases shows "No cases yet / 0 active", and an open case reads "This case is not in the ledger (it may have been erased)".
  - Reproduced twice.
  - **Not tested:** what a second `appState.boot()` does to a real ledger. The safety rules forbid opening one, so it remains an open question.
  - The first launch opened no window at all. The New Window used to get one probably caused the second fixture boot and the duplicate folder row (D3).
- **D2 — High. Case map (preview) lays the window out far taller than the window.**
  - **What happens:** with the switch on, the window's content spans about y −920 to +1850 pt inside an 845-pt window.
    - The canvas group is 856×2371, and each collapsed card is 856×587.
    - The case header, the switch, the view strip (Overview…Changes), Map/List/Table/Timeline, Save view, Back/Forward, "Waiting for me", zoom/fit, "Show details" and the whole sidebar sit above the window.
    - Coverage, Legend, Reset view and Undo sit below it.
    - Scrolling does not reach them. Only the cards show (s26-map-axtree.txt).
  - **Reproduction:**
    1. Open the case with the window at 1100×845 or zoomed to 1470×845.
    2. Turn on "Case map (preview)".
    3. It reproduces in a fresh window, after unzooming, and after toggling the sidebar.
  - **Same symptom on the Evidence screen (⌘2):** "10 file(s) ingested", "Ingest All", the first folder row and the banner "The case last open is not in this ledger …" are at negative y (s06c shows the list starting mid-screen with the sidebar cut).
  - **Effect:** no map task could be observed on screen in this walk.
- **D3 — Medium. False "not reached 10" in the intake batch receipt.**
  - **What happens:** the receipt's `notReached` is `planned − selected` (IntakeBatchReceipt.swift:137). The folder `acceptance-case-documents` is registered twice (two identical rows in Evidence ▸ folders), so the run planned 20 and selected 10. The overview then says 10 files were not reached, when none were missed.
  - **Related:** the duplicate root row recurs. It is the 2026-10-30 D-3, which had been fixed for the plain relaunch path.
- **D4 — Low. Contradiction source highlight ends mid-word.**
  - **What happens:** opening side A highlights "Invoice INV-2041 Dal" in "Subject: FW: Invoice INV-2041 Dalmia Traders" (s20). The statement is "Invoice INV-2041 Dalmia Traders on Mar 4, 2026 …".
- **D5 — Low. The same failure has two different labels.**
  - **What happens:** for the same scan, Evidence says "stage: parser — loaderFailure (… "empty(…)")" and the Add-sources sheet says "Not read — reading failed (metadataExtraction failed)".
- **Unexplained observation (not counted as a defect):** after the second boot the sidebar showed "93 new files added", while the ledger read 9 documents.

## Not observed, and why

- **The screen locked at about 12:17**, so these were never reached:
  - output routes (none retested);
  - the AI plan picker, which needs `--ui-walk-dummy-relay`, a second launch;
  - the once-per-case permission sheet;
  - the credit meter;
  - Ask's offline answer path;
  - ACH, statements, exports, the later document.
- **Every case-map task** could not be observed because of D2.
- **Evidence of the ledger path from `lsof`:** the command stalled at the host hook.

## Gate records

None was written. acceptance-case-ui, ui-consent-and-plans and output-routes stay OPEN:
- **acceptance-case-ui:** the walk covered steps 1–11 and was then cut short by D1 and the lock.
- **ui-consent-and-plans:** only the Workbench plan picker and offline case search were seen.
- **output-routes:** no route was retested.

## Left for the owner

- **Clear the local StoreKit test transaction.** The Workbench yearly trial bought in the Xcode StoreKit test environment is still there. To clear it:
  - run `PurchaseStoreKitTests/restoreWithNothingBoughtSaysSo()`, or
  - use Xcode ▸ Debug ▸ StoreKit ▸ Manage Transactions.
- **Case map switch:** turned back off (AX value 0). It was off at the start.

---

# Walk 2 — candidate f645b860 (D1–D5 fixes in 25e59ebd), AGENT run, 2026-11-13 13:52–14:18 IST — stopped early

**Result: PARTIAL. Not a gate record.**

The walk stopped because two GUI commands in a row timed out at the host's PreToolUse hook (about 10 minutes each,
from 13:58). This is the coordinator's stop rule. Only the start of the walk ran.

## Setup

- **Candidate:** f645b860a86785e2a90dfbd9686e00d8576c3f59, which is HEAD. f645b860 changes only `.github/workflows/build-and-guard.yml` on top of 25e59ebd.
- **Working tree:** only the Xcode edits to the two InfoPlist.xcstrings files and xcschememanagement.plist, as before.
- **Scheme:**
  - Before the walk, the sha1 matched /tmp/walk/scheme.backup (58481b72…).
  - `--acceptance-case` was enabled for the walk.
  - Restored afterwards: sha1 identical, and `git status` shows no scheme change.
- **Build and launch:** xcode-tools RunProject, which built for 102 s and launched pid 37456. `pgrep -fl` showed `…/Debug/Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh --acceptance-case -NSDocumentRevisionsDebugMode YES`. The app was stopped with StopProject.
- **Ledger:** the Live screen read "Files 10 · Objects 9 · Chunks 9 · Entities 25 · Events 3", which is the fixture.
- **Not touched or done:**
  - nothing bought;
  - no key entered;
  - nothing sent;
  - no "Back to my archive";
  - no ⌘Q.
- **Plan state:** the Workbench trial from walk 1 (local StoreKit test) still applied ("Free trial: 14 day(s) left").

## Fix checks (seen on screen)

| Defect | Check | Result | Screenshot |
|---|---|---|---|
| D1 — window at launch | The AX tree held the "Home" window [185,33 1100x845] straight after RunProject. No File ▸ New Window was needed. | PASS (launch half) | w2-01-launch.jpg |
| D1 — New Window no longer re-boots | Not re-checked: the stall came before this step. | NOT RUN | — |
| D2 — Evidence pinned | The Evidence header (title, Sources/Library/Completeness/Processing, "Whole library — no case is open … Open Cases") and the Sources header ("10 file(s) ingested", Ingest All, Add Folder…) are inside the window. The sidebar starts at "Jump to…". | PASS | w2-02-evidence.jpg, w2-03-sources.jpg |
| D2 — Cases and map pinned | Not re-checked (stall). | NOT RUN | — |
| D3 — one folder row, correct counts | Folders lists `acceptance-case-documents` once (AX: one title row). Counts: "Parsed 10/10 · 1 could not be read — see Needs attention · Embedded 9/9", "9 Searchable · 9 Evidence-ready · 1 Needs attention". The case's intake-batch line was not reached. | PASS (Evidence side) | w2-03-sources.jpg |
| D4 — whole-word highlight | Not re-checked (stall). | NOT RUN | — |
| D5 — one plain label | The Evidence row reads "reading failed (no text could be read from it)", and the parser stage and detail are in the tooltip. The Add-sources sheet was not re-opened. | PASS (Evidence side) | w2-03-sources.jpg |
| Sidebar "93 new files added" | No longer shown during this launch's ingest. | PASS (as seen) | w2-02-evidence.jpg |

**Also seen: SRC-05 retry.**
- "Read again" on scan-receipt-unreadable.pdf was pressed.
- The button then greyed out, and the row stayed listed as "unreadable" with its reason. The file is a blank PDF, so this is the expected outcome.
- "Read with AI…" stays disabled. Its tooltip reads "Unavailable: Online mode is off … Switch on Online mode in Settings ▸ Modules and choose AI Included or your own provider."
- Screenshot: w2-04-readagain.jpg.

## Not reached

The stall came while creating the matter, so none of these ran:
- the rest of the acceptance case;
- the plan picker with `--ui-walk-dummy-relay`;
- the permission sheet and the credit meter;
- offline search;
- every output route;
- all map tasks;
- small-window, keyboard and VoiceOver checks (MAP-12, QA-12).

**Note for the next walk:** two parts of ui-consent-and-plans cannot be reached under the current rules.
- **The per-case permission sheet and the credit meter** appear only with an active AI plan or an own key.
- **An AI plan cannot be obtained.**
  - With `--ui-walk-dummy-relay` (b45c8ffd), a StoreKit-test AI subscribe is refused before charging, because the relay cannot be reached.
  - The rules also forbid both purchases and keys.
- **Consequence:** these two items need a DEBUG presentation hook, or a deployed relay.

## Gate records

None written. acceptance-case-ui, ui-consent-and-plans and output-routes stay OPEN.

---

# How to walk ui-consent-and-plans

This section answers the note above: there is now a DEBUG presentation hook. It is the launch argument
`--ui-walk-simulated-plan=aiIncluded` (or `=aiPro`), in `Kalsmritikosh/App/UIWalkSimulatedPlan.swift`.

## What the argument does

- It gives the running Debug app a simulated, verified AI plan: AI Included monthly or AI Pro monthly, renewing in 30 days.
- It gives the credit meter a local receipt:
  - AI Included: 2,000 credits a month with 350 used, so 1,650 are left.
  - AI Pro: 6,000 credits a month with 350 used, so 5,650 are left.
- The relay counts as configured, using the reserved `relay.ui-walk.invalid` host (the same as `--ui-walk-dummy-relay`).
- The rest runs on the app's normal code:
  - the plan picker, which shows the AI plans, the current plan and the credit packs;
  - the credit meter, on the Ask and case screens and in Settings ▸ Online;
  - the "Turn on AI…" setup sheet;
  - the once-per-case permission sheet, which shows the documents, the estimate and "You have 1,650 credits left".

## What it cannot do

- **Send anything.**
  - The Online provider refuses every request, including a whole-case read after "Allow", before it writes its outbound record and before its transport.
  - The person sees "Walk simulation — nothing sent …", and the outbound record shows it as `blocked` with "walk simulation — nothing sent".
  - `NetworkHelperClient.send` refuses every request as well, including relay status, credit packs and lookups.
- **Buy anything.** Subscribe, credit packs and the pending-pack credit are refused with the same message before StoreKit is asked. No local StoreKit test transaction is created.
- **Persist anything.**
  - The simulated entitlement is never written to the entitlement cache.
  - The case permission granted on the sheet is kept in memory only, never in the preferences.
  - The switches turned on by the "Turn on AI…" sheet go into the process's argument domain. That domain is volatile, and the stored values are put back at once, so the next launch starts as before.
- **Run on the owner's ledger.** It is honoured only together with `--acceptance-case` (the disposable ledger) or in sample-archive mode. Otherwise it is refused, and the refusal is logged as "UI walk simulated plan refused: …".
- **Ship.**
  - The file and every reference to it are inside `#if DEBUG`.
  - `scripts/release-check-debug-args.sh` fails if `--ui-walk-simulated-plan` or `UIWalkSimulatedPlan` appears outside an active `#if DEBUG` region.
  - Its self-test, `scripts/tests/test_release_check_debug_args.py`, is run by `ci/guards/release-check-selftest.sh`.

## Steps

1. Back up the scheme as before. Then add and enable two arguments:
   - `--acceptance-case`
   - `--ui-walk-simulated-plan=aiIncluded`

   Build and launch with RunProject. Check with `pgrep -fl` that both arguments are on the command line.
2. **Plan picker.** Open the plans (Settings ▸ Subscription, or the status strip). Record that:
   - Workbench, AI Included and AI Pro are shown;
   - AI Included is the current plan;
   - the credits and the packs are shown.

   Do not press subscribe or buy. If one is pressed by mistake, it shows the "Walk simulation — nothing sent" message and nothing else happens.
3. **Credit meter.** Record "1,650 of 2,000 credits left this month" and the reset date. These appear on Ask and the case screens, and in Settings ▸ Online.
4. **Turn on AI.** Open the acceptance case (create the matter and add its 10 documents, as in walk 1). Ask a question in the case. If Ask offers "Turn on AI…", open the setup sheet, record its text, and choose "Allow AI to read case documents you permit". The switches it turns on last for this launch only.
5. **Permission sheet.** Ask a question in the case. The once-per-case sheet appears. Record:
   - the documents to be sent (names, count, size);
   - the documents not sent, with reasons (the unreadable scan);
   - the estimate and the balance line.

   Choose "Allow". Expected result: the answer falls back to search results, and the Online status reads "Walk simulation — nothing sent …". Ask a second question: the sheet does not come back for the same document set.
6. **Offline search results.** Quit with StopProject. Remove `--ui-walk-simulated-plan`, relaunch with `--acceptance-case` only, and ask in the case. Ask now returns the offline search results, which name the missing step.
7. Restore the scheme from the backup. Check the sha1 and that `git status` shows no scheme change. Write the gate record `release/approvals/ui-consent-and-plans.md`, naming the candidate commit.

Unit evidence: `KalsmritikoshTests/UIWalkSimulatedPlanTests.swift` (10 tests). These tests do not replace the GUI walk.
