# UI journeys — subscription screen with live local products, Help, onboarding (§6, §11) — 2026-10-31 (run h)

Build: working tree at `9e3da0d6` plus the read-only-window change (`gateDismissedThisLaunch`, Help / Backup &
recovery / "Look around first" on the leading subscription screen), Debug, built 11:20. Launched **from the shell**
(`open -n -a <DerivedData>/Build/Products/Debug/Kalsmritikosh.app --args --acceptance-case`, pid 21428), not from
Xcode — and in that launch the **StoreKit local testing environment was in effect**: the plan cards showed the
configuration's products. Ledger: `lsof` showed only `…/Containers/…/Data/tmp/acceptance-case.sqlite` (the disposable
acceptance ledger); the owner's archive was never opened. Exactly one instance for the whole run; quit with ⌘Q at the
end. Method as runs d–g (Accessibility API driver `/tmp/axd2`, `screencapture -l`). 36 files in this folder
(`NN-*.png` screenshots, `NN-*.txt` AX dumps). The run was performed by a sub-agent from a written step list; the
findings below are its observations, checked against the dumps.

## Before the run: a phantom subscription (H-0)

The first launch after the in-process StoreKit tests (`PurchaseStoreKitTests`) showed **Settings ▸ Subscription:
"Annual plan, renews 31 Oct 2027"** with no purchase ever made (`00-settings-subscription-annual-without-purchase.png`).
Cause, established by experiment: the local StoreKit testing environment keeps its transactions per app bundle, the
last test had left an annual purchase in it, and a Debug launch of the same bundle reads that environment. Running one
test whose session clears transactions and relaunching brought the subscription screen back (products present, state
"Not subscribed."). Fix in this commit: every StoreKit test clears its transactions when it ends. This cannot happen to
a customer (no test environment on their Mac); it is recorded because it would mislead anyone checking a Debug build.

## What was verified (verbatim from the AX dumps)

| Step | Pressed | Observed | Files |
| --- | --- | --- | --- |
| 1 First screen | — | `purchase.screen` with `purchase.plan.monthly` "Monthly plan, $4.99 per month, 14-day free trial", `purchase.plan.annual` "Annual plan, $39.99 per year, 14-day free trial", `purchase.subscribe` "Start 14-day free trial", `purchase.disclosure` "14 days free, then $39.99 per year. Renews automatically at $39.99 per year unless cancelled at least a day before the period ends. Manage or cancel through your Apple Account.", links "How to cancel a trial or subscription (Apple)", "Restore purchases", "Manage subscription", "Terms", "Privacy", buttons "Try a sample case", `purchase.help`, `purchase.backup`, link `purchase.lookAround` "Look around first (read-only)" | 01-* |
| 2 Monthly plan | `purchase.plan.monthly` | subscribe "Start 14-day free trial"; disclosure "14 days free, then $4.99 per month. Renews automatically at $4.99 per month unless cancelled at least a day before…"; back to annual restores the $39.99 text | 02-* |
| 3 Help before purchase | `purchase.help` | the screen gives way; window "Guide": `help.guide`, `help.search`, `help.replayTutorial`, `help.replayIntro`, "Support", topic rows (`help.topic.get-started` expanded with steps 1–10, two notes, "Open Professional Jobs"); strip `purchase.strip` **"No subscription yet. Reading, Help, the sample case and backup work; subscribe to add documents, run jobs and ask."** + "See plans" — exact | 03-* |
| 4 Help search | type `export` in `help.search` | "20 topics", "Clear search", `help.topic.task-review-approve-export` "Review, approve, redact and export" expanded with its five steps and "Open Cases"; clearing restores 164 topics | 04-* |
| 5 Persona recipe | expand "Recipe for a Forensic Accountant" | 19 steps starting "Open Professional Jobs and choose “Forensic Accountant”; press “Start matter”…", "Press “Add documents to this case” and confirm the scope preview…", "Run “Engagement intake”: …"; note "Professional limits: A matching amount is a candidate, not a finding; the app never labels a transaction fraudulent. Amounts are not converted between currencies; balances follow only the rows you include." and "…job documentation of the 16 jobs this profession ships with…" | 05-* |
| 6 Help menu | menu bar ▸ Help | items in order: "Investigations Made Easy Help", "Get Started Guide", "Replay the Tutorial (Sample Case)", "Replay the Introduction", "Subscription, Trial and Cancelling", "Manage Subscription (Apple Account)…", "Support (Privacy-Safe Bug Reports)…", "Privacy Policy…" | 06-help-menu.png |
| 7 Introduction | Help ▸ Replay the Introduction | sheet "Welcome to Investigations Made Easy / From evidence to findings"; `onboarding.trySample`, `onboarding.startDocuments`, `onboarding.resumeCase`; the five bullets verbatim (Private by default…; Documents, email… never filled in; Ask a question or run a job… whether the document is right is your call; A 14-day free trial… export, backup and recovery keep working; Help is one keystroke away (⌘?)…). "Start with my documents" → "What are you investigating?" → Continue → "What this Mac can do": "This Mac has enough memory (16 GB) to read large archives and run the on-device AI comfortably. An AI model is ready, so answers and summaries can be phrased in prose. Scans are read by OCR and recordings are transcribed on this Mac; both take longer than text files." + "Technical details" disclosure; next step "Pick your first folder". Closed with Escape | 07-*, 08-* |
| 8 Settings ▸ Subscription | sidebar Settings, disclosure "Subscription" | `settings.subscription.status` "Not subscribed."; `info.subscription-plans` "Information about Plans, the free trial, renewal and cancelling"; "See plans", "Restore purchases", "Manage subscription", "How to cancel (Apple)". ⓘ → popover "Plans, the free trial, renewal and cancelling" with the registry text and "Open in Help" | 09-* |
| 9 Test purchase (local environment) | "See plans" → sheet (same screen + "Not now") → `purchase.plan.annual` → `purchase.subscribe` | **No StoreKit confirmation sheet appeared**; the purchase completed at once (the testing environment had `disableDialogs` set by the unit tests). After: status "Free trial until 14 Nov 2026; the annual plan then renews unless cancelled a day before."; Settings shows "Restore purchases", "Manage subscription" (no "See plans"); strip "Free trial: 14 day(s) left. It renews automatically unless cancelled a day before it ends." + "Manage subscription" | 10-*, 11-* |
| 10 Paid surface after purchase | sidebar Professional Jobs | "Choose a professional focus" (nine cards), "1 Start here — open a matter", "Start matter" disabled with help "Available when: Type a matter title first (a workspace is created automatically if you have none)", phases 2–5 with their jobs; nothing run | 12-* |
| 11 | ⌘Q | one instance throughout; process gone | — |

Not pressed (rules): Try a sample case, Restore purchases, Manage subscription, external links, Choose folder.

## Defects found and their state

| # | Finding | State |
| --- | --- | --- |
| H-1 | With the leading subscription screen over Home the window measured 1100×**5038** pt and the card sat at y≈2267 — below the display: the person saw only the blurred background (`01b-first-screen-display.png`). Height returned to 845 once the screen was dismissed; the sheet variant was fine | **fixed in this commit**: the whole-window screen is pinned to the window's size (GeometryReader) and scrolls inside it (the macOS 26 split-view sizing already noted for other surfaces) |
| H-2 | AXPress on a sidebar button behind the blurred screen changed the window (Home → Settings) while the screen stayed. AXPress bypasses hit-testing, so mouse clicks are still blocked | **fixed**: the blurred content is also `accessibilityHidden` while the screen leads |
| H-3 | Recipe titles "Recipe for a Investigator / a Insurance Fraud (SIU) / a Individual" | **fixed**: "Recipe — <profession>" |
| H-4 | No StoreKit confirmation sheet before the test purchase | environment artefact (`disableDialogs` persisted from the unit tests); Apple's sheet appears in Sandbox/production. Recorded, nothing to fix in the app |
| H-5 | Onboarding: "Pick your first folder" still carries "Try the sample archive" with its own wording beside the welcome step's "Try a sample case" | **adjusted**: that button now opens the sample with the tutorial too and its text no longer says "nothing is ever mixed" |
| H-6 | Hardware step: the spoken (AX) text paraphrased the visible text | **fixed**: the accessibility label is the visible title and body |
| H-7 | "all nine professions" (ⓘ popover) vs "all nine personas" (Settings, purchase header, Home) | **fixed**: the popover says "nine personas (the professions listed under “By profession”)" |
| H-8 | Settings ▸ Subscription shows "Subscription" as the group row and again as the section heading | existing pattern of every Settings group (e.g. "Your data"); left |
| H-9 | Settings showed "Model won't run well — No reasoning model available — enable Local GGUF runtime…" and "Self-check found issues 13/15" | the acceptance ledger has no model configured; unrelated to this run |
| H-10 | Menu bar title "Kalsmritikosh" | the Debug build's display name; `InfoPlist.xcstrings` is rewritten by local builds and restored before commit (known); the distribution build must be checked for "Investigations Made Easy" (release gate) |
| H-11 | An unnamed 500×500 window (id 1040) listed from step 7 on, nothing visible | not explained; to watch in the next run |
| H-12 | The orange "?" help badge overlaps the corner of "Start matter"; the sidebar lens label "PERSONA · RESEARCHER" differs from the selected profession card | cosmetic / the lens (sidebar) and the profession (jobs) are two settings by design; noted for the UI review |

## Still open after this run

- The tutorial itself in the sample case (run i), the Guide's Replay buttons and the ⓘ buttons on Record finding, Unmerge, Erase case, Add documents to this case, Online send — not yet seen through the UI.
- Apple's real purchase sheet, Sandbox and TestFlight matrix: owner.
