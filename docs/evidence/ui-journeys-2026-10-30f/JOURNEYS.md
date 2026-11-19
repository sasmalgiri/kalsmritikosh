# UI journeys — subscription screen (§11) — 2026-10-31 (run f)

Verification of the new subscription screen (commit `5d92d52a`, build at `58abaf50`) through the real
macOS UI via the Accessibility API, against the instance Xcode had launched (pid 9073, `--acceptance-case`,
scheme carrying `StoreKit/Kalsmritikosh.storekit`). Same method as runs d/e: AX tree dump, AXPress by
identifier/description/frame, AX selected-text insertion for typing, hit-test (`AXUIElementCopyElementAtPosition`)
for remote views, `screencapture -l <windowID>` / `-R`. Driver sources are saved here (`axdrive-main.swift`,
`winid-main.swift`, compiled with `swiftc` to `/tmp/axd2`, `/tmp/winid`), plus a 25-line `axenabled-main.swift`
that prints `AXEnabled` for a control (the driver does not). Everything below is what was observed, not what
should have happened. **No source file was edited; no commit was made; the app was left running.**

**Headline: the subscription screen never appeared.** The store never answered this process — the
entitlement stayed `unknown` ("Checking with the App Store…") for the whole run — and in that state the app
is fully usable with no screen, no strip and no retry. Pressing "Restore purchases" raised Apple's real
"Sign in to your Apple Account" sheet, which shows the local StoreKit configuration was **not** in effect
for pid 9073. Steps 1–5 could therefore not be exercised as specified; what each step actually showed is
recorded below.

## Build under test

| Item | Value |
| --- | --- |
| Commit | `58abaf50` (branch `investigations-next`); subscription commit `5d92d52a`. Working tree: `Kalsmritikosh.xcscheme` modified (adds `--acceptance-case` enabled and `<StoreKitConfigurationFileReference identifier="../../StoreKit/Kalsmritikosh.storekit">`), the xcuserdata scheme plist, two `InfoPlist.xcstrings`, plus this evidence folder |
| Configuration | Debug, built by Xcode: `Contents/MacOS/Kalsmritikosh` 60 048 B **2026-10-31 08:14**, `Kalsmritikosh.debug.dylib` 218 064 704 B **08:14** |
| App | `/Users/shirshendusasmal/Library/Developer/Xcode/DerivedData/Kalsmritikosh-afuwpokhbetrmqerjbytctakqzot/Build/Products/Debug/Kalsmritikosh.app` |
| Process | `pgrep -fl MacOS/Kalsmritikosh` → exactly **pid 9073** `…/Contents/MacOS/Kalsmritikosh --acceptance-case -NSDocumentRevisionsDebugMode YES` at 08:25, 08:26, 08:50 (never a second instance; not launched, not quit by me). Xcode launch session ref `787f36c000`, state running; its console returned 0 lines for the whole run |
| Ledger | At 08:25 `lsof -p 9073` showed **no sqlite at all** except TipKit's `tips-store.db` (the app had no window and had not booted the ledger). After the window was opened (08:27): `…/Containers/ecosanskritiinnovation.Kalsmritikosh/Data/tmp/acceptance-case.sqlite` (fd 6u) + `-wal` (8u) + `-shm` (11u); re-read at 08:50: same three files, nothing else. No other ledger path was ever open, so ⌘Q was not pressed |
| StoreKit configuration | `StoreKit/Kalsmritikosh.storekit` (3 681 B, 07:51): `…trial14` "Legacy 14-day free trial" 0.0, `…unlock` "Legacy permanent unlock" 79.0, group with `…edition.monthly` 4.99 and `…edition.annual` 39.99, each `introductoryOffer paymentMode "free", subscriptionPeriod "P2W"`. Referenced by the (uncommitted) scheme. **Not in effect for pid 9073** — see step 5 |
| Screen / window | 1470×956 pt; window `[185,95 1100x720]`, window ID 177 |
| Owner archive | never opened; "Back to my archive", Erase, Forget, "Delete all my data", Online/cloud/API-key controls and Settings → Your data were not pressed. No purchase sheet ever appeared, so nothing was bought. "Manage subscription" was not pressed (opens an external Apple page). No Apple ID credential was entered anywhere |

Harness notes (not product defects):

1. The Claude command hook timed out twice (~10 and ~13 min: 08:2x and 08:33→08:46). The gaps in the
   timestamps are the harness.
2. The app's unified log could not be read from this shell (`log show --process 9073` returned nothing for
   any predicate, even the `kalsmritikosh` subsystem) and `ps eww` returned no environment, so whether
   `Product.products` threw or returned an empty list could not be seen directly; the behavioural evidence
   (step 5) is what this report rests on.
3. `screencapture -l` of the remote sign-in view (AuthKitUI XPC window) rendered a blank white rectangle;
   the region capture `-R 495,87,480,632` (06) shows it. The sheet is not in the app's AX tree; only
   hit-tests against pid 10386 reached it.

## Steps

| # | Step (brief) | Pressed (identifiers) | What appeared (exact on-screen text) | Screenshot | Result |
| --- | --- | --- | --- | --- | --- |
| 0 | State on arrival (08:25–08:27) | — | pid 9073 had been running since 08:14 with **no window at all**: `AXUIElementCopyAttributeValue(kAXWindows)` empty, `CGWindowList` showed only four 1470×33 menu-bar-sized entries, the main thread idle in `mach_msg2_trap`, frontmost app Xcode. `NSRunningApplication.activate()` (08:26) brought the app to front but opened no window. **File › New Window** (08:27) opened the window — title **"Home"**, `[185,95 1100x720]` — and only then did the ledger open. Who closed/never opened the first window is unknown (see Observations) | — | observation |
| 1 | First screen | File › New Window | Window **"Home"**. **No `purchase.screen`**, no `purchase.strip`, no `purchase.*` element anywhere in the tree (`find purchase.` → NOT FOUND, repeated at 08:27, 08:29, 08:31, 08:32, 08:46). Home content: "Investigations Made Easy" / "Your documents, worked by the professional's own SOP — cited, evidence-gated, to the real deliverable." / `home.startInvestigation` "Start an investigation", `home.resumeCase` "Resume a case", "Add your documents", "Ask a question", "Full guide" / "Pick the lens that fits your work — every path answers only from what you ingest." / four value chips incl. **"One plain plan" — "One edition, all nine personas, monthly or yearly. Cancel any time; your work stays readable and exportable."** / "Your tasks" (4 cards). Sidebar: "PERSONA · RESEARCHER", Cases, Professional Jobs, Competing Hypotheses, Insights ⌘4; GO TO Home / Ask ⌘1 / Projects / Files ⌘6 / Outputs / Settings ⌘9; indicator `AXProgressIndicator` "Getting search ready…, 0/9 · 0%" at 08:27, `AXButton` "Ready" from 08:30. Nothing said "The App Store did not return the plans…", so there was no "Try again" to press | 01-first-screen.png | **FAIL** — the never-bought profile was not shown the subscription screen; the window was fully usable |
| 2 | Select monthly / annual cards | — | Not possible: no plan cards exist in the window | — | **BLOCKED** (by step 1) |
| 3 | "Help" from the subscription screen | — | Not possible: the screen is absent. (Help itself is reachable from Home: "Full guide".) | — | **BLOCKED** (by step 1) |
| 4 | `purchase.subscribe` → StoreKit test sheet | — | Not possible: no `purchase.subscribe`. No purchase sheet of any kind appeared during the run; nothing was bought | — | **BLOCKED** (by step 1) |
| 5a | Settings → Subscription | sidebar "Settings, ⌘9" → disclosure "Subscription" (08:29) | Group **"Subscription"** (icon `creditcard`): `settings.subscription.status` = **"Checking with the App Store…"**; text **"One edition with all nine personas, monthly or annual, same access either way. Eligible new subscribers get a 14-day free trial, after which the chosen plan renews automatically unless cancelled at least a day before. Your cases stay readable and exportable whatever the subscription state; backup, recovery, Help, privacy and erasure never need one."**; buttons **"Restore purchases"**, **"Manage subscription"** (help "Opens your Apple Account's subscription page to change the plan or cancel. Cancel at least a day before the period ends to avoid the next charge."), link **"How to cancel (Apple)"**; footer **"Payment, renewal, refunds and restore are handled by Apple; the app never sees payment details and subscribing turns nothing else on (not Online mode). The subscription applies on the Macs signed in with your Apple account; your archive is not copied between them."** Status re-read at 08:29:04, 08:31:05, 08:32:35, 08:46:06 (19 min after the window opened): still **"Checking with the App Store…"** | 02-settings-subscription-checking.png | **FAIL** against the expected "Free trial until <date>; …" — but the layout, texts and three controls are present as specified |
| 5b | "Restore purchases" (pressed once, 08:31:34, to make the store answer) | Settings `AXButton` "Restore purchases" | Inside the app: nothing changed — status still "Checking with the App Store…", no message, no sheet in the app's AX tree. On screen, over the app window: a 480×632 window (ID 208, layer 8) owned by **pid 10386 `AKAuthorizationRemoteViewService.xpc` (AuthKitUI)** — Apple's **"Sign in to your Apple Account" / "Sign in to Apple Media Services using your Apple Account. Don't have an account? You can create one for free."**, e-mail field pre-filled with the Mac's Apple Account address, "Forgot Password", iCloud association notice, buttons **"Cancel"** / **"Sign In"** (region capture 06). Nothing was typed; Sign In was not pressed. The sheet had **closed by itself** when the harness returned at 08:46 (window 208 gone, hit-test −25208, pid 10386 still alive); my guarded Cancel press therefore never fired. A real-App-Store sign-in prompt from `AppStore.sync()` means the local StoreKit configuration was **not applied to this process** — with a `.storekit` file in effect, sync completes without an Apple ID prompt | 06-apple-account-sheet-region.png | **observation** — diagnoses step 1; also F-3 below |
| 6a | Start an investigation (paid action) | toolbar `house` → `home.startInvestigation` → card "Compliance / HR Investigator" (frame 448,241,241,63) → title field `setsel` "Sub check" → "Start matter" (08:47) | Screen "Professional Jobs" → matter **"Sub check"**; `jobs.progress.resolved` "0 of 16 jobs resolved"; `jobs.progress.summary` "0 completed · 16 not started"; `jobs.recommendations` "Rate the complaint and decide whether to investigate, decline or refer it." / "No documents are in this case yet. Add the sources the investigation covers."; `jobs.scope.summary` "Documents: 0 in scope · nothing new in the workspace"; `jobs.scope.review` "Review new documents"; banner **"Created case "Sub check" (rev 1) with 0 source(s) in scope — nothing is in scope yet: add documents to this workspace (Projects → Add sources…), then come back and use “Review new documents” to bring them into the case; until then every job will report that the case has no documents."** No paywall sheet. | 07-matter-sub-check-started.png | **PASS (as a paid action running)** — but it ran under the `unknown` entitlement, not under a trial: the brief's "allowed during the trial" was not what was tested |
| 6b | Files → "Add Folder…" | sidebar "Files, ⌘6" → `axenabled` | Screen "Sources": "10 file(s) ingested" · "Evidence-ready" · "Needs attention" · `sources.live.failed` "1 could not be read — see Needs attention" · "Ready" · Folders · "Needs attention — 1 file(s) could not be read" (scan-receipt-unreadable.pdf). `AXButton` **"Add Folder…" enabled=1**, "Ingest All" enabled=1. Not pressed (would open a picker). | 08-files-add-folder.png | **PASS** (enabled) — same caveat: under `unknown`, not under a trial |
| 7 | Expiry / read-only state | — | **Not exercised** in this run (no transaction existed to expire; Xcode's StoreKit transaction manager is not reachable from here). The read-only strip, the "Your work is safe and readable — subscribe to keep editing" sheet and the paid-action refusal remain unverified through the UI | — | not run |
| 8 | Leave running; evidence folder | — | App left running as pid 9073 on the acceptance ledger (08:50). Folder listing below. | — | done |

## Defects found (run f)

| ID | Severity | Where | What was observed | Why it matters | Evidence |
| --- | --- | --- | --- | --- | --- |
| **F-1** | **High** | `PurchaseGate` / `PurchaseCenter` (`Kalsmritikosh/UI/PurchaseGate.swift:47`, `Kalsmritikosh/App/Store/Purchase.swift:89,172,389–393`) | A profile that has never bought anything, whose store does not answer (no products loaded), gets the **entire app with no subscription screen, no strip, no retry and no time limit**: `entitlement` stays `.unknown` ("Checking with the App Store…" for 19+ min), `.unknown.allowsPaidUse == true`, and the whole-window screen is shown only for `.notStarted` (`gatesWholeWindow`). The paid action "Start matter" ran (6a); "Add Folder…" was enabled (6b). The screen's own "The App Store did not return the plans … Try again" copy can never be reached, because the screen that carries it is not shown in exactly the state it was written for. | The file header promises "when the store cannot be reached the screen says so and offers retry"; instead an unreachable store (offline Mac, blocked storefront, or — as here — product IDs that the store does not know) is a permanent free unlock for new installs. Also the instruction §11 ("the subscription screen covers the window before anything was bought") is not met whenever StoreKit is slow or absent. | 01-first-screen.png; 02-settings-subscription-checking.png; steps 1, 5a, 6a, 6b |
| **F-2** | Medium (test-environment) | Xcode launch of pid 9073 (scheme `Kalsmritikosh.xcscheme`, uncommitted `StoreKitConfigurationFileReference`) | The local StoreKit configuration was **not in effect** for the process under test: `Product.products(for:)` produced no offers for 19 min, and `AppStore.sync()` raised Apple's real "Sign in to your Apple Account … Apple Media Services" sheet (06), which a `.storekit`-backed session does not do. The subscription screen, the test purchase sheet, the strip and the Settings status therefore remain **unverified through the UI**. | Until Xcode runs the app with the configuration actually attached (Product › Scheme › Edit Scheme › Run › Options › StoreKit Configuration shows the file, then a fresh Run), none of steps 1–5 of the brief can be executed. Possible causes to check on the owner side: the scheme edit was saved after Xcode had loaded the scheme; the app was launched before the edit; or the reference path `../../StoreKit/Kalsmritikosh.storekit` does not resolve from the scheme's location. | 06-apple-account-sheet-region.png; step 5b |
| F-3 | Low | Settings → Subscription → "Restore purchases" (`SettingsView.swift:2271` area; `Purchase.swift:443–452`) | Pressing it gives **no feedback in Settings** in any outcome: `message` is rendered only on `PurchaseScreen`, and the "No active subscription or purchase was found…" text is set only when `!allowsPaidUse` (never under `.unknown`). The only visible result was Apple's sign-in sheet; after it closed, Settings looked exactly as before and the status still said "Checking with the App Store…". | A person who restores from Settings cannot tell whether anything happened or failed. | 02 (before = after); step 5b |
| F-4 | Low (observation, cause unknown) | App launch by Xcode (08:14) | The process ran for 13 min with **no window**; activation did not create one; File › New Window did. The ledger was not opened until the window existed. | If the first window can fail to open on launch (or is closed and not restorable by activation), a person launching from the Dock sees nothing happen. Not reproduced in this run (the app must not be relaunched here), so recorded as an observation. | step 0 |

## Status of the brief's expectations

| Brief step | Expected | Observed | Status |
| --- | --- | --- | --- |
| 1 first screen = `purchase.screen` with prices, cards, `purchase.subscribe` "Start 14-day free trial", `purchase.disclosure`, links, three always-available buttons | screen covers the window | Home; no `purchase.*` element | FAIL (F-1 + F-2) |
| 1 alt: "Try again" when plans missing | shown, press once | never shown (screen absent) | FAIL (F-1) |
| 2 monthly/annual switch | price switches | no cards | BLOCKED |
| 3 Help reachable before purchase | Guide opens | no screen to press it on | BLOCKED |
| 4 test purchase → `purchase.strip` "Free trial: 14 day(s) left. …" | strip appears | no purchase possible | BLOCKED |
| 5 `settings.subscription.status` "Free trial until <date>; …" + texts + 3 controls | as listed | "Checking with the App Store…"; texts and controls present verbatim | PARTIAL (controls/texts PASS, status FAIL) |
| 6 paid action allowed during trial; Add Folder… enabled | allowed | allowed and enabled — under `unknown`, not a trial | PASS with caveat |
| 7 expiry not exercised | record | recorded | — |
| 8 app left running; folder listed | — | pid 9073 running on `acceptance-case.sqlite`; listing below | done |

## Observations (not defects)

- The Home value chip already carries the subscription wording: "One plain plan — One edition, all nine personas, monthly or yearly. Cancel any time; your work stays readable and exportable." (01).
- Settings also showed "Self-check found issues 13/15 checks · all formats" and the "Model won't run well — No reasoning model available — enable Local GGUF runtime for full quality answers." banner (02) — unrelated to this brief, unchanged from earlier runs.
- The Settings AX tree exposes the Online-provider fields (`https://api.openai.com/v1`, `gpt-4o-mini`, a secure field) under Advanced; none was touched.
- "PERSONA · RESEARCHER" and the sidebar order carry over from preferences as in runs c–e.
- The `--acceptance-case` ledger had 10 files ingested (9 searchable, 1 unreadable PDF) exactly as run e left it; "Add Folder…" was not pressed, so nothing was added.

## Evidence folder

```
01-first-screen.png                      Home at 08:27 — no subscription screen (window 177)
02-settings-subscription-checking.png    Settings › Subscription: "Checking with the App Store…" (08:30)
06-apple-account-sheet-region.png        Apple "Sign in to your Apple Account" sheet after Restore (08:33, region 495,87 480×632)
07-matter-sub-check-started.png          Professional Jobs: "Sub check" created under the unknown entitlement (08:47)
08-files-add-folder.png                  Sources: "Add Folder…" enabled (08:47)
axdrive-main.swift · winid-main.swift · axenabled-main.swift   driver sources (compiled to /tmp)
JOURNEYS.md                              this record
```

## Summary

On `58abaf50` the new subscription screen could not be verified: the process Xcode launched (pid 9073) never
received an answer from StoreKit — `settings.subscription.status` read "Checking with the App Store…" from
08:27 to 08:46 — and in that `unknown` state the app shows no subscription screen, no strip and no retry while
allowing every paid action (a matter was created; "Add Folder…" was enabled). That is a product defect (F-1,
High): an unreachable store is an unlimited free unlock for a new install, and the screen's own "Try again"
path is unreachable. Separately, the local StoreKit configuration was not in effect for this launch — "Restore
purchases" raised Apple's real Apple-Account sign-in sheet (F-2) — so steps 1–4 and the status in step 5 are
BLOCKED, not failed on their copy. Of what could be seen, the Settings › Subscription texts and its three
controls match the specification verbatim. "Restore purchases" in Settings gives no feedback (F-3). The app
had also been running for 13 minutes with no window until File › New Window (F-4, observation). No source was
edited, nothing was committed, no purchase was made, no credential was entered, and the app is still running
on the disposable acceptance ledger.
