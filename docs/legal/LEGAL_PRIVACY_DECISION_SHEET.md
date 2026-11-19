# Legal, privacy and product-claims decision sheet (App Store completion §11)

Prepared 2026-10-31 by the agent. One sheet, one row per decision, the contradiction it resolves, the
recommended default, and the record that must exist before the listing is final. **Nothing here is in
force until the responsible person records it** in `release/approvals/legal-privacy.md` (format in
`release/approvals/README.md`) and `SHIP_DECISIONS.md`. The agent does not decide, sign or simulate.

## Contradictions found in the repository (to be resolved by the decisions below)

| # | Where | What it says | Conflict |
|---|---|---|---|
| C-1 | `release/APP_STORE_LISTING.md` §Privacy nutrition labels | "**Data Not Collected.** No data is collected, tracked, or linked to the user." stated as settled | `docs/DISTRIBUTION_PACK.md` §1 **withdrew** that recommendation (Apple's analysis reaches third parties; Online mode sends to the person's own provider); `docs/legal/DECISION_MEMO.md` D-1 recommends "Data Not Collected" **with** a disclosure that Online mode sends to the person's provider. Three documents, two positions, one stated as fact. |
| C-2 | `Marketing/APP_STORE_LISTING.md` | An older draft: app name "Kalsmritikosh", subtitle "Private evidence workbench", placeholder URLs (`yourdomain.com`), "nothing sent to the cloud" | The canonical listing is `release/APP_STORE_LISTING.md` ("Investigations Made Easy", live privacy/support/terms URLs, Online mode disclosed). The old draft contradicts the product name and the Online-mode disclosure. |
| C-3 | `release/APP_STORE_LISTING.md` subtitle/description vs `docs/legal/DECISION_MEMO.md` D-8 | The listing's review notes are fine; any accuracy percentage anywhere in marketing is not | No adjudicated held-out number exists (FINAL_BRIEF_EXECUTION §E3/§E6 §7); the listing must not state one. |
| C-4 | In-app `LegalNotice` (terms 1.8) vs `docs/terms.html` vs `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md` (2.0) | Three wordings of the terms | One adopted text, one version, in the app and on the site in one change (D-2). |

## Decisions

| ID | Decision | Facts the code establishes | Recommended default | Who records | Before the listing is final |
|---|---|---|---|---|---|
| L-1 | App Privacy label | Publisher receives nothing; no SDKs; `network.client` false in the main app; Online mode off by default, person's own key, per-send consent, privileged/restricted passages refused; protected identities masked. Providers may retain API content under their own terms. | **Option (b)-lite**: declare **"Data Not Collected"** for the publisher **and** add the Online-mode disclosure sentence to the listing, `privacy.html` and the review notes (DECISION_MEMO D-1). If counsel reads Apple's definition as reaching user-directed sends to a third party, switch to **Other User Content, linked, App Functionality, Online mode only** — the privacy manifest's collected-data array then lists it. Either way the listing stops stating the label as a settled fact until recorded. | counsel + owner | `release/approvals/legal-privacy.md`: chosen option, reasoning, the three provider retention terms with versions and dates |
| L-2 | Terms | `LegalNotice` 1.8 ≠ `terms.html`; reconciled draft 2.0 exists | **Standard EULA + the reconciled supplement (2.0)**, one text, one version/date, in the app and on the site in one change; fill publisher, address, telephone | counsel + owner | adopted text committed to both places; version noted in the record |
| L-3 | Governing law and venue | Publisher named as Eco Sanskriti Innovation (India); launch markets not fixed | Publisher's registered seat, mandatory consumer protections of the user's residence preserved | counsel | record names the seat and the launch markets |
| L-4 | Name | Display name "Investigations Made Easy", internal "Kalsmritikosh" (bundle id, ledger, build settings) | Proceed as is pending clearance; no filing until cleared | counsel | clearance result per launch market |
| L-5 | Encryption export | SQLCipher AES-256 ledger, AES-GCM sealed cache, keys on device, no encryption as a service | "Uses encryption; exempt" (mass-market / data-at-rest); `ITSAppUsesNonExemptEncryption = NO` only if counsel agrees | counsel | exemption category recorded; self-classification report if due |
| L-6 | Publisher identity | Six documents name Eco Sanskriti Innovation; seller record not in repo | One registered legal name and form everywhere (`BuildIdentity`), same entity as the App Store seller | owner | record names the entity and the seller account |
| L-7 | Retention, erasure, holds | Fail-closed erasure, hold precedence, append-only audit chain, backups carry erasure records | Keep; state in `privacy.html` that a hold the person created blocks erasure until released | counsel | wording approved |
| L-8 | Professional claims | Every job result cited, drafts until accepted, no legal/accounting conclusions stated | Listing claims limited to what acceptance scenarios prove; no accuracy percentage until the adjudicated number exists | owner | listing text frozen with the record |
| L-9 | Print entitlement (new, UI run d D-5) | The sandboxed app has no `com.apple.security.print`; macOS refuses `NSPrintOperation`; the app now says so and records nothing | Owner's call: add the print entitlement (standard sandbox capability; no data leaves the Mac) **or** ship with Print reported as unavailable. Recommended: add it, re-run the print route on the Distribution build. | owner | decision recorded; if added, the entitlements file change and a distribution-build print test |
| L-10 | Subscription terms and markets (new, 2026-10-30) | One edition, monthly $4.99 / annual $39.99 (US), India target ₹249/₹1,999; 14-day introductory free trial by StoreKit eligibility; automatic renewal; 3-day grace; legacy permanent unlock honoured; after expiry cases readable with export/backup/recovery/help/privacy kept (`Purchase.swift`, `PurchaseTests`). Terms, privacy, support, listing and the supplemental terms already carry this wording. | Adopt the wording as written; confirm the auto-renewal disclosures and cancellation rights satisfy consumer law in each launch market; confirm the India price points actually available in App Store Connect (never substitute silently); confirm trader/seller details required by the approved markets | counsel + owner (App Store Connect account holder) | `release/approvals/legal-privacy.md` names the markets, the price points chosen per storefront and the consumer-law confirmation; `release/approvals/storekit.md` records the Sandbox/TestFlight matrix |

## What changes in the repository once L-1 is recorded

- `release/APP_STORE_LISTING.md` privacy section: replace the settled sentence with the recorded answer and the Online-mode disclosure.
- `Kalsmritikosh/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes` stays empty (option a) or lists Other User Content (option b).
- `docs/privacy.html`: the disclosure sentence, tagged for `scripts/check-claims.sh`.
- `Marketing/APP_STORE_LISTING.md`: already marked superseded (see its header); delete after the listing is final.
