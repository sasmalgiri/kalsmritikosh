# RELEASE_EVIDENCE_v1

_Release-evidence record (REL-006 / spec §9). Regenerated 2026-08-07 from current `main`
(release-closure macros B–F). Bracketed `[owner: …]` fields require an owner-run build / app
run / hardware / Apple account and must be filled before submission. Gate authority:
`RELEASE_EVIDENCE_INDEX.md` (per-gate states with hosted run ids) under `SHIP_DECISIONS.md`._

## Build identity

| Field | Value |
|---|---|
| git SHA | current `main` after PRs #70–#74 _(update to the tagged release commit at archive time)_ |
| Schema version | **v102** (`SchemaMigrations.latestVersion`) |
| App version / build | `[owner: e.g. 1.0 (1)]` |
| Xcode / macOS SDK | `[owner: e.g. Xcode 26.x / macOS 26 SDK]` |
| Minimum OS | **macOS 15.6, capability-adaptive (GOV-004)** — `MACOSX_DEPLOYMENT_TARGET = 15.6` uniform, CI-enforced by `ci/guards/release-configuration.sh`. Foundation Models runtime-gated; macOS 15.6–25 runs honestly deterministic-only. |
| Test hardware | `[owner: model, chip, RAM]` |
| Reasoning model | Apple Foundation Models (on-device) where available; deterministic engine otherwise. No bundled/third-party LLM in release. |
| Embedding model | Bundled BGE-small-en-v1.5, 384-dim Core ML (NLEmbedding remains the labelled degraded fallback) |

## Release provider matrix (directive §6)

| Provider | Debug | Release | Network | Ship status |
|---|---|---|---|---|
| Apple Foundation Models (on-device) | as supported | yes (macOS 26+ hardware) | no | shipping |
| Deterministic evidence engine | yes | yes | no | shipping |
| BGE-small Core ML embedder | yes | yes | no | shipping |
| Ollama (localhost daemon) | internal only (`#if DEBUG`; probe + registration + install path all gated — macro B) | no | yes (local) | non-shipping |
| MLX provider | internal only | no | — | intentional stub |
| LlamaCpp provider | compiled, never available | no | — | intentional stub |
| Cloud providers | internal only | no | yes | non-shipping |

Enforcement is at the capability level (registration gated in AppState), not UI hiding; the
Release build additionally has the **outgoing-network sandbox entitlement disabled**, and
`ci/guards/release-configuration.sh` + the `release-build` CI check keep both facts true on
every push. `PrivacyInfo.xcprivacy` declares "Data Not Collected" and names no network path.

## Test results (hosted actuals)

| Suite | Result |
|---|---|
| Whole suite (`build-and-test`) | **total=3389, passed=3387, failed=0, skipped=2** (PR #73 run 31170924940; floor 3389 in `ci/test-baseline.json`) |
| Migration matrix (named check) | green, floor 375 (fresh→latest, historical→latest, reopen, double-migration, rollback, fk/integrity checks) |
| Parser fixtures (named check) | green, floor 126 — every advertised structural format has a dedicated fixture suite (gate F1) |
| Sensitive export (named check) | green, floor 122 (S2 PASS) |
| Report/receipt integrity (named check) | green |
| Architecture guards | 8 green, incl. `release-configuration` and `persona-neutral-truth` |
| Release build (named check) | green — the TRUE Release configuration compiles on every push (first proven in macro B) |
| Citation integrity (gate F3) | CitationResolverTests (11) + EvidenceVerifierCitationIntegrationTests (4), hosted PR #71 |
| Redaction (gate S3) | ReleaseSecurityGateTests — output-representation level incl. PDFKit page-text extraction; citation-leak fails closed; visual source-document redaction is NOT claimed (RED-002 out of v1) |
| Archive hardening (gate S6) | ContainerSafetyTests + ContainerIngestIntegrationTests (traversal/budgets/bombs/encrypted/cycles/zero-byte) |
| Truth gates (T1/T3) | CrossPersonaTruthInvarianceTests + DuplicateSourceIndependenceTests + persona-neutral-truth guard (PR #74) |

## Gold metrics

**Deterministic-layer retrieval floor (hosted test `RetrievalGoldEvalTests`, fresh Tier-0/1
ingest of ProjectDelta, NO Tier-2 enrichment, no LLM — measured 2026-08-07 on current main):**

| Class | Recall |
|---|---:|
| lookup | 0.667 |
| aggregation | 0.133 |
| temporal | 0.233 |
| multihop | 0.322 |
| **overall (n=60)** | **0.339** |

Interpretation: this is the floor a JUST-INGESTED corpus answers from before background
enrichment; the pinned CI floors sit slightly below these values and may only be raised.

**Full-pipeline retrieval baseline (historical in-app run, Tier-2 enriched, commit 3e8d57e):**
lookup/aggregation/temporal/multihop all at recall 1.000 (n=60) — retrieval is not the
bottleneck on the enriched corpus. `[owner: re-record on the release build during acceptance]`

**Answer-citation metrics (LLM-bound):** historical fast-subset run: recall 1.00 across classes,
citation precision 0.33–0.50. `[owner: run the FULL 60-question answer eval in-app on target
hardware (SmokeTest T12 harness / EvalKitRunner) and record per-class metrics — per-question LLM
latency makes this an owner/hardware run]`

## Large-corpus metrics (SCL-001…004)

`[owner: record ingest time + first-search latency + Fast latency + Full Evidence latency +
peak memory + DB/index size at the target corpus size on the test hardware; the store
"tested to N GB" figure comes from THIS run and nothing else (SC1/SC2)]`

Scale-strategy note: v1 ships the in-memory HNSW index only; disk-backed/sharded ANN (P9.3)
is not implemented. Gate 8 scope needs an explicit owner decision: implement P9.3, or supersede
it with tested-figure-only marketing (GOV-00x entry in SHIP_DECISIONS).

## Privacy / security results

- Release build has the **outgoing-network entitlement disabled** and registers **no network
  provider** (capability-level gating, macro B). `[owner: run the prepared network-egress
  procedure on the release binary to physically confirm zero egress]`
- `PrivacyInfo.xcprivacy` present, "Data Not Collected", no Ollama/network references (guard-enforced).
- Temporary-artifact hygiene proven (gate S4); archive/malformed-file hardening proven (gate S6);
  redaction fail-closed at output level (gate S3); prompt-injection guard (S5) and SensitiveScope
  cross-surface enforcement (S2, 122 tests) hosted-green.

## Clean-machine result (REL-002)

`[owner: run CLEAN_MACHINE_ACCEPTANCE.md on a Mac that never had Xcode/the app; include one
macOS 15.6–25 machine if available to witness the honest deterministic-only mode (GOV-004)]`

## Known limitations (v1)

- Audio/video recognized but not transcribed (deferred by design).
- PPT/PST/OST/MSG/NSF remain unsupported; RAR/7z recognized with custody preserved and an
  explicit honest-unsupported manifest (never silently empty).
- Optional downloaded local GGUF models deferred to v1.x (GOV-001).
- Advertised scale is the recorded owner-tested figure only (SC1/SC2).
- Source-document visual/binary redaction is not a v1 capability (RED-002); generated-export
  redaction is verified fail-closed.
- On macOS 15.6–25 the app is deterministic-only (no on-device generation) — honest mode,
  GOV-004.

## Owner sign-off

- [ ] `[owner]` I have run the app on target hardware and completed the full journey.
- [ ] `[owner]` Gold + large-corpus metrics recorded above.
- [ ] `[owner]` Privacy egress audit clean on the release binary.
- [ ] `[owner]` Store copy matches this binary (no over-claims).
- [ ] `[owner]` Five persona acceptance journeys recorded (RELEASE_EVIDENCE_INDEX §E).
- [ ] `[owner]` Signed archive builds and validates in App Store Connect.

Signed: `[owner name / date]`
