# Online mode — disclosure drafts (O-8) — FOR OWNER / LEGAL REVIEW

Status: **draft, not published.** `release/PRIVACY_POLICY.md`, `release/APP_STORE_LISTING.md` and
`docs/privacy.html` are unchanged until the owner approves this text. Online mode cannot run in
any build until the network helper target exists (O-2), so nothing here is in effect yet.

## 1. Privacy policy — new section (insert after "What stays on your Mac")

> **Online mode (optional, off by default).** Investigation Docs Made Easy starts in Private mode, in which
> nothing you add or ask ever leaves your Mac. You may switch on Online mode in Settings and enter
> your own API key for a cloud AI provider you choose (Anthropic, OpenAI or Google). In Online
> mode, when Investigation Docs Made Easy needs AI to word an answer, it shows you exactly the text it intends to
> send — passages from your documents and your question — before sending it, and sends it only if
> you agree. You can have names, email addresses, phone numbers and long identifiers replaced by
> placeholders before anything is sent. The text goes directly from your Mac to that provider,
> under your own account and that provider's terms and privacy policy; it does not pass through
> any server of ours, and we never receive it, your key or the reply. Every send is recorded on
> your Mac so you can see what left and when. Your API key is stored in your Mac's Keychain. You
> can return to Private mode at any time with one click.

## 2. App Store privacy answers

- **Data collected by the developer:** none (unchanged). The developer operates no server and
  receives nothing in either mode.
- **Data sent to third parties:** only in Online mode, only to the provider the user chooses with
  the user's own key, only after per-send consent. Answer the App Store "third-party AI" questions
  accordingly and describe the consent screen in Review Notes.

## 3. App Review notes (add)

> Investigation Docs Made Easy is fully offline by default (Private mode). Online mode is an explicit opt-in:
> the user supplies their own API key for Anthropic, OpenAI or Google Gemini. Before any text is
> sent, a consent screen shows the exact text, the destination host and its size; nothing is sent
> without the user pressing Send. Network access is confined to a bundled XPC service
> (KalsmritikoshNetworkHelper) that may only make HTTPS requests to those three hosts; the main app has
> no network entitlement. To test: Settings ▸ Modules ▸ Connection ▸ Online, enter a key, ask a
> question, and observe the consent screen.

## 4. App Store listing — sentence to add (claims registry row required)

> "Fully private by default. If you choose, connect your own cloud AI key — you'll see exactly
> what would be sent before anything leaves your Mac."

`CLAIMS_APP.md` must gain a row for this sentence in the same change that adds it to the listing
(`ci/guards/app-claims-coverage.sh`). Existing claims ("private, on-device workspace") remain
true for the default mode but should be reviewed for wording such as "always" or "never connects".

## 5. Consent screen text (as built in `OutboundConsentSheet`)

"Send to <provider>? This text will be sent to <host> (model <model>) with your own key. Nothing
else leaves your Mac." Buttons: Don't send · Send (· Send and don't ask again this session, when
"Ask before every send" is off).
