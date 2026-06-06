# EvalKit

T12 — Eval harness for Gate 1. Walks a bundled `questions.json` through
`MasterBrain` and emits `eval-report.md` with per-class metrics:
keyword-hit rate, citation precision, retrieval recall, p50/p95 latency.

Targets (recorded as goals — not enforced yet):

- lookup citation precision ≥ 0.9
- temporal answers carry non-empty coverage with named gap labels
- aggregation keyword-hit rate ≥ 0.8
- multi-hop retrieval recall ≥ 0.6

## Files

- `Kalsmritikosh/EvalKit/EvalKitRunner.swift` — the runner. Exposes
  `run(brain:outputDir:)` (live brain) and `runOffline(outputDir:)`
  (deterministic stand-ins from question metadata, for environments
  where `MasterBrain` isn't available).
- `Kalsmritikosh/Resources/Eval/questions.json` — the bundled question
  set. The 16 shipped questions hit every class (lookup, aggregation,
  temporal, multihop) over the in-tree `Resources/Fixtures/ProjectDelta`
  corpus.

## How to run

From the in-process smoke test (the path the T12 acceptance uses):

```swift
let runner = EvalKitRunner()
let url = try runner.runOffline(outputDir: outputDir)
// or, with brain wired:
// let url = try await runner.run(brain: appState.brain, outputDir: outputDir)
print("Report at \\(url.path)")
```

From a debug menu / future CLI scheme, call the same APIs.

## Adding the Enron-scale corpus (operator instructions)

Do NOT vendor any Enron data into the repo. Instead:

1. Download an Enron maildir tarball (e.g. CALO project's mirror — verify
   licence terms for redistribution; this repo only points at the data,
   never bundles it).
2. Untar into a local directory, e.g. `~/Corpora/enron-skeleton/`.
3. Pick a subset (e.g. one to five users) and copy or symlink it into
   the project's working ingestion roots from the **Sources** UI.
4. Author additional questions in `questions.json`. Each question MUST
   carry `expectedKeywords` and `expectedSourceFiles` so the metrics
   are reproducible across runs.
5. Re-run the smoke test (or the future eval CLI). Compare
   `eval-report.md` files across runs to confirm ±5% reproducibility.

## Roadmap

- [ ] Expand `questions.json` to 60 entries (15 per class) once an
  Enron-subset is wired locally.
- [ ] SPM executable target (`evalkit/Package.swift`) once the app
  splits Knowledge OS into a SwiftPM library so the runner can run
  outside of Xcode.
- [ ] Threshold enforcement in CI once two consecutive runs land
  inside the ±5% reproducibility envelope.
