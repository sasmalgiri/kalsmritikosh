# Investigations Made Easy — App Store Listing (draft)

_Draft copy + review notes for App Store Connect (REL-005). Owner fills the bracketed items,
adds screenshots, and submits. Every claim below is deliberately kept within the "Do NOT claim"
list of the release spec (§6) and the locked contract in `SHIP_DECISIONS.md`. Last reviewed
2026-10-24 (R-2 App Review 2.3.1 pass: evidence-only answers by default, English only, no judgement promised)._

## Metadata

- **Name:** Investigations Made Easy
- **Subtitle (≤30 chars):** `From evidence to findings`
- **Name note:** App Store names are limited to 30 characters, so the owner's full name "Investigation documentation made easy" (37) ships as **Investigations Made Easy** (28); the full phrase opens the description and the website (owner decision 2026-10-18).
- **Category:** Productivity (secondary: Reference)
- **Age rating:** 4+ (no objectionable content; user supplies their own files)
- **Price:** **Free download with a 14-day free trial, then one $79 in-app purchase that unlocks everything for good** — no subscription, no yearly fee (SHIP_DECISIONS 2026-10-18). App price tier: Free. In-app purchases (non-consumable, Family Sharing on): `ecosanskritiinnovation.Kalsmritikosh.trial14` "14-day free trial" at Free; `ecosanskritiinnovation.Kalsmritikosh.unlock` "Investigations Made Easy" at $79. Optional launch price $59 for two weeks (price schedule). The iPhone/iPad app is free.
- **Export compliance:** declared in the build (`ITSAppUsesNonExemptEncryption = NO` — Apple OS crypto only; SHIP_DECISIONS 2026-10-17).
- **Keywords (≤100 chars):**
  `investigation,case,evidence,interview,exhibit,chronology,custody,hr,fraud,compliance,report,private`

## Promotional text (≤170 chars)

> Run every investigation from intake to findings — evidence, interviews, exhibits and a cited
> report — privately on your Mac. The app keeps the record; you make the call.

## Description

> **Investigation documentation made easy.**
>
> **Investigations Made Easy is a private, on-device case file for investigators** — HR and
> compliance teams, fraud and insurance investigators, lawyers, journalists, researchers, and
> anyone putting a personal dispute in order. It organises, finds and documents; **every finding
> is yours to make.**
>
> **Run the whole case.** Record how a matter came in (anonymously if needed), triage it, and pick
> the kind of investigation — the plan and the usual tasks with due dates are set up for you. Add
> the evidence, register exhibits, issue preservation notices, plan and hold interviews and record
> the statement the person confirms. For each allegation, link the evidence for and against it,
> then record your finding and why. Close the case with your reasons; everything done is in the
> case log.
>
> Point it at your folders of documents and email. It builds a structured record — people,
> dates, events, facts — and lets you ask questions and get answers that **cite the exact source
> passages** they came from. When the evidence isn't there, it tells you honestly instead of
> guessing.
>
> **Private by design.** Everything runs on your Mac, and the knowledge base is encrypted on
> disk. There's no account, no sign-in, and no analytics. By default your files and questions
> never leave your device. By default answers come from your evidence only: every answer is a
> value or a passage your documents state, with its source, or an honest "the documents don't say".
> If you choose, turn on AI — Apple's on-device model, or your own cloud AI key, where you see
> exactly what would be sent before anything leaves your Mac.
>
> **What you can do**
> • Cases: intake, triage, plan, tasks and reminders, people and interviews, exhibits, holds, redaction log, review batches with a second-person check, chronology, journal and an append-only case log.
> • Evidence from documents, email (including PST), chat exports (WhatsApp, Slack, Teams and more), Cellebrite phone reports, scans and recordings.
> • Follow the money: totals per currency and where each flow stops — every figure lists its sources.
> • Export the case file report, exhibit list, custody report, statements for signature and a personal-data export.
> • Search and ask questions across everything you've added — answers come with clickable citations.
> • Build timelines and see how events connect across sources.
> • Surface contradictions and gaps between documents.
> • Organize evidence into workspaces and export cited work products.
> • See exactly what's been processed, and what couldn't be, with honest per-source coverage.
> • Works beside DEVONthink: import a DEVONthink database in place, send items back to it.
> • Save to Investigations Made Easy from the Share and Services menus in Safari, Mail, Finder and more.
> • Scan a document or take a photo with your iPhone or iPad straight into your archive (Continuity Camera).
> • Write your own notes in Markdown — searchable, with every earlier version kept.
> • Automate with Shortcuts and AppleScript.
> • Use it beside DEVONthink, or on its own: one switch turns on tags, highlights, smart collections and the other organising tools.
> • Arrange documents in your own folders — one document can live in several at once — and see what else in your archive is alike, with suggestions for where to file it.
> • Highlight, underline and comment on PDFs without changing the original; export a marked copy.
> • Clip any page from Safari: the page, your selection, or a clean Markdown copy.
> • Keep your Macs and your iPhone or iPad in step through a folder you choose (iCloud Drive, Dropbox, a disk), encrypted with your passphrase. Scan paper on your phone straight into your archive.
> • Take a signed, read-only snapshot to your iPhone or iPad with the companion viewer.
>
> **Try it free for 14 days, then buy it once — no subscription, no yearly fee.**
>
> **No AI writes your answers unless you turn it on.** Out of the box, answers, search, timelines,
> matrices, contradictions, gaps and cited reports all come from your evidence alone. Turn on
> "Use AI to write answers" in Settings to use Apple's on-device intelligence where your Mac
> supports it, or your own cloud AI key in Online mode.
>
> **English only in this version.** The app's screens are in English. Documents in other languages
> are kept and searchable by keyword, but names and dates in them may be missed.
>
> **Supported files** include common document, spreadsheet, presentation, email, image (with text
> recognition), and structured-data formats. Some formats are supported with limits and are shown
> honestly in-app; the words spoken in audio and video are turned into text while importing (on by default; Settings ▸ Modules ▸ “Transcribe audio & video”), fully on-device with Apple’s speech recognition, English, each line timecoded — the transcript is as accurate as the recording, and the app reads only what is said: it does not watch video, identify speakers or judge what the footage shows.
> Workflows cite US and international instruments; procedures are jurisdiction-neutral and deviations are recorded on the certificate.
>
> _Investigations Made Easy is an informational aid. It organises and cites your evidence; it does not
> decide findings, guilt or outcomes — you do. Verify important answers against the cited originals; it
> is not legal, financial, or professional advice._

## Privacy nutrition labels — DECISION PENDING (counsel + owner)

- The publisher collects nothing: no account, analytics, crash reporter, ads or tracking; the main app has no network
  entitlement. Online mode (off by default) sends the person's chosen text to the AI provider *they* chose, under their
  own key and that provider's terms, after per-send consent.
- The label answer is **not yet recorded**: either "Data Not Collected" with the Online-mode disclosure above, or
  "Other User Content, linked, App Functionality, Online mode only". See `docs/legal/LEGAL_PRIVACY_DECISION_SHEET.md`
  L-1 and `docs/DISTRIBUTION_PACK.md` §1. The sentence that stood here before ("Data Not Collected" as settled) was
  withdrawn on 2026-10-28 and must not be pasted into App Store Connect until the decision is recorded in
  `release/approvals/legal-privacy.md`.

## URLs

- **Privacy URL:** https://sasmalgiri.github.io/kalsmritikosh/privacy.html
- **Support URL:** https://sasmalgiri.github.io/kalsmritikosh/support.html
- **Terms/EULA:** https://sasmalgiri.github.io/kalsmritikosh/terms.html (Apple's standard LEULA also applies where no custom EULA is presented)

## Screenshots (plan — capture on a demo corpus with NO real PII)

1. **"What are you investigating?"** — the first-run question that opens the right persona with a case ready.
2. **Case file** — the case's documents in scope, with custody hashes and the chronology.
3. **Contradictions & gaps** — two sources that disagree, both shown with their citations.
4. **A persona studio filled from the case** — e.g. the SIU referral or privilege log, each filled line marked with its source document, typed lines marked "investigator entry".
5. **Findings report** — sections with claims, every sentence linked to its source, and the sealed receipt.

Use the demo corpus in `Resources/Fixtures/ProjectDelta` (synthetic) or the public-domain case packs in
`KalsmritikoshTests/Fixtures/InvestigationCases` (DOJ releases, court opinions, an NTSB docket — no private data).

## Review notes (paste into App Review Notes)

> Investigations Made Easy is **investigation documentation software**: it keeps every source of an
> investigation with custody, builds the chronology, finds contradictions and gaps, and produces the
> report where every sentence points at its source. **Judgement stays human** — the app never decides
> guilt, privilege, credibility or root cause, and its studios never fill those fields; it documents the
> investigation a person runs. It is a **local evidence workspace**. It processes only files the user
> explicitly selects via macOS security-scoped folder access. **No account is required** and
> **core processing is on-device**. The app starts in **Private mode**, in which it makes no network
> connections at all; its knowledge base is encrypted at rest with a key kept in the Keychain.
>
> **Online mode (optional, off by default).** Settings ▸ Modules ▸ Connection ▸ Online. The user
> enters their own API key for Anthropic, OpenAI or Google Gemini. Before any text is sent, a
> consent screen shows the exact text, the destination host and its size; nothing is sent unless
> the user presses Send. Network access is confined to the bundled, sandboxed extension
> KalsmritikoshNetworkHelper, which may only make HTTPS requests to those three hosts; the main
> app has no network entitlement. To test: switch to Online, enter a key, ask a question, and
> observe the consent screen. (Cloud AI is used only when "Use AI to write answers" is also on —
> see below.)
>
> **To demo:** launch → Sources → add the included demo folder (or any folder of documents) →
> "Ingest All" → open **Ask** and enter a question → the answer appears with clickable source
> citations. Work products export from the Studio/report screens.
>
> **Free trial and one purchase.** On first launch the app offers "Start free trial" (a free
> non-consumable in-app purchase that starts a 14-day trial) or "Buy now" ($79 non-consumable that
> unlocks everything for good). "Restore purchase" is on the same screen. After the trial, the main
> window shows the purchase screen; Settings (backup and export) stays usable. To test in the
> sandbox: start the trial, then buy; or buy directly. **No subscription, no other purchases.** **No model download** in this version. Minimum OS
> macOS 15.6. **By default no AI model is used**: answers are built from the person's documents by
> keyword, structured-field and document matching. AI is optional (Settings → Modules → "Use AI to
> write answers"): Apple's on-device model on macOS 26+ with Apple Intelligence, or the person's own
> cloud key in Online mode, with consent before every send.
> Workflows cite US and international instruments; procedures are jurisdiction-neutral and
> deviations are recorded on the certificate.

## Do-NOT-claim checklist (verified against this copy)

- [x] Does not claim *every* format (says "common … formats", "some with limits").
- [x] Does not claim legal admissibility (explicit "not legal advice / verify against sources").
- [x] Does not claim video understanding: speech is transcribed on-device (Apple speech recognition, English, on by default, timecoded); the app does not watch footage, identify speakers or decide what happened. Does not name Whisper — the app does not use it.
- [x] Does not claim 1 TB / unlimited scale (no scale number in copy; store page uses tested figure).
- [x] Does not claim a bundled reasoning model (says Apple on-device where supported, else deterministic).
- [x] Does not imply AI writes answers by default (says no AI writes answers unless "Use AI to write answers" is on; SHIP_DECISIONS 2026-10-24).
- [x] Does not promise judgement (no "proves", "determines guilt", "finds the truth", "solves"); says every finding is the investigator's (App Review 2.3.1, R-2 2026-10-24).
- [x] States English only for this version (SHIP_DECISIONS 2026-10-23).
- [x] Quotes no accuracy figures (measured figures live in docs/CASE_BENCH_AI_ROUNDS.md only).
- [x] Does not claim "no network" falsely (accurate: Private mode — the default — makes no connections; Online mode is opt-in, user-keyed and consented per send; no downloader).
- [x] Zero-data-collection claim is accurate (no telemetry/analytics/account exist).
