# In-App Purchase setup sheet — App Store Connect

_Prepared 2026-11-04 (agent) from `StoreKit/Kalsmritikosh.storekit` and owner decisions 2026-11-04. Product IDs below are
exactly those in the StoreKit file and in `Kalsmritikosh/App/Store/Purchase.swift` — a typo means the app cannot find the product.
Bundle ID: `ecosanskritiinnovation.Kalsmritikosh`. Team: `6TPTCJD42Q`. Do this after the app record exists
(`release/OWNER_LAUNCH_CHECKLIST.md` step 4) and after the Paid Apps agreement is active (step 2)._

## 1. Subscription group

App Store Connect ▸ Apps ▸ Investigations Made Easy ▸ Monetization ▸ **Subscriptions** ▸ Subscription Groups ▸ **+**

| Field | Value |
|---|---|
| Reference name | `Investigations Made Easy plans` |
| Group localization (English (U.S.)) — display name | `Investigations Made Easy` |
| App name display | Use app name |

**Levels** (drag to order; level 1 = highest service). Upgrades (to a higher level) take effect at once; downgrades at the next
renewal; switching monthly ↔ yearly within a level follows Apple's crossgrade rules.

| Level | Plan | Products |
|---|---|---|
| 1 (top) | AI Pro | `…aipro.monthly`, `…aipro.annual` |
| 2 | AI Included | `…ai.monthly`, `…ai.annual` |
| 3 | Workbench | `…edition.monthly`, `…edition.annual` |

## 2. The six auto-renewable subscriptions (all in the one group)

| Level | Product ID | Reference name | Duration | US price | India price | Intro offer |
|---|---|---|---|---|---|---|
| 1 | `ecosanskritiinnovation.Kalsmritikosh.aipro.monthly` | AI Pro — monthly | 1 month | $99.00 | owner sets (see §6) | none |
| 1 | `ecosanskritiinnovation.Kalsmritikosh.aipro.annual` | AI Pro — yearly | 1 year | $989.00 | owner sets | none |
| 2 | `ecosanskritiinnovation.Kalsmritikosh.ai.monthly` | AI Included — monthly | 1 month | $39.00 | owner sets | none |
| 2 | `ecosanskritiinnovation.Kalsmritikosh.ai.annual` | AI Included — yearly | 1 year | $389.00 | owner sets | none |
| 3 | `ecosanskritiinnovation.Kalsmritikosh.edition.monthly` | Workbench — monthly | 1 month | $4.99 | ₹249 | **Free, 2 weeks** |
| 3 | `ecosanskritiinnovation.Kalsmritikosh.edition.annual` | Workbench — yearly | 1 year | $39.99 | ₹1,999 | **Free, 2 weeks** |

Per subscription: **Subscription Prices** ▸ base country United States, enter the US price; let Apple compute other storefronts,
then **override India** with the ₹ price for Workbench. **Never substitute a different price silently** — if a price point does
not exist, stop and decide (§6).

**Introductory offer (Workbench monthly and yearly only):** Subscription ▸ Introductory Offers ▸ **+** ▸ all countries ▸ start
today, no end date ▸ type **Free** ▸ duration **2 weeks** (= 14 days). Eligibility is Apple's (new to the group). Do **not** create
an introductory offer on AI Included or AI Pro.

**Localization — English (U.S.)** (display name ≤ 30 characters, description ≤ 45):

| Product | Display name | Description |
|---|---|---|
| aipro.monthly | `AI Pro monthly` | `Workbench plus 6,000 AI credits and big reads` |
| aipro.annual | `AI Pro yearly` | `Workbench plus 6,000 AI credits and big reads` |
| ai.monthly | `AI Included monthly` | `Workbench plus 2,000 AI credits each month` |
| ai.annual | `AI Included yearly` | `Workbench plus 2,000 AI credits each month` |
| edition.monthly | `Workbench monthly` | `Every feature on your Mac; your own AI key` |
| edition.annual | `Workbench yearly` | `Every feature on your Mac; your own AI key` |

(The longer descriptions in the `.storekit` file are for local testing only; App Store Connect limits descriptions to 45
characters.)

**Group settings:** App Store Connect ▸ Monetization ▸ Subscriptions ▸ **Billing Grace Period** ▸ On, **3 days**, all renewals,
production and sandbox. **Family Sharing:** Off for every product (credits are per subscription). Offer codes / promotional
offers: none.

**Review information per subscription:** screenshot = the paywall showing that plan (capture 2880×1800 from the app: Plans
screen, `release/APP_STORE_LISTING.md` screenshot 7 — one image may be reused for all six); review notes: "Shown on the Plans
screen at first launch and in Settings ▸ Online ▸ See plans. AI plans: see the app's review notes, steps 3–5."

## 3. The two consumables (credit packs)

App Store Connect ▸ Monetization ▸ **In-App Purchases** ▸ **+** ▸ type **Consumable**

| Product ID | Reference name | US price | Display name | Description (≤45) |
|---|---|---|---|---|
| `ecosanskritiinnovation.Kalsmritikosh.ai.credits500` | AI credits — 500 | $9.99 | `500 AI credits` | `500 AI credits for AI plans; never expire` |
| `ecosanskritiinnovation.Kalsmritikosh.ai.credits2000` | AI credits — 2000 | $34.99 | `2,000 AI credits` | `2,000 AI credits for AI plans; never expire` |

Family Sharing: Off. Review screenshot: Settings ▸ Online with the "Buy 500 credits" button visible. Review note: "Usable
while AI Included or AI Pro is active; spent after the month's credits; never expire (Guideline 3.1.1). Credited by the
publisher's relay to the buyer's subscription."

Do **not** create the retired products: `…unlock`, `…trial14`, `…ai.topup200`.

**Attach to the first submission** (Version ▸ In-App Purchases and Subscriptions) **only if the relay is deployed and its host is
in the build** (`AIIncludedRelay.host`). Without the relay, attach only the two Workbench subscriptions and remove the AI steps
from the review notes (Guideline 2.1).

## 4. App Store Server Notifications (Version 2)

App Store Connect ▸ Apps ▸ the app ▸ **App Information** ▸ App Store Server Notifications:

- Production Server URL: `https://<relay host>/v1/apple-notifications` — Version 2
- Sandbox Server URL: the same URL — Version 2

The relay uses them to remove a refunded or revoked pack's remaining credits promptly (it also re-checks with Apple).

## 5. In-App Purchase key for the relay

App Store Connect ▸ **Users and Access** ▸ **Integrations** ▸ **In-App Purchase** ▸ **Generate In-App Purchase Key** (name:
`kals-relay`). Download the `.p8` once (it cannot be downloaded again). Note the **Key ID** and the **Issuer ID** shown on that page.
Then, in `relay/`:

```
npx wrangler secret put APPLE_ISSUER_ID     # Issuer ID
npx wrangler secret put APPLE_KEY_ID        # Key ID
npx wrangler secret put APPLE_PRIVATE_KEY   # paste the whole .p8, including the BEGIN/END lines
```

The relay asks the production App Store Server API first, then sandbox (so TestFlight and App Review sandbox purchases work —
and draw on the publisher's capped Anthropic key).

## 6. Owner decisions on this sheet

1. **Price points.** Confirm in the price picker that $389.00 and $989.00 (yearly AI plans) and $39.00 / $99.00 exist as US
   price points. If one does not, choose the replacement yourself and update `StoreKit/Kalsmritikosh.storekit`, the listing,
   `docs/terms.html` and `docs/USER_MANUAL.md` together — the app shows StoreKit's price, but the copy states these figures.
2. **India and other storefronts for the AI plans.** Only Workbench's ₹249 / ₹1,999 are decided. Apple's automatic equivalents
   apply to the AI plans and packs unless you override them. The credits are US-dollar-cost based, so a lower local price
   lowers the margin.
3. **Credit packs in AI-blocked storefronts.** Packs are useless where Online AI is switched off (CN, HK, MO, RU, BY, VE, AF, MM,
   YE, IR, KP, SY, CU). Consider removing the AI plans and packs from those storefronts' availability (Pricing and
   Availability per product) so nobody can buy what they cannot use.
