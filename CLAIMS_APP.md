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
| app.q0-refusal | `Investigations Made Easy answers only from your ingested documents` | Kalsmritikosh/Brain/QuestionShapeRouter.swift |
| app.gk-banner | `Not from your documents — general knowledge from the on-device AI` | Kalsmritikosh/Brain/GeneralKnowledgeLane.swift |

## App Store description sentences

| Claim ID | Verbatim fragment in the listing | Source |
|---|---|---|
| asc.private-on-device | `private, on-device case file` | release/APP_STORE_LISTING.md |
| asc.honest-refusal | `it tells you honestly` | release/APP_STORE_LISTING.md |
| asc.cited-answers | `answers come with clickable citations` | release/APP_STORE_LISTING.md |
| asc.on-device-ai | `Apple's on-device intelligence` | release/APP_STORE_LISTING.md |
| asc.evidence-only-default | `No AI writes your answers unless you turn it on.` | release/APP_STORE_LISTING.md |
| asc.judgement-human | `It organises, finds and documents` | release/APP_STORE_LISTING.md |
| asc.no-decision | `It organises and cites your evidence` | release/APP_STORE_LISTING.md |
| asc.english-only | `English only in this version.` | release/APP_STORE_LISTING.md |
| asc.trial-then-buy | `Try it free for 14 days, then buy it once` | release/APP_STORE_LISTING.md |
| asc.encrypted-at-rest | `the knowledge base is encrypted on` | release/APP_STORE_LISTING.md |
| asc.no-account | `There's no account, no sign-in, and no analytics.` | release/APP_STORE_LISTING.md |
| asc.private-by-default | `By default your files and questions` | release/APP_STORE_LISTING.md |
| asc.consent-before-send | `exactly what would be sent before anything leaves your Mac` | release/APP_STORE_LISTING.md |

What each App Store row rests on (R-2, App Review 2.3.1, 2026-10-24). The ids are backticked so
`ci/guards/app-claims-coverage.sh` does not read these as fragment rows.

| Claim | Evidence |
|---|---|
| `asc.evidence-only-default` | `EvidenceOnlyRelease.enforced` = `!aiEnabled` with `aiEnabled` absent = off (Kalsmritikosh/Routing/EvidenceOnlyRelease.swift); toggle "Use AI to write answers" (Kalsmritikosh/UI/SettingsView.swift); SHIP_DECISIONS 2026-10-24 (1)–(2). No unit test pins the default (the test host keeps stored behaviour by design). |
| `asc.judgement-human` / `asc.no-decision` | SHIP_DECISIONS 2026-10-23 (4) and (6); the case report states "judgement stays with the investigator" (test:documentsAndLog in KalsmritikoshTests/CaseFileTests.swift). |
| `asc.english-only` | SHIP_DECISIONS 2026-10-23 (2). |
| `asc.trial-then-buy` | Products `…trial14` and `…unlock`, `familyShareable: true` (StoreKit/Kalsmritikosh.storekit); Kalsmritikosh/App/Store/Purchase.swift; test:trialThenBuy (KalsmritikoshTests/PurchaseTests.swift); SHIP_DECISIONS 2026-10-18 (1). |
| `asc.encrypted-at-rest` | test:aKeyedLedgerIsEncryptedOnDisk (KalsmritikoshTests/LedgerEncryptionTests.swift); SHIP_DECISIONS 2026-10-15 (W2-7). |
| `asc.no-account` | Privacy label Data Not Collected (owner:OWNER_ACCEPTANCE_CHECKLIST.md); site row `privacy.no-servers` in CLAIMS.md. |
| `asc.private-by-default` | grep:return .privateMode:Kalsmritikosh/App/Modules/ConnectivityMode.swift (site row `privacy.online-opt-in`); main app has no network entitlement (ci/guards/release-configuration.sh). |
| `asc.consent-before-send` | grep:OutboundConsentSheet:Kalsmritikosh (site row `privacy.consent-before-send`). |
