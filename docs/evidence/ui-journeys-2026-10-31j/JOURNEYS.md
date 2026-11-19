# UI journeys — re-verification of the run-h/i fixes (§6, §11) — 2026-10-31 (run j)

Build: `b1a2e11f` (Debug, built 12:51), launched from the shell in sample archive mode
(`open … --args -kalsmritikosh.sampleArchiveMode YES`), pid 29290, only `…/DemoArchive/sample-knowledge.sqlite`
open; one instance from start to ⌘Q; no new crash report. Method as runs d–i; performed by a sub-agent from a
written step list. 36 files in this folder. "Back to my archive" was never pressed.

| Check | Result | Evidence |
| --- | --- | --- |
| J-1 Window and strip (I-3) | **PASS.** Window "Ask" [0,33 1470×845] fits the 956-pt display. Composer: question field bottom 818, "Send question" bottom 825; strip `purchase.strip` top 848 ("Sample case: everything here can be tried without a subscription. Subscribe to work on your own documents." + "See plans") — a row below the composer, not over it | 00-start-winid.txt, 01-ask-depth7.txt, 01-ask.png |
| J-2 Accessibility crash (I-1) | **PASS.** New question "Who signed the master supply agreement?" → answer quoting the contract ("…signed this 12th day of January 2024 by John Carter (Procurement Director, Northwind) and Maria Lopez (VP Operations, Supplier ABC)…"), "Answer status: Partially supported", "Confidence: moderate · 1 source"; evidence area `ask.evidence` with chip "Source 1: contract.md. Opens at the quoted passage." A full-depth AX dump (depth 20, 193 lines), `find`, pressing the chip (sheet "contract.md", passage highlighted, Done) and expanding "Technical details" all left the process alive — the same reads crashed the app four times in run i | 02-live-answer*.txt/.png, 03-citation-sheet*.png/.txt |
| J-3 Replay from Help (I-8) | **PASS.** Help ▸ "Replay the Tutorial (Sample Case)" shows the panel at "Step 1 of 10 — You are in the sample case"; Next → Step 2 "Choose the investigation question", Next → Step 3 "Inspect and authorise the case documents", Back → Step 2; Stop removes it; Replay after Stop brings it back at Step 1 | 04-*.txt/.png |
| J-4a ⓘ Unmerge | **not testable in the sample**: Knowledge (opened with ⌘5; it is not in the Researcher lens's sidebar nor among the palette's 14 destinations) lists John / John Carter / Maria / Maria Lopez as four entities with no Merged section, so the Unmerge row and its ⓘ are not rendered. Observation: the namesakes are not unified in the sample | 05-knowledge*.txt/.png |
| J-4b ⓘ Record finding | **not testable**: the matter has no allegation yet (Plan & allegations shows the entry field and "Add") | 06-case-allegations.png |
| J-4c ⓘ Erase case | **PASS**: `info.task-keys-backup-erase` "Information about Encryption, backup, recovery key, erasure and holds" sits left of "Erase case…" (disabled with "Unavailable: A reason for the erasure is required."); the popover shows the topic title, lead and its four paragraphs verbatim and "Open in Help" | 06-case-info*.txt/.png |
| J-4c "Open in Help" | **FAIL → fixed in this commit (D-1)**: the Guide opened at the top with only Get started expanded; the target topic sat collapsed off-screen. Cause: the notification fired before the Guide was mounted. Fix: the requested topic is kept (`HelpNavigation.pendingTopic`) and consumed when the Guide appears | 07-help-topic*.txt/.png |
| J-5 Quit | one instance; ⌘Q exited in 1 s | 08-finish.txt |

Also observed: the tutorial panel, as a bottom-right overlay, covered the right end of the Ask composer (Attach /
Investigate / Send) — **changed in this commit**: the tutorial is a column beside the content, so it covers
nothing. A blank, untitled 500×500 window (id 1483) is listed by the window server in every instance, never
visible (as runs h/i H-11); not explained.

Still open: I-7 (a matter resumed after relaunch shows another profession's job catalogue), I-10 (actor label
"me" vs the account name in the case log), H-11 (the blank window), the sample's namesakes (John / John Carter)
not unified, and a UI check of the D-1 fix and the side-column panel (run k).
