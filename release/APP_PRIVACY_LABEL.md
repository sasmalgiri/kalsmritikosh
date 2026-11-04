# App Privacy ("nutrition label") answers — Investigations Made Easy v1

_Prepared 2026-11-04 by an agent (not counsel) for candidate `investigations-next` @ `7bb6323b`. The owner enters these in
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
- **Own key (Workbench or any plan):** content goes from the Mac directly to the person's own Anthropic / Gemini account. That is
  not collection by the developer or its partners and need not be declared; it is covered anyway because the same types are
  declared for the AI plans (conservative and harmless).
- **Third-party AI is not a separate category** in the questionnaire: it is declared through the data types sent (User Content),
  and App Review 5.1.2(i) is met in the app by the once-per-case permission sheet plus the privacy policy's disclosure.
- **The relay** (Cloudflare Worker, publisher-operated) keeps, per AI subscription: the App Store original transaction number,
  credits used per month and per day, credit packs bought and remaining, plus the service's total spend. → User ID, Purchase
  History and Product Interaction, **linked** (the transaction number is an account-level identifier).
- **Apple's own purchase processing** (StoreKit, payment, receipts) is Apple's and is not declared by the developer; the
  developer declares only what its relay keeps.
- **Diagnostics:** MetricKit payloads stay on the Mac (`App/Diagnostics/DiagnosticsReporter.swift`); the person may choose to email
  them from their own Mail app. No crash, analytics or telemetry SDK. → **not collected** (see owner decision 2).
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
  Functionality — **matches** the table.
- `docs/privacy.html` names the same recipients (Anthropic, Google, the relay on Cloudflare, Apple), the once-per-case permission,
  what is never sent, the relay's counts-only storage and retention (13 months / 40 days / packs while credits remain + 25 months).

## Owner decisions still needed

1. **Confirm "not linked" for content.** Defensible because the relay strips the transaction number before forwarding and stores
   no content, and Anthropic/Google see only the publisher's account. If counsel prefers the cautious reading (the relay sees
   content and the transaction number together in transit), switch the four User Content rows to *Linked* — no other change.
2. **Diagnostics by email.** Apple's optional-disclosure rule covers infrequent, user-initiated support data. If you plan to use
   emailed MetricKit reports beyond answering that person, declare Diagnostics ▸ Crash Data / Performance Data, not linked.
3. **Own-key OpenAI.** The build still offers OpenAI as an own-key provider for question wording only (no document text). Nothing
   to declare (the person's own account), but decide whether to keep it given the "own Anthropic key" positioning.
4. **Age rating 18+** (owner decision 2026-11-02) is set in the age-rating questionnaire, not here; answer "Unrestricted Web
   Access: Yes" (web capture) and choose 18+.
