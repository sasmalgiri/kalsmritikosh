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

## Findings

1. **Open — needs a test before release.** Asking in the case went to the AI provider without showing either the once-per-case permission sheet or the per-send preview, before the walk's own refusal stopped it.
   - The walk plan (docs/evidence/gui-walk-2026-11-13/README.md §ui-consent-and-plans step 5) expects the sheet at this point.
   - The provider's code shows the preview for any send carrying documents unless the case's stored permission covers it.
   - Either the send was classed as question-only, or a permission was considered granted.
   - This must be reproduced in a unit test (simulated plan, a case with no stored permission, Ask), and fixed if documents could leave without the sheet.
2. The case overview's "at a glance" still says "not been compared for contradictions yet" after Find contradictions ran. It does not refresh.
3. The fallback message after an AI failure starts "No AI is set up, so no answer is written", although AI was set up and only the provider declined. The failure reason should replace "No AI is set up".
4. The empty Ask screen shows the chip "Private · on-device · evidence-gated" while the app is in Online mode.
5. The Cases header button "Contribute to a team folder…" is cut off ("Contribute to a t…"); its label should be shorter.

## Not walked (gates stay OPEN)

- The plan picker (paywall)
- The per-case permission sheet (see finding 1)
- Every output route: file, clipboard, print
- The rest of the acceptance case: requests, explanation, revised finding, report and reopen
