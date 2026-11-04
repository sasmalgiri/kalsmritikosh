# In-App Purchase setup sheet — App Store Connect

_Prepared 2026-11-04 (agent) from `StoreKit/Kalsmritikosh.storekit`, owner decisions 2026-11-04 and the owner's accepted release
decisions of the same day (yearly AI prices $389.99 / $989.99, India prices, AI products not sold in the 13 AI-blocked storefronts). Product IDs below are
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
| 1 | `ecosanskritiinnovation.Kalsmritikosh.aipro.monthly` | AI Pro — monthly | 1 month | $99.00 (see §6.1) | ₹8,999 | none |
| 1 | `ecosanskritiinnovation.Kalsmritikosh.aipro.annual` | AI Pro — yearly | 1 year | **$989.99** | ₹89,999 | none |
| 2 | `ecosanskritiinnovation.Kalsmritikosh.ai.monthly` | AI Included — monthly | 1 month | $39.00 (see §6.1) | ₹3,499 | none |
| 2 | `ecosanskritiinnovation.Kalsmritikosh.ai.annual` | AI Included — yearly | 1 year | **$389.99** | ₹34,999 | none |
| 3 | `ecosanskritiinnovation.Kalsmritikosh.edition.monthly` | Workbench — monthly | 1 month | $4.99 | ₹249 | **Free, 2 weeks** |
| 3 | `ecosanskritiinnovation.Kalsmritikosh.edition.annual` | Workbench — yearly | 1 year | $39.99 | ₹1,999 | **Free, 2 weeks** |

Per subscription: **Subscription Prices** ▸ base country United States, enter the US price; let Apple compute other storefronts,
then **override India** with the ₹ price in the table (all six subscriptions). Apple's storefront prices are what the customer
pays **including GST** in India (Apple collects and remits the tax; your proceeds are net of it and of the commission). **Never
substitute a different price silently** — if a price point does not exist, stop and decide (§6).

**Availability of the four AI subscriptions (AI Included and AI Pro, monthly and yearly):** each subscription ▸ **Availability**
▸ remove these **13 storefronts**, where Online AI is blocked (`Kalsmritikosh/App/Store/AIRegion.swift`, `relay/src/policy.ts`
AI_BLOCKED_STOREFRONTS): **China mainland (CHN), Hong Kong (HKG), Macao (MAC), Russia (RUS), Belarus (BLR), Venezuela (VEN),
Afghanistan (AFG), Myanmar (MMR), Yemen (YEM), Iran (IRN), North Korea (PRK), Syria (SYR), Cuba (CUB)** (several are not App
Store storefronts at all — remove the ones the list shows). Leave the two **Workbench** subscriptions available everywhere the app
is. The app already hides the AI plans, the credit packs and the own-key option for App Store accounts of those countries.

**Introductory offer (Workbench monthly and yearly only):** Subscription ▸ Introductory Offers ▸ **+** ▸ all countries ▸ start
today, no end date ▸ type **Free** ▸ duration **2 weeks** (= 14 days). Eligibility is Apple's (new to the group). Do **not** create
an introductory offer on AI Included or AI Pro.

**Localization — English (U.S.)** (display name ≤ 30 characters, description ≤ 45):

| Product | Display name | Description |
|---|---|---|
| aipro.monthly | `AI Pro monthly` | `Workbench plus 6,000 AI credits and big reads` |
| aipro.annual | `AI Pro yearly` | `Workbench plus 5,400 AI credits and big reads` |
| ai.monthly | `AI Included monthly` | `Workbench plus 2,000 AI credits each month` |
| ai.annual | `AI Included yearly` | `Workbench plus 2,000 AI credits each month` |
| edition.monthly | `Workbench monthly` | `Every feature on your Mac; own Anthropic key` |
| edition.annual | `Workbench yearly` | `Every feature on your Mac; own Anthropic key` |

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

Pricing: US price as above, Apple's equivalents elsewhere, **override India** (₹899 / ₹2,999). **Availability:** remove the same
13 AI-blocked storefronts as for the AI subscriptions (§2). Family Sharing: Off. Review screenshot: Settings ▸ Online with the "Buy 500 credits" button visible. Review note: "Usable
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

## 6. Owner decisions and checks on this sheet

1. **Price points (owner check — not verified by the agent).** The yearly AI prices are **$389.99** and **$989.99** (owner
   decision 2026-11-04: Apple's points end in .99). The monthly AI prices stay **$39.00** and **$99.00** in the copy. Apple's
   price grid (December 2022 upgrade: 900 points, $0.50 steps up to $49.99, $1 steps up to $199.99, $10 steps up to $999.99,
   with alternate rounded endings such as .00 at each point) suggests $39.00 and $99.00 are offered, but the agent could not
   read the exact US list. **In the price picker, confirm $39.00, $99.00, $389.99 and $989.99 exist.** If $39.00 / $99.00 do
   not, use **$39.99 / $99.99** (or another point you choose) and tell the agent, who updates `StoreKit/Kalsmritikosh.storekit`
   (now `39.0` / `99.0`), `release/APP_STORE_LISTING.md`, `relay/README.md`, the tests that pin the StoreKit file, and this sheet
   together — the app shows StoreKit's price, but the copy states these figures. Same for $389.99 / $989.99 (the copy uses
   them now).
2. **India prices (decided 2026-11-04):** Workbench ₹249 / ₹1,999; AI Included ₹3,499 / ₹34,999; AI Pro ₹8,999 / ₹89,999;
   packs ₹899 (500 credits) / ₹2,999 (2,000 credits). Set them as India overrides (§2, §3); confirm each is an India price point
   (if not, stop and decide). They include GST. The credits are US-dollar-cost based: ₹3,499 at the current rate is close to
   US$39 before tax, so the margin after GST and Apple's commission is lower in India than in the US.
3. **AI Pro yearly allowance (decided 2026-11-04): 5,400 credits a month, not 6,000.** At Apple's 15 % commission (Small
   Business Program) and the highest EU VAT (27 %, prices include VAT), AI Pro yearly nets about $989.99 ÷ 1.27 × 0.85 ÷ 12 ≈
   **$55.2 a month**; a fully used 6,000 credits would cost $60 of Claude, a loss. 5,400 credits = $54 stays covered. AI Pro
   monthly keeps 6,000 ($99 ÷ 1.27 × 0.85 ≈ $66.3 ≥ $60). AI Included keeps 2,000 monthly and yearly: yearly nets $389.99 ÷ 1.27 ×
   0.85 ÷ 12 ≈ **$21.75 ≥ $20**; monthly $39 ÷ 1.27 × 0.85 ≈ $26.1. At Apple's 30 % first-year rate (before the Small Business
   Program applies) the yearly plans do not cover full use in high-VAT storefronts — confirm the Small Business Program is
   active before AI sales. The relay grants the allowance by product (`relay/src/policy.ts` `monthlyAllowance`,
   `yearlyMonthlyCredits`); the app, the paywall, the `.storekit` file, the listing and the terms state "AI Pro yearly: 5,400
   credits a month".
4. **AI-blocked storefronts (decided):** the AI subscriptions and both packs are **not** available in the 13 storefronts listed
   in §2 — remove them from each AI product's availability. Only Workbench is sold there. Other storefronts: Apple's automatic
   equivalents apply unless you override them.
