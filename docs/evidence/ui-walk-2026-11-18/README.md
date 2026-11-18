# GUI walk — 2026-11-18, 23:21–23:31 IST (agent, Debug build of candidate 56b9e08c)

Launched directly as
`Kalsmritikosh.app --acceptance-case --ui-walk-simulated-plan=aiIncluded`.
- The app ran on a disposable ledger in its own temporary folder, never the owner's ledger.
- It had a simulated AI Included plan: no purchase, no key, and nothing sent.
- The app was driven by accessibility (`build/axdrive`), with screenshots `w02`–`w17`.

**This is a partial walk.** It stopped at the open consent question below. None of the gate records `acceptance-case-ui`, `ui-consent-and-plans` or `output-routes` was written: they stay OPEN.

## What was walked

| Step | Screenshot | Result |
|---|---|---|
| Cases, empty | w02 | Empty state with one next action |
| New case from a question | w03–w05 | Question typed; the title came from it; "Create case" enabled only with a question or title |
| Case overview | w06 | The question is shown. "No documents yet" is the next step. The AI-off banner offers "Turn on AI…" |
| Add documents (file picker, 10 files incl. an unreadable scan) | w08–w12 | All 10 in scope. "1 not read: scan-receipt-unreadable.pdf (reading failed)". Overview: Read 9 · Not read 1, the scan named, and intake traced 10 of 10 |
| Find contradictions with AI off | w13 | "Compared 9 document(s) … 0 found by the rules". It says this does not prove the documents agree. The new AI-off sentence ("…a conflict written in sentences needs AI") is shown |
| Turn on AI… (setup sheet) | w14 | The sheet names Anthropic (Claude Opus 5.5), the relay that keeps counts only, and Google for recordings. It shows the document terms and the accuracy notice, and says nothing is sent now |
| AI on: online bar and credit meter | w15 | "Online — answers may use AI Included … 1,650 of 2,000 credits left this month · resets 18 Dec 2026" |
| Ask in the case | w16–w17 | Refused by the walk simulation, so nothing was sent. The answer fell back to search results with the citation and the AI-off sentence |

## Findings (2–5 fixed on 2026-11-19; see the commit)

1. **Resolved — not a defect (re-walked 2026-11-19 00:21–00:33 IST, fresh disposable ledger):**
   - **Sheet:** the first question in the case brings up "Let the AI read this case?" after about 2 s (`consent-sheet.jpg`). It lists the 9 documents sent and the one that could not be read, with the estimate and credits left, and it waits for an answer.
   - **Not now:** sends nothing. The answer says "You have not allowed the AI to read this case's documents, so these are search results" (`consent-not-now.jpg`).
   - **Allow for this case:** the send goes ahead and is stopped by the walk simulation (`consent-allowed.jpg`).
   - Walk 1 most likely answered the sheet with one of the driver's automated key presses. Unit coverage: `CaseWholeReadingTests/consentOncePerDocumentSet`, `providerCaseRead`.
2. The case overview's "at a glance" still says "not been compared for contradictions yet" after Find contradictions ran. It does not refresh.
3. The fallback message after an AI failure starts "No AI is set up, so no answer is written", although AI was set up and only the provider declined. The failure reason should replace "No AI is set up".
4. The empty Ask screen shows the chip "Private · on-device · evidence-gated" while the app is in Online mode.
5. The Cases header button "Contribute to a team folder…" is cut off ("Contribute to a t…"); its label should be shorter.

## Second session — 2026-11-19 00:40–01:25 IST

Build: Debug of the working tree committed as `e61f9002`, which includes the fixes for findings 2–5. Disposable ledger, the case re-created, 10 documents added.

### Fixes checked

- **Glance:** after Find contradictions, the "not compared yet" line is gone (finding 2).
- **Fallback reason:** the copied answer's reason reads "Online mode is off, so the AI is not used" (finding 3).

### Output routes (saved through the real save panel into /tmp/walk/exports; files kept in `exports/`)

| Route (docs/OUTPUT_ROUTES_INVENTORY.md) | Result |
|---|---|
| 1 Case file report… (Markdown) | Saved, 1,722 bytes. "DRAFT case file — not an approved findings report", case revision and read time |
| 1 Report as PDF or Word… ▸ PDF | Saved, 33,661 bytes, valid PDF |
| 1 Report as PDF or Word… ▸ Word | Saved, 8,348 bytes .docx |
| 2 Case log… (CSV) | Saved. Each export listed with file name and SHA-256. Observation: the 10 document admissions are not in the case log CSV, though the overview's "What changed" counts them |
| 3 Exhibit list… (CSV) | Saved. Header only, since no exhibit was registered |
| 4 Custody report… | Saved, 4,171 bytes. Every source with its version, SHA-256 and acquisition and hash times |
| 20 Ask ▸ Copy (clipboard) | The clipboard holds the passage, the AI-off sentence, the confidence and the source name |

The case log on screen (`exports-case-log.jpg`) records every export with its SHA-256.

### Plans and meter

| Check | Screenshot | Result |
|---|---|---|
| Subscription with a simulated AI Included plan | `subscription-simulated-ai-included.jpg` | "AI Included monthly plan, renews 19 Dec 2026", with Restore, Manage subscription and How to cancel |
| Plan picker with no plan (relaunched without the simulation) | `plan-picker-workbench.jpg` | Workbench monthly $4.99 and yearly $39.99, 14-day trial, renewal disclosure, Restore, Manage, Terms, Privacy, and the new AI-off sentence in the Workbench text. AI Included and AI Pro are not offered, because no relay host is configured (by design: they are attached only once the relay is deployed). Nothing was bought |
| Credit meter | `credit-meter.jpg` (w15) | "1,650 of 2,000 credits left this month · resets …" |

Also seen: Settings shows "Self-check found issues 13/15 checks" on the disposable ledger. Not investigated in this session.

## Not walked (gates stay OPEN)

- **Plan picker with AI plans:** walk again once the relay host is set (owner, SHIP-13).
- **Output routes:** 7 of about 30 walked. Still to walk:
  - routes 5–19 and 21–30: personal data export, statement for signature, notice, redaction log, the studios, Data Lab, the Work centre, the Export centre and the others;
  - every Print route.
- **Acceptance case beyond intake and the first checks:** requests, an explanation, a revised finding, the report after review, close and reopen.
