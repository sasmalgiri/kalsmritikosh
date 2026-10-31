# UI journeys — subscription screen (§11) — 2026-10-31 (run g)

Follow-up to run f (`../ui-journeys-2026-10-30f/JOURNEYS.md`), which found F-1 (an unanswered store left
the whole app unlocked with no screen) and F-2 (the local StoreKit configuration was not in effect for the
Xcode-launched process). This run checks the F-1 fix (`37995fbb`) through the real UI and records what
could and could not be done about F-2. Same method as runs d–f: Xcode launch (`RunProject`, scheme
`Kalsmritikosh`, Debug, `--acceptance-case` → disposable ledger), Accessibility-API tree dump
(`/tmp/axd2`, source in `../ui-journeys-2026-10-30f/axdrive-main.swift`), `screencapture -l <windowID>`.
Everything below is what was observed. **No owner data was opened**: `lsof` on each process showed only
`…/Containers/ecosanskritiinnovation.Kalsmritikosh/Data/tmp/acceptance-case.sqlite` (+ `-wal`, `-shm`).

## Build under test

| Item | Value |
| --- | --- |
| Commit | `37995fbb` (F-1 fix) on `investigations-next`; working tree: scheme with the StoreKit reference and `--acceptance-case` enabled for the run (disabled again before commit) |
| Processes | pid 13259 (09:39, scheme reference `../../StoreKit/Kalsmritikosh.storekit`), then pid 13584 (09:43, reference `../../../StoreKit/…` to test the path); each `Contents/MacOS/Kalsmritikosh --acceptance-case -NSDocumentRevisionsDebugMode YES`; exactly one instance at a time (`pgrep -fl MacOS/Kalsmritikosh`) |
| Window | "Home", `[185,33 1100x845]`, window IDs 457 / (second run) same geometry |
| Screenshots | `01-first-screen.png` (pid 13259), `02-first-screen-store-unanswered-retry.png` (pid 13584) |

## What the UI showed

**F-1 is fixed.** With the store unanswered (the configuration still not in effect — see below), the window
now leads with the subscription screen (`AXGroup id=purchase.screen`), the content behind it blurred and
not hit-testable. The screen read, verbatim from the AX tree:

- "Investigations Made Easy — one edition, all nine personas"
- "Every persona and every job is included. On-device features need no AI-provider key; optional Online AI
  uses your own provider account and may cost extra. Monthly and annual plans give the same access."
- "The App Store did not return the plans and prices for your storefront, so none can be shown and nothing
  can be subscribed to yet. Nothing is charged until a plan is shown and chosen. Reading, exporting,
  backing up, Help and the sample case work meanwhile." — followed by a **Try again** button (02).
- Links "Restore purchases", "Manage subscription"; buttons "Try a sample case" (help text: separate ledger,
  no purchase needed), "Help", "Backup & recovery" (help text: Settings ▸ Your data never needs a
  subscription); the footer on Apple handling payment, no connection opened by the app, Online mode not
  enabled by subscribing, and the archive not being copied between Macs.

No price was shown anywhere (no made-up price), no plan card, no subscribe button — correct for an
unanswered store. Nothing was pressed on this screen: "Restore purchases" would raise the real Apple
sign-in sheet again (run f, step 5), and "Manage subscription" opens an external Apple page.

## F-2: the StoreKit configuration is still not applied to Xcode launches from this harness

Both path forms were tried (`../../StoreKit/…`, which is Xcode's own convention — relative to a directory
one level inside the `.xcodeproj` — and `../../../StoreKit/…`); the scheme was reloaded by switching schemes
and back; the run destination was re-set to "My Mac". In both runs `Product.products(for:)` returned
nothing (the retry text above), no StoreKit testing daemon appeared in `ps`, and no mention of the
configuration appeared in the Xcode run logs. The most likely cause is that `StoreKit/Kalsmritikosh.storekit`
is **not a member of the Xcode project** (`project.pbxproj` has no reference to it); Xcode's scheme editor
lists only project members in its StoreKit Configuration menu. Adding it is a `project.pbxproj` change, which
is owner-in-Xcode only (File ▸ Add Files… → `StoreKit/Kalsmritikosh.storekit`, no target membership; then
Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Options ▸ StoreKit Configuration → `Kalsmritikosh.storekit`).

The scheme keeps the `../../StoreKit/Kalsmritikosh.storekit` reference (Xcode's convention) so that step is
a single menu choice.

## What was verified instead: the store flows in-process, against the same configuration

`KalsmritikoshTests/PurchaseStoreKitTests.swift` loads `StoreKit/Kalsmritikosh.storekit` into an
`SKTestSession` (Apple's StoreKitTest framework) inside the test host and drives a `PurchaseCenter` that
talks to that store — the same `Product.products`, `Product.purchase`, `Transaction.currentEntitlements`,
`Transaction.latest(for:)` and `Product.SubscriptionInfo.status` calls the app makes. Eleven tests, all
passing locally (RunSomeTests 2026-10-31 10:20, 33/33 together with `PurchaseTests`,
`HostArtifactRobustnessTests`, `TestHostIsolationTests`; the plan-change test was then made to wait for
StoreKit's asynchronous renewal record and re-run green at 10:2x):

| Test | What StoreKit itself did | What the app showed |
| --- | --- | --- |
| storefrontPlansAndTrialEligibility | returned the two plans for storefront USA | `$4.99` per 1 month, `$39.99` per 1 year, both eligible for the 14-day introductory free trial, "Start 14-day free trial", disclosure "14 days free, then $39.99 per year. Renews automatically at $39.99 per year unless cancelled at least a day before…", annual saving 33 %, state `notStarted` → screen leads, paid action refused and paywall requested |
| trialRenewsThenIsCancelledThenExpires | purchase → introductory period; forced renewal → paid period; auto-renew disabled | `introductoryTrial(14 days, monthly, renews)` → `subscribed(renews)` → `subscribed(cancelled — access until …)`; cache kept the verified state |
| cancelledSubscriptionExpiresAtPeriodEndIntoReadOnly | time at one renewal per 2 s; cancelled; period ended | `lapsed(expired)`: paid use off, read access on, `hadAccessBefore` (read-only window, not the never-started screen), paid action refused with paywall, cache reads lapsed |
| refundRevokesAndRestoreReportsIt | annual bought, then refunded | `lapsed(revoked)`; Restore says "No active subscription or purchase was found for this Apple account." |
| billingRetryWithGraceKeepsAccessUntilGraceEnds | renewal failed with grace enabled (time 1 renewal/min); issue resolved | `grace(until …)` keeps paid use, status "Payment did not go through; access continues until …"; then `subscribed` |
| billingRetryWithoutGraceIsReadOnly | renewal failed, grace disabled | `billingRetry(monthly)`: paid use off, `hadAccessBefore`, "Payment did not go through. Update the payment method…" |
| planChangeWithinTheGroup | monthly bought, then annual (same level → crossgrade) | Apple's renewal record names annual as what renews next; after the renewal the annual plan stands |
| legacyPermanentUnlockBeatsEverythingAndIsNeverAskedToSubscribe | `…unlock` bought outside the app; monthly bought; unlock refunded; subscription expired | `legacyUnlocked` throughout (paid action allowed, no paywall), then read-only `lapsed` once nothing stands |
| legacyFreeTrialProductIsATrialNotBillingConsent | `…trial14` bought outside the app | `legacyTrial(ends in 14 days)`, "no charge follows it", still eligible for the subscription's introductory offer |
| restoreWithNothingBoughtSaysSo | `AppStore.sync()` on an empty account | "No active subscription or purchase was found for this Apple account." |
| storeFailureNeverUnlocksAndNeverRemovesValidAccess | purchase dialog fails (`paymentNotAllowed`) | the person is told, the verified state is unchanged; a centre with no products still reads the verified state |

Two product defects were found and fixed by these tests (`Purchase.swift`, this commit):

- **Expired or refunded subscribers were read as "never started".** `Transaction.currentEntitlements`
  drops expired and revoked transactions, so after expiry the app saw no subscription at all → `notStarted`
  → the whole-window screen for a new customer instead of the read-only window the mandate requires.
  `refresh()` now also reads `Transaction.latest(for:)` for each product (verified only) so the lapsed
  state, its reason and `hadAccessBefore` are right.
- A revocation seen on one of the two reads is kept when the same transaction appears in both.

Environment notes (not product behaviour): the testing environment keeps `isEligibleForIntroOffer` true
while the trial is still running, so "no second trial" is asserted only in the pure-rules `PurchaseTests`;
renewal settings are keyed by the current period's transaction; a forced renewal always succeeds (billing
failure is reached by letting accelerated time run); setting `storefront`/`locale` on the session made
paid purchases fail with "Item Unavailable", so the configuration's defaults (USA, en_US) are relied on.

## Still open for §11

| Item | Who | How |
| --- | --- | --- |
| Plan cards, trial action, disclosure, test purchase and the status strip **seen in the UI** | owner (two Xcode menu steps above) then the agent's AX run, or the owner by hand | with the configuration in effect the screen shows the cards at the storefront prices; the Settings ▸ Subscription section shows the state |
| Sandbox and TestFlight matrix (`docs/DISTRIBUTION_PACK.md` §6, 12 rows) | owner, App Store Connect | products created at the adopted price points; `release/approvals/storekit.md` |
