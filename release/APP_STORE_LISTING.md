# Investigations Made Easy — App Store Listing

_The ONLY paste source for App Store Connect (`APP_STORE_METADATA.md` is superseded). Updated 2026-11-04 for the candidate
`investigations-next` @ `7bb6323b`: plans and credits (owner decisions 2026-11-04), the whole-case reader with permission once per
case, offline search results, simulation-only testing (owner decision 2026-11-04). Every sentence stays inside the "Do NOT claim"
checklist at the end and the locked contract in `SHIP_DECISIONS.md`. Claim fragments registered in `CLAIMS_APP.md` are checked by
`ci/guards/app-claims-coverage.sh` — reword them only together with that file. Agent-prepared, not counsel-reviewed._

Related: privacy answers → `release/APP_PRIVACY_LABEL.md`; products → `release/IAP_SETUP.md`; owner steps →
`release/OWNER_LAUNCH_CHECKLIST.md`.

## Metadata

| Field | Value |
|---|---|
| Name (≤30) | **Investigations Made Easy** (28). The owner's full phrase "Investigation documentation made easy" opens the description. |
| Subtitle (≤30) | `Private case files, cited` (25) |
| Primary / secondary category | Productivity / Business |
| Age rating | **18+** (owner decision 2026-11-02). Questionnaire: answer honestly; "Unrestricted Web Access: **Yes**" (web capture); then set the age to 18+. Reasons: Gemini API terms require 18+, Anthropic restricts minors. |
| Seller / copyright | `© 2026 Shrabani Sasmal` — exactly the individual Apple Developer account name, everywhere (site, terms, policy, app). |
| Support email | sasmalgiri@gmail.com |
| Price | Free download; one auto-renewable subscription group (Workbench, AI Included, AI Pro) + two credit packs — `release/IAP_SETUP.md` |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` in the build (Apple OS crypto only; SHIP_DECISIONS 2026-10-17) |
| Availability | The app: all storefronts. Online AI is switched off inside the app (and refused by the relay) for App Store accounts in CHN, HKG, MAC, RUS, BLR, VEN, AFG, MMR, YEM, IRN, PRK, SYR, CUB; the app itself still works there without AI. **In those 13 storefronts only Workbench is sold**: the four AI subscriptions and both credit packs are removed from their availability in App Store Connect (`release/IAP_SETUP.md` §2–§3), and the app hides the AI plans, the packs and the own-key option there (release decisions 2026-11-04). |

**Keywords (≤100 chars):** `investigation,case,evidence,interview,exhibit,chronology,custody,hr,fraud,compliance,report,private` (99)

## URLs

- **Privacy Policy URL:** https://sasmalgiri.github.io/kalsmritikosh/privacy.html
- **Support URL:** https://sasmalgiri.github.io/kalsmritikosh/support.html
- **Marketing URL:** https://sasmalgiri.github.io/kalsmritikosh/
- **Terms of Use (EULA):** https://sasmalgiri.github.io/kalsmritikosh/terms.html — add this link at the end of the description
  (App Review 3.1.2 requires a functional EULA link in the metadata) and, optionally, as a custom EULA in App Store Connect.

## Promotional text (≤170 chars)

> Run an investigation from intake to findings on your Mac. Ask AI about a case and every statement it makes is checked against
> the exact source line. You decide.

## Description

_Plain text (App Store Connect does not render Markdown). Keep each paragraph on one line here (the claims guard matches fragments line by line). Limit 4,000 characters._

> Investigation documentation made easy.
>
> Investigations Made Easy is a private, on-device case file for investigators in HR, compliance, fraud, insurance, law, journalism and research. It organises, finds and documents; every finding is yours to make.
>
> Run the whole case: intake, triage, plan, evidence and exhibits, preservation notices, interviews, evidence for and against each allegation, your finding and closure — all in the case log.
>
> Point it at your folders of documents and email. It builds a structured record — people, dates, events, facts — and answers your questions citing the exact source passages. When no passage supports an answer, it says so and shows the closest passage. Answers can still be incomplete or wrong — check the cited source.
>
> Ask AI about a case — with your permission, once per case. With an AI plan or your own Anthropic key, Claude can read a whole case. The first time, the app lists which documents would go to Anthropic and which would not (privileged material never does), with the estimated cost; you are asked again when they change. Every AI statement is checked against the exact source line it cites before you see it; what cannot be matched is left out. The investigator decides.
>
> Private by design. The app itself has no network access, and the knowledge base is encrypted on disk. No account, no sign-in, no analytics. Without AI, nothing leaves your Mac and Ask returns the matching passages with a link to the source. With an AI plan or your own Anthropic key, the documents of a case you allow go to Anthropic (recordings you transcribe to Google).
>
> • Cases, interviews, exhibits, holds, redaction log, chronology and an append-only case log
> • Documents, email (including Outlook MSG and PST), chat exports, Cellebrite reports, scans and recordings
> • Search and ask across everything — answers come with clickable citations
> • Timelines, contradictions and gaps between documents; follow the money with sources
> • Cited case reports, exhibit lists, custody reports and statements to export
> • Optional Online lookups: exchange rates, sanctions, registries, court records, transcription
>
> Plans (auto-renewing; your storefront's price is shown in the app):
> • Workbench $4.99/month or $39.99/year — every feature on your Mac, no AI of ours; optional Online AI with your own Anthropic key, billed by Anthropic. Eligible new subscribers can try every Workbench feature free for 14 days (no AI credits), then the Workbench price.
> • AI Included $39/month or $389.99/year — Workbench plus 2,000 AI credits a month.
> • AI Pro $99/month (6,000 AI credits a month) or $989.99/year (5,400 a month) — Workbench plus larger whole-case reads.
> • 1 credit = US$0.01 of AI cost; each request is charged what it actually cost. A case's first read costs about 1–2 credits per 1,000 words; a question within an hour of the last usually 5–30. Credit packs of 500 ($9.99) or 2,000 ($34.99) never expire. No trial on the AI plans. Where Online AI is not offered, only Workbench is sold.
>
> Payment is charged to your Apple Account. Subscriptions renew automatically unless cancelled at least 24 hours before the period ends; manage or cancel in your Apple Account settings. When a plan ends, your cases stay readable and exportable.
>
> No AI writes your answers unless you turn it on. After buying an AI plan or saving your Anthropic key, one step turns it on: "Allow AI to read case documents you permit". AI answers need macOS 26 or later.
>
> English only in this version; other languages are kept and keyword-searchable, but names and dates in them may be missed.
>
> An investigation aid for adults (18+). It organises and cites your evidence; it does not decide findings, guilt or outcomes — you do. AI output can be incomplete or wrong; verify against the cited originals. Not legal, financial or professional advice.
>
> Terms of Use: https://sasmalgiri.github.io/kalsmritikosh/terms.html · Privacy: https://sasmalgiri.github.io/kalsmritikosh/privacy.html

## What's New (version 1.0)

> First release. Cases from intake to findings, cited answers, chronology, contradictions and gaps; optional AI with your
> permission once per case, every AI statement checked against its source line; Workbench, AI Included and AI Pro plans.

## Subscription disclosure (App Review 3.1.2) — what the in-app paywall and the description must both state

The paywall (`Kalsmritikosh/UI/PurchaseGate.swift`) shows StoreKit's own localized prices; the copy below is the reference text.

- **Title and period of each plan:** Workbench monthly / yearly; AI Included monthly / yearly; AI Pro monthly / yearly.
- **Price per period (US):** Workbench $4.99 / month, $39.99 / year; AI Included $39 / month, $389.99 / year; AI Pro $99 / month,
  $989.99 / year; packs $9.99 / $34.99. **India** (set in App Store Connect; Apple's storefront prices include GST): Workbench
  ₹249 / ₹1,999; AI Included ₹3,499 / ₹34,999; AI Pro ₹8,999 / ₹89,999; packs ₹899 (500) / ₹2,999 (2,000). The monthly AI
  prices assume Apple's rounded US points $39.00 / $99.00 exist (owner check, `release/IAP_SETUP.md` §6).
- **What each includes:** Workbench — all personas and jobs, no AI of ours, Online AI with your own Anthropic key (billed by
  Anthropic). AI Included — Workbench + 2,000 AI credits a month. AI Pro — Workbench + 6,000 AI credits a month (AI Pro yearly: 5,400 a month) + larger
  whole-case reads (up to 3,000 credits per confirmed read vs 600). AI Included yearly gets the same 2,000 credits every month.
- **Free trial:** Workbench only, 14 days, for eligible new subscribers; then the chosen Workbench price. The AI plans have none.
- **Credits:** 1 credit = US$0.01 of Claude cost at Anthropic's published rates; each request is charged its actual cost rounded
  up (at least 1), a failed request costs nothing; the estimate is shown before a whole-case read; one request ≤ 400 credits; a
  daily limit applies (1,500 AI Included / 4,000 AI Pro). Monthly credits reset on the purchase day and do not carry over.
- **Credit packs:** 500 credits $9.99, 2,000 credits $34.99, consumable, **never expire**, used after the month's credits while
  an AI plan is active; a refunded pack's remaining credits are removed.
- **Auto-renewal and cancellation:** renews automatically unless cancelled at least 24 hours before the period ends; manage or
  cancel in the Apple Account (System Settings ▸ your name ▸ Media & Purchases ▸ Subscriptions, or App Store ▸ your name ▸
  Subscriptions). Moving up takes effect at once; moving down at the next renewal. 3-day billing grace.
- **Links shown on the paywall:** Terms of Use (EULA) and Privacy Policy; Restore purchases; Manage subscription.

## Screenshots to capture (2880×1800 or 1440×900; demo data only — no real PII)

Use `Resources/Fixtures/ProjectDelta` (synthetic) or the public-domain packs in `KalsmritikoshTests/Fixtures/InvestigationCases`.

1. **Home / "What are you investigating?"** — the first-run question that opens a persona with a case ready.
2. **Case file** — the case's documents with custody hashes and the chronology.
3. **Ask in a case with AI** — an answer whose every statement links to its source line (quality strip visible).
4. **The once-per-case permission sheet** — "Let the AI read this case?" with the documents sent / not sent and the estimate.
5. **Contradictions & gaps** — two sources that disagree, both cited.
6. **Findings report** — sections with claims, every sentence linked to its source.
7. **Plans** — the paywall with Workbench / AI Included / AI Pro, prices, the trial line and the credit packs.
8. **Offline search results** — Ask with AI off: matching passages with the question's words in bold and "Open source".

Optional: Settings ▸ Online with the credit meter; "What was sent" log.

## App Review notes (paste into App Review Information ▸ Notes)

> Investigations Made Easy is investigation documentation software for adults (18+). It keeps every source of an
> investigation with custody, builds the chronology, finds contradictions and gaps, and produces a report where every
> sentence points at its source. Judgement stays human: the app never decides guilt, privilege, credibility or root cause.
> No account or sign-in. The main app has no network entitlement; the knowledge base is encrypted at rest.
>
> 1. QUICK LOOK WITHOUT AI (no purchase needed for the sample): on the subscription screen choose "Try a sample case" (or
>    Help ▸ tutorial). Open the sample case, then Ask a question (e.g. "Who was charged and with what?"). With AI off the
>    answer is "Search results for …": matching passages, words in bold, "Open source" opens the cited document.
>
> 2. SUBSCRIBE (Sandbox account): the paywall shows Workbench (14-day free trial), AI Included and AI Pro, monthly and
>    yearly, at storefront prices, with Restore purchases, Manage subscription, Terms and Privacy links.
>
> 3. AI INCLUDED (the publisher pays): buy AI Included monthly with the Sandbox account. Right after the purchase the app
>    shows "Turn on AI for your AI plan" with the AI's terms and where documents go (Anthropic, through the publisher's
>    relay). Choose "Allow AI to read case documents you permit". This one step turns on Online mode, "Use AI to write
>    answers" and AI reading of case documents, and records the terms acceptance — no other setting is needed. (If you
>    chose "Not now": Ask shows search results that name the missing step, with a "Turn on AI…" button; or Settings ▸
>    Online ▸ "Turn on AI…".) Settings ▸ Online ▸ "Check credits" shows 2,000 credits.
>    Requests go to the publisher's relay (Cloudflare Worker, <RELAY HOST>), which verifies the subscription with the App
>    Store Server API (Sandbox transactions are accepted), reserves the request's worst-case cost in credits, forwards to
>    Anthropic (Claude Opus 5) — or, for recordings, Google Gemini — under the publisher's own key, and charges the actual
>    cost. The relay stores counts and credits only, never content. Your review usage runs on the publisher's key under a
>    hard monthly safety cap (US$20 at launch); if it were reached, the app says the service is paused until the 1st.
>
> 4. THE PERMISSION SHEET (Guideline 5.1.2(i)): open a case (the sample case or a new case with a few documents) and Ask
>    a question. The first AI use in that case shows "Let the AI read this case?": exactly which documents go to Anthropic,
>    which do not and why (e.g. privileged), size, and the estimate in credits. "Allow for this case" sends; "Not now" sends
>    nothing and returns search results. You are asked again only if the case's documents change. The answer's statements
>    are each checked against the source line they cite; everything sent is listed in Settings ▸ Online ▸ What was sent.
>
> 5. CREDIT PACKS: Settings ▸ Online ▸ "Buy 500 credits" (consumable, never expires), usable while an AI plan is active.
>
> 6. OWN KEY (Workbench): with Workbench, Settings ▸ Online ▸ "Claude (Anthropic)" — the only own-key provider — paste an
>    Anthropic API key (Keychain) and choose "Save key"; the same one-step sheet appears ("Allow AI to read case documents
>    you permit").
>    The same permission sheet appears, with the estimate in dollars; requests go directly from the Mac to api.anthropic.com.
>    We do not provide a key for this path.
>
> Network access is confined to the bundled, sandboxed extension KalsmritikoshNetworkHelper: HTTPS POST only to
> api.anthropic.com (own key) and the relay (AI plans), and HTTPS GET only to five public-record sources (data-api.ecb.europa.eu,
> sanctionslistservice.ofac.treas.gov, scsanctions.un.org, api.gleif.org, www.courtlistener.com) or a page the user asks to
> capture. Online AI is switched off for App Store accounts in CN, HK, MO, RU, BY, VE, AF, MM, YE, IR, KP, SY, CU, and only
> Workbench is sold there (no AI plan, no credit pack, no own-key setup).
> Minimum macOS 15.6. Contact: Shrabani Sasmal, sasmalgiri@gmail.com.

_Before pasting: replace `<RELAY HOST>` with the deployed host (OWNER_LAUNCH_CHECKLIST step 6). If the relay is not deployed,
do NOT attach the AI plans or packs to the submission and delete steps 3–5 (Guideline 2.1: IAPs must be testable)._

## Do-NOT-claim checklist (verified against this copy, 2026-11-04)

- [x] No accuracy percentages, no "solves cases", no "proves", "finds the truth", "determines guilt"; the investigator decides (2.3.1).
- [x] Says the app is an investigation aid and AI output can be wrong; not legal, financial or professional advice.
- [x] "Every AI statement is checked against the exact source line it cites" — registered (`asc.ai-checked`, CLAIMS_APP.md);
      it says checked, not "correct".
- [x] Does not claim every format, legal admissibility, video understanding, a scale number, or a bundled reasoning model.
- [x] Does not imply AI by default; English only stated.
- [x] Does not claim "no network" falsely: default on-device; Online mode, AI plans and own keys are opt-in with a permission sheet.
- [x] No zero-data-collection claim; the privacy label declares the AI sends and the relay's counts.
- [x] States each plan's price, period, content, credits, that packs never expire (3.1.1), that only Workbench has a trial, and
      auto-renew/cancel terms (3.1.2); no free AI anywhere.
