# CLAIMS_APP.md — the claims registry's second and third renderings (RC-7 / P5-U1)

ONE claims discipline, three surfaces. The SITE surface lives in CLAIMS.md
(the audited `data-claim` id gate). This file registers the same discipline
for the other two renderings:

- **In-app claim strings** — load-bearing sentences the app itself shows.
- **App Store description sentences** — what the listing promises.

Rule: every row's verbatim fragment must occur in its named source file.
`ci/guards/app-claims-coverage.sh` verifies on every push; a fragment that
drifts (reworded, deleted) FAILS CI until the row is updated in the same
change — copy and registry move together or not at all.

## In-app claim strings

| Claim ID | Verbatim fragment in the app | Source |
|---|---|---|
| app.unreadable-honest | `recorded honestly — never faked` | Kalsmritikosh/UI/GuideContent.swift |
| app.ocr-incomplete | `extraction may be incomplete` | Kalsmritikosh/UI/CompletenessView.swift |
| app.evidence-only-state | `still answers every question from your evidence` | Kalsmritikosh/UI/OnboardingView.swift |
| app.private-mode | `Fully private (no AI)` | Kalsmritikosh/UI/SettingsView.swift |
| app.twin-badge | `Independent AI reading agreed.` | Kalsmritikosh/Brain/ComposeTwin.swift |
| app.q0-refusal | `Kalsmritikosh answers only from your ingested documents` | Kalsmritikosh/Brain/QuestionShapeRouter.swift |

## App Store description sentences

| Claim ID | Verbatim fragment in the listing | Source |
|---|---|---|
| asc.private-on-device | `private, on-device workspace` | release/APP_STORE_LISTING.md |
| asc.honest-refusal | `it tells you honestly` | release/APP_STORE_LISTING.md |
| asc.cited-answers | `answers come with clickable citations` | release/APP_STORE_LISTING.md |
| asc.on-device-ai | `Apple's on-device intelligence` | release/APP_STORE_LISTING.md |
