# KalsmritikoshTests — pre-submission test scaffolding

These tests are written against the Swift Testing framework (`@Test`
macros, the Xcode 16+ default) and target the pure-logic surface that
doesn't require a running app, ledger, or LLM provider.

## How to wire them into Xcode

1. In Xcode, **File → New → Target… → macOS → Unit Testing Bundle**.
2. Name it `KalsmritikoshTests`. Pair it with the `Kalsmritikosh`
   app target.
3. Drag the `KalsmritikoshTests/` folder into the new target.
4. In each test file, ensure the test target is selected in the
   File Inspector (right pane).
5. **Run with ⌘U.**

The tests are intentionally `@testable import Kalsmritikosh` —
they reach into module-internal types (the actor counters, the
classifier rules, etc.) so the suite verifies real behaviour, not
just the public surface.

## Pre-submission gate

These run in addition to the existing in-app SmokeTest and EvalKit:

| Suite | Triggered | Pass criterion |
|---|---|---|
| `KalsmritikoshTests` (this directory) | every commit | all `@Test` functions green |
| `SmokeTest` (in-app) | every release | ProjectDelta fixture ingest succeeds; ≥1 chapter rendered |
| `EvalKitRunner` (in-app) | every release | lookup precision ≥ 0.85, multi-hop recall ≥ 0.55 |
| `NarrativeEvalKit` (in-app) | every release | confidence RMSE ≤ 0.20 |
| `GroundTruthEvalKit` (in-app) | every release | Entity F1 ≥ 0.80, Event F1 ≥ 0.70, Timeline ≥ 0.95 |

CI workflow (TODO — not yet wired): `xcodebuild test -scheme Kalsmritikosh
-destination 'platform=macOS' KalsmritikoshTests`. If the suite fails
the build is rejected before notarization.
