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

## Stronger-reasoning model trial (G2-4)

Gate 1's LLM-on baseline is `llama3:latest` (8B, Q4_0). Aggregation
keyword-hit doubled (0.25 → 0.50) but is short of the 0.8 target. This
is a model-ceiling question, not a code question — so the trial path is
operational: pull a stronger model, rerun the eval, save a new report,
and compare side by side. The architecture invariant keeps the model
name confined to `Kalsmritikosh/App/`, so only one line changes.

### Procedure

1. Pull the candidate model on the host where `ollama serve` is
   running:

   ```sh
   ollama pull qwen2.5:14b
   # or whatever larger model fits the user's RAM / disk budget.
   # The 14B class needs ~10 GB free; pick smaller for tight machines.
   ```

2. Point the Ollama provider at the new tag — edit
   `Kalsmritikosh/App/AppState.swift` (search for `modelTag:` — there
   is exactly one site, currently `"llama3:latest"`). Update both the
   `modelTag:` and the `displayName:` strings:

   ```swift
   await capabilities.register(OllamaProvider(
       modelTag: "qwen2.5:14b",
       embeddingModelTag: "nomic-embed-text",
       enabled: true,
       displayName: "Local Ollama (qwen2.5:14b)",
       tier: .medium
   ))
   ```

   No other code changes. Capability discipline means the experts and
   the brain stay model-agnostic — only this one provider registration
   names a tag.

3. Build the app and let `MasterBrain` boot once so the registry
   resolves the new tag against its `isAvailable()` probe.

4. Re-run the eval. From the in-app SmokeTest or a debug menu:

   ```swift
   let runner = EvalKitRunner()
   let url = try await runner.run(brain: appState.brain,
                                  objects: appState.objects,
                                  outputDir: outputDir)
   ```

5. Save the produced `eval-report.md` next to the previous trial,
   renamed by model:

   ```sh
   cp /tmp/eval-report.md ./eval-report-llm-qwen2.5-14b.md
   ```

   The naming convention is `eval-report-llm-<model-tag-with-dots-as-dashes>.md`
   so the repo can hold a column per trialed model.

### macOS 26 / Apple Intelligence path

`FoundationModelsProvider` carries a `#available(macOS 26.0, *)` gate.
On macOS 26 hosts the provider becomes eligible automatically and the
registry will rank it alongside the Ollama provider; no `modelTag`
swap is needed for the Apple model. To trial Apple-only, disable
the Ollama provider (`enabled: false`) for the run.

### Reading the reports

- Each report carries per-class metrics (lookup, aggregation,
  temporal, multihop) and a per-question detail table. The
  aggregation keyword-hit rate is the metric most sensitive to model
  reasoning depth — that's the row to watch.
- The targets at the top of the report are **goals, not lock-in**.
  Additional rows from new trials are evidence of model ceilings, not
  new Gate 1 targets. The lock stays.
- Compare across reports by diffing the per-class table. A real win
  needs both ≥10pp keyword-hit gain AND no regression on citation
  precision — a model that gets more answers right but cites the
  wrong files isn't actually stronger.

### Reproducibility

Same model, same Ollama server, same fixture corpus → reports should
land within ±5% on each metric. If they don't, the brain is leaking
state across questions (check `await brain.resetSession()` in
`EvalKitRunner.run(_:_:)`).

## Roadmap

- [ ] Expand `questions.json` to 60 entries (15 per class) once an
  Enron-subset is wired locally.
- [ ] SPM executable target (`evalkit/Package.swift`) once the app
  splits Knowledge OS into a SwiftPM library so the runner can run
  outside of Xcode.
- [ ] Threshold enforcement in CI once two consecutive runs land
  inside the ±5% reproducibility envelope.
