# Investigations Made Easy — App Store Listing (draft)

_Draft copy + review notes for App Store Connect (REL-005). Owner fills the bracketed items,
adds screenshots, and submits. Every claim below is deliberately kept within the "Do NOT claim"
list of the release spec (§6) and the locked contract in `SHIP_DECISIONS.md`. Last reviewed
2026-10-24 (R-2 App Review 2.3.1 pass: evidence-only answers by default, English only, no judgement promised);
updated 2026-11-02 for AI Included, the Online tools, 18+ and the agent legal review (`docs/agent-reviews/legal-privacy.md`).
This file is the ONLY paste source for App Store Connect; `APP_STORE_METADATA.md` is superseded._

## Metadata

- **Name:** Investigations Made Easy
- **Subtitle (≤30 chars):** `From evidence to findings`
- **Name note:** App Store names are limited to 30 characters, so the owner's full name "Investigation documentation made easy" (37) ships as **Investigations Made Easy** (28); the full phrase opens the description and the website (owner decision 2026-10-18).
- **Category:** Productivity (secondary: Reference)
- **Age rating:** **18+** (owner decision 2026-11-02): Google's Gemini API requires users 18+, Anthropic restricts minors, and the web-capture tool gives unrestricted web access. In the questionnaire answer "Unrestricted Web Access: Yes" and set the age to 18+.
- **Seller / copyright:** Shrabani Sasmal (the individual Apple Developer account; owner decision 2026-11-02) — the same name on the website, terms, privacy policy and in the app.
- **Price:** **Free download; all nine personas; one auto-renewable subscription group with three levels** (owner decisions 2026-11-04; supersedes 2026-10-30/11-02). Create in App Store Connect, all in ONE group (levels from the top):
  1. **AI Pro** — `ecosanskritiinnovation.Kalsmritikosh.aipro.monthly` US $99 · `…aipro.annual` US $989. 6,000 AI credits a month (yearly: the same every month), larger whole-case read. NO introductory offer.
  2. **AI Included** — `ecosanskritiinnovation.Kalsmritikosh.ai.monthly` US $39 · `…ai.annual` US $389. 2,000 AI credits a month. NO introductory offer.
  3. **Workbench** — `ecosanskritiinnovation.Kalsmritikosh.edition.monthly` US $4.99 / ₹249 · `…edition.annual` US $39.99 / ₹1,999 (verify the price points; never substitute silently). **14-day free introductory offer** (the only plan with one). Online AI with the user's own Anthropic key.
  Consumables: `ecosanskritiinnovation.Kalsmritikosh.ai.credits500` US $9.99 (500 credits) and `…ai.credits2000` US $34.99 (2,000 credits) — **never expire**, usable with an AI plan. 3-day billing grace. Family Sharing not advertised. No legacy products (no earlier buyers: `…unlock` and `…trial14` are not created; `…ai.topup200` is not created). Set AI-plan prices in other storefronts (incl. India) yourself; the app shows whatever the storefront returns. Attach the AI plans and packs to the submission ONLY once the relay is deployed and its address is in the build (`AIIncludedRelay.host`); otherwise leave them unattached. App Store Server Notifications V2 URL: `<relay>/v1/apple-notifications`.
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
> If you choose, turn on AI — Apple's on-device model, AI Included, or your own cloud AI key — and
> you see exactly what would be sent before anything leaves your Mac.
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
> • Online tools (optional): exchange rates at a date from the European Central Bank, sanctions-list checks searched on your Mac, company-registry and court-record lookups, web-page capture with a timestamped record, and recording transcription with speaker labels.
> • AI helps (optional, Online): read a scan your Mac could not, translate a document into English, challenge an answer, or draft a cited report paragraph — always marked as AI output.
>
> **Workbench: try every paid feature free for 14 days, then $4.99 a month or $39.99 a year (your storefront's price is shown in the app), renewing automatically unless cancelled.** Online AI uses your own Anthropic key, billed by Anthropic, with the cost estimated before each send and a monthly limit you set. Cancel any time; your cases stay readable and exportable.
>
> **AI Included** ($39 a month or $389 a year) and **AI Pro** ($99 a month or $989 a year) add 2,000 or 6,000 AI credits a month for Claude Opus 5 — no AI account of your own. 1 credit = US$0.01 of AI cost; each request is charged what it actually cost, and a whole-case read shows its estimate first. Credit packs of 500 ($9.99) or 2,000 ($34.99) never expire. No free trial on the AI plans. If the service's monthly capacity is reached it pauses until the 1st, nothing is charged, and everything else keeps working. Not available in every country.
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

## Privacy nutrition labels — agent determination 2026-11-02 (agent review, not counsel; owner direction 2026-11-01)

Answer in App Store Connect ▸ App Privacy: **"Yes, we collect data"**, with exactly these types (no tracking for any):

| Data type | Linked to the user? | Purpose | Why |
|---|---|---|---|
| User Content ▸ Other User Content (questions, document passages) | No | App Functionality | AI Included sends approved text through the relay to Anthropic / Google, which may keep it up to 30 days |
| User Content ▸ Emails or Text Messages (passages from mail and chats) | No | App Functionality | same path, when the passages come from email or messages |
| User Content ▸ Photos or Videos (page images, video recordings) | No | App Functionality | Read with AI and transcription of video |
| User Content ▸ Audio Data (recordings) | No | App Functionality | transcription through AI Included (Gemini) |
| Identifiers ▸ User ID (the AI plan subscription's App Store transaction number) | Yes | App Functionality | the relay keeps it with the month's and day's credit counts |
| Purchases ▸ Purchase History (AI plan subscription and credit packs) | Yes | App Functionality | the relay verifies them with Apple and keeps credit-pack records (balance) |
| Usage Data ▸ Product Interaction (questions used this month) | Yes | App Functionality | the relay's counts |

`Kalsmritikosh/PrivacyInfo.xcprivacy` declares the same seven types; `docs/DISTRIBUTION_PACK.md` §1 and
`docs/privacy.html` give the reasoning and the user-facing text. Private mode, the default, sends nothing.

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
> **Online mode (optional, off by default).** Settings ▸ Modules ▸ Connection ▸ Online, then Settings ▸
> Online: **AI Included / AI Pro** (the AI plans' monthly credits) or the user's own API key for Anthropic, OpenAI or Google Gemini.
> Before anything is sent, a consent screen shows the exact text (and any page image or recording), the
> destination and its size; nothing is sent unless the user presses Send, and every send is recorded in
> Settings ▸ Online ▸ What was sent. Network access is confined to the bundled, sandboxed extension
> KalsmritikoshNetworkHelper: HTTPS POST only to the AI providers and the AI Included relay, and HTTPS GET only
> to five public-record sources (data-api.ecb.europa.eu, sanctionslistservice.ofac.treas.gov, scsanctions.un.org,
> api.gleif.org, www.courtlistener.com) or a page the user asks to capture; the main app has no network
> entitlement. **AI Included** sends approved requests through the publisher's relay (Cloudflare Worker), which
> checks the subscription with the App Store Server API, reserves the request's worst-case cost in credits, forwards to
> Anthropic (Claude Opus 5) or, for recordings, Google Gemini under the publisher's account, and charges the actual
> cost; it keeps only counts and credits. Credit packs (consumables) never expire and are kept by the relay per subscription. Online AI is switched off for
> App Store accounts in CN, HK, MO, RU, BY, VE, AF, MM, YE, IR, KP, SY, CU (the providers' supported-country lists).
> To test: switch to Online, choose a provider, ask a question, and observe the consent screen.
> **Online tools** (Sources ▸ Online tools…): exchange rate, sanctions lists (downloaded and searched on the Mac),
> company registry, court records, web capture, transcription — each previewed before it is sent.
>
> **To demo:** launch → Sources → add the included demo folder (or any folder of documents) →
> "Ingest All" → open **Ask** and enter a question → the answer appears with clickable source
> citations. Work products export from the Studio/report screens.
>
> **Subscription.** On first launch the app shows the subscription screen with the three plans (Workbench,
> AI Included, AI Pro), each monthly and yearly, what each includes, the credit packs, at the storefront's own
> prices, Workbench's 14-day free trial for eligible accounts (StoreKit decides
> eligibility), the price and period that follow, automatic renewal, how to cancel (at least a day
> before the period ends, in the Apple Account), Restore purchases and Manage subscription. Help, the
> isolated sample case and backup/recovery are reachable from that screen without subscribing. After a
> plan ends, cases stay readable and exports, backups, recovery, Help and privacy controls keep working;
> only creating, editing and analysing ask for a plan. To test in the sandbox: subscribe to either plan
> (the trial applies once per account), upgrade to an AI plan (one subscription, immediate), cancel, let it
> lapse, restore. **No model download** in this version. Minimum OS
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
- [x] Does not claim "no network" falsely (accurate: Private mode — the default — makes no connections; Online mode is opt-in and consented per send).
- [x] Makes no zero-data-collection claim (AI Included sends approved content to providers; the label declares it). No telemetry, analytics or account exist.
- [x] States the AI plans' credits (2,000 / 6,000 a month, 1 credit = US$0.01 of AI cost), that packs never expire (App Review 3.1.1), that only Workbench has a free trial, and that the service can pause at its monthly capacity (App Review 3.1.2(c): what each plan includes).
