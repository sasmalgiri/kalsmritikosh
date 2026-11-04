# Owner launch checklist — Investigations Made Easy v1 (Mac App Store)

_Prepared 2026-11-04 by an agent. Every step here needs the owner (Apple account, money, signing, legal acceptance) — the agent
cannot do them. Do them in this order; each step says where to click or what to type. Testing is simulation-only by owner
decision 2026-11-04 (no paid live testing); the owner funds US$20 on the relay's Anthropic key for Apple's reviewer._

Names used everywhere: seller / publisher / copyright **Shrabani Sasmal** (individual account) · support **sasmalgiri@gmail.com** ·
bundle ID `ecosanskritiinnovation.Kalsmritikosh` · repository `github.com/sasmalgiri/kalsmritikosh` (public).

---

## 1. Apple Developer Program (individual)

1. https://developer.apple.com/programs/enroll/ ▸ sign in with the Apple Account of **Shrabani Sasmal** ▸ enrol as
   **Individual** ▸ pay the annual fee. The App Store "Seller" will be the legal name on this account — it must read
   exactly "Shrabani Sasmal".
2. **Verify the Team ID** (release decision 2026-11-04, item 7): developer.apple.com ▸ Account ▸ **Membership** (Membership
   details) for **Shrabani Sasmal**'s account, and note the Team ID shown there. The project and `StoreKit/Kalsmritikosh.storekit`
   currently carry **`6TPTCJD42Q`**. **If Shrabani's Team ID differs from `6TPTCJD42Q`, tell the agent before archiving** — the
   signing team of every target and the App Group (`6TPTCJD42Q.ecosanskritiinnovation.Kalsmritikosh`, used by the app and its Share
   extension) must change with it. Do not change the project yourself; the agent was told not to change it until you confirm.

## 2. Agreements, tax and banking

1. https://appstoreconnect.apple.com ▸ **Business** (Agreements, Tax, and Banking) ▸ **Paid Apps** ▸ Review and accept.
2. **Bank account:** add the account in Shrabani Sasmal's name (IFSC / SWIFT for an Indian account).
3. **Tax forms:** U.S. Form **W-8BEN** (individual, India resident; claim the India–US treaty, Article 12) — and any other forms
   the page lists for your storefronts.
4. **Contacts:** Senior Management, Finance, Technical, Legal — all may be Shrabani Sasmal / sasmalgiri@gmail.com.
5. Wait until the Paid Apps agreement shows **Active** (can take a day or more). Subscriptions cannot be sold before that.

## 3. App Store Small Business Program (15 % commission)

https://developer.apple.com/app-store/small-business-program/ ▸ **Enroll** (Account Holder, after the Paid Apps agreement is
accepted) ▸ declare no associated developer accounts ▸ submit. Takes effect from the next fiscal month after approval.

## 4. App record and products

1. App Store Connect ▸ **Apps** ▸ **+** ▸ New App ▸ Platform **macOS** ▸ Name **Investigations Made Easy** ▸ Primary language
   English (U.S.) ▸ Bundle ID `ecosanskritiinnovation.Kalsmritikosh` (register it first under Certificates, Identifiers &
   Profiles ▸ Identifiers if it is not offered; enable **App Groups** and **In-App Purchase**) ▸ SKU `kalsmritikosh-mac-1`.
2. **App Information:** category Productivity / Business; **Content Rights:** "contains third-party content" → Yes, you have
   the rights (MIT-licensed BGE models; public-domain sample cases); **Age Rating:** fill the questionnaire honestly
   ("Unrestricted Web Access: Yes"), then choose **18+**.
3. **Pricing and Availability:** Free; all territories (Online AI switches itself off in the 13 blocked storefronts, and only
   Workbench is sold there — see step 4).
4. **Subscriptions and credit packs:** follow `release/IAP_SETUP.md` §1–§3 exactly (six subscriptions in one group with
   levels, Workbench's 14-day free intro offer only, two consumables, 3-day billing grace, Family Sharing off). Prices (release
   decisions 2026-11-04): US Workbench $4.99 / $39.99, AI Included $39 / **$389.99**, AI Pro $99 / **$989.99**, packs $9.99 /
   $34.99; **India overrides** Workbench ₹249 / ₹1,999, AI Included ₹3,499 / ₹34,999, AI Pro ₹8,999 / ₹89,999, packs ₹899 /
   ₹2,999 (Apple's storefront prices include GST). **Confirm in the price picker that $39.00 and $99.00 exist** as US points
   (IAP_SETUP §6.1); if not, tell the agent which points you chose.
   **Remove the 13 AI-blocked storefronts** — CHN, HKG, MAC, RUS, BLR, VEN, AFG, MMR, YEM, IRN, PRK, SYR, CUB — from the
   **availability of the four AI subscriptions and both credit packs** (each product ▸ Availability). Leave Workbench available.
   The app already hides the AI plans, the packs and the own-key option for App Store accounts of those countries.
5. **In-App Purchase key** for the relay: `release/IAP_SETUP.md` §5 (download the `.p8` once; note Key ID and Issuer ID).
6. **App Privacy:** enter the answers in `release/APP_PRIVACY_LABEL.md`; Privacy Policy URL
   `https://sasmalgiri.github.io/kalsmritikosh/privacy.html`.

## 5. Deploy the relay (Cloudflare) and fund the reviewer's usage

In Terminal, in the repository's `relay/` folder (Node ≥ 23.6 for the tests):

```
cd relay
npm test                                   # expect: pass 19, fail 0
npx wrangler login                         # free Cloudflare account
npx wrangler d1 create kals-relay          # copy the printed database_id into wrangler.toml
npm run db:init
npx wrangler secret put ANTHROPIC_API_KEY  # console.anthropic.com ▸ API Keys ▸ Create key (publisher's account)
npx wrangler secret put GEMINI_API_KEY     # aistudio.google.com ▸ API key in a billing-enabled project
npx wrangler secret put APPLE_ISSUER_ID
npx wrangler secret put APPLE_KEY_ID
npx wrangler secret put APPLE_PRIVATE_KEY  # paste the whole .p8
npx wrangler secret put GLOBAL_CAP_USD     # type: 20  (keep 20 until Apple approves the app — see step 12)
npm run deploy                             # note the address: https://kals-ai-relay.<you>.workers.dev
curl https://kals-ai-relay.<you>.workers.dev/v1/sellable   # expect {"sellable":true}
```

- **Anthropic money:** console.anthropic.com ▸ **Billing** ▸ buy **US$20** of credit; turn **auto-reload off**; ▸ **Limits** ▸
  monthly spend limit **US$20**. The relay stops new AI work at 90 % of `GLOBAL_CAP_USD` (US$18), so the console limit is the
  last backstop.
- **Gemini (transcription):** a billing-enabled Google Cloud project with a **US$5 budget alert** (`GEMINI_BUDGET_USD = 5` in
  `wrangler.toml`). If you do not want to fund Gemini, leave `GEMINI_API_KEY` unset: transcription on an AI plan then fails with
  a clear message (decision: say so in the review notes).
- **Server Notifications:** App Store Connect ▸ the app ▸ App Information ▸ App Store Server Notifications ▸ Production and
  Sandbox URL `https://kals-ai-relay.<you>.workers.dev/v1/apple-notifications`, **Version 2**.

## 6. Put the relay host into the app

The host (without `https://`, e.g. `kals-ai-relay.<you>.workers.dev`) is written in **two** places, which must match:

- `Kalsmritikosh/Routing/Providers/Online/AIIncludedRelay.swift` — `public static let host = ""`
- `KalsmritikoshNetworkHelper/KalsmritikoshNetworkHelper.swift` — `static let relayHost = ""`

Either give the address to the agent, or edit both lines yourself, then run `bash ci/guards/relay-host-match.sh` (expect
`ok: relay host identical …`) and commit. This is a product-code change: it makes a **new candidate** (step 9 re-runs the
checks on it). Then replace `<RELAY HOST>` in the review notes of `release/APP_STORE_LISTING.md`.

## 7. Host the privacy policy, terms and support pages (GitHub Pages)

1. Merge the release branch into `main` (the agent prepares the PR; you approve and merge).
2. github.com/sasmalgiri/kalsmritikosh ▸ **Settings** ▸ **Pages** ▸ Source **Deploy from a branch** ▸ Branch `main`, folder
   **/docs** ▸ Save.
3. After a minute, open https://sasmalgiri.github.io/kalsmritikosh/privacy.html, …/terms.html and …/support.html and check the
   date line reads "4 November 2026" and "Shrabani Sasmal". (If the repository should not be public, use another host and
   change the three URLs in `release/APP_STORE_LISTING.md`.)

## 8. Sign, archive and upload (Xcode)

1. Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ add Shrabani Sasmal's Apple Account.
2. Open `Kalsmritikosh.xcodeproj` ▸ target **Kalsmritikosh** ▸ Signing & Capabilities ▸ Team = Shrabani Sasmal; "Automatically
   manage signing" on. Repeat for **KalsmritikoshNetworkHelper**, **KalsmritikoshClipper**, **KalsmritikoshShare**.
3. Scheme **Kalsmritikosh** ▸ Product ▸ Destination **Any Mac** ▸ **Product ▸ Archive** (Release configuration).
4. Organizer ▸ the archive ▸ **Validate App** ▸ App Store Connect ▸ automatic signing ▸ fix anything it reports.
5. **Distribute App** ▸ **App Store Connect** ▸ Upload. (Notarisation is not needed for Mac App Store distribution — Apple
   re-signs the build. Notarise only if you also hand out a copy outside the store.)
6. Record the candidate commit, the archive's version/build and the upload's build number in
   `release/approvals/distribution-archive.md` (and the agent writes `release/artifacts/distribution-archive.json`).

## 9. Release check on the frozen candidate

```
bash scripts/release-check.sh
```

The human gates need records **you** write in `release/approvals/<gate>.md` (format in `release/approvals/README.md`):
`legal-privacy`, `publisher-decision`, `accuracy-adjudication` (by your 2026-11-04 decision the ≤3 % bar was **not measured
live** on this candidate — record ACCEPTED only if you knowingly accept that, with the reason in Notes), `practitioner-review`,
`user-evaluation`. Never sign a record for a commit other than the one you upload.

## 10. TestFlight (optional, free)

App Store Connect ▸ the app ▸ **TestFlight** ▸ the uploaded build ▸ Internal Testing ▸ add yourself ▸ install with the TestFlight
app on the Mac. Sandbox purchases there are free; AI requests do spend the relay's capped budget.

## 11. Submit

App Store Connect ▸ the app ▸ macOS App ▸ version **1.0**:

1. Paste from `release/APP_STORE_LISTING.md`: promotional text, description (plain text), keywords, support URL, marketing URL,
   What's New, copyright `2026 Shrabani Sasmal`.
2. Screenshots: the eight listed there (2880×1800).
3. **Build:** select the uploaded build; answer export compliance (already declared in the build: no non-exempt encryption).
4. **In-App Purchases and Subscriptions:** attach all eight products — **only if** step 6 put the relay host into this build.
5. **App Review Information:** no sign-in required; contact Shrabani Sasmal, phone, sasmalgiri@gmail.com; paste the review
   notes (with the real relay host).
6. **Version release:** "Manually release this version".
7. **Add for Review** ▸ **Submit**.

## 12. After approval

- **Release** the version (manual release).
- **Global spend cap (release decision 2026-11-04, item 6).** Keep **`GLOBAL_CAP_USD=20` until Apple approves the app** (review
  traffic only). **After approval, set it to about US$25 × the number of AI subscribers you expect** this month (e.g. 40 expected
  subscribers → 1000), and raise it as subscribers grow. At US$20 a single AI Included subscriber (2,000 credits = US$20 of
  Claude cost) could use the whole service's month; US$25 per subscriber covers an AI Included allowance plus some packs and
  transcription — if many subscribers are on AI Pro (6,000 credits = US$60), size the cap up for them. Then raise the Anthropic
  console spend limit to at least the cap and add credit. Command: `cd relay && npx wrangler secret put GLOBAL_CAP_USD` (type the
  new number) — takes effect immediately.
- **Watch `/v1/sellable`** — `curl https://<relay host>/v1/sellable` (or the app's plan screen) — at least weekly and after
  each cap change: `false` means 90 % of the cap is spent, AI plans
  are no longer offered to new buyers and new AI requests are refused until the 1st (UTC) or until you raise the cap.
- Check console.anthropic.com ▸ Usage weekly against Apple's proceeds.
- Consider turning off the relay's Sandbox acceptance after review (today it accepts Sandbox and TestFlight transactions, which
  spend the real budget) — ask the agent for a flag.
- Subscriber deletion requests: `relay/README.md` ▸ "Retention and requests".
- **Lawyer review (optional, recommended before taking money).** The terms, privacy policy, privacy label and listing were
  prepared and reviewed by agents, not counsel (`docs/agent-reviews/legal-privacy.md`). A lawyer's review is not required to
  submit, but is recommended before the first paid subscription is sold — especially the India tax/GST position, the AI-provider
  disclosures (App Review 5.1.2(i)) and the "not linked" privacy-label reading (`release/APP_PRIVACY_LABEL.md`, owner decision 1).
