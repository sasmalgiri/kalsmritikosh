# AGENT REVIEW — user evaluation (not a user study; owner decision 2026-11-01)

- **Reviewer:** a Claude agent walking the first-run and paid paths by reading the code, the help registry and the paywall.
  The owner decided on 2026-11-01 that agents replace the five-user evaluation for v1. No users took part, and no GUI was
  driven (another agent holds the GUI).
- **Date:** 2026-11-04
- **Candidate:** `7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0`
- **Baseline:** `user-evaluation-2026-11-02.md`, `candidate-re-review-f766b035.md`; changes `0c5ec1c3..7d720fe1`.
- **Read:** `UI/PurchaseGate.swift`, `App/Store/Purchase.swift`, `App/Store/AICredits.swift`, `App/Store/AIRegion.swift`,
  `UI/OnlineViews.swift`, `UI/SettingsView.swift` (Modules), `UI/CaseReadConsentSheet.swift`, `Brain/OfflineSearchResults.swift`,
  `Routing/Providers/Online/CloudUsage.swift`, `AIPricing.swift`, `UI/Help/HelpRegistry.swift`, `release/APP_STORE_LISTING.md`.

**Verdict: NOT APPROVED. There is one blocking finding.**

## The journeys as built

1. **First launch, no purchase.** The plans screen opens with "Try a sample case", Help, Backup & recovery and "Look around
   first (read-only)". Nothing is charged until a plan is chosen, and the screen says so if the App Store returns no
   products (`PurchaseGate.swift:128-176`). Good.
2. **Workbench trial.** "Start 14-day free trial" is offered only to eligible accounts. The disclosure reads "14 days free,
   then $X per month. Renews automatically … at least a day before … Manage or cancel through your Apple Account". There is
   a link "How to cancel a trial or subscription (Apple)" (`Purchase.swift:434-447`; `PurchaseGate.swift:136-145`). Good.
3. **AI Included / AI Pro purchase.** Each plan card says "2,000 AI credits every month · no free trial". The full AI terms
   are in the disclosure: credits, US$0.01, per-request / case-read / daily limits, packs, capacity pause, recipients
   (`Purchase.swift:450-453`). The AI plans are hidden in the 13 blocked storefronts and when the relay is not configured
   (`:456-461`). Good.
4. **After buying an AI plan → first question in a case.** **Breaks, see UB1.**
5. **Own key (Workbench).** Settings ▸ Online ▸ "Claude (Anthropic)", key in the Keychain, attestation tick, optional monthly
   US$ limit. Before each send, an estimate "up to $X … (list prices; usually less)" and a refusal past the limit
   (`AICredits.swift:239-248`). Good.
6. **Credits running out.** The app checks locally and refuses before sending, in the relay's words, offering "Buy credits"
   or "Upgrade" (`OnlineViews.swift:99-124`; `AICredits.swift:51-61`). A pack is offered only with an active AI plan
   (`Purchase.swift:808-811`). Nothing is sent and nothing charged. Good, apart from the wording in US2.
7. **Offline.** Ask returns "Search results for …" with the matching passages, highlighted words and "Open source"
   (`OfflineSearchResults.swift:39-48`). Honest, but see US1 for the reason it gives.

## Blocking

| # | Finding | Evidence |
|---|---|---|
| **UB1** | **A paying AI-plan subscriber who follows the Help, the listing or the App Review notes never reaches the AI.** The whole-case reader is installed only when (a) "Use AI to write answers" is on in Settings ▸ Modules, which is **off by default** (`EvidenceOnlyRelease.aiEnabled`, absent = off), and (b) the provider's document-terms attestation is ticked in Settings ▸ Online (`acceptsDocuments`). Otherwise Ask answers "Search results for … No AI is set up, so no answer is written". No sheet, no hint which switch is missing, and the person has just paid US$39–99. The Help topic `task-ai-included` says "Choose AI Included or AI Pro … Then Settings ▸ Online ▸ Provider ▸ AI Included or AI Pro" and nothing more. No help topic mentions "Use AI to write answers". The listing says "Turn on 'Use AI to write answers' for Apple's on-device intelligence … **or** Online mode for an AI plan", which reads as an alternative. Review notes step 3 lists only Connection and the provider. This is also a Guideline 2.1 risk: the reviewer buys AI Included and sees no AI. Fix in one of two ways. (a) When an AI plan is bought, or the AI-plan provider is chosen, turn on "Use AI to write answers" and show the attestation inline. (b) At minimum, make the offline note name the missing switch ("AI answers are off — Settings ▸ Modules ▸ Use AI to write answers"; "confirm the document terms in Settings ▸ Online"), and add both steps to the Help topic and the review notes. | `Routing/EvidenceOnlyRelease.swift:20-31`; `Routing/PrivacyGate.swift:27-30`; `App/FeatureFlags.swift:226, :251-253`; `App/AppState+CaseReading.swift:35-44`; `Routing/Providers/Online/OnlineCloudProvider.swift:145-149`; `UI/OnlineViews.swift:222-228`; `Brain/OfflineSearchResults.swift:44`; `UI/SettingsView.swift:1483-1490`; `release/APP_STORE_LISTING.md:72, :137-149`; `UI/Help/HelpRegistry.swift` `task-ai-included` |

## Should-fix — price and credit text

| # | Finding | Evidence |
|---|---|---|
| US1 | **"No AI is set up" is the same message for six different causes:** AI answers off, Online off, no provider, terms not ticked, blocked country, relay unreachable. Say which one, with the place to fix it (see UB1). | `Brain/OfflineSearchResults.swift:44`; `App/AppState+CaseReading.swift:35-44` |
| US2 | **"This needs about N credits and B are left" uses the relay's worst-case reservation as "about".** For a question on a 300k-token case, the reservation (every input token at the 1-hour-write rate plus the full 24k output) is roughly 360 credits. The expected cost from the cache is about 15–25. A person with 200 credits left is told the question "needs about 360". Say "up to N credits are held while it runs (usually far less); you have B". | `App/Store/AICredits.swift:59`; `Routing/Providers/Online/AIPricing.swift` (`relayReservation`); `OnlineCloudProvider.swift:514-520` |
| US3 | **"A typical question uses a few credits" understates whole-case reading.** On the AI plans, a question in an open case re-reads the cached case: about 1 credit per 20k tokens of case, plus output. The first read of a 100k-token case costs about 100+ credits, and again after an idle hour. Say "a question in an open case: usually 5–30 credits; reading a case the first time: about 1–2 credits per 1,000 words of case text — the app shows the estimate first". | `App/Store/Purchase.swift:112`; `Routing/Providers/Online/CloudUsage.swift:78-88` |
| US4 | **"then about N per question while it stays open"** should say "within an hour of the last question". | `CloudUsage.swift:84, :87` |
| US5 | **The help says every send is previewed.** "Every send is still shown to you first, with its estimated credits", but inside an allowed case questions are sent without a prompt (by design, stated in the policy). Align the help with the once-per-case rule. | `UI/Help/HelpRegistry.swift:252` |
| US6 | **The listing says "New subscribers can try every paid feature free for 14 days".** The trial is Workbench's only, with no AI credits. Say "try every Workbench feature free for 14 days". | `release/APP_STORE_LISTING.md:65` |
| US7 | **The site still sells "One plain plan"** ("Monthly or yearly, every persona included … No per-gigabyte fees") and "No processing fees, ever". There are three plans and metered AI credits now. | `docs/for/*.html:59`; `docs/index.html` (lawyers card) |
| US8 | **The site's requirements line says "AI-written answers require macOS 26+ with Apple Intelligence enabled".** AI-plan and own-key answers do not. | `docs/index.html:181` |
| US9 | **Owner economics (not a user-facing defect, but the owner's zero-cost rule).** Credits are priced at exactly the provider's cost (1 credit = US$0.01), so all the margin is price − credits. A fully used **AI Pro yearly** (US$989.99 for 72,000 credits = US$720) returns US$693 at Apple's 30 % first-year rate: a loss. At 15 % (Small Business Program, effective only from the fiscal month after approval) it returns about US$841 in the US. But in VAT storefronts it loses at either rate (e.g. 19 % VAT: ≈ US$707 at 15 %). AI Included yearly and the 2,000-credit pack are marginal at 30 % in high-VAT storefronts. Either price AI Pro yearly higher, or give yearly plans fewer credits than 12× monthly, or confirm SBP is active before AI sales. | `release/IAP_SETUP.md:32-37, :83-84`; `Routing/Providers/Online/AIPricing.swift:24-28` (credits/plan); owner decision 2026-11-01 item 3 |

## Fine (checked)

- Every price comes from StoreKit (`displayPrice`), never a hard-coded figure. The annual saving is computed from the two
  storefront prices (`Purchase.swift:465-472`).
- Workbench-only trial, "no free trial" on AI cards, and "No free trial on this account" for ineligible accounts
  (`PurchaseGate.swift:236-241`).
- Restore, Manage subscription, Terms and Privacy are on the paywall. "Subscribing does not turn on Online mode or send
  anything anywhere" (`PurchaseGate.swift:150-156, :279-281`).
- The credit meter: "N of M credits left this month · K in packs · last request C credits"; "Check credits" sends only
  the subscription number, as the UI says (`AICredits.swift:152-158`; `OnlineViews.swift:274-286`).
- Capacity pause: "paused until the 1st. Nothing is charged meanwhile", and new AI sales are refused with "Nothing was
  charged. Workbench is available …" (`AICredits.swift:61`; `Purchase.swift:775-796`).
- Blocked storefronts: an explanation instead of empty controls (`OnlineViews.swift:172-178`; `PurchaseGate.swift:270-272`).
- The permission sheet gives an honest two-part estimate ("At most about N credits for the first read …, then about M per
  question") and a list of documents sent and not sent with reasons (`CloudUsage.swift:78-88`; `CaseReadConsentSheet.swift`).
- Lapsed subscription: "Your work is safe and readable — subscribe to keep editing", and every case stays readable and
  exportable (`PurchaseGate.swift:256-266`).

## Conditions to re-review

Fix UB1, re-walk journeys 3 → 4 in the GUI (gate `ui-consent-and-plans`), and fix US2–US6 in the same pass, because they
are the texts a first-time paying user reads.
