# App Privacy ("nutrition label") answers — Investigations Made Easy v1

_Prepared 2026-11-04 by an agent (not counsel) for candidate `investigations-next` @ `7bb6323b`; updated the same day with the
owner's accepted release decisions (item 5: content not linked, App Functionality; no Diagnostics; own key = Anthropic only). The owner enters these in
App Store Connect ▸ the app ▸ **App Privacy**. Source of truth for what the build does: `Kalsmritikosh/PrivacyInfo.xcprivacy`
(the same seven types), `docs/privacy.html`, `relay/src/store.ts` + `relay/schema.sql` (what the relay keeps), and the agent
legal review `docs/agent-reviews/legal-privacy.md` (S1). This file supersedes the label table in `APP_STORE_LISTING.md`._

## How Apple's definitions apply here

- Apple counts data as **collected** when it leaves the device so that the developer **or its third-party partners** can
  access it for longer than needed to service the request in real time. Data that stays on the Mac is not collected.
- **AI plans (AI Included, AI Pro):** a case's documents and questions (after the person allows it for that case) and recordings
  for transcription go from the Mac through the publisher's relay to **Anthropic** (Claude) or **Google** (Gemini) under the
  publisher's accounts. Anthropic and Google are the developer's third-party partners and keep inputs for a period under their
  commercial terms (Anthropic: up to 30 days by default) → **collected**. The relay forwards no user identifier and stores no
  content, and the providers see only the publisher's account → **not linked** to the user.
- **Own key (Workbench or any plan):** content goes from the Mac directly to the person's own Anthropic account (Anthropic is the
  only own-key provider; OpenAI and Gemini are not offered for answering, and recordings go to Gemini only through the relay). That is
  not collection by the developer or its partners and need not be declared; it is covered anyway because the same types are
  declared for the AI plans (conservative and harmless).
- **Third-party AI is not a separate category** in the questionnaire: it is declared through the data types sent (User Content),
  and App Review 5.1.2(i) is met in the app by the once-per-case permission sheet plus the privacy policy's disclosure.
- **The relay** (Cloudflare Worker, publisher-operated) keeps, per AI subscription: the App Store original transaction number,
  credits used per month and per day, credit packs bought and remaining, plus the service's total spend. → User ID, Purchase
  History and Product Interaction, **linked** (the transaction number is an account-level identifier).
- **Apple's own purchase processing** (StoreKit, payment, receipts) is Apple's and is not declared by the developer; the
  developer declares only what its relay keeps.
- **Diagnostics — not declared (owner decision 2026-11-04):** MetricKit payloads stay on the Mac
  (`App/Diagnostics/DiagnosticsReporter.swift`) and are never sent automatically. Diagnostics are shared only if the person
  chooses to email them from their own Mail app — an optional, user-initiated act, used only to answer that person. No crash,
  analytics or telemetry SDK. → **not collected**; no Diagnostics type in the label or in `PrivacyInfo.xcprivacy`.
- **Tracking:** none. No advertising, no data broker, no cross-app linking, no IDFA/AdServices. Answer **No** for every type.

## Answers to enter

"Do you or your third-party partners collect data from this app?" → **Yes, we collect data from this app.**

| Category ▸ Data type | Collected | Linked to the user | Used for tracking | Purposes | What it is |
|---|---|---|---|---|---|
| User Content ▸ Other User Content | **Yes** | No | No | App Functionality | Questions and case documents/passages sent to Anthropic (AI plans: via the relay) after the person allows it |
| User Content ▸ Emails or Text Messages | **Yes** | No | No | App Functionality | The same, when the case documents are emails or chat messages |
| User Content ▸ Photos or Videos | **Yes** | No | No | App Functionality | Page images ("Read with AI") and video recordings sent for transcription |
| User Content ▸ Audio Data | **Yes** | No | No | App Functionality | Recordings sent to Google Gemini for transcription |
| Identifiers ▸ User ID | **Yes** | **Yes** | No | App Functionality | The AI subscription's App Store original transaction number, the relay's key for credit counts |
| Purchases ▸ Purchase History | **Yes** | **Yes** | No | App Functionality | The relay verifies the AI plan with Apple and keeps credit-pack records and balances |
| Usage Data ▸ Product Interaction | **Yes** | **Yes** | No | App Functionality | Credits used per month and per day |
| Contact Info (all) | No | — | — | — | No account; the relay receives no name, email or Apple ID |
| Health & Fitness, Financial Info, Contacts, Sensitive Info | No | — | — | — | Case content may incidentally contain such data; it is covered under User Content |
| Location (precise, coarse) | No | — | — | — | Storefront from StoreKit; the relay reads Cloudflare's request country only to refuse blocked countries and does not keep it |
| Browsing History, Search History | No | — | — | — | Web capture runs from the person's Mac; questions are declared as Other User Content |
| Identifiers ▸ Device ID | No | — | — | — | — |
| Usage Data ▸ Advertising Data, Other Usage Data | No | — | — | — | — |
| Diagnostics (crash, performance, other) | No | — | — | — | MetricKit stays on the Mac; emailing it is the person's own act |
| Other Data | No | — | — | — | — |

For each "Yes" row Apple then asks per purpose: choose **App Functionality** only; "Is this data linked to the user's identity?"
as in the table; "Do you or your third-party partners use this data for tracking?" → **No**.

## Consistency checks (done 2026-11-04)

- `Kalsmritikosh/PrivacyInfo.xcprivacy` `NSPrivacyCollectedDataTypes`: OtherUserContent, AudioData, PurchaseHistory (linked),
  EmailsOrTextMessages, PhotosorVideos, UserID (linked), ProductInteraction (linked), all tracking false, purpose App
  Functionality, **no Diagnostics type** — **matches** the table (re-checked after the release decisions; the manifest's comment
  records owner decision item 5).
- `docs/privacy.html` names the same recipients (Anthropic, Google, the relay on Cloudflare, Apple), the once-per-case permission,
  what is never sent, the relay's counts-only storage and retention (13 months / 40 days / packs while credits remain + 25 months).
- `docs/privacy.html` says Anthropic is the only own-key provider, that inside a case the person allowed their questions are sent
  without a further prompt, and that diagnostics stay on the Mac unless the person emails them.

## Owner decisions (accepted 2026-11-04)

1. **Content sent to AI: collected, not linked to identity, not used for tracking, purpose App Functionality** (the four User
   Content rows above). Basis: the relay strips the transaction number before forwarding and stores no content; Anthropic and
   Google see only the publisher's account. If counsel later prefers the cautious reading (the relay sees content and the
   transaction number together in transit), switch the four User Content rows to *Linked* in both places — this file and
   `Kalsmritikosh/PrivacyInfo.xcprivacy` — no other change.
2. **No Diagnostics declaration.** MetricKit stays on the Mac; diagnostics are shared only if the person chooses to email them.
   If emailed reports are ever used beyond answering that person, declare Diagnostics ▸ Crash Data / Performance Data, not
   linked, in both places.
3. **Own key = Anthropic only.** OpenAI and Gemini are no longer offered as answering providers (Settings shows Claude
   (Anthropic) and, with a plan, the AI plans); a stored OpenAI/Gemini choice migrates to "not set up" with a notice. The network
   helper's AI hosts are `api.anthropic.com` and the relay only. Nothing to declare for the own key (the person's own account).
4. **Age rating 18+** (owner decision 2026-11-02) is set in the age-rating questionnaire, not here; answer "Unrestricted Web
   Access: Yes" (web capture) and choose 18+.
